# Bedrock Baseline — 2026-10-24 (G0)

**Worktree:** `/Users/johanrembeci/Desktop/Reading Tracker Bedrock`
**Branch:** `bedrock/2026-10-24`
**Base commit:** `bafb9e9` (`main`)
**Xcode:** 27.1 (27A9275) · macOS 26.6.1 host · deployment target 26.5

---

> **Historical baseline.** The numbers below are the starting point. The final
> AsterismaV2.5 census is **213 passed / 0 failed / 9 skipped**; see `GATE-G8.md`.

## Build and census

| Check | Result |
|---|---|
| Debug build | **BUILD SUCCEEDED**, 26.1 s wall (fresh worktree build) |
| Full test run | **TEST SUCCEEDED**, 46.4 s wall |
| Unit census | **191 passed / 0 failed / 4 skipped** (195 cases) |
| UI tests | 4 executed template cases, all pass |
| Baseline `.xcresult` | `Test-AsterismaV2.5-2026.10.24_01-23-44--0400.xcresult` |

## Source

| Metric | Value |
|---|---:|
| App Swift files | 114 |
| App source bytes | 1,580,214 |
| App lines | 42,569 |
| Test files | 34 |
| Test bytes | 230,429 |
| Test lines | 5,272 |
| `@Test` declarations | 193 |

## Real data store (snapshot source)

| Metric | Value |
|---|---:|
| `library.json` | 29,625,947 bytes |
| Books | 7 |
| Sessions | 292 |
| Page timings | 138,459 |
| `library-state.json` | 83,766 bytes |
| Earned achievement records | 592 |
| Unique achievement kinds | 10 |
| Collections | 1 |
| Goals | empty |
| Backups | 10 / ~72 MB |
| Covers | 38 files / 584 KB |
| Weather snapshots | 0 |
| Audio profiles | 3 |

## Data snapshot

- Destination: `~/Desktop/ReadingTracker-Backups/2026-10-24-pre-bedrock/`
  (historical; deleted by the owner on 2026-10-24)
- Contents: `ReadTracker/` app-support tree, 61 files, 102 MB
- Checksum manifest: `SHA256-MANIFEST.txt`
- This snapshot is outside the repo and is the rollback source of record.

## Baseline performance

`scripts/benchmark.sh` operates on a **copy** of the store, never the live one.

| Metric | Baseline |
|---|---:|
| `DataStore` load (29.6 MB / 138k timings) | **493.7 ms** |
| `readerProfile` | 0.93 ms |
| `streak` | 1.46 ms |
| `trendAnalysis` | 0.76 ms |
| `timeOfDayAnalysis` | 0.25 ms |
| `genreProfiles` | 0.21 ms |
| `EstimationEngine.estimate` (one book, full analytics) | **182.1 ms** |

The load target is already met at this data size; the SQLite/lazy work is about
keeping it flat as the library grows, and removing the ~182 ms estimate path
from hover/main-thread interactions.

Baseline app bundle: ~27 MB (Debug, previous build).

## G0 safety changes

- `CoverStore.active` + `testOverride` so tests can use a temp covers directory.
- `SentinelEngine` accepts an injected journal URL; unit tests use a temp journal.
- `DataStore`, `CoverStore`, and `SentinelEngine` honor `RT_TEST_STORE_DIR` for UI-test/app isolation.
- UI tests launch with `RT_TEST_STORE_DIR`.
- `scripts/census.sh`, `scripts/verify-test-isolation.sh`, `scripts/benchmark.sh`.
- `BedrockBaselineTests` (opt-in; not part of default census).

## Known baseline issues (by design, fixed in later gates)

- 592 achievement records (duplicate-award bug) → G1.
- 0 weather snapshots (WeatherKit/entitlement path) → G4.
- No app icon / `Assets.car` → G2.
- No bundled Mirage runtime → G2B.
- JSON monolith + write-ordering defect → G1 interim, G3 full.
- Behavior Context V3 uncalled → G6.
- Notes/collections metadata never populated → G5.
