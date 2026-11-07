#!/usr/bin/env python3
"""Report which EPUB packages actually contain pagination.

Pages are a property of a screen and a font size in a reflowable EPUB, not a
property of the book. This script answers one question, with counts only:
how many packages in a folder carry real page-break markers, and how many
declare a page count in their package document?

It assigns no verdict and grades nothing. It exists so the claim "most of this
library has no pages" can be re-derived from the files instead of taken on a
grader's word.

Usage:
    python3 scripts/real-book-pagination.py "/path/to/asterisma new testing suite"

Exit status: 0 on success, 2 if the folder is missing or contains no packages.

Marker detection is the token `pagebreak` or `page-break` (case-insensitive) in
any .xhtml/.html/.htm file. A package using an unusual convention would be
missed, so the "no markers" count is an upper bound, not a proof.
"""

import os
import re
import sys

MARKER = re.compile(rb"pagebreak|page-break", re.I)
DECLARED = re.compile(rb"numberOfPages|number-of-pages|dcterms:extent")
THRESHOLD = 5


def packages(folder):
    """Return the .epub entries that are directories (unzipped packages)."""
    entries = sorted(os.listdir(folder))
    return [
        os.path.join(folder, name)
        for name in entries
        if name.lower().endswith(".epub") and os.path.isdir(os.path.join(folder, name))
    ]


def scan(path):
    """Count page markers in the XHTML and any page-count declaration in the OPF."""
    markers = 0
    declared = False
    for root, _, files in os.walk(path):
        for name in files:
            low = name.lower()
            try:
                if low.endswith((".xhtml", ".html", ".htm")):
                    with open(os.path.join(root, name), "rb") as handle:
                        markers += len(MARKER.findall(handle.read()))
                elif low.endswith(".opf"):
                    with open(os.path.join(root, name), "rb") as handle:
                        if DECLARED.search(handle.read()):
                            declared = True
            except OSError:
                continue
    return markers, declared


def main(argv):
    if len(argv) != 2:
        print(__doc__.strip().split("\n\n")[2], file=sys.stderr)
        return 2
    folder = argv[1]
    if not os.path.isdir(folder):
        print(f"real-book-pagination: not a directory: {folder}", file=sys.stderr)
        return 2
    found = packages(folder)
    if not found:
        print(f"real-book-pagination: no .epub packages in {folder}", file=sys.stderr)
        return 2

    paginated = []
    unpaginated = []
    declared_any = []
    for path in found:
        markers, declared = scan(path)
        (paginated if markers >= THRESHOLD else unpaginated).append((path, markers))
        if declared:
            declared_any.append(path)

    print(f"packages: {len(found)}")
    print(f"with >= {THRESHOLD} pagebreak markers: {len(paginated)}")
    print(f"with fewer than {THRESHOLD}: {len(unpaginated)}")
    print(f"declaring a page count in the OPF: {len(declared_any)}")
    if paginated:
        print("\nhighest marker counts:")
        for path, markers in sorted(paginated, key=lambda item: -item[1])[:10]:
            print(f"  {markers:6d}  {os.path.basename(path)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
