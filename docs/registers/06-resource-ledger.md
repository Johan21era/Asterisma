# Resource ledger — multi-LLM execution

**Status:** active for the 2026-11-07 progression session.
**Owner:** Buffy, main administrator.
**Scope:** provider identity, smoke receipts, session accounting, and stop
authority. This file records metadata only; it never contains credentials.

## Provider preflight — 2026-11-07

Commands:

```bash
opencode models
opencode auth list
```

| Handle | Resolves | Auth visible to OpenCode | Smoke session | Smoke result | Exit | Cost |
|---|---|---|---:|---:|---:|---:|
| `opencode/glm-5.3-flash-free` | yes | OpenCode Zen free | `ses_e4bea8366ffegZHg4pXCbazItP` | `PREFLIGHT_OK` | 0 | 0 |
| `openrouter/stealth/crouton-alpha` | yes | OpenRouter stored; `OPENROUTER_API_KEY` environment | `ses_e4bea78ddffetH7olv1j7NqkID` | `PREFLIGHT_OK` | 0 | 0 |
| `opencode/crouton-alpha-free` | yes | OpenCode free fallback | not smoked separately | handle resolves | — | — |

The GLM smoke used 12,052 input tokens and 6 output tokens. The Crouton smoke
used 8,486 input tokens and 3 output tokens. Both reported `reason: stop`. No
secret value was read, printed, or recorded.

### What changed from the earlier 402

The earlier OpenRouter sessions
`ses_e4c052f0affeRdQlFgpLYdVnXD` and
`ses_e4c04fa4cffeLMbdGo53gJH56J` returned HTTP 402 when the requested completion
ceiling exceeded the available balance. The minimal preflight above succeeded
with the same handle at cost 0. The constraint is therefore **completion-ceiling
fit**, not total request access. A 402 is still a stop signal: do not retry the
same oversized request; fit the ceiling or use `opencode/crouton-alpha-free`.

## Session accounting

| Window | Session | Purpose | Messages | Notes |
|---|---|---|---:|---|
| GLM | `ses_e4bea8366ffegZHg4pXCbazItP` | P0.2 smoke | 1 | success |
| Crouton | `ses_e4bea78ddffetH7olv1j7NqkID` | P0.2 smoke | 1 | success |
| GLM | `ses_e4be99068ffeSUBkfahAgpeIy5` | WP-0.1 read-only audit | completed | isolated worktree `quick-planet`; verified subset in `docs/audits/2026-11-07-open-work-reconciliation.md` |
| GLM | `ses_e4bfda691ffeAwZ3sEM2I02v38` | GLM roadmap review | completed | worktree `swift-eagle` |
| GLM | `ses_e4bcf9dc0ffeFPW3wHs7GX9LMV` | WP-1.1 annotation schema | ended without a handoff file | worktree `shiny-nebula` at `bd40080`; diff reviewed directly by Buffy, merged in `6e35429` |
| GLM | `ses_e4bc3d173ffeCDOk8y56smWROo` | WP-1.2 EPUB selection | completed | worktree `calm-lagoon` at `b81fc99`; merged in `3a82d50` |
| GLM | `ses_e4bc3d036ffewaz2oeFsMJzyFO` | WP-1.3 PDF selection | completed | worktree `kind-orchid` at `b81fc99`; one dead-callback defect corrected by Buffy; merged in `a010a72` |
| Crouton | `ses_e4bad8f47ffemS5k67Um9XkLyR` | CR-1 annotation review | completed | read-only; three S1 findings confirmed and fixed in `98aaaf3`; dispositions in `docs/audits/2026-11-07-cr1-annotation-review.md` |
| Crouton | `ses_e4bad8ec1ffdlUh6HdHcTxrXHl` | CR-2 annotation UI design | completed | design only; brief folded into `docs/roadmap/packets/WP-1.4.md` |
| GLM | `ses_e4b97d907ffe7MZavRdmhkB9bN` | WP-1.4 annotation UI | cap reached | worktree `kind-planet`; five new files and three edits, no build, coordinator and PDF untouched; finished by Buffy |

The message count is taken from `opencode session export <session-id>`, not from
memory. The GLM window uses the 80/100/120/160-message checkpoints in the master
roadmap. Crouton uses the 1,000-request daily allocation, the per-phase ceilings,
the 30-request packet ceiling, and the 750-request stop.

