#!/usr/bin/env python3
"""CDE command line: calibrate the reference, evaluate a corpus, summarise.

Read-only with respect to the corpus and the app. Writes only the files named on
the command line.

    # 1. build the frozen reference distribution from book-level features
    python3 tools/cde/cde_run.py calibrate \
        --corpus "asterisma new testing suite" \
        --queue docs/audits/evidence/cde-phase1-engine-output-2026-10-29.json \
        --features /tmp/cde-features.json \
        --reference tools/cde/config/reference-v1.json

    # 2. score every book
    python3 tools/cde/cde_run.py evaluate --features /tmp/cde-features.json \
        --reference tools/cde/config/reference-v1.json \
        --out docs/audits/evidence/cde-v0-scores-2026-10-29.json

    # 3. print the summary
    python3 tools/cde/cde_run.py report \
        --scores docs/audits/evidence/cde-v0-scores-2026-10-29.json
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import cde_extract
import cde_features
import cde_model
import cde_text


def load_corpus(folder, queue, limit=None):
    entries = json.loads(Path(queue).read_text())
    books = []
    for entry in entries:
        if entry.get("dup_of") is not None:
            continue
        path = Path(folder) / entry["file"]
        if not path.exists():
            continue
        books.append({
            "title": entry["title"],
            "file": entry["file"],
            "path": path,
            "words": entry["words"],
        })
        if limit and len(books) >= limit:
            break
    return books


def features_for(path, windows=12, tokens=1200):
    package = cde_extract.load_package(path)
    selected, skipped, total_chars = cde_extract.select_windows(
        package, count=windows, tokens_per_window=tokens
    )
    feats = []
    for window in selected:
        f = cde_features.window_features(window["text"])
        if f:
            feats.append(f)
    excluded_chars = sum(c for _, _, c in skipped if isinstance(c, int))
    return {
        "title": package.title or path.name,
        "windows": feats,
        "windows_attempted": len(selected),
        "excluded_documents": [
            {"name": n, "reason": r, "chars": c} for n, r, c in skipped
        ],
        "prose_share": 1.0 - (excluded_chars / total_chars) if total_chars else 0.0,
    }


def cmd_frequency(args):
    """Build the familiar-word list from the reference corpus's own windows."""
    books = load_corpus(args.corpus, args.queue, args.limit)
    counts = {}
    total = 0
    for i, book in enumerate(books, 1):
        try:
            package = cde_extract.load_package(book["path"])
            windows, _, _ = cde_extract.select_windows(
                package, count=args.windows, tokens_per_window=args.tokens
            )
        except Exception:  # noqa: BLE001 - corpus is untrusted input
            continue
        for window in windows:
            for token in cde_text.words(window["text"]):
                counts[token] = counts.get(token, 0) + 1
                total += 1
        if i % 25 == 0 or i == len(books):
            print(f"  {i}/{len(books)}  tokens={total}  types={len(counts)}", flush=True)

    ranked = sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))[: args.top]
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text(json.dumps({
        "version": "lexicon-v1",
        "source": "cde reference corpus, sampled windows",
        "books": len(books),
        "corpus_tokens": total,
        "types": len(counts),
        "top": [word for word, _ in ranked],
    }, indent=1))
    print(f"types {len(counts)}  tokens {total}  written {len(ranked)} -> {args.out}")
    return 0


def cmd_calibrate(args):
    books = load_corpus(args.corpus, args.queue, args.limit)
    print(f"calibrating on {len(books)} books", flush=True)
    records = []
    for i, book in enumerate(books, 1):
        try:
            record = features_for(book["path"], args.windows, args.tokens)
        except Exception as error:  # noqa: BLE001 - corpus is untrusted input
            record = {"title": book["title"], "windows": [], "error": str(error)}
        record["file"] = book["file"]
        record["words"] = book["words"]
        records.append(record)
        if i % 10 == 0 or i == len(books):
            print(f"  {i}/{len(books)} {book['title'][:40]}", flush=True)

    usable = [r["windows"] for r in records if len(r["windows"]) >= 3]
    config = json.loads(json.dumps(cde_model.DEFAULT_CONFIG))
    raws = [cde_model.raw_dimension(w, config) for w in usable]
    grids = cde_model.build_grids(raws)

    config["reference"] = grids
    in_sample = []
    for raw in raws:
        dim_values = {d: cde_model.percentile(v["raw"], grids.get(d, []))
                      for d, v in raw.items()}
        in_sample.append(cde_model.combine(dim_values, config))
    bands = cde_model.provisional_bands(sorted(in_sample))

    Path(args.features).write_text(json.dumps(records, separators=(",", ":")))
    Path(args.reference).parent.mkdir(parents=True, exist_ok=True)
    Path(args.reference).write_text(json.dumps({
        "version": "ref-v2",
        "reference_version": "ref-v2",
        "books": len(usable),
        "grids": grids,
        "bands": bands,
    }, indent=2, sort_keys=True))
    print(f"features: {args.features}")
    print(f"reference: {args.reference} ({len(grids)} dimensions, {len(usable)} books)")
    print(f"provisional bands: {[b['name'] for b in bands]}")
    return 0


