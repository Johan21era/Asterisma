#!/usr/bin/env python3
"""Score every package in a corpus with ADF, duplicates included.

Two jobs the existing commands do not do:

1. Cover the *whole* folder, not the de-duplicated works. `cde_run calibrate`
   skips `dup_of` entries because calibration must not count one book twice.
   A retest has the opposite obligation: show that all 149 packages were run,
   and show the 14 copies landed on the same score as their host rather than
   assuming it.
2. Emit a sheet a human can grade from. The score alone is not auditable; the
   sampled share, the interval and the worst windows are what let a reviewer
   say "this looks wrong" or "this cannot be judged".

Duplicate identity is proved by digest, not by filename: every package is hashed
and the groups are formed from the hashes. A group whose scores disagree is a
defect and the script exits non-zero.

    python3 tools/cde/cde_sheet.py \
        --corpus "asterisma new testing suite" \
        --queue docs/audits/evidence/cde-phase1-engine-output-2026-10-29.json \
        --reference tools/cde/config/reference-v3.json \
        --features-out docs/audits/evidence/adf-149-features-2026-10-29.json \
        --out-json docs/audits/evidence/adf-149-scores-2026-10-29.json \
        --out-md docs/audits/evidence/adf-149-sheet-2026-10-29.md
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
from pathlib import Path

import cde_model
import cde_run


def digest(path: Path) -> str:
    """Content digest of a package, zip or unzipped directory.

    A directory digest covers every contained file's relative path and bytes,
    in sorted order, so it is stable against mtime and inode noise and equal for
    two trees that differ only in extraction order. This is the value duplicate
    claims rest on.
    """
    h = hashlib.sha256()
    if path.is_file():
        with path.open("rb") as fh:
            for block in iter(lambda: fh.read(1 << 20), b""):
                h.update(block)
        return h.hexdigest()
    for child in sorted(path.rglob("*"), key=lambda q: q.relative_to(path).as_posix()):
        if not child.is_file():
            continue
        rel = child.relative_to(path).as_posix().encode()
        inner = hashlib.sha256()
        with child.open("rb") as fh:
            for block in iter(lambda: fh.read(1 << 20), b""):
                inner.update(block)
        h.update(rel + b"\0" + inner.digest())
    return h.hexdigest()


def enumerate_packages(folder: Path) -> list[Path]:
    """Every `.epub` entry, whether it is a zip file or an unzipped directory."""
    return sorted(
        (p for p in folder.iterdir()
         if p.name.lower().endswith(".epub") and (p.is_file() or p.is_dir())),
        key=lambda p: p.name.lower(),
    )


def queue_index(queue: Path | None) -> dict:
    """Optional title/word lookup, keyed by filename. Never required."""
    if queue is None or not queue.exists():
        return {}
    try:
        entries = json.loads(queue.read_text())
    except (OSError, ValueError):
        return {}
    return {e.get("file"): e for e in entries if isinstance(e, dict)}


def load_reference(path: Path) -> tuple[dict, list, int]:
    doc = json.loads(path.read_text())
    books = doc.get("books")
    if not isinstance(books, int):
        books = max((len(v) for v in doc["grids"].values()), default=0)
    return doc["grids"], doc.get("bands") or [], books


def score_one(path: Path, grids: dict, bands: list, windows: int, tokens: int):
    record = cde_run.features_for(path, windows, tokens)
    config = json.loads(json.dumps(cde_model.DEFAULT_CONFIG))
    config["reference"] = grids
    scored = cde_model.score_book(record["windows"], config, bands=bands)
    return record, scored


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", required=True)
    ap.add_argument("--queue", default=None)
    ap.add_argument("--reference", required=True)
    ap.add_argument("--features-out", required=True)
    ap.add_argument("--out-json", required=True)
    ap.add_argument("--out-md", default=None)
    ap.add_argument("--windows", type=int, default=12)
    ap.add_argument("--tokens", type=int, default=1200)
    ap.add_argument("--limit", type=int, default=None)
    args = ap.parse_args()

    folder = Path(args.corpus).expanduser()
    if not folder.is_dir():
        print(f"corpus not found: {folder}", file=sys.stderr)
        return 2

    grids, bands, reference_books = load_reference(Path(args.reference))
    queued = queue_index(Path(args.queue).expanduser() if args.queue else None)
    packages = enumerate_packages(folder)
    if args.limit:
        packages = packages[: args.limit]
    print(f"packages: {len(packages)}  reference books: {reference_books}", flush=True)

    started = time.time()
    features, rows = [], []
    failures = []
    for i, path in enumerate(packages, 1):
        try:
            record, scored = score_one(path, grids, bands, args.windows, args.tokens)
        except Exception as error:  # noqa: BLE001 - corpus is untrusted input
            failures.append({"file": path.name, "error": str(error)})
            print(f"  FAIL {path.name}: {error}", flush=True)
            continue

        record["file"] = path.name
        record["digest"] = digest(path)
        known = queued.get(path.name) or {}
        record["words"] = known.get("words") or record.get("words") or 0
        features.append(record)

        row = {
            "file": path.name,
            "title": known.get("title") or record.get("title") or path.stem,
            "digest": record["digest"],
            "dup_of": known.get("dup_of"),
            "words": record["words"],
            "windows_attempted": record.get("windows_attempted"),
            "windows_used": len(record.get("windows") or []),
            "prose_share": round(record.get("prose_share", 0.0), 4),
        }
        if scored is None:
            row.update({"status": "INSUFFICIENT_EVIDENCE", "score": None, "band": None,
                        "interval": None, "dimensions": None, "sampled_share": None,
                        "low_coverage": True})
        else:
            row.update({
                "status": "ok",
                "score": scored["score"],
                "band": scored.get("band_provisional"),
                "interval": scored.get("interval"),
                # `score` is the percentile against the frozen reference (0..1).
                # `contribution` is weight x percentile, so the six add to D and
                # a reader can see which dimension moved the number.
                "dimensions": {d: round(v["score"], 4)
                               for d, v in scored["dimensions"].items()},
                "contributions": {d: round(v["contribution"], 4)
                                  for d, v in scored["dimensions"].items()},
                "tokens_sampled": scored.get("tokens_sampled"),
                "sampled_share": (round(scored["tokens_sampled"] / record["words"], 4)
                                  if record["words"] else None),
                "low_coverage": bool(record["words"] and record["words"] > 0
                                     and scored["tokens_sampled"] / record["words"] < 0.03),
            })
        rows.append(row)
        if i % 10 == 0 or i == len(packages):
            print(f"  {i}/{len(packages)} {path.name[:52]}", flush=True)

    # --- duplicate identity, proved by digest -------------------------------
    groups: dict[str, list[dict]] = {}
    for row in rows:
        groups.setdefault(row["digest"], []).append(row)
    duplicate_groups = {d: g for d, g in groups.items() if len(g) > 1}

    mismatches = []
    for d, group in duplicate_groups.items():
        reference = group[0]
        for other in group[1:]:
            same = (other.get("score") == reference.get("score")
                    and other.get("dimensions") == reference.get("dimensions"))
            if not same:
                mismatches.append({
                    "digest": d,
                    "a": reference["file"],
                    "b": other["file"],
                    "score_a": reference.get("score"),
                    "score_b": other.get("score"),
                })

    elapsed = time.time() - started
    scored_rows = [r for r in rows if r["status"] == "ok"]
    summary = {
        "formula": cde_model.FORMULA_ID,
        "reference_version": Path(args.reference).stem,
        "packages": len(packages),
        "scored": len(scored_rows),
        "insufficient": len(rows) - len(scored_rows),
        "failures": len(failures),
        "distinct_digests": len(groups),
        "duplicate_groups": len(duplicate_groups),
        "duplicate_packages": len(rows) - len(groups),
        "duplicate_score_mismatches": len(mismatches),
        "windows": args.windows,
        "tokens_per_window": args.tokens,
    }
    print(json.dumps(summary, indent=2))
    # Timing is printed, never stored: an artifact that embeds wall-clock time
    # cannot be reproduced byte for byte, and reproducibility is the property
    # this file exists to demonstrate.
    print(f"elapsed {elapsed:.2f}s")

    Path(args.features_out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.features_out).write_text(json.dumps(features, separators=(",", ":")))
    Path(args.out_json).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out_json).write_text(json.dumps(
        {"summary": summary, "rows": rows, "duplicate_mismatches": mismatches,
         "failures": failures},
        indent=2, sort_keys=False))

    if args.out_md:
        Path(args.out_md).write_text(render_markdown(rows, summary))
        print(f"sheet: {args.out_md}")

    return 1 if (mismatches or failures) else 0


def render_markdown(rows: list[dict], summary: dict) -> str:
    lines = [
        "# ADF — every package in the corpus",
        "",
        "> Generated by `tools/cde/cde_sheet.py`. Do not hand-edit; rerun the tool.",
        "",
        f"- **Formula:** `{summary['formula']}`",
        f"- **Packages:** {summary['packages']}  "
        f"(**{summary['distinct_digests']} distinct digests**, "
        f"{summary['duplicate_packages']} byte-identical copies)",
        f"- **Scored:** {summary['scored']}  insufficient evidence: {summary['insufficient']}  "
        f"failures: {summary['failures']}",
        f"- **Duplicate score mismatches:** {summary['duplicate_score_mismatches']}",
        f"- **Sampling:** {summary['windows']} windows × {summary['tokens_per_window']} tokens",
        "",
        "`D` is a text-demand index against the frozen reference, not a reading-time",
        "prediction and not a grade level. `band` is a corpus quintile.",
        "",
        "| # | Book | D | ± | Band | Words | Sampled | Windows | Cover |",
        "|---:|---|---:|---:|---|---:|---:|---:|---|",
    ]
    ordered = sorted(rows, key=lambda r: (r.get("score") is None, r.get("score") or 0))
    for i, row in enumerate(ordered, 1):
        score = f"{row['score']:.4f}" if row.get("score") is not None else "—"
        interval = row.get("interval") or [None, None]
        width = (f"{interval[1] - interval[0]:.3f}"
                 if interval[0] is not None and interval[1] is not None else "—")
        sampled = f"{row['sampled_share'] * 100:.1f}%" if row.get("sampled_share") else "—"
        cover = "low" if row.get("low_coverage") else ""
        dup = " ᵈ" if row.get("dup_of") is not None else ""
        title = (row["title"] or row["file"]).replace("|", "\\|")[:62]
        lines.append(
            f"| {i} | {title}{dup} | {score} | {width} | {row.get('band') or '—'} | "
            f"{row['words']:,} | {sampled} | {row['windows_used']} | {cover} |"
        )
        if row.get("status") != "ok":
            lines[-1] = lines[-1].replace("| — | — | — |", "| INSUFFICIENT | — | — |")
    lines += [
        "",
        "ᵈ byte-identical copy of another package in this corpus; it is scored",
        "independently and must match its host exactly.",
        "",
        "`cover` marks books sampled below 3% of their word count — the interval",
        "understates how little of the text was read.",
    ]
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    sys.exit(main())
