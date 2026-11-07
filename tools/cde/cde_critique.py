#!/usr/bin/env python3
"""Adversarial checks on the CDE, written to answer a specific technical review.

Each section tests an objection that was made against the model on the basis of
its description rather than its code:

1. sampling coverage          — what share of a book is actually measured
2. feature redundancy         — are the 18 features measuring 18 things
3. aggregation alternatives   — mean vs Q85 vs Q90 vs CVaR vs max
4. lambda sensitivity         — how much the peak weight matters
5. split-half disagreement    — does the reported interval span it

Read-only. Prints a summary and, with --out, writes JSON.
"""

from __future__ import annotations

import argparse
import itertools
import json
import math
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import cde_model
from cde_model import build_grids, combine, percentile, quantile

FEATURES = (
    "A_oov", "A_morph", "A_abstract",
    "B_sentence", "B_clause", "B_pronoun", "B_passive",
    "G_names", "G_cooc",
    "H_discontinuity", "H_shift", "H_orphan",
    "I_content", "I_novelty", "I_np",
    "K_quote", "K_tagless", "K_speakers",
)


def mean(xs):
    return sum(xs) / len(xs) if xs else 0.0


def pearson(xs, ys):
    n = min(len(xs), len(ys))
    if n < 3:
        return 0.0
    mx, my = mean(xs[:n]), mean(ys[:n])
    num = sum((x - mx) * (y - my) for x, y in zip(xs[:n], ys[:n]))
    dx = math.sqrt(sum((x - mx) ** 2 for x in xs[:n]))
    dy = math.sqrt(sum((y - my) ** 2 for y in ys[:n]))
    return num / (dx * dy) if dx and dy else 0.0


def ranks(values):
    order = sorted(range(len(values)), key=lambda i: values[i])
    out = [0.0] * len(values)
    i = 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and values[order[j + 1]] == values[order[i]]:
            j += 1
        avg = (i + j) / 2 + 1
        for k in range(i, j + 1):
            out[order[k]] = avg
        i = j + 1
    return out


def spearman(xs, ys):
    return pearson(ranks(xs), ranks(ys))


def window_demands(windows, config):
    """Per-dimension list of per-window demands, skipping absent features."""
    out = {}
    for dim, spec in config["dimensions"].items():
        values = []
        for w in windows:
            total, weight_sum = 0.0, 0.0
            for feature, beta in spec["features"].items():
                if feature in w:
                    total += beta * w[feature]
                    weight_sum += beta
            if weight_sum:
                values.append(total / weight_sum)
        if values:
            out[dim] = values
    return out


def aggregate(values, kind, lam):
    if kind == "mean":
        return mean(values)
    if kind == "peak90":
        return (1 - lam) * mean(values) + lam * quantile(values, 0.90)
    if kind == "peak85":
        return (1 - lam) * mean(values) + lam * quantile(values, 0.85)
    if kind == "max":
        return max(values)
    if kind in ("cvar", "cvar90"):
        ordered = sorted(values, reverse=True)
        k = max(1, int(math.ceil(0.10 * len(ordered))))
        return mean(ordered[:k])
    raise ValueError(kind)


def dim_raw(windows, config, kind=None, lam=0.35):
    """Raw demand per dimension under one aggregation scheme."""
    kind = kind or config.get("peak_kind", "peak85")
    out = {}
    for dim, values in window_demands(windows, config).items():
        out[dim] = aggregate(values, kind, lam)
    return out