def cmd_evaluate(args):
    records = json.loads(Path(args.features).read_text())
    reference_doc = json.loads(Path(args.reference).read_text())
    config = json.loads(json.dumps(cde_model.DEFAULT_CONFIG))
    config["reference"] = reference_doc["grids"]
    config["reference_version"] = reference_doc.get("reference_version", "ref-v2")
    bands = reference_doc.get("bands") or []

    results = []
    for record in records:
        windows = record.get("windows") or []
        scored = cde_model.score_book(windows, config, bands=bands)
        entry = {
            "title": record.get("title"),
            "file": record.get("file"),
            "words": record.get("words"),
            "windows_attempted": record.get("windows_attempted"),
            "prose_share": round(record.get("prose_share", 0.0), 3),
        }
        if scored is None:
            entry.update({
                "status": "INSUFFICIENT_EVIDENCE",
                "reason": f"{len(windows)} usable windows, "
                          f"{int(sum(w.get('tokens', 0) for w in windows))} tokens",
            })
        else:
            entry.update({
                "status": "ok",
                "score": scored["score"],
                "interval": scored["interval"],
                "band_provisional": scored["band_provisional"],
                "dimensions": {
                    k: {kk: vv for kk, vv in v.items()}
                    for k, v in scored["dimensions"].items()
                },
                "explanation": cde_model.explain(scored),
                "tokens_sampled": scored["tokens_sampled"],
                "sampled_share": (round(scored["tokens_sampled"] / record["words"], 4)
                                  if record.get("words") else None),
                "low_coverage": bool(record.get("words")
                                     and scored["tokens_sampled"] / record["words"] < 0.03),
            })
        results.append(entry)

    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text(json.dumps({
        "config_version": config["version"],
        "reference_version": config["reference_version"],
        "books": results,
    }, separators=(",", ":"), sort_keys=True))
    ok = [r for r in results if r["status"] == "ok"]
    print(f"scored {len(ok)}/{len(results)} books")
    print(f"out: {args.out}")
    return 0


def cmd_refit(args):
    """Rebuild the whole model from stored window features.

    No EPUB corpus needed: features are immutable inputs, so a new configuration
    can be fitted, normalised and scored reproducibly from
    `cde-v0-features-*.json`. This is how a version bump is made without
    re-reading 149 archives.
    """
    records = json.loads(Path(args.features).read_text())
    config = json.loads(json.dumps(cde_model.DEFAULT_CONFIG))
    if args.config:
        overrides = json.loads(Path(args.config).read_text())
        config.update({k: v for k, v in overrides.items() if k != "reference"})
        config["version"] = overrides.get("version", config["version"])
        config["reference_version"] = overrides.get(
            "reference_version", config["reference_version"])

    usable = [r for r in records
              if len(r.get("windows") or []) >= config["refusal"]["min_windows"]]
    raws = [cde_model.raw_dimension(r["windows"], config) for r in usable]
    grids = cde_model.build_grids(raws)
    config["reference"] = grids

    in_sample = [
        cde_model.combine(
            {d: cde_model.percentile(v["raw"], grids[d])
             for d, v in raw.items() if d in grids}, config)
        for raw in raws
    ]
    bands = cde_model.provisional_bands(sorted(in_sample))

    reference_doc = {
        "version": config["reference_version"],
        "reference_version": config["reference_version"],
        "config_version": config["version"],
        "peak_kind": config.get("peak_kind", "peak90"),
        "books": len(usable),
        "grids": grids,
        "bands": bands,
    }
    Path(args.reference_out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.reference_out).write_text(
        json.dumps(reference_doc, indent=2, sort_keys=True))

    results = []
    for record in records:
        windows = record.get("windows") or []
        words = record.get("words")
        tokens = int(sum(w.get("tokens", 0) for w in windows))
        entry = {
            "title": record.get("title"),
            "file": record.get("file"),
            "words": words,
            "windows_attempted": record.get("windows_attempted"),
            "prose_share": round(record.get("prose_share", 0.0), 3),
            "tokens_sampled": tokens,
            "sampled_share": round(tokens / words, 4) if words else None,
            "low_coverage": bool(words and tokens / words < 0.03),
        }
        scored = cde_model.score_book(windows, config, bands=bands)
        if scored is None:
            entry.update({
                "status": "INSUFFICIENT_EVIDENCE",
                "reason": f"{len(windows)} usable windows, {tokens} tokens",
            })
        else:
            raw = cde_model.raw_dimension(windows, config)
            joint = cde_model.joint_interval(
                raw, raws, config, draws=args.draws)
            entry.update({
                "status": "ok",
                "score": scored["score"],
                "interval": ([round(joint[0], 4), round(joint[1], 4)]
                             if joint else scored["interval"]),
                "interval_window_only": scored["interval"],
                "band_provisional": scored["band_provisional"],
                "dimensions": scored["dimensions"],
                "explanation": cde_model.explain(scored),
            })
        results.append(entry)

    Path(args.scores_out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.scores_out).write_text(json.dumps({
        "config_version": config["version"],
        "reference_version": config["reference_version"],
        "books": results,
    }, separators=(",", ":"), sort_keys=True))

    ok = [r for r in results if r["status"] == "ok"]
    widths = sorted(r["interval"][1] - r["interval"][0] for r in ok)
    print(f"config {config['version']}  reference {config['reference_version']}  "
          f"peak {config.get('peak_kind', 'peak90')}")
    print(f"scored {len(ok)}/{len(results)}  refusal path triggered "
          f"{len(results) - len(ok)}")
    if widths:
        print(f"interval width median {statistics.median(widths):.3f}  "
              f"max {widths[-1]:.3f}  (draws {args.draws})")
    print(f"reference: {args.reference_out}")
    print(f"scores:    {args.scores_out}")
    return 0