## Authority

Buffy may interrupt, inspect, or terminate any session, deny any agent request,
revert any change, and discard any unmerged worktree. A builder's request is a
proposal, not a permission. Every agent outcome remains Buffy's responsibility.

## WP-1.1 — annotation schema, 2026-11-07

| Check | Where | Result |
|---|---|---|
| Build | GLM worktree `shiny-nebula` at `bd40080` | exit 0, `** BUILD SUCCEEDED **` |
| Focused suites | same worktree: `AnnotationSchemaTests`, `SQLiteFoundationTests`, `SQLiteDataStoreTests`, `SQLiteLoadIntegrityTests`, `SchemaEvolutionTests`, `LibraryRebuildAndRowRepairTests` | exit 0, **26 tests in 6 suites passed** |
| Whitespace | same worktree | `git diff --check` exit 0 |
| Migration DDL | `sqlite3` on a populated v1 `notes` table | exit 0; the existing row survived with the new columns `NULL` |
| Merge | `main` | `6e35429`; three files, all inside the packet's allowed paths |

The model session ended without writing `.agent-handoff/WP-1.1.md`, so every
check above is Buffy's rerun, not the model's report. Crouton's read-only design
review recommended flat fields and warned that a nested anchor might not survive
repair paths; the shipped design keeps the nested anchor because
`LibraryRowRepairService` exports and restores orphan rows with `SELECT rowid, *`
and no fixed column list, so `anchor_json` round-trips as plain text.

## WP-1.2 / WP-1.3 — reader selection bridges, 2026-11-07

| Check | WP-1.2 (EPUB) | WP-1.3 (PDF) |
|---|---|---|
| Worktree build | exit 0, `** BUILD SUCCEEDED **` | exit 0, `** BUILD SUCCEEDED **` |
| Focused suites | exit 0, **16 tests in 2 suites** (7 new + 9 appearance) | exit 0, **14 tests in 2 suites** (6 new + 9 appearance) |
| `git diff --check` | exit 0 | exit 0 |
| Scope | only `EPUBReaderScreen.swift` + new test | only `PDFReaderView2.swift` + new test |
| Merge | `3a82d50` | `a010a72` |
| Full census after both | — | **536 tests / 527 passed / 9 skipped / 0 failed / 719 runs**, exit 0 |

**Defect caught before merge.** The PDF packet implemented the hook as
`func pdfViewSelectionChanged(_:)` on the `PDFViewDelegate` Coordinator.
`PDFViewDelegate` declares no selection callback, so that method compiled and
was never called. Buffy replaced it with a `.PDFViewSelectionChanged`
`NotificationCenter` observer registered against the view in `makeNSView`,
added `removeObserver` to `deinit`, corrected the header comment, and added a
sixth PDF test that posts the notification and requires a usable anchor. The
model's own 5 tests passed against the dead code, which is why the packet's
test list was insufficient.

**False pass caught.** A first verification run used
`-only-testing:AsterismaV2.0Tests/PDFSelectionTests`; no such type exists, so
only the nine appearance tests ran and `TEST SUCCEEDED` was reported. Buffy
reran with `PDFSelectionGeometryTests` and got the five PDF tests.

## CR-1 / CR-2 — Crouton review lane, 2026-11-07

| Session | Worktree | Role | Output |
|---|---|---|---|
| `ses_e4bad8f47ffemS5k67Um9XkLyR` | `cr1-review` | read-only review of `6e35429`, `3a82d50`, `a010a72` | three S1 findings, all confirmed by Buffy and fixed in `98aaaf3` |
| `ses_e4bad8ec1ffdlUh6HdHcTxrXHl` | `cr2-design` | WP-1.4 design brief | file plan, restore semantics, test list; adopted with two parts dropped (selection-menu extension, 2,000-character limit) |

CR-1's confirmed findings: chapter-absolute EPUB offsets were clamped to the
quote length; a multi-page PDF quote was paired with a first-page rect; and an
unknown `Quote` tag would have made the library unreadable in an older build.
Buffy verified each against the code before changing anything and fixed all
three. Two findings are deferred (duplicate-id save abort, edge-selection
tolerance) and two are assigned to WP-1.4 (EPUB deselect clearing, the single
`upsertNote` path writing `pageNumber` and `anchor` together).

