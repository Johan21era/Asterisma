#!/usr/bin/env python3
"""Phase 1 audit measurements for the Cognitive Difficulty Engine.

Read-only. Produces numbers for docs/plans/cde/PHASE-1-AUDIT.md. It assigns no
difficulty verdict and modifies nothing.

What it measures:
  1. Whether the app's estimated time is a closed form of word count and the
     difficulty multiplier alone (no other book-dependent term).
  2. The distribution of the multiplier, including how often it saturates the
     0.5-2.0 clamp.
  3. The named diagnostic failures, read from recorded engine output.
  4. Whether the app's own Swift word counter agrees with an independent
     Python count over the same spine.
  5. How much of a book the 5,000-character difficulty sample actually covers.

Usage:
    python3 scripts/cde-phase1-audit.py "<folder>" --wc /tmp/wc

The queue defaults to the preserved engine-output snapshot committed with this
script. `--wc` is a counter built from the app's own SharedTextUtilities.swift:

    swiftc -O -parse-as-library -swift-version 5 -default-isolation MainActor \
      -o /tmp/wc AsterismaV2.0/Core/SharedTextUtilities.swift <counter-main>.swift
"""

from __future__ import annotations

import argparse
import html
import json
import math
import re
import statistics
import subprocess
import sys
from pathlib import Path
from xml.etree import ElementTree as ET

TAG_RE = re.compile(r"<[^>]+>")
WS_RE = re.compile(r"\s+")
SAMPLE_CHARS = 5000
WP = 250.0
DEFAULT_SECONDS_PER_PAGE = 120.0


def spine_files(package: Path) -> list[Path]:
    """Return the spine documents of one package directory, in reading order."""
    container = ET.fromstring((package / "META-INF/container.xml").read_bytes())
    opf_rel = None
    for el in container.iter():
        if el.tag.endswith("rootfile"):
            opf_rel = el.attrib.get("full-path")
            break
    if not opf_rel:
        return []
    opf_path = package / opf_rel
    opf = ET.fromstring(opf_path.read_bytes())
    base = opf_path.parent

    manifest: dict[str, str] = {}
    for el in opf.iter():
        if el.tag.endswith("item"):
            manifest[el.attrib.get("id", "")] = el.attrib.get("href", "")
    ordered: list[Path] = []
    for el in opf.iter():
        if el.tag.endswith("itemref"):
            href = manifest.get(el.attrib.get("idref", ""))
            if not href:
                continue
            ordered.append(base / href)
    return [p for p in ordered if p.exists()]


def plain(path: Path) -> str:
    try:
        raw = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""
    raw = re.sub(r"<(script|style)[^>]*>[\s\S]*?</\1>", " ", raw, flags=re.I)
    return WS_RE.sub(" ", html.unescape(TAG_RE.sub(" ", raw)))


def python_words(files: list[Path]) -> int:
    return sum(len(plain(f).split()) for f in files)


def swift_words(files: list[Path], wc: str) -> int | None:
    if not files:
        return None
    total = 0
    for chunk in [files[i:i + 40] for i in range(0, len(files), 40)]:
        out = subprocess.run(
            [wc, *[str(p) for p in chunk]], capture_output=True, text=True
        )
        if out.returncode != 0:
            return None
        for line in out.stdout.strip().splitlines():
            parts = line.rsplit("\t", 1)
            if len(parts) == 2 and parts[1].isdigit():
                total += int(parts[1])
    return total


