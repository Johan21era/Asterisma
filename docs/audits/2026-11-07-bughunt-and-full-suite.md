# Bug hunt and full-suite run — 2026-11-07

**Scope:** the annotation tranche (WP-1.1–1.4), the DataStore/SQLite persistence
path, every reader file changed today, a static sweep of the whole app, the
Xcode analyzer, and the full scheme (unit + UI).

**Status:** two real defects fixed, one false failure explained, full scheme
green. No live reader run exists; that limit is unchanged by this work.

## Findings

| # | Finding | Evidence | Disposition |
|---|---|---|---|
| 1 | A duplicated note id could abort the whole library save (CR-1 finding 6), and even when the row write survived, the authoritative payload still carried both copies. | The old statement was a plain `INSERT INTO notes` into a table keyed by note id, inside `saveAll`'s transaction. The new test proved the second half directly: with `INSERT OR REPLACE` alone the reload still returned **two** notes (assertion `reloaded.notes.count == 1` failed), because `payload_json` is decoded in preference to the rows. | **Fixed.** Both note INSERT sites use `INSERT OR REPLACE`, and `writeBook` normalizes `book.notes` by id (last write wins) before encoding the payload and writing rows, so both agree. Pinned by `duplicateNoteIDDoesNotAbortSave`. The pre-fix abort itself was not separately reproduced; it follows from the primary key, not from a recorded failing run. |
| 2 | `pageNumber` and `anchor` could diverge (CR-1 finding 7). The library editor wrote its page field into anchored notes, creating a second location for the same highlight. | `BookDetailsView.commitNote` set `pageNumber` unconditionally on every save. | **Fixed.** The editorial page field is applied only when `anchor == nil`. No unit test covers this view logic; that is a stated limitation, not a pass. |
| 3 | A full-scheme run reported `testFreshDemoRounds` "crashed with signal term". | Two `xcodebuild` runs were alive at once — an orphaned background census plus the synchronous run. In isolation the test passed: 2 tests, `testFreshDemoRounds` 137.749 s. | **Not a product defect.** Self-inflicted concurrency. Re-run clean: full scheme **Passed**. Recorded so the red run is not mistaken for a regression. |
| 4 | A second writer to `book.notes` would let the mirror drift (WP-1.4 requirement 2). | `BookDetailsView` routes create/edit through `upsertNote` and delete through `deleteNote`; `grep` for `notes.removeAll`, `notes.append`, `notes.insert`, `notes = [` outside `DataStore3.swift` returns only unrelated string arrays in the recovery doctors. | **Verified, no change.** |
| 5 | `upsertNote`/`deleteNote` might not reach SQLite, because they bypass `updateBook`. | `scheduleSave` → `save()` calls `database.saveAll(books:state:)` on `dbWriteQueue` in SQLite mode; `saveImmediately` does the same synchronously. | **Verified, no change.** |
| 6 | Unsafe constructs in app code. | Four grep hits for `try!`, `fatalError(`, `as!`, `.first!`, `.last!`; all four are comments recording earlier removals. | **Clean.** |
| 7 | Compiler/analyzer defects. | `xcodebuild analyze` exit 0, 0 errors, 1 warning: `appintentsmetadataprocessor` skipping metadata because the app has no AppIntents dependency. | **Clean; the warning is tooling, not code.** |
| 8 | Tests could mutate the real library. | `./scripts/verify-test-isolation.sh` exit 0: "TEST ISOLATION OK — real app-support data is byte-identical" (store 620 KB). | **Clean.** |

## Fixes in this commit

- `AsterismaV2.0/Core/Storage/LibraryDatabase.swift` — `INSERT OR REPLACE` for
  notes in both paths, plus per-book note dedupe before the payload is encoded.
- `AsterismaV2.0/Features/Library/BookDetailsView.swift` — the editorial page
  field no longer overwrites an anchored note's `pageNumber`.
- `AsterismaV2.0Tests/Library/AnnotationSchemaTests.swift` — one new test,
  `duplicateNoteIDDoesNotAbortSave`.

## Tests run

| Check | Command | Result |
|---|---|---|
| Full scheme, unit + UI | `./scripts/census.sh` | exit 0, **Passed**; 561 tests, 552 passed, 9 skipped, 0 failed, 721 runs; `rt-census-20261107-005854.xcresult` |
| Unit-only census (pre-fix boundary) | `./scripts/census.sh --unit-only` | exit 0; 557 tests, 548 passed, 9 skipped, 0 failed; `rt-census-20261107-002415.xcresult` |
| Stress bundle alone | "xcodebuild test -only-testing:AsterismaV2.0Tests/FreshStressBundleTests" | exit 0; 2 passed; `testFreshDemoRounds` 137.749 s |
| Annotation schema | "xcodebuild test -only-testing:AsterismaV2.0Tests/AnnotationSchemaTests" | exit 0; **6 tests** passed |
| Analyzer | `xcodebuild analyze` | exit 0; 0 errors; 1 tooling warning |
| Test isolation | `./scripts/verify-test-isolation.sh` | exit 0; real store byte-identical |
| Whitespace | `git diff --check` | exit 0 |

## Not run, and why

- **No live reader.** Nothing here opens a `WKWebView` or a `PDFView`. The CSS
  Custom Highlight renderer, the click-to-offset mapping, and PDF annotation
  drawing remain compiled-and-reviewed only.
- **UI coverage is thin.** The four UI tests launch the app and measure launch
  time; none drives the annotation surface. The 561-test total is broad at the
  model layer, not deep at the UI layer.
- **`benchmark.sh` was not run.** It copies the owner's real store into a
  temporary directory and runs the baseline benchmark; the store exists (620 KB)
  but this hunt did not need a performance baseline, and touching a copy of user
  data without a reason is avoidable.
- **Main-thread cost.** EPUB resolution is `O(notes × chapter length)` per
  re-render, computed in the view body. It is correct but could stutter on a
  large chapter with many highlights; no measurement was taken.
- **One swallowed error.** `loadFromDatabase` uses `try? db.saveAll` after
  de-duplicating achievements. A failure means the dedupe repeats next launch
  (idempotent), so it is low risk, but the failure is invisible.
