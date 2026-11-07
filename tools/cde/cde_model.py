"""Normalisation, aggregation, scoring and uncertainty for the CDE.

The formula, in full:

    s_{w,d} = sum_f beta_{d,f} * x_{w,f}                     raw window demand
    R_d     = (1 - lambda_d) * mean_w(s_{w,d}) + lambda_d * Q90_w(s_{w,d})
    A_d     = percentile of R_d against the frozen reference for dimension d
    D       = sum_d w_d * A_d + sum_(i,j) v_ij * A_i * A_j

Design notes, each one bought by a measurement on the reference corpus:

* Normalisation is by **percentile against a frozen reference**, not by
  z-score. Z-scores compressed most books near zero and let whichever
  dimension had the heaviest tail dominate the total. Percentiles make every
  dimension's between-book spread comparable, which is what equal weights
  assume.
* Normalisation happens **once, at book level**, not per window. Per-window
  normalisation nearly cancelled out in the mean.
* `lambda` mixes the book's average passage with its 90th percentile, so a book
  that is easy except for four brutal chapters scores differently from a book
  that is uniformly moderate.
* Interaction terms exist in the schema and are **empty by default**. There are
  no human grades, so there is no evidence that would justify a non-zero `v`.

Nothing here is a validated accuracy claim. See PHASE-3-VALIDATION.md.
"""

from __future__ import annotations

import bisect
import math
import random
import statistics

# Canonical identity. One model, one name — cite these symbols instead of
# inventing a handle per document.
#
#   engine  = CDE (Cognitive Difficulty Engine) — the instrument
#   formula = ADF (Asterisma Difficulty Formula) — the model it computes
#   output  = D, a text-demand index in [0, 1]
#
# The artifact string "cde-v0.3" written into existing evidence JSON is the
# legacy form of FORMULA_ID; both name this same model.
FORMULA_NAME = "Asterisma Difficulty Formula"
FORMULA_HANDLE = "ADF"
FORMULA_VERSION = "0.3"
FORMULA_ID = "asterisma-difficulty-formula@0.3"

DIMENSIONS = ("A", "B", "G", "H", "I", "K")

# v0.3 makes three changes, each bought by a measurement, not by taste:
#
# 1. Weights inside a dimension are equal. The v0.2 splits (0.55/0.25/0.20 and
#    friends) implied a precision no evidence supports and put most of a
#    dimension's weight on whichever feature happened to be listed first.
# 2. Three features left each dimension because they duplicate another feature
#    there (|r| >= 0.90 on 135 books: A_morph/A_abstract +0.954,
#    B_sentence/B_clause +0.951, I_content/I_np +0.905). Dropping them cost
#    nothing in reliability (0.0550 either way) and stops a dimension from being
#    one indicator wearing three names.
# 3. The peak operator is the 85th percentile rather than the 90th. At lambda
#    0.35 the three candidates scored, on median split-half disagreement:
#    peak85 0.0550, peak90 0.0617, cvar 0.0633 (cde_recalibrate.py). The margin
#    over Q90 is small and is not claimed to be significant; the 85th percentile
#    is also the less tail-dependent of the two.
DEFAULT_CONFIG = {
    "version": "cde-v0.3",
    "reference_version": "ref-v3",
    "peak_kind": "peak85",
    "reference": {},
    "dimensions": {
        "A": {"weight": 1 / 6, "lambda": 0.35, "reliability": "B",
              "label": "Lexical load",
              "features": {"A_oov": 0.50, "A_abstract": 0.50}},
        "B": {"weight": 1 / 6, "lambda": 0.35, "reliability": "B",
              "label": "Syntactic load",
              "features": {"B_clause": 1 / 3, "B_pronoun": 1 / 3,
                           "B_passive": 1 / 3}},
        "G": {"weight": 1 / 6, "lambda": 0.35, "reliability": "B",
              "label": "Entity interaction",
              "features": {"G_names": 0.50, "G_cooc": 0.50}},
        "H": {"weight": 1 / 6, "lambda": 0.35, "reliability": "B",
              "label": "Continuity and direction",
              "features": {"H_discontinuity": 0.40, "H_shift": 0.30,
                           "H_orphan": 0.30}},
        "I": {"weight": 1 / 6, "lambda": 0.35, "reliability": "B",
              "label": "Information density",
              "features": {"I_content": 0.50, "I_novelty": 0.50}},
        "K": {"weight": 1 / 6, "lambda": 0.35, "reliability": "B",
              "label": "Dialogue load",
              # Quote density is context, not difficulty: a children's book can
              # be 60% dialogue and still be easy. The difficulty-bearing parts
              # of dialogue are ambiguous attribution and speaker tracking.
              "features": {"K_tagless": 0.50, "K_speakers": 0.30,
                           "K_quote": 0.20}},
    },
    "interactions": [],
    "refusal": {"min_tokens": 5000, "min_windows": 3, "min_prose_share": 0.60},
    "labels": {"provisional": True, "bands": []},
}

