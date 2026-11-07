#!/usr/bin/env python3
"""Build standalone, offline 3D graph pages from graphify-out/graph.json.

The output is a single HTML file: embedded graph data, embedded renderer, no
CDN, no server, no network calls. Open it with:

    open graphify-out/graph-3d-full.html

This is the only 3D view: every graph node (7,621 nodes / 19,186 edges at the
2026-10-29 build). The aggregated community view was retired on
2026-10-29 — `graphify-out/graph.html` is the 2D community export.

Examples:

    python3 scripts/build-graph-3d.py
    python3 scripts/build-graph-3d.py --check
"""

from __future__ import annotations

import argparse
import collections
import hashlib
import html
import json
import math
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
GRAPHIFY_OUT = ROOT / "graphify-out"
DEFAULT_GRAPH = GRAPHIFY_OUT / "graph.json"
DEFAULT_LABELS = GRAPHIFY_OUT / ".graphify_labels.json"
TEMPLATE = ROOT / "scripts" / "graph3d-template.html"
LIBRARY = ROOT / "scripts" / "vendor" / "3d-force-graph-1.80.2.min.js"
LICENSE = ROOT / "scripts" / "vendor" / "3d-force-graph-1.80.2.LICENSE"

# Tableau 10, the same palette graphify's 2D export uses for communities.
PALETTE = [
    "#4E79A7",
    "#F28E2B",
    "#E15759",
    "#76B7B2",
    "#59A14F",
    "#EDC948",
    "#B07AA1",
    "#FF9DA7",
    "#9C755F",
    "#BAB0AC",
]

OUTPUT_NAME = "graph-3d-full.html"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def node_id(value: Any) -> str | None:
    """graph.json uses string ids; links may already be id strings."""
    if isinstance(value, dict):
        value = value.get("id")
    if value is None:
        return None
    return str(value)


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def load_graph(graph_path: Path, labels_path: Path) -> tuple[list[dict], list[dict], dict, dict[int, str], dict]:
    graph = load_json(graph_path)
    if not isinstance(graph, dict):
        raise SystemExit(f"{graph_path}: expected a JSON object")
    nodes = graph.get("nodes") or []
    links = graph.get("links") or []
    if not isinstance(nodes, list) or not isinstance(links, list):
        raise SystemExit(f"{graph_path}: expected 'nodes' and 'links' arrays")

    labels: dict[int, str] = {}
    if labels_path.exists():
        raw_labels = load_json(labels_path)
        if isinstance(raw_labels, dict):
            for key, value in raw_labels.items():
                try:
                    labels[int(key)] = str(value)
                except (TypeError, ValueError):
                    continue

    node_degrees: collections.Counter[str] = collections.Counter()
    for link in links:
        source = node_id(link.get("source"))
        target = node_id(link.get("target"))
        if source is None or target is None or source == target:
            continue
        node_degrees[source] += 1
        node_degrees[target] += 1

    return nodes, links, labels, node_degrees, graph


def full_view(
    nodes: list[dict],
    links: list[dict],
    labels: dict[int, str],
    node_degrees: collections.Counter[str],
    graph: dict,
    meta: dict,
) -> dict:
    ids = {str(node.get("id")) for node in nodes if node.get("id") is not None}
    view_nodes: list[dict] = []
    communities: set[str] = set()

    for node in nodes:
        identifier = node_id(node.get("id"))
        if identifier is None:
            continue
        cid = node.get("community")
        try:
            cid = int(cid) if cid is not None else None
        except (TypeError, ValueError):
            cid = None
        community_name = labels.get(cid, "") if cid is not None else ""
        if not community_name:
            community_name = str(node.get("community_name") or "Unassigned")
        if cid is not None:
            communities.add(str(cid))
        degree = int(node_degrees.get(identifier, 0))
        view_nodes.append(
            {
                "id": identifier,
                "label": str(node.get("label") or identifier),
                "community": cid if cid is not None else -1,
                "communityName": community_name,
                "color": PALETTE[cid % len(PALETTE)] if cid is not None else "#8ab4f8",
                "val": round(1.0 + math.sqrt(max(1, degree)) * 0.5, 2),
                "degree": degree,
                "type": str(node.get("file_type") or ""),
                "file": str(node.get("source_file") or ""),
                "loc": str(node.get("source_location") or ""),
            }
        )

    view_links: list[dict] = []
    dropped = 0
    for link in links:
        source = node_id(link.get("source"))
        target = node_id(link.get("target"))
        if source is None or target is None or source not in ids or target not in ids:
            dropped += 1
            continue
        view_links.append(
            {
                "source": source,
                "target": target,
                "relation": str(link.get("relation") or "link"),
                "confidence": str(link.get("confidence") or ""),
                "weight": link.get("weight") if isinstance(link.get("weight"), (int, float)) else 1,
                "directed": True,
            }
        )

    if dropped:
        print(f"  note: dropped {dropped:,} links whose endpoints are not nodes", file=sys.stderr)

    payload = {
        "mode": "full",
        "title": "Graphify 3D — AsterismaV2.5 full view",
        "subtitle": (
            f"{len(view_nodes):,} nodes · {len(view_links):,} edges · "
            f"{len(communities):,} communities · hover a node to inspect"
        ),
        "stats": {
            "sourceNodes": len(nodes),
            "sourceLinks": len(links),
            "communities": len(communities),
            "viewNodes": len(view_nodes),
            "viewLinks": len(view_links),
        },
        "meta": dict(meta),
        "nodes": view_nodes,
        "links": view_links,
    }
    return payload


