# 12 · Sentinel v2 first tranche (2026-10-28)

> **Current status.** This is the execution receipt for the first Sentinel v2 tranche.
> It supersedes every “eight probes / four repairs” description in older docs.
> The program ceiling remains the 700-probe / 120-domain / 350-repair target in
> [SENTINEL-ROADWORK.md](../plans/sentinel/SENTINEL-ROADWORK.md); this tranche ships
> **138 probes / 15 domains / 25 repairs at SG7**; the SG8 postscript below adds two generic probes.

**Branch:** `main`
**Base commit:** `6099e4e`
**Tree state at verification:** committed in `16d6d16`; GitHub `census` green at `bed710a` and `310b9d3`
**Decision:** SG0–SG6 recorded with evidence; **SG7 is HOLD** on the criteria listed below.

> **Postscript (SG8, 2026-10-28).** The post-SG8 census is **432 tests / 671
> runs / 9 skipped / 0 failed**; the 379 / 1,024 table below is the SG7
> snapshot. The catalog now carries **140 probes / 58
> required** after `SQL-016` and `SELF-011`, plus a source-derived surface
> manifest (15 tables, 8 preferences, 5 notification names) enforced by a CI
> freshness gate. SG7's holds are unchanged. See [SG8](../plans/sentinel/gates/SG8.md).

---

## What shipped

| Area | Delivered |
|---|---|
| Domain | Typed `SentinelIssue`, evidence, subjects, severity/impact/risk classes, lifecycle, trend vocabulary, root-cause diagnoses, stable fingerprints |
| Runtime | Serialized `SentinelRuntime` actor, immutable generation snapshots, per-probe budgets/timeouts, honest coverage, single-cycle lock |
| Registry | 138 probes across library, sessions, goals, collections, database, backups, files, weather, audio, behavior, Mirage, app, Sentinel self-audit, security, capacity |
| Repairs | 25 implemented plans: sessions, pages, timings, collections, deadlines, notes, chapters, speed cache, covers, journal, issue store, backups, temp files, notifications, behavior archive |
| Safety | Preview → safety snapshot → exact-subject re-read → apply → verify → rollback; undo for verified repairs; R3 never one-click |
| Journal | Segmented JSONL, checksums, rotation, retention, v1 import; safe projection only |
| Product | Release Health Center (⌘⇧H) with Overview / Issues / History / Checks / Settings; launch card; settings; notification policy; redacted diagnostics export |
| Hygiene | Release-only compile fix; test isolation proof; no menu bar shipped (see holds) |

---

## Verification

| Check | Result |
|---|---|
| Unit census | **379 test functions · 1,024 passed cases · 9 skipped · 0 failed** |
| Sentinel test functions | **151** |
| Parameterized probe-contract cases | **414** (clean, deterministic, privacy × 138 probes) |
| Fast pass (70 books) | **1.31 ms** (budget < 50 ms) |
| Release build | **exit 0** |
| Test isolation | **byte-identical real App Support tree** |
| Census artifact | `rt-census-20261028-152733.xcresult` |

The 9 skips are environment/live-integration gates (Mirage real engine, real-library SQLite parity, live Open-Meteo, benchmark), not Sentinel coverage.

---

## What is not done

1. **SG7 “v1 removed.”** `SentinelEngine` remains for the Debug Developer Console and older pins. The active app path is `SentinelRuntime`.
2. **Localization.** Copy is centralized but English-only; no String Catalog extraction.
3. **Manual owner acceptance.** The ten roadwork scenarios need a human and a copied real library.
4. **Menu bar.** A `MenuBarExtra` implementation hung the test host on the main thread and was removed. The config key is reserved; no toggle is shown.
5. **Accessibility automation.** Labels and native layout exist; VoiceOver and largest-Dynamic-Type checks were not run.
6. **10× SQLite fixture.** Deep-pass timing/memory at 1.38 M timings is unmeasured.
7. **Program ceiling.** 138/15/25 is the first tranche, not 700/120/350.

These are recorded with rollback steps in the [gate index](../plans/sentinel/gates/README.md).

---

## Evidence map

- Gate receipts: [docs/plans/sentinel/gates/](../plans/sentinel/gates/README.md)
- Program plan: [SENTINEL-ROADWORK.md](../plans/sentinel/SENTINEL-ROADWORK.md)
- Runtime: [SentinelRuntime.swift](../../AsterismaV2.5/Core/Sentinel/SentinelRuntime.swift)
- Registry: [SentinelProbeCatalog.swift](../../AsterismaV2.5/Core/Sentinel/SentinelProbeCatalog.swift)
- Repairs: [SentinelRepairCatalog.swift](../../AsterismaV2.5/Core/Sentinel/SentinelRepairCatalog.swift)
- Product surface: [SentinelHealthCenterView.swift](../../AsterismaV2.5/Features/Sentinel/SentinelHealthCenterView.swift)
- Tests: [SentinelCatalogTests.swift](../../AsterismaV2.5Tests/Core/SentinelCatalogTests.swift), [SentinelLaunchAndRepairTests.swift](../../AsterismaV2.5Tests/Core/SentinelLaunchAndRepairTests.swift)
