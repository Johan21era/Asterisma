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

## Baseline build — 2026-11-07

| Check | Result |
|---|---|
| `xcodebuild ... CODE_SIGNING_ALLOWED=NO build` | exit 0; `** BUILD SUCCEEDED **` |
| App bundle privacy manifest | `AsterismaV2.0.app/Contents/Resources/PrivacyInfo.xcprivacy` present and readable |
| Built usage strings | `NSAppleEventsUsageDescription` and `NSLocationWhenInUseUsageDescription` present |
| Unit census | exit 0; 518 tests / 509 passed / 9 skipped / 0 failed / 719 runs |