def safe_json(payload: dict) -> str:
    raw = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    # Inside <script type="application/json">, '<' is the only character that
    # can terminate the element early. \u003c keeps the JSON equivalent.
    return raw.replace("<", "\\u003c")


def build_html(payload: dict, template: str, library: str, license_text: str) -> str:
    title = html.escape(str(payload.get("title") or "Graphify 3D"), quote=True)
    output = (
        template.replace("%%TITLE%%", title)
        .replace("%%GRAPH_DATA%%", safe_json(payload))
        .replace("%%LIBRARY%%", library)
        .replace("%%LICENSE%%", html.escape(license_text))
    )
    if "%%" in output:
        raise SystemExit("template token left unreplaced; refusing to write a broken page")
    return output


def verify_renderer(library: str) -> None:
    if "ForceGraph3D" not in library:
        raise SystemExit(f"{LIBRARY}: does not look like the 3d-force-graph UMD bundle")
    if "</script" in library.lower():
        raise SystemExit(f"{LIBRARY}: contains '</script' and cannot be inlined safely")


def write_atomic(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(content, encoding="utf-8")
    temporary.replace(path)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--graph", type=Path, default=DEFAULT_GRAPH)
    parser.add_argument("--labels", type=Path, default=DEFAULT_LABELS)
    parser.add_argument("--out-dir", type=Path, default=GRAPHIFY_OUT)
    parser.add_argument("--check", action="store_true", help="verify the existing files match a fresh build")
    args = parser.parse_args(argv)

    if not TEMPLATE.exists():
        raise SystemExit(f"missing template: {TEMPLATE}")
    if not LIBRARY.exists():
        raise SystemExit(f"missing renderer: {LIBRARY}")
    if not LICENSE.exists():
        raise SystemExit(f"missing renderer license: {LICENSE}")
    if not args.graph.exists():
        raise SystemExit(f"missing graph: {args.graph}")

    template = TEMPLATE.read_text(encoding="utf-8")
    library = LIBRARY.read_text(encoding="utf-8")
    license_text = LICENSE.read_text(encoding="utf-8")
    verify_renderer(library)

    nodes, links, labels, node_degrees, graph = load_graph(args.graph, args.labels)
    source_hash = sha256_file(args.graph)
    library_hash = sha256_file(LIBRARY)
    commit = graph.get("built_at_commit") or "unknown"
    meta = {
        "source": str(args.graph.relative_to(ROOT)) if args.graph.is_relative_to(ROOT) else str(args.graph),
        "sourceSha256": source_hash,
        "library": "3d-force-graph 1.80.2",
        "librarySha256": library_hash,
        "builtAtCommit": str(commit),
        "note": (
            f"Source {args.graph.name} SHA-256 {source_hash[:16]}… · commit {commit} · "
            f"renderer 3d-force-graph 1.80.2 (MIT, vendored) · generated by "
            "scripts/build-graph-3d.py"
        ),
    }

    payload = full_view(nodes, links, labels, node_degrees, graph, meta)
    output = build_html(payload, template, library, license_text)
    destination = args.out_dir / OUTPUT_NAME
    if args.check:
        if not destination.exists():
            print(f"MISSING {destination}", file=sys.stderr)
            return 1
        if destination.read_text(encoding="utf-8") != output:
            print(f"STALE   {destination}", file=sys.stderr)
            return 1
        print(f"ok      {destination}")
        return 0

    write_atomic(destination, output)
    print(
        f"wrote   {destination}  "
        f"({len(payload['nodes']):,} nodes / {len(payload['links']):,} links, "
        f"{len(output) / (1024 * 1024):.2f} MiB)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