def predicted_hours(words: int, m: float) -> float:
    """Reproduce the recorded estimate: ceil(W*m/250) pages at a flat 120 s/page.

    Difficulty enters through the page count only. That is the measured
    behaviour of the audited path, not an assumption: with this formula the
    recorded hours reproduce to within rounding on every book.
    """
    pages = max(1, math.ceil(words * max(0.1, m) / WP))
    current = pages // 3
    remaining = max(0, pages - 1 - current)
    return remaining * DEFAULT_SECONDS_PER_PAGE / 3600.0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("folder")
    ap.add_argument(
        "--queue",
        default="docs/audits/evidence/cde-phase1-engine-output-2026-10-29.json",
    )
    ap.add_argument("--wc", default="/tmp/wc")
    args = ap.parse_args()

    queue = json.loads(Path(args.queue).read_text())
    folder = Path(args.folder)

    rows = []
    for entry in queue:
        if entry.get("dup_of") is not None:
            continue
        engine = entry["engine"]
        rows.append({
            "title": entry["title"],
            "words": entry["words"],
            "m": engine["difficultyMultiplier"],
            "label": engine["difficultyLabel"],
            "grade": engine["gradeLevel"],
            "pages": math.ceil(entry["words"] * engine["difficultyMultiplier"] / WP),
            "hours": engine["hoursAt120s"],
            "package": folder / entry["file"],
        })

    # 1. Closed form: difficulty enters once, through the page count --------
    errors = []
    for r in rows:
        pred = predicted_hours(r["words"], r["m"])
        errors.append(abs(pred - r["hours"]) / r["hours"] if r["hours"] else 0)
    print("== 1. closed form: hours = f(words, multiplier), flat 120 s/page ==")
    print(f"books: {len(rows)}")
    print(f"max relative error: {max(errors):.6f}")
    print(f"median relative error: {statistics.median(errors):.6f}")
    print(f"books within 0.5%: {sum(1 for e in errors if e < 0.005)}/{len(errors)}")

    # 2. Multiplier distribution --------------------------------------------
    ms = sorted(r["m"] for r in rows)
    print("\n== 2. difficulty multiplier distribution ==")
    print(f"min {ms[0]:.3f}  p25 {ms[len(ms)//4]:.3f}  median {statistics.median(ms):.3f}"
          f"  p75 {ms[3*len(ms)//4]:.3f}  max {ms[-1]:.3f}")
    print(f"at ceiling (>=1.99): {sum(1 for m in ms if m >= 1.99)}")
    print(f"at floor (<=0.51):   {sum(1 for m in ms if m <= 0.51)}")
    print(f"median m^2 (what the second path would apply): "
          f"{statistics.median(ms)**2:.3f}")

    labels: dict[str, int] = {}
    for r in rows:
        labels[r["label"]] = labels.get(r["label"], 0) + 1
    print("label counts:")
    for k in ["Easy", "Light", "Moderate", "Challenging", "Dense"]:
        if k in labels:
            print(f"  {k:12s} {labels[k]}")

    # 3. Named diagnostics ---------------------------------------------------
    print("\n== 3. named diagnostic cases ==")
    wanted = [
        "In the Woods", "The Likeness", "Jade City", "Jade Legacy",
        "The Lion, the Witch and the Wardrobe", "Prince Caspian",
        "The Silver Chair", "The Last Battle",
        "TBATE: Ascension (Book 8)", "Spy Classroom, Vol. 3",
        "Spy Classroom, Vol. 10", "A Game of Thrones",
        "Crime and Punishment", "Don Quixote (Grossman)",
    ]
    for name in wanted:
        for r in rows:
            if r["title"] == name:
                print(f"  {r['title'][:42]:42s} m={r['m']:.3f} "
                      f"{r['label']:11s} pages={r['pages']:6d} h={r['hours']:7.2f}")

    # 4. Extraction agreement ------------------------------------------------
    print("\n== 4. Swift word counter vs independent Python count ==")
    pairs = []
    for r in rows:
        if not r["package"].is_dir():
            continue
        files = spine_files(r["package"])
        if not files:
            continue
        swift = swift_words(files, args.wc)
        if swift is None:
            continue
        cp = python_words(files)
        if cp:
            pairs.append((r["title"], cp, swift, len(files)))

    if pairs:
        rel = [abs(s - p) / p for _, p, s, _ in pairs]
        print(f"books compared: {len(pairs)}")
        print(f"median |swift-python|/python: {statistics.median(rel):.4f}")
        print(f"mean   |swift-python|/python: {statistics.mean(rel):.4f}")
        print(f"books off by >5%:  {sum(1 for x in rel if x > 0.05)}")
        print(f"books off by >20%: {sum(1 for x in rel if x > 0.20)}")
        worst = sorted(pairs, key=lambda t: -abs(t[2] - t[1]) / t[1])[:6]
        print("worst disagreements:")
        for title, p, s, n in worst:
            print(f"  {title[:38]:38s} python={p:8d} swift={s:8d} "
                  f"spine={n:3d} dev={100*(s-p)/p:+7.1f}%")

    # 5. Sample coverage -----------------------------------------------------
    print("\n== 5. what the 5,000-character difficulty sample covers ==")
    coverages = []
    for r in rows:
        if not r["package"].is_dir():
            continue
        files = spine_files(r["package"])
        if not files:
            continue
        collected = ""
        for f in files:
            if len(collected) >= SAMPLE_CHARS:
                break
            collected += plain(f) + "\n"
        sample_words = len(collected[:SAMPLE_CHARS].split())
        total = python_words(files)
        if total and sample_words:
            coverages.append(sample_words / total)
    if coverages:
        coverages.sort()
        print(f"books: {len(coverages)}")
        print(f"median share of book in sample: {100*statistics.median(coverages):.2f}%")
        print(f"min {100*coverages[0]:.2f}%   max {100*coverages[-1]:.2f}%")

    return 0


if __name__ == "__main__":
    sys.exit(main())