def score_corpus(books, config, kind="peak90", lam=0.35):
    raws = [dim_raw(b["windows"], config, kind, lam) for b in books]
    as_raw = [{d: {"raw": v} for d, v in r.items()} for r in raws]
    grids = build_grids(as_raw)
    scored = []
    for r in raws:
        dims = {d: percentile(v, grids[d]) for d, v in r.items() if d in grids}
        scored.append(combine(dims, config))
    return scored, raws, grids


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--features", required=True)
    parser.add_argument("--reference", required=True)
    parser.add_argument("--scores", required=True)
    parser.add_argument("--out")
    args = parser.parse_args()

    books = json.loads(Path(args.features).read_text())
    reference = json.loads(Path(args.reference).read_text())
    scores = json.loads(Path(args.scores).read_text())

    config = dict(cde_model.DEFAULT_CONFIG)
    config["reference"] = reference.get("grids", {})
    config["dimensions"] = {
        k: dict(v) for k, v in cde_model.DEFAULT_CONFIG["dimensions"].items()
    }

    by_title = {b["title"]: b for b in scores["books"]}
    report = {}

    # 1. sampling coverage -----------------------------------------------------
    coverage = []
    for b in books:
        words = b.get("words") or 0
        sampled = sum(w.get("tokens", 0) for w in b["windows"])
        if words:
            coverage.append(sampled / words)
    coverage.sort()
    report["coverage"] = {
        "median": round(quantile(coverage, 0.50), 4),
        "p10": round(quantile(coverage, 0.10), 4),
        "p90": round(quantile(coverage, 0.90), 4),
        "min": round(coverage[0], 4),
        "max": round(coverage[-1], 4),
    }
    print("\n1. sampling coverage (sampled tokens / book words)")
    print(f"   median {report['coverage']['median']:.1%}   "
          f"p10 {report['coverage']['p10']:.1%}   p90 {report['coverage']['p90']:.1%}   "
          f"range {report['coverage']['min']:.1%}–{report['coverage']['max']:.1%}")

    # 2. feature redundancy ----------------------------------------------------
    per_book = []
    for b in books:
        row = {}
        for f in FEATURES:
            vals = [w[f] for w in b["windows"] if f in w]
            if vals:
                row[f] = mean(vals)
        per_book.append(row)
    in_use = {f for spec in config["dimensions"].values()
              for f in spec["features"]}
    present = [f for f in FEATURES if all(f in r for r in per_book)]
    print(f"   (18 stored features, {len(in_use)} in use by config {config['version']})")
    pairs = []
    for a, b in itertools.combinations(present, 2):
        r = pearson([row[a] for row in per_book], [row[b] for row in per_book])
        pairs.append((abs(r), r, a, b))
    pairs.sort(reverse=True)
    report["feature_pairs"] = [
        {"a": a, "b": b, "r": round(r, 3)} for _, r, a, b in pairs[:10]
    ]
    print("\n2. strongest feature pairs across books (Pearson, n=135)")
    for _, r, a, b in pairs[:10]:
        print(f"   {r:+.3f}  {a} / {b}")

    # dimension-level correlation on raw demand
    raws_current = [dim_raw(b["windows"], config) for b in books]
    dims = sorted({d for r in raws_current for d in r})
    matrix = {}
    print("\n2b. dimension correlation (raw demand, n=135)")
    header = "        " + "".join(f"{d:>8}" for d in dims)
    print(header)
    for d1 in dims:
        row = []
        for d2 in dims:
            xs = [r[d1] for r in raws_current if d1 in r and d2 in r]
            ys = [r[d2] for r in raws_current if d1 in r and d2 in r]
            r = pearson(xs, ys)
            matrix[f"{d1}{d2}"] = round(r, 3)
            row.append(f"{r:>8.2f}")
        print(f"   {d1:>4} " + "".join(row))
    report["dimension_matrix"] = matrix

    # 3. aggregation alternatives ---------------------------------------------
    shipped_kind = config.get("peak_kind", "peak85")
    shipped_label = {"peak85": "Q85", "peak90": "Q90",
                     "cvar": "CVaR90"}.get(shipped_kind, shipped_kind)
    schemes = [
        ("mean (lambda=0)", "mean", 0.0),
        (f"{shipped_label} / 65-35 (shipped)", shipped_kind, 0.35),
        ("Q85 / 70-30", "peak85", 0.30),
        ("Q90 / 65-35", "peak90", 0.35),
        ("CVaR90", "cvar90", 0.0),
        ("max (lambda=1)", "max", 1.0),
    ]
    current, _, _ = score_corpus(books, config, shipped_kind, 0.35)
    order_current = sorted(range(len(books)), key=lambda i: -current[i])
    top10_current = set(order_current[:10])
    print("\n3. aggregation alternatives (grids rebuilt under each scheme)")
    print("   scheme                    spearman   max|dD|   top-10 overlap")
    agg_rows = []
    for name, kind, lam in schemes:
        scored, _, _ = score_corpus(books, config, kind, lam)
        rho = spearman(current, scored)
        max_delta = max(abs(a - b) for a, b in zip(current, scored))
        order = sorted(range(len(books)), key=lambda i: -scored[i])
        overlap = len(top10_current & set(order[:10]))
        agg_rows.append({"scheme": name, "spearman": round(rho, 4),
                         "max_delta": round(max_delta, 4), "top10": overlap})
        print(f"   {name:<24} {rho:>8.3f} {max_delta:>9.3f}   {overlap}/10")
    report["aggregation"] = agg_rows

    # 4. lambda sweep ----------------------------------------------------------
    print("\n4. lambda sweep at Q90")
    lam_rows = []
    for lam in (0.0, 0.15, 0.35, 0.50, 0.75, 1.0):
        scored, _, _ = score_corpus(books, config, "peak90", lam)
        rho = spearman(current, scored)
        order = sorted(range(len(books)), key=lambda i: -scored[i])
        overlap = len(top10_current & set(order[:10]))
        lam_rows.append({"lambda": lam, "spearman": round(rho, 4),
                         "top10": overlap})
        print(f"   lambda {lam:<5} spearman {rho:>7.3f}   top-10 {overlap}/10")
    report["lambda_sweep"] = lam_rows

    # 5. split-half disagreement vs the reported interval ---------------------
    print("\n5. split-half disagreement against the reported interval")
    diffs, widths, ratios, exceed = [], [], [], 0
    for b in books:
        if len(b["windows"]) < 8:
            continue
        odd = b["windows"][0::2]
        even = b["windows"][1::2]
        halves = []
        for half in (odd, even):
            r = dim_raw(half, config)
            dims_p = {d: percentile(v, config["reference"].get(d, []))
                      for d, v in r.items()}
            halves.append(combine(dims_p, config))
        diff = abs(halves[0] - halves[1])
        record = by_title.get(b["title"])
        if not record:
            continue
        width = record["interval"][1] - record["interval"][0]
        diffs.append(diff)
        widths.append(width)
        if width > 0:
            ratios.append(diff / width)
            if diff > width:
                exceed += 1
    n = len(diffs)
    report["split_half"] = {
        "books": n,
        "median_abs_diff": round(quantile(diffs, 0.50), 4),
        "median_interval_width": round(quantile(widths, 0.50), 4),
        "median_ratio": round(quantile(ratios, 0.50), 3),
        "share_exceeding_width": round(exceed / n, 3) if n else None,
    }
    print(f"   books {n}   median |D_odd - D_even| "
          f"{report['split_half']['median_abs_diff']:.4f}   "
          f"median interval width {report['split_half']['median_interval_width']:.4f}")
    print(f"   median ratio {report['split_half']['median_ratio']:.2f}   "
          f"halves further apart than the interval: "
          f"{report['split_half']['share_exceeding_width']:.1%}")

    if args.out:
        Path(args.out).write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        print(f"\nwritten: {args.out}")


if __name__ == "__main__":
    main()
