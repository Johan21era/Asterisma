# Mirage × Asterisma integration smoothing — 2026-11-07

**Scope:** the live path between Asterisma's UI and the Mirage sidecar — sheet
open, warm engine, import, status, library scan, and the packaged runtime.

**Status:** three main-thread stalls removed and re-tested; the real engine is
green end-to-end; the built app carries the runtime. The app itself was not
launched, so nothing here is a visual acceptance.

## Wiring, as it actually runs

```
EPUBReaderScreen ▸ Analyze sheet ─┐
Settings ▸ Start / Scan / Batch ──┤
                                  ▼
                  MirageEngineService (one warm session, FIFO gate)
                                  ▼
                  MirageAnalyzeSession (lazy supervisor + client)
                                  ▼
                  MirageSidecarSupervisor (handshake, backoff, pid guard)
                                  ▼
                  MirageProcessTransport (NDJSON, one line each way)
                                  ▼
                  <interpreter> examples/mirage_sidecar.py <ledger>
```

- `MirageImportFlow` is the only writer of `identity-map.json`; the sheet's
  local status reads the map, and `books_list` is the only read-only engine
  view.
- Runtime ladder: `Bundle.main/Contents/Resources/mirage-runtime` (verified
  against `RUNTIME-MANIFEST.json`) first, then the dev gate
  `MIRAGE_REAL_ENGINE_DIR`, otherwise the honest unavailable state.
- Every operation enters through `MirageEngineService.withEngine`; the existing
  ADR-13 pins (single session, peak concurrency 1, idle stop, disabled gate)
  still pass unchanged.

## Defects found and fixed

| # | What was wrong | Why it mattered | Fix | Proof |
|---|---|---|---|---|
| 1 | `MirageStatusController.init` called `MirageStatusSurface.localStatus`, which resolved the book and hashed the **entire EPUB**, synchronously on the main actor. | Every sheet open on a linked book froze the UI for the length of a full-file read + SHA-256, before the sheet even appeared. | Init now uses `mapOnlyStatus` (identity map only, no file access). The sheet's `.task` calls `refreshLocalStatus()`, which hashes in a detached task and upgrades the row. | `mapOnlyStatusNeverResolvesTheSourceFile` (resolution count 0), `localRefreshHashesOffTheOpenPathAndOrphansSourceChanges` (matching file stays linked; changed file orphans `sourceChanged`). |
| 2 | `MirageSourceFingerprint.sha256Hex(fileAt:)` did `Data(contentsOf:)` and hashed the buffer. | A large EPUB was held in memory whole just to compute a digest — a spike on the import path and the status path. | Streams 1 MiB chunks through `SHA256`; the digest is unchanged. | `streamingDigestMatchesInMemoryDigest` (3 MiB + 17 B crosses the chunk boundary), `emptyFileHashesToTheEmptyDigest`, and the real-engine import still matches the receipt's edition lineage. |
| 3 | `MirageAnalyzeSession.init` resolved the dev interpreter by **executing** up to six candidate binaries with 4 s waits, on the main actor (called from `MirageEngineService.ensureSession`). | The first analyze gesture in a dev checkout could block the UI for about a second, longer if a candidate hung. | `MiragePythonLocator.executableURLAsync()` runs the probe on a detached task; `MirageAnalyzeSession` stores the runtime inputs and builds the supervisor lazily on first acquire. | Real-engine smoke, import, and latency suites all pass on the new path; probe measured 51.5 ms, outside the cold-start number. |

No second engine path was introduced: the batch runner, sheet, and settings
still converge on the same service gate.

## Measured on the pinned engine

Environment: `MirageV1.0` checkout `8142261`, disposable ledger, tiny real EPUB
fixture, one sidecar lifecycle. Source line:

`MIRAGE-LATENCY probe_ms=51.5 cold_start_ms=95.2 warm_median_ms=0.1 warm_p95_ms=0.1 import_ms=2.4 reuse_ms=0.5`

| Measure | Result |
|---|---|
| Interpreter probe (dev channel, memoised afterwards) | 51.5 ms |
| Cold start: spawn + banner + pinned `version` handshake | 95.2 ms |
| Warm `health` round-trip, median of 30 | 0.1 ms |
| Warm `health` round-trip, p95 of 30 | 0.1 ms |
| First real `import_epub` of the fixture | 2.4 ms |
| Same bytes again (`reused:true`) | 0.5 ms |

