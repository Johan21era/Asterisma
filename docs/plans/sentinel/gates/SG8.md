# Gate SG8 — Auto-extending surface coverage

**Date:** 2026-10-28
**Branch:** `main`
**Base commit:** `76e8a23`; SG8 landed in `29dd4f6`
**State:** executable scope complete and committed; owner acceptance still governed by SG7.

---

## What this gate adds

Before SG8, Sentinel was modular in *rule* design but closed in *inventory*: a
feature could add a table or a stored preference and no probe would know until a
human wrote one. SG8 makes the inventory source-derived and the execution
generic, so a new declarative surface is inspected on the next manifest
regeneration with **zero new probe code**.

Three planes:

| Plane | Implementation | Contract |
|---|---|---|
| Inventory | `scripts/sentinel-surface.py` → `AsterismaV2.5/Core/Sentinel/Generated/SentinelSurface.generated.swift` | Scans app sources for `sql.table`, `defaults.key`, `notification.name`; sorted output, SHA-256 digest prefix, no timestamps |
| Policy | `SentinelSurfaceCoverage.swift` | Only `sql.table` is *required* (a generic probe really enumerates it). Defaults and notifications are advisory: counted, never raised as user issues. Waivers carry reasons. |
| Execution | `SentinelProbesSurface.swift` — `SQL-016`, `SELF-011` | SQL-016 checks every manifest table exists, is readable, and has a primary key. SELF-011 raises one finding per required family when ownership is lost. |

### Catalog delta

| Measure | Before | After |
|---|---:|---:|
| Probes | 138 | **140** |
| Required probes | 56 | **58** |
| Domains | 15 | 15 |
| Repairs | 25 | 25 |
| Source-derived surfaces | 0 | **28** (15 tables, 8 defaults keys, 5 notifications) |
| Surfaces with a live owner | — | **22** (15 tables via SQL-016, 7 keys via real probes) |
| Explicit waivers | — | **6** (1 UI-only key, 5 delivery-only notification names) |
| Unaccounted surfaces | — | **0** |

### New files

- `scripts/sentinel-surface.py` — scanner (`--write`, `--check`, `--stdout`, `--report`)
- `scripts/verify-sentinel-surface.sh` — CI freshness gate
- `AsterismaV2.5/Core/Sentinel/Generated/SentinelSurface.generated.swift`
- `AsterismaV2.5/Core/Sentinel/SentinelSurfaceCoverage.swift`
- `AsterismaV2.5/Core/Sentinel/SentinelProbesSurface.swift`
- `AsterismaV2.5Tests/Core/SentinelSurfaceTests.swift`

Modified: `SentinelSnapshot` (carries the catalog), `SentinelProbeCatalog`
(one extension point), `SentinelCatalogTests` (140 pin), CI workflow (freshness
step before the census).

---

## Verification

| Check | Command | Result |
|---|---|---|
| Manifest freshness | `./scripts/verify-sentinel-surface.sh` | **OK — 15 tables, 8 keys, 5 names** |
| Staleness detection | add a temporary Swift file with one `CREATE TABLE` + one `forKey:` read, run the gate | **exit 1**, message: `manifest is stale. Run ./scripts/sentinel-surface.py --write` |
| Debug build | `xcodebuild build -configuration Debug` | **BUILD SUCCEEDED** |
| Release build | `xcodebuild build -configuration Release` | **BUILD SUCCEEDED** |
| Targeted suite | `-only-testing:…/SentinelSurfaceTests -only-testing:…/SentinelCatalogTests` | **23 tests in 2 suites passed, 0.642 s** |
| Full unit census | `./scripts/census.sh --unit-only` | **432 tests / 671 runs, 9 skipped, 0 failed** |
| Surface test functions | `rg -c '@Test' SentinelSurfaceTests.swift` | **11** |

The 11 surface pins prove, in order: catalog completeness and sortedness;
required coverage complete on the shipped catalog; a synthetic table added after
generation is auto-owned; removing `SQL-016` turns every table into a
`owner-not-registered` gap; unknown preferences are advisory only; waivers are
not gaps; SQL-016 silent on a fully migrated database; SQL-016 names a missing
table and does not produce collateral findings; SQL-016 skips with no database;
SELF-011 silent on the shipped catalog; SELF-011 emits one finding per required
family when ownership is lost.

---

## What this does and does not guarantee

**Does**

- A new table, defaults key, or notification is *visible* the moment the
  manifest is regenerated; for tables it is also *executed* against immediately
  by SQL-016 (existence, readability, primary-key contract).
- A stale manifest fails CI before the unit census runs.
- Removing or renaming the auto-probe creates a visible required gap, not a
  silent hole.

**Does not**

- Reflect arbitrary Swift types. Codable declarations are deliberately not
  inventoried: a type name is not a state surface, and no probe could honestly
  claim it. Stored JSON is covered by SQL-007/SQL-013 plus SQL-016's per-table
  read contract.
- Replace feature probes for semantics (referential meaning, business rules).
  It guarantees *structural* coverage of declarative surfaces, not that a new
  feature's behavior is understood.
- Regenerate itself during the Xcode build. Freshness is CI-enforced; a local
  build before regeneration compiles against the previous catalog. Wiring a
  pre-build phase is the next increment if local strictness is wanted.
- Turn defaults keys or notifications into executed checks. They are debt
  visibility (advisory), by design.

---

## Next increments (ordered)

1. **Build-phase regeneration** so a local build cannot compile against a stale
   manifest (currently CI-only).
2. **Column contract family** — extend SQL-016 to assert declared `_json`
   columns validate with `json_valid`, no `NOT NULL` text column is empty, and
   every declared foreign key has an index. Source of columns: `PRAGMA` at
   runtime, so still zero-config.
3. **Self-registering probe bundles** — generate the registry from types
   conforming to `SentinelProbeV2` instead of six hand-maintained `.all` arrays.
   This removes the last central edit when a new domain lands.
4. **Advisory debt surface** — show advisory counts in the Developer Console
   report so unowned preferences are visible without becoming issues.
