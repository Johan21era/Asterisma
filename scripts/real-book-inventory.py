#!/usr/bin/env python3
"""Read-only inventory of an unzipped-EPUB test library.

The folder named on the command line is never modified. For every *.epub
entry (a package directory, which this app supports, or a zip archive) the
script reports:

  title, creator, language, subjects
  spine document count
  total word count after tag stripping
  the documented content unit: ceil(words * difficulty / 250)

Difficulty is *not* computed here. This script exists so the content side of a
hand-graded pass is reproducible; engine numbers must come from the app's own
code, never from a second implementation.

Usage:
  python3 scripts/real-book-inventory.py "<folder>" [--json out.json]
  python3 scripts/real-book-inventory.py "<folder>" --sample "Title" [words]
"""
from __future__ import annotations

import argparse
import html
import json
import re
import zipfile
from pathlib import Path
from xml.etree import ElementTree as ET

TAG_RE = re.compile(r"<[^>]+>")
WS_RE = re.compile(r"\s+")


def read_epub_text(path: Path) -> dict:
    """Return metadata plus per-spine-document plain text for one EPUB."""
    if path.is_dir():
        reader = None
        root = path
    else:
        reader = zipfile.ZipFile(path)
        root = None

    def read(rel: str) -> bytes:
        if root is not None:
            return (root / rel).read_bytes()
        return reader.read(rel)

    container = ET.fromstring(read("META-INF/container.xml"))
    opf_rel = None
    for el in container.iter():
        if el.tag.endswith("rootfile"):
            opf_rel = el.attrib.get("full-path")
            break
    if not opf_rel:
        raise ValueError("no rootfile in container.xml")

    opf_dir = Path(opf_rel).parent
    opf = ET.fromstring(read(opf_rel))

    def text_of(tag: str) -> str:
        for el in opf.iter():
            if el.tag.endswith("}" + tag) or el.tag == tag:
                return (el.text or "").strip()
        return ""

    title = text_of("title")
    creator = text_of("creator")
    language = text_of("language")
    subjects = [
        (el.text or "").strip()
        for el in opf.iter()
        if el.tag.endswith("}subject") or el.tag == "subject"
    ]

    manifest: dict[str, str] = {}
    for el in opf.iter():
        if el.tag.endswith("}item") or el.tag == "item":
            mid = el.attrib.get("id")
            href = el.attrib.get("href")
            if mid and href:
                manifest[mid] = href

    spine: list[str] = []
    for el in opf.iter():
        if el.tag.endswith("}itemref") or el.tag == "itemref":
            idref = el.attrib.get("idref")
            if idref and idref in manifest:
                spine.append(manifest[idref])

    documents: list[tuple[str, str]] = []
    for href in spine:
        rel = str(opf_dir / href) if str(opf_dir) != "." else href
        try:
            raw = read(rel)
        except (KeyError, FileNotFoundError):
            continue
        markup = raw.decode("utf-8", errors="replace")
        plain = html.unescape(TAG_RE.sub(" ", markup))
        plain = WS_RE.sub(" ", plain).strip()
        if plain:
            documents.append((href, plain))

    words = sum(len(doc.split()) for _, doc in documents)
    if reader is not None:
        reader.close()

    return {
        "title": title or path.stem,
        "creator": creator,
        "language": language,
        "subjects": subjects,
        "spineDocuments": len(documents),
        "words": words,
        "documents": documents,
    }


def iter_epubs(folder: Path):
    for entry in sorted(folder.iterdir()):
        if entry.name.startswith("."):
            continue
        if entry.is_dir() and (entry / "META-INF" / "container.xml").is_file():
            yield entry
        elif entry.is_file() and entry.suffix.lower() == ".epub":
            yield entry


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("folder")
    parser.add_argument("--json")
    parser.add_argument("--sample")
    parser.add_argument("--manifest", help="write a JSON manifest for tools/real-book-audit")
    parser.add_argument("--sample-words", type=int, default=220)
    args = parser.parse_args()

    folder = Path(args.folder).expanduser()
    if not folder.is_dir():
        print(f"not a folder: {folder}")
        return 2

    if args.sample:
        for entry in iter_epubs(folder):
            data = read_epub_text(entry)
            if data["title"] == args.sample or entry.name == args.sample:
                print(f"# {data['title']} — {data['creator']} ({data['language']})")
                print(f"spine documents: {data['spineDocuments']}, words: {data['words']}")
                words = data["documents"][0][1].split() if data["documents"] else []
                print(" ".join(words[: args.sample_words]))
                return 0
        print("no matching title")
        return 1

    if args.manifest:
        manifest = []
        for entry in iter_epubs(folder):
            data = read_epub_text(entry)
            # Up to 1,200 words across the longest documents: enough for the
            # difficulty analyzer to see real prose, not a title page.
            parts = sorted(data["documents"], key=lambda d: -len(d[1]))[:3]
            sample = " ".join(" ".join(doc.split()[:400]) for _, doc in parts)
            manifest.append({
                "title": data["title"],
                "words": data["words"],
                "sample": sample,
            })
        Path(args.manifest).write_text(
            json.dumps(manifest, indent=1, ensure_ascii=False) + "\n"
        )
        print(f"wrote manifest for {len(manifest)} books: {args.manifest}")
        return 0

    rows = []
    failures = []
    for entry in iter_epubs(folder):
        try:
            data = read_epub_text(entry)
            rows.append({
                "file": entry.name,
                "title": data["title"],
                "creator": data["creator"],
                "language": data["language"],
                "subjects": data["subjects"],
                "spineDocuments": data["spineDocuments"],
                "words": data["words"],
            })
        except Exception as exc:  # noqa: BLE001 - per-book reporting
            failures.append({"file": entry.name, "error": str(exc)})

    words = [r["words"] for r in rows if r["words"] > 0]
    summary = {
        "folder": str(folder),
        "books": len(rows),
        "failures": failures,
        "totalWords": sum(words),
        "minWords": min(words) if words else 0,
        "maxWords": max(words) if words else 0,
        "medianWords": sorted(words)[len(words) // 2] if words else 0,
        "languages": sorted({r["language"] for r in rows if r["language"]}),
        "rows": rows,
    }
    print(json.dumps({k: v for k, v in summary.items() if k != "rows"}, indent=2))
    if args.json:
        Path(args.json).write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n")
        print(f"wrote {args.json}")
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
