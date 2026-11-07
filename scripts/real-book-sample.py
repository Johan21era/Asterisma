#!/usr/bin/env python3
"""Print the evidence a human needs to grade one slice of the test library.

This script assigns no verdicts. It exists so that every hand grade in
docs/audits/new-era-testing.md can cite the exact prose the grader read,
taken from the *middle* of a book rather than its title page or front
matter — the inventory script's ``--sample`` reads from the first document,
which is often a title page and is therefore the wrong evidence for judging
difficulty.

For each book in the requested slice it prints:

  index, title, creator, language, words
  engine row from the audit JSON (pages, multiplier, label, hours per pace)
  an excerpt of ``--words`` words starting ``--at`` through the document

Usage:
  python3 scripts/real-book-sample.py "<folder>" --audit /tmp/real-books-audit.json \
      --start 21 --count 10

Read-only: the folder is never modified.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def load_inventory():
    spec = importlib.util.spec_from_file_location(
        "real_book_inventory", ROOT / "real-book-inventory.py"
    )
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def excerpt(documents: list[tuple[str, str]], words: int, at: float) -> str:
    """A contiguous window from the longest document, `at` through it."""
    if not documents:
        return ""
    _, text = max(documents, key=lambda d: len(d[1]))
    tokens = text.split()
    if not tokens:
        return ""
    start = int(len(tokens) * at)
    start = max(0, min(start, max(0, len(tokens) - words)))
    return " ".join(tokens[start:start + words])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("folder")
    parser.add_argument("--audit", help="JSON written by tools/real-book-audit")
    parser.add_argument("--start", type=int, default=1, help="1-based index")
    parser.add_argument("--count", type=int, default=10)
    parser.add_argument("--words", type=int, default=220)
    parser.add_argument("--at", type=float, default=0.4,
                        help="fraction through the longest document")
    args = parser.parse_args()

    inv = load_inventory()
    folder = Path(args.folder).expanduser()
    if not folder.is_dir():
        print(f"not a folder: {folder}", file=sys.stderr)
        return 2

    audit = {}
    if args.audit:
        for row in json.loads(Path(args.audit).read_text()):
            audit[row["title"]] = row

    end = args.start + args.count - 1
    for index, entry in enumerate(inv.iter_epubs(folder), start=1):
        if index < args.start or index > end:
            continue
        data = inv.read_epub_text(entry)
        row = audit.get(data["title"], {})
        print(f"\n===== {index}. {data['title']} =====")
        print(f"creator: {data['creator']}   language: {data['language']}   "
              f"words: {data['words']}   spine: {data['spineDocuments']}")
        if row:
            print(
                "engine: pages {pages} | multiplier {difficultyMultiplier} | "
                "label {difficultyLabel} | grade {gradeLevel} | "
                "hours@60 {hoursAt60s} | hours@90 {hoursAt90s} | "
                "hours@120 {hoursAt120s} | status {statusAt120s}".format(**row)
            )
        else:
            print("engine: NO ROW")
        print(f"--- excerpt ({args.words} words from {args.at:.0%} through) ---")
        print(excerpt(data["documents"], args.words, args.at))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
