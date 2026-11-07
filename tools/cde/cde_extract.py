"""EPUB extraction and deterministic stratified sampling for the CDE.

Two jobs, both storage-agnostic:

1. Load the spine in reading order and strip markup, recording what was
   excluded and why (audit defect X12).
2. Select fixed windows across the whole book, so a book-level score cannot be
   decided by the first pages (defect X4).

Sampling is deterministic: window positions are fixed fractions of the book's
character stream, not random draws. Two runs on the same file always sample the
same text, which is what makes a score reproducible.
"""

from __future__ import annotations

import bisect
import html
import re
import zipfile
from pathlib import Path
from xml.etree import ElementTree as ET

TAG_RE = re.compile(r"<[^>]+>")
WS_RE = re.compile(r"[ \t\r\f\v]+")
BLOCK_RE = re.compile(r"</(p|div|h[1-6]|li|blockquote|tr|section|article)>", re.I)
SCRIPT_RE = re.compile(r"<(script|style)[^>]*>[\s\S]*?</\1>", re.I)
NUMERIC_RE = re.compile(r"\b\d+\b")


class Package:
    """One EPUB package: metadata plus ordered spine documents."""

    def __init__(self, title, creator, documents, excluded):
        self.title = title
        self.creator = creator
        self.documents = documents          # list of (name, text)
        self.excluded = excluded            # list of (name, reason, chars)


def _read(reader, root, rel):
    if root is not None:
        return (root / rel).read_bytes()
    return reader.read(rel)


def strip_markup(raw):
    """HTML to plain text. Keeps paragraph breaks; drops scripts and styles."""
    text = SCRIPT_RE.sub(" ", raw)
    text = BLOCK_RE.sub("\n", text)
    text = TAG_RE.sub(" ", text)
    text = html.unescape(text)
    text = WS_RE.sub(" ", text)
    text = re.sub(r"\n\s*\n+", "\n", text)
    return text.strip()


def load_package(path):
    """Read one .epub directory or zip. Returns a Package; raises on bad input."""
    path = Path(path)
    if path.is_dir():
        reader, root = None, path
    else:
        reader, root = zipfile.ZipFile(path), None

    container = ET.fromstring(_read(reader, root, "META-INF/container.xml"))
    opf_rel = None
    for el in container.iter():
        if el.tag.endswith("rootfile"):
            opf_rel = el.attrib.get("full-path")
            break
    if not opf_rel:
        raise ValueError("no rootfile in container.xml")

    opf = ET.fromstring(_read(reader, root, opf_rel))
    opf_dir = Path(opf_rel).parent

    manifest, title, creator = {}, "", ""
    for el in opf.iter():
        if el.tag.endswith("item"):
            manifest[el.attrib.get("id", "")] = el.attrib.get("href", "")
        elif el.tag.endswith("title") and not title:
            title = (el.text or "").strip()
        elif el.tag.endswith("creator") and not creator:
            creator = (el.text or "").strip()

    documents, excluded = [], []
    for el in opf.iter():
        if not el.tag.endswith("itemref"):
            continue
        href = manifest.get(el.attrib.get("idref", ""))
        if not href:
            continue
        try:
            payload = _read(reader, root, str(opf_dir / href))
        except (KeyError, OSError):
            excluded.append((href, "unreadable", 0))
            continue
        if href.lower().endswith((".jpg", ".jpeg", ".png", ".gif", ".svg")):
            excluded.append((href, "image", 0))
            continue
        text = strip_markup(payload.decode("utf-8", errors="replace"))
        if not text:
            excluded.append((href, "empty", 0))
            continue
        documents.append((href, text))

    return Package(title, creator, documents, excluded)


def _doc_eligible(name, text):
    """Reject navigation, index and table documents before they reach a score."""
    low = name.lower()
    if "nav" in low or "toc" in low or "contents" in low:
        return False, "navigation"
    if not text:
        return False, "empty"
    sample = text[:3000]
    tokens = sample.split()
    if len(tokens) < 30:
        return False, "too short"
    numeric = sum(1 for t in tokens if NUMERIC_RE.fullmatch(t.strip(".,;:()")))
    if numeric / len(tokens) > 0.25:
        return False, "numeric"
    mean_line = sum(len(line.split()) for line in text.split("\n")[:60]) / max(
        1, len(text.split("\n")[:60])
    )
    if mean_line < 3.0:
        return False, "list-like"
    return True, ""


def select_windows(package, count=12, tokens_per_window=1200):
    """Pick `count` windows at fixed fractions of the book's character stream."""
    eligible = []
    skipped = list(package.excluded)
    for name, text in package.documents:
        ok, reason = _doc_eligible(name, text)
        if ok:
            eligible.append((name, text))
        else:
            skipped.append((name, reason, len(text)))

    if not eligible:
        return [], skipped, 0

    total = sum(len(t) for _, t in eligible)
    starts, run = [], 0
    for _, text in eligible:
        starts.append(run)
        run += len(text)

    windows = []
    for i in range(count):
        frac = 0.02 + (0.95 * (i + 0.5) / count)
        offset = int(frac * total)
        doc_index = max(0, bisect.bisect_right(starts, offset) - 1)
        local = offset - starts[doc_index]
        chunk = ""
        j = doc_index
        while j < len(eligible) and len(chunk) < tokens_per_window * 8:
            text = eligible[j][1]
            begin = local if j == doc_index else 0
            chunk += text[begin:begin + tokens_per_window * 8] + "\n"
            j += 1
        windows.append({
            "index": i,
            "position": round(frac, 4),
            "document": eligible[doc_index][0],
            "text": chunk.strip(),
        })

    return windows, skipped, total
