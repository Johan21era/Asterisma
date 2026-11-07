#!/usr/bin/env python3
"""Mechanical evidence collector for the Markdown truth audit.

This does not judge prose. It extracts the claims a machine can settle and
reports them with byte-level evidence: the file digest and line count, every
backticked repository path, every `path:line` anchor (with the target line's
text), every 64-hex hash, and every command in a bash fence.

Exit status is 1 when a path is missing or an anchor is outside its file.
The weighted prose rubric lives in AGENTS.md; record its result in
docs/registers/05-doc-audit.md.

Usage:
    python3 scripts/audit-markdown.py                 # every tracked .md
    python3 scripts/audit-markdown.py README.md docs/INDEX.md
    python3 scripts/audit-markdown.py --json /tmp/md-audit.json README.md
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

PATH_ROOTS = (
    "AsterismaV2.5/",
    "AsterismaV2.5Tests/",
    "AsterismaV2.5UITests/",
    "AsterismaV2.5.xcodeproj/",
    "docs/",
    "scripts/",
    "graphify-out/",
    ".github/",
)
ROOT_FILES = {
    "README.md",
    "AGENTS.md",
    "DBappends.md",
    "merge-log.md",
    "AsterismaV2.5-Info.plist",
    "AsterismaV2.5.entitlements",
    ".gitignore",
}

BACKTICK = re.compile(r"`([^`\n]+)`")
HASH_64 = re.compile(r"\b[0-9a-f]{64}\b")
ANCHOR = re.compile(r"^(?P<path>[^#:]+?)(?:#L(?P<start>\d+)(?:-L(?P<end>\d+))?|:(?P<colon>\d+)(?:-(?P<colon_end>\d+))?)?$")
SKIP_FRAGMENTS = ("*", "?", "<", ">", "{", "}", "[", "]", "$", "~", "://", " ")


def tracked_markdown() -> list[str]:
    result = subprocess.run(
        ["git", "ls-files", "-z", "--", "*.md"], cwd=ROOT, capture_output=True, text=True
    )
    return [path for path in result.stdout.split("\0") if path]


def repository_path(token: str) -> str | None:
    token = token.strip().strip(".,;:)")
    if not token or any(fragment in token for fragment in SKIP_FRAGMENTS):
        return None
    if token.startswith("./"):
        token = token[2:]
    if token.rstrip("/") in ROOT_FILES:
        return token.rstrip("/")
    if any(token.startswith(root) for root in PATH_ROOTS):
        return token
    return None


def resolve(token: str) -> dict:
    match = ANCHOR.match(token)
    if not match:
        return {"ref": token, "kind": "unparsed", "ok": False}
    path = match.group("path")
    start = match.group("start") or match.group("colon")
    end = match.group("end") or match.group("colon_end") or start
    target = ROOT / path
    record = {"ref": token, "path": path, "ok": True}
    if not target.exists():
        record.update({"kind": "missing", "ok": False})
        return record
    if target.is_dir():
        record.update({"kind": "directory"})
        return record
    record["kind"] = "file"
    if start is not None:
        lines = target.read_text(encoding="utf-8", errors="ignore").splitlines()
        record["lines"] = len(lines)
        record["anchor"] = f"{start}-{end}"
        if int(start) < 1 or int(end) > len(lines):
            record.update({"kind": "anchor-out-of-range", "ok": False})
        else:
            record["target_line"] = lines[int(start) - 1].strip()[:160]
    return record


def bash_commands(text: str) -> list[str]:
    commands: list[str] = []
    inside = False
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("```"):
            inside = not inside and stripped.lower() in ("```bash", "```sh", "```zsh")
            continue
        if inside and stripped and not stripped.startswith("#"):
            commands.append(stripped)
    return commands


def audit(path: str) -> dict:
    raw = (ROOT / path).read_bytes()
    text = raw.decode("utf-8", errors="ignore")
    refs: list[dict] = []
    seen: set[str] = set()
    for token in BACKTICK.findall(text):
        candidate = repository_path(token)
        if not candidate or candidate in seen:
            continue
        seen.add(candidate)
        refs.append(resolve(candidate))
    failures = [ref for ref in refs if not ref["ok"]]
    return {
        "path": path,
        "sha256": hashlib.sha256(raw).hexdigest(),
        "bytes": len(raw),
        "lines": len(text.splitlines()),
        "paths": len(refs),
        "failures": failures,
        "hashes": HASH_64.findall(text),
        "commands": bash_commands(text),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("files", nargs="*")
    parser.add_argument("--json", type=Path)
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args(argv)

    files = args.files or tracked_markdown()
    reports = [audit(path) for path in files]
    failed = 0
    for report in reports:
        status = "FAIL" if report["failures"] else "OK"
        print(
            f"{status:4} {report['path']}  {report['lines']} lines  "
            f"{report['bytes']} B  sha256 {report['sha256'][:12]}…  "
            f"paths {report['paths']}  commands {len(report['commands'])}"
        )
        for failure in report["failures"]:
            failed += 1
            print(f"     missing/anchor: {failure['ref']} ({failure['kind']})")
        if not args.quiet and report["hashes"]:
            for digest in report["hashes"]:
                print(f"     sha256 claim: {digest}")
        if not args.quiet:
            for command in report["commands"]:
                print(f"     command: {command}")
    if args.json:
        args.json.write_text(json.dumps(reports, indent=2) + "\n", encoding="utf-8")
        print(f"report: {args.json}")
    if failed:
        print(f"{failed} broken path/anchor claim(s)", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
