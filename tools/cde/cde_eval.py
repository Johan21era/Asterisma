#!/usr/bin/env python3
"""Evaluation battery for the CDE.

What this measures, and what it deliberately does not:

  * determinism          same input, same output, twice
  * sampling stability   does splitting the windows change the score?
  * ablation             what happens if a dimension is removed?
  * weight sensitivity   does the ranking survive a +-50% weight change?
  * independence         is this just the old Flesch-Kincaid formula again?
  * within-series        do one author's books cluster together?

None of these is accuracy. Accuracy needs human grades, which do not exist.
These are the checks that can be made without them, and they are the checks
that expose a model which is noise, unstable, or a re-skin of the old one.

    python3 tools/cde/cde_eval.py --features /tmp/cde-features.json \
        --reference tools/cde/config/reference-v1.json \
        --engine docs/audits/evidence/cde-phase1-engine-output-2026-10-29.json
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


def spearman(xs, ys):
    def ranks(values):
        order = sorted(range(len(values)), key=lambda i: values[i])
        out = [0.0] * len(values)
        i = 0
        while i < len(order):
            j = i
            while j + 1 < len(order) and values[order[j + 1]] == values[order[i]]:
                j += 1
            average = (i + j) / 2 + 1
            for k in range(i, j + 1):
                out[order[k]] = average
            i = j + 1
        return out

    rx, ry = ranks(xs), ranks(ys)
    n = len(rx)
    mx, my = sum(rx) / n, sum(ry) / n
    num = sum((a - mx) * (b - my) for a, b in zip(rx, ry))
    dx = math.sqrt(sum((a - mx) ** 2 for a in rx))
    dy = math.sqrt(sum((b - my) ** 2 for b in ry))
    return num / (dx * dy) if dx and dy else 0.0


def load(features_path, reference_path):
    records = json.loads(Path(features_path).read_text())
    reference = json.loads(Path(reference_path).read_text())
    config = json.loads(json.dumps(cde_model.DEFAULT_CONFIG))
    config["reference"] = reference["grids"]
    config["reference_version"] = reference.get("reference_version", "ref-v2")
    return records, config, reference.get("bands") or []


def score(record, config, bands, windows=None):
    w = record.get("windows") or []
    if windows is not None:
        w = [w[i] for i in windows if i < len(w)]
    return cde_model.score_book(w, config, bands=bands)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--features", required=True)
    parser.add_argument("--reference", required=True)
    parser.add_argument("--engine", default=None)
    args = parser.parse_args()

    records, config, bands = load(args.features, args.reference)
    scored = {}
    for record in records:
        result = score(record, config, bands)
        if result:
            scored[record["title"]] = (record, result)

    print(f"books scored: {len(scored)}")

    # 1. Determinism ---------------------------------------------------------
    same = 0
    for title, (record, result) in scored.items():
        again = score(record, config, bands)
        if again and again["score"] == result["score"]:
            same += 1
    print(f"\n1. determinism: {same}/{len(scored)} books reproduce the same score bit-for-bit")

    # 2. Sampling stability --------------------------------------------------
    spreads = []
    for title, (record, result) in scored.items():
        thirds = []
        for offset in range(3):
            subset = list(range(offset, len(record["windows"]), 3))
            part = score(record, config, bands, windows=subset)
            if part:
                thirds.append(part["score"])
        if len(thirds) == 3:
            spreads.append(statistics.pstdev(thirds))
    if spreads:
        print(f"\n2. sampling stability across 3 disjoint window subsets (4 windows each)")
        print(f"   median within-book SD: {statistics.median(spreads):.3f}")
        print(f"   p90:                   {cde_model.quantile(spreads, 0.9):.3f}")
        print(f"   max:                   {max(spreads):.3f}")

    # 3. Ablation ------------------------------------------------------------
    print("\n3. ablation: remove one dimension, rescore")
    print("   dim   mean|dD|   max|dD|   spearman vs full")
    base_scores = {t: r["score"] for t, (_, r) in scored.items()}
    for dim in cde_model.DIMENSIONS:
        variant = json.loads(json.dumps(config))
        variant["dimensions"][dim]["weight"] = 1e-9
        deltas, variant_scores = [], {}
        for title, (record, _) in scored.items():
            result = score(record, variant, bands)
            if result:
                variant_scores[title] = result["score"]
                deltas.append(abs(result["score"] - base_scores[title]))
        common = [t for t in base_scores if t in variant_scores]
        rho = spearman([base_scores[t] for t in common],
                       [variant_scores[t] for t in common])
        print(f"   {dim}     {statistics.mean(deltas):.4f}    {max(deltas):.4f}    {rho:.3f}")

    # 4. Weight sensitivity --------------------------------------------------
    print("\n4. weight sensitivity: perturb one weight at a time by +50% and -50%")
    rhos = []
    for dim in cde_model.DIMENSIONS:
        for factor in (0.5, 1.5):
            variant = json.loads(json.dumps(config))
            variant["dimensions"][dim]["weight"] *= factor
            variant_scores = {}
            for title, (record, _) in scored.items():
                result = score(record, variant, bands)
                if result:
                    variant_scores[title] = result["score"]
            common = [t for t in base_scores if t in variant_scores]
            rhos.append(spearman([base_scores[t] for t in common],
                                 [variant_scores[t] for t in common]))
    print(f"   min rank correlation {min(rhos):.3f}  median {statistics.median(rhos):.3f}")

    # 5. Independence from the old formula -----------------------------------
    if args.engine:
        engine = json.loads(Path(args.engine).read_text())
        old = {}
        for entry in engine:
            if entry.get("dup_of") is None:
                old[entry["title"]] = entry["engine"]["difficultyMultiplier"]
        common = [t for t in base_scores if t in old]
        rho = spearman([base_scores[t] for t in common], [old[t] for t in common])
        print(f"\n5. independence: Spearman(CDE, old multiplier) = {rho:+.3f} over {len(common)} books")
        print("   (the old multiplier is r=+0.975 with Flesch-Kincaid grade, so this is the")
        print("    closest available proxy for 'did we rebuild the same formula?')")

    # 6. Within-series consistency -------------------------------------------
    print("\n6. within-series spread vs corpus spread")
    corpus = list(base_scores.values())
    corpus_sd = statistics.pstdev(corpus)
    series = {
        "Narnia": ["The Lion, the Witch and the Wardrobe", "Prince Caspian",
                   "The Voyage of the Dawn Treader", "The Silver Chair",
                   "The Last Battle", "The Horse and his Boy",
                   "The Magician's Nephew"],
        "Spy Classroom": None,
        "Naruto novels": None,
    }
    for name, titles in series.items():
        if titles is None:
            prefix = name.split()[0]
            titles = [t for t in base_scores if t.lower().startswith(prefix.lower())]
        values = [base_scores[t] for t in titles if t in base_scores]
        if len(values) >= 3:
            print(f"   {name:14s} n={len(values):2d}  SD={statistics.pstdev(values):.3f}"
                  f"  range={max(values) - min(values):.3f}")
    print(f"   {'corpus':14s} n={len(corpus):2d}  SD={corpus_sd:.3f}"
          f"  range={max(corpus) - min(corpus):.3f}")

    # 7. Interval width ------------------------------------------------------
    widths = [r["interval"][1] - r["interval"][0] for _, r in scored.values()]
    print(f"\n7. bootstrap interval width: median {statistics.median(widths):.3f} "
          f"p90 {cde_model.quantile(widths, 0.9):.3f} max {max(widths):.3f}")
    print("   Coverage against human grades cannot be computed: there are none.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