Checks after the fix: build exit 0; five focused suites **32 tests passed**;
census exit 0 with **537 tests / 528 passed / 9 skipped / 0 failed / 719 runs**.

## WP-1.4 — annotation UI, 2026-11-07

GLM session `ses_e4b97d907ffe7MZavRdmhkB9bN` ran in worktree `kind-planet` at
`54640b1` and ended with `Error: Free usage limit reached` after writing the
factory, restore resolver, shared views, both test suites, the DataStore
helpers, and the `BookDetailsView` extraction. It did not build or test, and
`PDFReaderView2.swift` was untouched. Buffy verified the tree, fixed a Swift
`..<` parse error, added the missing EPUB coordinator members and highlight
renderer, closed the EPUB half of CR-1 finding 4, and implemented the entire PDF
side (annotation rendering, tap hit test, action bar, editor popover).

Checks: build exit 0; focused run 29 tests in 3 suites passed; full census exit
0 with **557 tests / 548 passed / 9 skipped / 0 failed** (546 Swift Testing
tests in 105 suites; `rt-census-20261107-002415.xcresult`); `git diff --check`
exit 0. No live reader run, no owner visual pass, no live-library migration.

## Mirage integration smoothing — 2026-11-07 (Buffy)

No model was used. Scope: the live Asterisma–Mirage path (sheet, warm engine,
import, status, runtime bundling).

Three main-thread stalls fixed. (1) Sheet init hashed the whole EPUB on the
main actor; init is now map-only and the hash moved to a detached
`refreshLocalStatus()`. (2) Digests loaded the whole file via
`Data(contentsOf:)`; hashing now streams 1 MiB chunks with the identical digest.
(3) The dev interpreter probe ran inside a main-actor session init; it is now
detached and the supervisor is built on first acquire.

Receipts: real-engine smoke 1 passed (3.805 s); real import suite 1 passed
(0.332 s) covering fresh import, `reused:true`, `books_list`, and degraded
refusal; latency run `probe 51.5 ms, cold 95.2 ms, warm median/p95 0.1 ms,
import 2.4 ms, reuse 0.5 ms`; focused suites 25 tests passed; unit census exit
0 with 563 tests / 553 passed / 10 skipped / 0 failed. The explicit build
embeds the runtime (48 MB), and `bundle_smoke.py` boots the bundled copy with
its own interpreter (banner ready, version + books_list ok, manifest hashes
match). The app was not launched; no large-book analysis was timed.

## Bug hunt + full suite — 2026-11-07 (Buffy)

No model was used: this was Buffy-run inspection and testing. Scope: annotation
tranche, DataStore/SQLite persistence, unsafe constructs app-wide, analyzer,
full unit + UI scheme, test isolation.

Two defects fixed. (1) CR-1 finding 6: duplicate note ids aborted the library
save, and `payload_json` kept both copies even after the row write deduped; both
note INSERT sites now use `INSERT OR REPLACE` and `writeBook` normalises notes
by id before encoding. New test `duplicateNoteIDDoesNotAbortSave`; it failed
with only the table fix, which proved the payload half. (2) CR-1 finding 7: the
library editor overwrote `pageNumber` on anchored notes; the field now applies
only when `anchor == nil`.

One red run is explained, not hidden: two concurrent `xcodebuild` runs caused a
SIGTERM in `testFreshDemoRounds`; alone it passes in
137.749 s and the clean full run is green.

Checks: full scheme exit 0, **Passed** — 561 tests, 552 passed, 9 skipped, 0
failed, 721 runs (`rt-census-20261107-005854.xcresult`); unit-only 557 / 548 /
9 / 0; analyzer exit 0 with one AppIntents tooling warning; test isolation exit
0 with the real store byte-identical; `git diff --check` exit 0. No live reader
run and no annotation UI automation exist.

## Baseline build — 2026-11-07

| Check | Result |
|---|---|
| `xcodebuild ... CODE_SIGNING_ALLOWED=NO build` | exit 0; `** BUILD SUCCEEDED **` |
| App bundle privacy manifest | `AsterismaV2.0.app/Contents/Resources/PrivacyInfo.xcprivacy` present and readable |
| Built usage strings | `NSAppleEventsUsageDescription` and `NSLocationWhenInUseUsageDescription` present |
| Unit census | exit 0; 518 tests / 509 passed / 9 skipped / 0 failed / 719 runs |