def cmd_report(args):
    doc = json.loads(Path(args.scores).read_text())
    books = doc["books"]
    ok = [b for b in books if b["status"] == "ok"]
    refused = [b for b in books if b["status"] != "ok"]
    scores = sorted(b["score"] for b in ok)
    widths = sorted(b["interval"][1] - b["interval"][0] for b in ok)

    print(f"config {doc['config_version']}  reference {doc['reference_version']}")
    print(f"books {len(books)}  scored {len(ok)}  refused {len(refused)}")
    if scores:
        print(f"score min {scores[0]:.3f}  median {statistics.median(scores):.3f}  max {scores[-1]:.3f}")
        print(f"interval width median {statistics.median(widths):.3f}  max {widths[-1]:.3f}")
        bands = {}
        for b in ok:
            bands[b["band_provisional"]] = bands.get(b["band_provisional"], 0) + 1
        print("provisional bands:", bands)
        print("\nmost demanding:")
        for b in sorted(ok, key=lambda x: -x["score"])[:6]:
            print(f"  {b['score']:.3f} [{b['interval'][0]:.2f},{b['interval'][1]:.2f}] "
                  f"{b['title'][:44]}")
        print("\nleast demanding:")
        for b in sorted(ok, key=lambda x: x["score"])[:6]:
            print(f"  {b['score']:.3f} [{b['interval'][0]:.2f},{b['interval'][1]:.2f}] "
                  f"{b['title'][:44]}")
    if refused:
        print("\nrefused:")
        for b in refused[:10]:
            print(f"  {b['title'][:44]}: {b.get('reason', '')}")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    freq = sub.add_parser("frequency")
    freq.add_argument("--corpus", required=True)
    freq.add_argument("--queue", required=True)
    freq.add_argument("--out", required=True)
    freq.add_argument("--top", type=int, default=20000)
    freq.add_argument("--windows", type=int, default=12)
    freq.add_argument("--tokens", type=int, default=1200)
    freq.add_argument("--limit", type=int, default=None)
    freq.set_defaults(func=cmd_frequency)

    cal = sub.add_parser("calibrate")
    cal.add_argument("--corpus", required=True)
    cal.add_argument("--queue", required=True)
    cal.add_argument("--features", required=True)
    cal.add_argument("--reference", required=True)
    cal.add_argument("--windows", type=int, default=12)
    cal.add_argument("--tokens", type=int, default=1200)
    cal.add_argument("--limit", type=int, default=None)
    cal.set_defaults(func=cmd_calibrate)

    ev = sub.add_parser("evaluate")
    ev.add_argument("--features", required=True)
    ev.add_argument("--reference", required=True)
    ev.add_argument("--out", required=True)
    ev.set_defaults(func=cmd_evaluate)

    rf = sub.add_parser("refit")
    rf.add_argument("--features", required=True)
    rf.add_argument("--reference-out", required=True)
    rf.add_argument("--scores-out", required=True)
    rf.add_argument("--config", default=None)
    rf.add_argument("--draws", type=int, default=200)
    rf.set_defaults(func=cmd_refit)

    rep = sub.add_parser("report")
    rep.add_argument("--scores", required=True)
    rep.set_defaults(func=cmd_report)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
