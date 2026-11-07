#!/usr/bin/env python3
"""Choose the v0.3 aggregation by measured reliability, not by preference.

Reliability here is internal consistency: score each book twice from disjoint
halves of its twelve windows, then look at how far apart the two halves land.
That is not validity — a broken instrument can be perfectly reliable — but it is
the one property that can be measured without human ratings, and an aggregation
that is noisier than another buys nothing in exchange for its noise.

Also measures what the v0.3 feature deduplication costs, by scoring the v0.2 and
v0.3 configurations on the same windows and comparing.
"""

from __future__ import annotations

import argparse
import json
import math
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import cde_model
from cde_model import (build_grids, combine, percentile, quantile,
                       raw_dimension, window_aggregate)


def spearman(xs, ys):
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
    rx, ry = ranks(xs), ranks(ys)
    mx, my = sum(rx) / len(rx), sum(ry) / len(ry)
    num = sum((a - mx) * (b - my) for a, b in zip(rx, ry))
    dx = math.sqrt(sum((a - mx) ** 2 for a in rx))
    dy = math.sqrt(sum((b - my) ** 2 for b in ry))
    return num / (dx * dy) if dx and dy else 0.0


def config_with(base, version, features=None, peak="peak90", lam=0.35):
    config = json.loads(json.dumps(base))
    config["version"] = version
    config["peak_kind"] = peak
    for dim in config["dimensions"]:
        config["dimensions"][dim]["lambda"] = lam
    if features:
        for dim, subset in features.items():
            keep = {k: v for k, v in config["dimensions"][dim]["features"].items()
                    if k in subset}
            total = sum(keep.values()) or 1.0
            config["dimensions"][dim]["features"] = {
                k: v / total for k, v in keep.items()}
    return config


def score_all(records, config):
    raws = [raw_dimension(r["windows"], config) for r in records]
    grids = build_grids(raws)
    config = dict(config)
    config["reference"] = grids
    scores = []
    for raw in raws:
        dims = {d: percentile(v["raw"], grids[d]) for d, v in raw.items() if d in grids}
        scores.append(combine(dims, config))
    return scores, raws, grids, config


def half_scores(raw, grids, config):
    """Score odd and even windows separately against the full-book grids."""
    dims = [d for d in raw if raw[d]["windows"]]
    out = []
    for parity in (0, 1):
        values = {}
        for dim in dims:
            windows = raw[dim]["windows"][parity::2]
            if not windows:
                continue
            values[dim] = percentile(
                window_aggregate(windows,
                                 config["dimensions"][dim].get("lambda", 0.35),
                                 config.get("peak_kind", "peak90")),
                grids.get(dim, []))
        out.append(combine(values, config))
    return out


def reliability(records, config):
    scores, raws, grids, bound = score_all(records, config)
    diffs = []
    for raw in raws:
        a, b = half_scores(raw, grids, bound)
        diffs.append(abs(a - b))
    return {
        "median_abs_diff": round(quantile(diffs, 0.50), 4),
        "p90_abs_diff": round(quantile(diffs, 0.90), 4),
        "mean_abs_diff": round(statistics.fmean(diffs), 4),
        "scores": scores,
        "grids": grids,
        "config": bound,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--features", required=True)
    parser.add_argument("--out")
    args = parser.parse_args()

    records = json.loads(Path(args.features).read_text())
    records = [r for r in records if len(r.get("windows") or []) >= 3]
    base = json.loads(json.dumps(cde_model.DEFAULT_CONFIG))

    v02 = json.loads(Path("tools/cde/config/cde-v0.2.json").read_text())
    v02["reference"] = {}
    dedup = {"A": {"A_oov", "A_abstract"},
             "B": {"B_clause", "B_pronoun", "B_passive"},
             "I": {"I_content", "I_novelty"}}

    def equalise(config):
        """Equal within-dimension beta, keeping every feature."""
        out = json.loads(json.dumps(config))
        for dim, spec in out["dimensions"].items():
            n = len(spec["features"])
            spec["features"] = {k: 1 / n for k in spec["features"]}
        return out

    table = []
    print("scheme                       median|d|   p90|d|   mean|d|")
    variants = []
    variants.append(("v0.2 (18 features, Q90 65/35)", v02))
    for peak in ("peak85", "peak90", "cvar"):
        variants.append((f"18 feat equal-beta, {peak}",
                         config_with(equalise(base), "cde-v0.3", None, peak, 0.35)))
    for peak in ("peak85", "peak90"):
        variants.append((f"dedup equal-beta, {peak}",
                         config_with(base, "cde-v0.3", dedup, peak, 0.35)))
    variants.append(("18 feat equal-beta, mean only",
                     config_with(equalise(base), "cde-v0.3", None, "mean", 0.0)))

    for name, config in variants:
        result = reliability(records, config)
        table.append({"scheme": name, **{k: result[k] for k in
                                        ("median_abs_diff", "p90_abs_diff",
                                         "mean_abs_diff")}})
        print(f"{name:<28} {result['median_abs_diff']:>8.4f} "
              f"{result['p90_abs_diff']:>8.4f} {result['mean_abs_diff']:>9.4f}")

    print("\neffect of deduplication and operator (Spearman vs v0.2, top-10 overlap)")
    baseline = reliability(records, v02)["scores"]
    base_top = set(sorted(range(len(baseline)), key=lambda i: -baseline[i])[:10])
    for name, config in variants[1:]:
        scores = reliability(records, config)["scores"]
        top = set(sorted(range(len(scores)), key=lambda i: -scores[i])[:10])
        max_delta = max(abs(a - b) for a, b in zip(baseline, scores))
        print(f"{name:<28} rho {spearman(baseline, scores):>7.3f}  "
              f"max|dD| {max_delta:>6.3f}  top-10 {len(base_top & top)}/10")

    print("\ndimension split-half noise (v0.3 dedup, Q90 65/35), median percentile gap")
    chosen = config_with(base, "cde-v0.3", dedup, "peak90", 0.35)
    _, raws, grids, bound = score_all(records, chosen)
    for dim in sorted(grids):
        gaps = []
        for raw in raws:
            if dim not in raw:
                continue
            windows = raw[dim]["windows"]
            if len(windows) < 4:
                continue
            a = percentile(window_aggregate(windows[0::2], 0.35, "peak90"), grids[dim])
            b = percentile(window_aggregate(windows[1::2], 0.35, "peak90"), grids[dim])
            gaps.append(abs(a - b))
        print(f"  {dim}  {quantile(gaps, 0.50):>6.3f}")

    if args.out:
        Path(args.out).write_text(json.dumps(table, indent=2) + "\n")
        print(f"\nwritten: {args.out}")


if __name__ == "__main__":
    main()