GRID_POINTS = 101


def quantile(values, q):
    if not values:
        return 0.0
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    pos = q * (len(ordered) - 1)
    low = int(math.floor(pos))
    high = min(low + 1, len(ordered) - 1)
    frac = pos - low
    return ordered[low] * (1 - frac) + ordered[high] * frac


def peak_value(values, kind):
    """The high end of a window distribution, under one operator.

    `peak90` interpolates an order statistic; `cvar` averages the hardest tenth
    of the windows instead, which is less sensitive to a single window. Both are
    bounded by the maximum, which is never used: at twelve windows the maximum is
    one noisy observation.
    """
    if kind == "peak85":
        return quantile(values, 0.85)
    if kind == "peak90":
        return quantile(values, 0.90)
    if kind == "cvar":
        ordered = sorted(values, reverse=True)
        k = max(1, int(math.ceil(0.10 * len(ordered))))
        return sum(ordered[:k]) / k
    raise ValueError(f"unknown peak operator: {kind}")


def window_aggregate(values, lam, kind="peak90"):
    """Collapse per-window demands into one book-level demand.

    `lam = 0` is the plain average and `lam = 1` is the peak operator alone.
    """
    if not values:
        return 0.0
    base = sum(values) / len(values)
    if lam <= 0:
        return base
    return (1 - lam) * base + lam * peak_value(values, kind)


def raw_dimension(windows, config):
    """Raw (un-normalised) demand per dimension, from a window feature list."""
    out = {}
    kind = config.get("peak_kind", "peak90")
    for dim, spec in config["dimensions"].items():
        per_window = []
        for w in windows:
            total, weight_sum = 0.0, 0.0
            for feature, beta in spec["features"].items():
                if feature in w:
                    total += beta * w[feature]
                    weight_sum += beta
            if weight_sum:
                per_window.append(total / weight_sum)
        if not per_window:
            continue
        lam = spec.get("lambda", 0.35)
        mean = sum(per_window) / len(per_window)
        peak = mean if lam <= 0 else peak_value(per_window, kind)
        out[dim] = {
            "raw": window_aggregate(per_window, lam, kind),
            "mean": mean,
            "peak": peak,
            "windows": per_window,
        }
    return out


def build_grids(books_raw):
    """Freeze a percentile grid per dimension from the reference corpus."""
    grids = {}
    for dim in DIMENSIONS:
        values = sorted(
            b[dim]["raw"] for b in books_raw if dim in b
        )
        if len(values) < 3:
            continue
        n = len(values)
        grid = [values[min(n - 1, int(round(i * (n - 1) / (GRID_POINTS - 1))))]
                for i in range(GRID_POINTS)]
        grids[dim] = [round(v, 6) for v in grid]
    return grids


def percentile(value, grid):
    """Fraction of the reference distribution at or below `value`."""
    if not grid:
        return 0.5
    i = bisect.bisect_right(grid, value)
    return max(0.0, min(1.0, i / (len(grid) - 1)))


def combine(dim_values, config):
    total, weight_sum = 0.0, 0.0
    for dim, spec in config["dimensions"].items():
        if dim in dim_values:
            total += spec["weight"] * dim_values[dim]
            weight_sum += spec["weight"]
    base = total / weight_sum if weight_sum else 0.0

    extra = 0.0
    for term in config.get("interactions", []):
        a, b, v = term.get("a"), term.get("b"), term.get("v", 0.0)
        if a in dim_values and b in dim_values:
            extra += v * dim_values[a] * dim_values[b]
    return max(0.0, min(1.0, base + extra))


