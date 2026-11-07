#!/usr/bin/env python3
"""sentinel-surface.py — derive Sentinel's surface manifest from Swift source.

Why this exists
---------------
Sentinel's probes are hand-registered. That is correct for rule semantics and
wrong for coverage: a feature can add a table, a persisted key, or a
notification and Sentinel will not know the surface exists until a human adds a
probe. This scanner closes the *inventory* half of that gap. It walks the app
sources, extracts the declarative surfaces that probes can check generically,
and emits a generated Swift catalog that the runtime consumes:

    sql.table          every table the app creates
    defaults.key       every literal UserDefaults key the app reads
    notification.name  every Notification.Name the app defines

The runtime side (`SQL-016`, `SELF-011`) treats the manifest as the source of
truth, so a table added tomorrow is contract-checked on the next build with zero
new Swift probes. Freshness is enforced by `scripts/verify-sentinel-surface.sh`
and a CI step, so a manifest that was not regenerated fails loudly instead of
silently omitting the new surface.

Deliberately not scanned
------------------------
* Codable type declarations. A type name is not a state surface; the stored
  payload columns are already checked by SQL-007/SQL-013 and by SQL-016's
  per-table JSON-column contract. Type-level coverage would add hundreds of
  names with no probe that could honestly claim them.
* Test sources. They are fixtures, not shipped surface.
* The generated file itself, to keep regeneration idempotent.

Determinism
-----------
Output depends only on the set of matched strings, sorted. No timestamps, no
paths, no counts that change when an unrelated comment is edited. `--check`
therefore compares bytes, not semantics.
"""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = ROOT / "AsterismaV2.5"
OUTPUT = SOURCE_ROOT / "Core" / "Sentinel" / "Generated" / "SentinelSurface.generated.swift"

SCHEMA_VERSION = 1

TABLE_PATTERNS = (
    re.compile(r'db\.create\(table:\s*"([^"]+)"'),
    re.compile(
        r"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?[\"`\[]?([A-Za-z_][A-Za-z0-9_]*)",
        re.IGNORECASE,
    ),
)

# Every UserDefaults read with a literal key. `forKey:` covers string, bool,
# integer, double, object, data, and url variants.
DEFAULTS_PATTERN = re.compile(r'forKey:\s*"([^"]+)"')

# Declarations only: a name that is posted or observed must be defined somewhere,
# and the definition is what belongs in the inventory.
NOTIFICATION_PATTERN = re.compile(r'Notification\.Name\("([^"]+)"\)')


def swift_files() -> list[Path]:
    files = []
    for path in SOURCE_ROOT.rglob("*.swift"):
        if "Generated" in path.parts:
            continue
        files.append(path)
    return sorted(files)


def scan() -> dict[str, list[str]]:
    tables: set[str] = set()
    defaults: set[str] = set()
    notifications: set[str] = set()

    for path in swift_files():
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as error:
            raise SystemExit(f"sentinel-surface: cannot read {path}: {error}")

        for pattern in TABLE_PATTERNS:
            tables.update(pattern.findall(text))
        defaults.update(DEFAULTS_PATTERN.findall(text))
        notifications.update(NOTIFICATION_PATTERN.findall(text))

    return {
        "sql.table": sorted(tables),
        "defaults.key": sorted(defaults),
        "notification.name": sorted(notifications),
    }


def digest(surfaces: dict[str, list[str]]) -> str:
    canonical = "\n".join(
        f"{family}\t{name}"
        for family in sorted(surfaces)
        for name in surfaces[family]
    )
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()[:16]


def swift_string_array(values: list[str], indent: str = "        ") -> str:
    if not values:
        return "[]"
    lines = ",\n".join(f'{indent}    "{value}"' for value in values)
    return "[\n" + lines + ",\n" + indent + "]"


def render(surfaces: dict[str, list[str]]) -> str:
    tables = surfaces["sql.table"]
    defaults = surfaces["defaults.key"]
    notifications = surfaces["notification.name"]
    fingerprint = digest(surfaces)
    total = len(tables) + len(defaults) + len(notifications)

    return f'''//  SentinelSurface.generated.swift
//  AsterismaV2.5
//
//  GENERATED FILE — do not edit by hand.
//  Regenerate: ./scripts/sentinel-surface.py --write
//  Freshness:  ./scripts/verify-sentinel-surface.sh
//
//  Source-derived surface inventory: {total} surfaces
//  ({len(tables)} tables, {len(defaults)} defaults keys, {len(notifications)} notification names).
//  SQL-016 and SELF-011 read this catalog; nothing here is hand-maintained.

import Foundation

/// The declarative surfaces Sentinel can own without knowing what a feature is
/// called. Regenerated from source; treated as immutable at runtime.
nonisolated struct SentinelSurfaceCatalog: Codable, Hashable, Sendable {{
    var schemaVersion: Int
    var digest: String
    var sqlTables: [String]
    var defaultsKeys: [String]
    var notificationNames: [String]

    static let empty = SentinelSurfaceCatalog(
        schemaVersion: {SCHEMA_VERSION},
        digest: "empty",
        sqlTables: [],
        defaultsKeys: [],
        notificationNames: [])

    var surfaceCount: Int {{
        sqlTables.count + defaultsKeys.count + notificationNames.count
    }}

    var isEmpty: Bool {{ surfaceCount == 0 }}

    /// Every surface as a stable `<family>.<name>` key. Used by the coverage
    /// policy so a gap is addressable in tests and reports.
    var keys: [String] {{
        sqlTables.map {{ "sql.table.\\($0)" }}
            + defaultsKeys.map {{ "defaults.key.\\($0)" }}
            + notificationNames.map {{ "notification.name.\\($0)" }}
    }}
}}

nonisolated enum SentinelSurfaceRegistry {{
    /// Generated from source at commit checkout. Never mutated at runtime.
    static let current = SentinelSurfaceCatalog(
        schemaVersion: {SCHEMA_VERSION},
        digest: "{fingerprint}",
        sqlTables: {swift_string_array(tables)},
        defaultsKeys: {swift_string_array(defaults)},
        notificationNames: {swift_string_array(notifications)})
}}
'''


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--write", action="store_true", help="rewrite the generated Swift file")
    group.add_argument("--check", action="store_true", help="fail if the generated file is stale")
    group.add_argument("--stdout", action="store_true", help="print the generated Swift file")
    parser.add_argument("--report", action="store_true", help="print surface counts after the action")
    args = parser.parse_args()

    surfaces = scan()
    rendered = render(surfaces)

    if args.stdout:
        sys.stdout.write(rendered)
        return 0

    if args.check:
        if not OUTPUT.exists():
            print(f"sentinel-surface: missing {OUTPUT.relative_to(ROOT)}", file=sys.stderr)
            return 1
        existing = OUTPUT.read_text(encoding="utf-8")
        if existing != rendered:
            print(
                "sentinel-surface: manifest is stale. Run ./scripts/sentinel-surface.py --write",
                file=sys.stderr,
            )
            return 1
        if args.report:
            print(
                f"sentinel-surface: OK — {len(surfaces['sql.table'])} tables, "
                f"{len(surfaces['defaults.key'])} defaults keys, "
                f"{len(surfaces['notification.name'])} notification names"
            )
        return 0

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(rendered, encoding="utf-8")
    if args.report:
        print(
            f"sentinel-surface: wrote {OUTPUT.relative_to(ROOT)} — "
            f"{len(surfaces['sql.table'])} tables, "
            f"{len(surfaces['defaults.key'])} defaults keys, "
            f"{len(surfaces['notification.name'])} notification names"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