The cold-start figure excludes the probe (measured immediately before it). The
warm figures are one run of 30 on a tiny fixture — sufficient to show the wire
is not the bottleneck, not a claim about large-book analysis time.

## Receipts

| Check | Command (focused) | Result |
|---|---|---|
| Real engine handshake + health | `xcodebuild test … -only-testing:AsterismaV2.0Tests/MirageRealEngineSmokeTests` | exit 0, 1 test passed, 3.805 s (`rt-mirage-smoke`) |
| Real engine import / reuse / books_list / degraded | `xcodebuild test … -only-testing:AsterismaV2.0Tests/MirageIdentityRealEngineImportTests` | exit 0, 1 test passed, 0.332 s (`rt-mirage-import`) |
| Warm latency + import timings | `xcodebuild test … -only-testing:AsterismaV2.0Tests/MirageWarmLatencyTests` | exit 0, 1 test passed (`rt-mirage-latency`); numbers above |
| Focused unit suites (fingerprint, status, page-turn, engine service, mount) | `xcodebuild test … -only-testing:` five suites | exit 0, 25 tests in 5 suites passed (`rt-mirage-focused`) |
| Unit census | `./scripts/census.sh --unit-only` | exit 0; 563 tests, 553 passed, 10 skipped, 0 failed |
| Runtime embedded in the built app | `xcodebuild build …` then inspect `Contents/Resources` | exit 0; log line `Embedded Mirage runtime at …`; 48 MB present |
| Packaged runtime boots with its own interpreter | `python3 scripts/bundle_smoke.py <app>/Contents/Resources/mirage-runtime` | exit 0; banner `status:ready`, `api_version 1.0.0`, `ledger@0.0.10`; `version` and `books_list` ok; `BUNDLE SMOKE OK` |
| Manifest bindings | `shasum -a 256` on the bundled interpreter and sidecar | both digests equal the manifest's `bin/python3.12` and `examples/mirage_sidecar.py` values |

## Not verified, and why

- **No app launch.** The sheet open path is unit-pinned and the engine is
  exercised from the test bundle; no SwiftUI window was opened, so this is not
  a visual or interactive acceptance.
- **Bundled channel through the Swift locator.** The packaged runtime was
  proven by the Python-side bundle smoke and by the locator's own layout and
  manifest tests. No signed `.app` was built and driven to spawn through
  `MirageRuntimeLocator.bundledRuntime`; that is a release-build check.
- **Large books.** The fixture is tiny. Import still uses the existing 25 s
  response timeout; a real book that takes longer would time out, restart the
  sidecar, and surface a failure. No measurement was taken.
- **Concurrent status writes.** `refreshLocalStatus` can persist an
  `sourceChanged` orphan from its detached task while an engine verification
  writes an `editionGone` orphan. Both transitions only orphan; no activation
  is involved, so the overlap is benign — but the identity-map store has no
  cross-thread file lock.
- **Analyzer.** Not re-run for this diff; the build and the suites above
  compiled the changed files.

## Files changed

- `AsterismaV2.0/Features/Mirage/MirageStatusSurface.swift` — map-only status,
  async local refresh, injectable store for tests.
- `AsterismaV2.0/Features/Mirage/MirageAnalysisSheetView.swift` — `.task`
  refresh on the status section.
- `AsterismaV2.0/Features/Mirage/MirageImportFlow.swift` — streaming digest.
- `AsterismaV2.0/Features/Mirage/MirageChildProcess.swift` — off-main
  interpreter resolution.
- `AsterismaV2.0/Features/Mirage/MirageAppImportMount.swift` — lazy supervisor,
  no work in session init.
- `AsterismaV2.0Tests/Mirage/MirageStatusSurfaceTests.swift` — two new pins.
- `AsterismaV2.0Tests/Mirage/MirageFingerprintTests.swift` — streaming digest
  pins.
- `AsterismaV2.0Tests/Mirage/MirageWarmLatencyTests.swift` — opt-in latency
  receipt.