def score_book(windows, config, seed=20261029, resamples=1000, bands=None):
    """Score one book with a bootstrap interval over its sampled windows."""
    if len(windows) < config["refusal"]["min_windows"]:
        return None
    tokens = sum(w.get("tokens", 0) for w in windows)
    if tokens < config["refusal"]["min_tokens"]:
        return None

    raw = raw_dimension(windows, config)
    grids = config["reference"]
    dim_values = {
        d: percentile(v["raw"], grids.get(d, []))
        for d, v in raw.items()
    }
    score = combine(dim_values, config)

    rng = random.Random(seed)
    n = len(windows)
    kind = config.get("peak_kind", "peak90")
    draws = []
    for _ in range(resamples):
        idx = [rng.randrange(n) for _ in range(n)]
        values = {}
        for dim, spec in config["dimensions"].items():
            if dim not in raw:
                continue
            sample = [raw[dim]["windows"][i] for i in idx]
            lam = spec.get("lambda", 0.35)
            values[dim] = percentile(window_aggregate(sample, lam, kind),
                                     grids.get(dim, []))
        draws.append(combine(values, config))

    interval = (quantile(draws, 0.025), quantile(draws, 0.975))

    band = None
    for entry in bands or []:
        if score < entry["max"]:
            band = entry["name"]
            break

    return {
        "score": round(score, 4),
        "interval": [round(interval[0], 4), round(interval[1], 4)],
        "band_provisional": band,
        "dimensions": {
            d: {
                "label": config["dimensions"][d]["label"],
                "score": round(dim_values[d], 4),
                "weight": round(config["dimensions"][d]["weight"], 4),
                "contribution": round(config["dimensions"][d]["weight"] * dim_values[d], 4),
                "raw": round(raw[d]["raw"], 5),
                "window_spread": round(statistics.pstdev(raw[d]["windows"]), 5)
                if len(raw[d]["windows"]) > 1 else 0.0,
            }
            for d in raw
        },
        "windows": len(windows),
        "tokens_sampled": int(tokens),
    }


def joint_interval(raw, reference_raws, config, draws=200, seed=20261029):
    """Interval covering window sampling *and* reference-corpus composition.

    The plain `score_book` interval resamples the twelve windows against a fixed
    grid, so it answers "what if the sampler had landed elsewhere?". It cannot
    answer "what if the reference library had been different?". This resamples
    both: each draw rebuilds the percentile grids from a bootstrap sample of the
    reference books, then rescores the target book on a bootstrap sample of its
    windows. The result is wider and covers two sources, not five.

    Still not covered: feature measurement error, model form, and disagreement
    between readers.
    """
    if not raw or not reference_raws:
        return None
    rng = random.Random(seed)
    kind = config.get("peak_kind", "peak90")
    dims = [d for d in raw if raw[d]["windows"]]
    if not dims:
        return None
    n_windows = len(raw[dims[0]]["windows"])
    n_ref = len(reference_raws)
    results = []
    for _ in range(draws):
        idx_ref = [rng.randrange(n_ref) for _ in range(n_ref)]
        grids = build_grids([reference_raws[i] for i in idx_ref])
        idx = [rng.randrange(n_windows) for _ in range(n_windows)]
        values = {}
        for dim, spec in config["dimensions"].items():
            if dim not in raw or dim not in grids:
                continue
            windows = raw[dim]["windows"]
            sample = [windows[i % len(windows)] for i in idx]
            values[dim] = percentile(
                window_aggregate(sample, spec.get("lambda", 0.35), kind),
                grids[dim],
            )
        results.append(combine(values, config))
    return quantile(results, 0.025), quantile(results, 0.975)


def provisional_bands(scores, names=("Light", "Moderate", "Demanding",
                                     "Heavy", "Very heavy")):
    """Quintile cut points over the reference corpus, honestly labelled."""
    if len(scores) < len(names):
        return []
    cuts = [quantile(scores, q) for q in (0.20, 0.40, 0.60, 0.80)]
    bands, previous = [], 0.0
    for name, cut in zip(names[:-1], cuts):
        bands.append({"max": round(max(cut, previous + 1e-6), 4), "name": name})
        previous = cut
    bands.append({"max": 1.01, "name": names[-1]})
    return bands


def explain(result, top=3):
    items = sorted(
        result["dimensions"].items(),
        key=lambda kv: kv[1]["contribution"],
        reverse=True,
    )[:top]
    return [
        f"{spec['label']} (percentile {spec['score']:.2f} × weight {spec['weight']:.3f})"
        for _, spec in items
    ]
