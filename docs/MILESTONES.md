# Milestones

## 001 — First successful EPUB import and read on a clean slate

**Date and time:** 2026-10-25 00:08:33 EDT (−0400)
**Recorded by:** the engineering session, immediately after the owner’s report
**Build:** `dist/AsterismaV1.0-1.0-arm64.zip`
**SHA-256:** `c77b61af98a6b193f17882bc4abd72119b67b6a232473aa67490e149dcdad649`
**Code:** `3281450` · tag `asterisma-v1.0-import-fix`

### What happened

For the first time, the owner:

1. opened the Add Book picker,
2. selected an EPUB from `Desktop/library tests`,
3. imported it successfully,
4. opened it in the reader, and
5. actually read it.

The live store confirms the full loop, not just the picker:

```text
1 book / 1 session / 24 page timings
```

### Why this is monumental

This is the first clean-slate, end-to-end proof of the app’s core promise:

```text
choose a book → import it → see it in the library → open it → read it
→ record a real reading session and page timings
```

It validates the file picker contract, iBooks-style EPUB package support, the
import pipeline, the library surface, the reader, and session timing together.
After the recent erase/reset work, this is a genuinely fresh library rather
than a carry-over from old test data.

### What this does not mean

This is a **capability milestone**, not a declaration that every issue is
fixed. Multiple unrelated issues remain, and the owner’s test results remain
the absolute source of truth. It means the central product loop is now real
and repeatable.

### Evidence

- Owner report, recorded at the timestamp above.
- Live SQLite library: 1 book / 1 session / 24 page timings.
- Package checksum above.
- Picker/package regression tests and full census: **217 passed / 0 failed /
  9 skipped** at this build.

### Next

Keep reading. Use **More (…) → Erase Library & Data…** between test sessions
when a clean slate is useful, and keep recording owner results as the truth of
record.

---

## 002 — RSVP speed reader survived deliberate abuse

**Date and time:** 2026-10-25 00:17:54 EDT (−0400)
**Recorded by:** the engineering session, immediately after the owner’s report
**Build:** `dist/AsterismaV1.0-1.0-arm64.zip`
**SHA-256:** `c77b61af98a6b193f17882bc4abd72119b67b6a232473aa67490e149dcdad649`

### What happened

The owner deliberately tried to break the RSVP speed-reader feature:

- violently dragged its sliders,
- pushed its buttons in rapid succession,
- changed settings mid-flow.

It stayed responsive. No crash, freeze, “beachball,” or visual crack. The owner
described it as “unusually crisp.”

The live store after the session: **1 book / 4 sessions / 50 page timings**.

### Why it matters

The RSVP surface is a high-frequency interaction surface: rapid slider changes
and button presses can expose re-entrancy, timer, layout, or cancellation bugs
that ordinary reading never touches. It held up under deliberate abuse.

### Future polish (not a defect in this milestone)

- Make the RSVP typography designable.
- Consider honoring the EPUB’s chosen font rather than using a fixed reader
  font.

### Scope note

This milestone covers RSVP stability only. It does not claim that the EPUB
pagination/page-count issues reported in the same session are resolved.

---

## 003 — Beta audit remediation accepted: the core reader works end to end

**Date and time:** 2026-10-25 01:46:44 EDT (−0400)
**Recorded by:** the engineering session, immediately after the owner’s report
**Build:** `dist/AsterismaV1.0-1.0-arm64.zip`
**SHA-256:** `936ba504337d6cb6663c66f736cee0bcb64491a6b0abf2588f0fd9bcc1a566ed`
**Code:** `8a68136` · tag `asterisma-v1.0-ux-audit-2`

### What happened

The owner resumed live testing after the second UX-audit remediation batch and
reported that **everything worked perfectly**:

- EPUB import and open.
- Reading and page turns.
- Typography/theme controls.
- Sidebar hiding in reading mode.
- Search and selected-book detail.
- Reading-progress restoration.
- The paged reader and its controls.

Live store at the report: **1 book / 3 sessions / 20 page timings**.

### Why it matters

This is the first time the complete product loop has passed the owner’s real
testing after the beta-audit remediation work:

```text
import → open → read → navigate → change reading settings
→ leave → reopen at the saved position
```

The remaining request is a refinement, not a broken workflow: auto-hide the
floating upper-left reader controls after a few seconds and reveal them on
demand.

### Scope note

This is owner-accepted behavior for the tested build. It does not convert every
remaining product decision in the UX audit into a completed feature.

### Follow-up — reader controls now yield the page

The single refinement requested at acceptance is implemented in a new
candidate:

**Build:** `dist/AsterismaV1.0-1.0-arm64.zip`
**SHA-256:** `298cd18ca6a2f4acd152f2bb7145a3583d4216fd3765a89c10963d4dae233a70`
**Code:** `cfeb677` · tag `asterisma-v1.0-ux-audit-3`

The floating upper-left reader capsule now fades out after three seconds. It
stays visible while hovered or while a popover/sheet is open, and a small
top-left reveal control restores it on demand. Chapter changes deliberately
re-show the controls with the new label. Owner retest of the refinement is
pending.

---

## 004 — Reader appearance system and library polish (candidate)

**Date and time:** 2026-10-25 20:58:01 EDT (−0400)
**Build:** `dist/AsterismaV1.0-1.0-arm64.zip`
**SHA-256:** `a8ebf2ec1efd0b3513dd59a04a1efb8a830aefb2007b32632539906ba0517009`
**Code:** `3bff002` · tag `asterisma-v1.0-polish-1`

### What shipped

- Apple Books-style Appearance panel with six themes.
- Font family, bold, size, line/character/word spacing, margins.
- Justify, hyphenation, Auto/One/Two columns.
- Slide/Fade/Instant page turns and optional page numbers.
- Adaptive reader chrome and document-level edge-click page turns.
- Redesigned selected-book detail and quieter sidebar rows.

### Status

Candidate implemented, built, signed, and packaged. `ReaderAppearanceTests`
passes 5/5, including WCAG AA contrast for every theme. Owner visual
acceptance is pending, so this is a candidate milestone rather than an
owner-accepted one.

Live store at session close: **1 book / 3 sessions / 77 page timings**.

### Supersession note

The `a8ebf2ec…` candidate package above remains the historical artifact for the
Appearance implementation. It was superseded for owner testing by the ready
package in milestone 005; the reader behavior is unchanged. Visual acceptance
of the panel and book plate is still pending.

---

## 005 — Repository reorganization, green remote CI, and a ready package

**Date and time:** 2026-10-26 00:20:11 EDT (−0400)
**Recorded by:** the engineering session, after the remote census turned green
**Build:** `dist/AsterismaV1.0-1.0-arm64.zip`
**SHA-256:** `786832c8049e38ebe03d6220ae0a39b3a0005b010bdce4675e440cea65ef4643`
**Code:** `1c88ae5` · ready tag `asterisma-v1.0-ready-2026-10-26`

### What happened

1. The repository was reorganized without changing file contents, ownership,
   history, or behavior:
   - app shell moved to `AsterismaV2.5/App/`;
   - 48 flat test files grouped into `App`, `Behavior`, `Core`,
     `DeveloperConsole`, `Environment`, `Library`, `Mirage`, and `Reader`;
   - 50 `git mv` operations, 100% renames, 0 insertions/deletions;
   - all 280 baseline tracked files reconciled with 0 missing, 0 mismatched,
     and 0 unapproved changes.
2. GitHub CI was repaired:
   - the workflow moved from `macos-14` / Xcode 15.4 to `macos-26` /
     Xcode 26.6, because Xcode 15.4 cannot open project format 77;
   - Xcode 26.6 exposed a real `MainActor` concurrency diagnostic in the
     Open-Meteo safe-subscript helper; the subscript is now `nonisolated`.
3. The signed package was rebuilt from the corrected app code.
4. The remote unit census turned green: GitHub run `40266848038`,
   **229 tests / 10 deliberate skips / 0 failures**.

### Why it matters

The repository is now navigable without sacrificing a single byte of history,
and the remote green check finally means what it claims: the project opens,
compiles, and passes the deterministic unit suite on the current macOS/Xcode
pair. The local and remote receipts now agree.

### What this does not mean

- Owner visual acceptance of the Appearance panel and book plate is still
  pending; this milestone does not promote milestone 004.
- The UI-inclusive census is still not claimed. UI tests remain placeholder
  launch stubs that depend on interactive macOS automation.
- The package is ad-hoc signed, not notarized; first launch still needs
  right-click → Open.
- Reader pagination remains per-chapter/spread, not a global physical page map.

### Evidence

- `docs/reorganization/AV1-ROR-EXECUTION-2026-10-26.md`
- GitHub run `40266848038` (green)
- Local unit census: **220 passed / 0 failed / 9 skipped**
- Baseline reconciliation: 280/280 tracked files
- Package: checksum above; signature, sandbox entitlements, embedded-Mirage
  smoke, and Gatekeeper verdict re-verified by `scripts/package-release.sh`
- Live store: **1 book / 3 sessions / 77 page timings**

### Next

Owner retest on the ready package. If accepted, record acceptance and promote
milestone 004.

---

## 006 — Sentinel v2 first tranche: 138 probes, 25 verified repairs, Release Health Center

**Date and time:** 2026-10-28 15:27 EDT (−0400)
**Recorded by:** the engineering session, after the first tranche census
**Build:** working tree at base `6099e4e` (uncommitted at recording time)
**Code:** Sentinel v2 under `AsterismaV2.5/Core/Sentinel/` and `AsterismaV2.5/Features/Sentinel/`

### What happened

Sentinel stopped being an eight-probe Debug-console watchdog and became the
first tranche of the roadwork's immune system:

- **138 probes across 15 domains**, with typed descriptors, budgets, roles,
  copy, and evidence.
- **25 repair plans** with preview, safety snapshot, exact-subject re-read,
  verification, rollback, and undo.
- A **Release Health Center** (⌘⇧H) with Overview, Issues, History, Checks,
  and Settings.
- A launch report card, opt-in notifications with a weekly cap, and a
  redacted diagnostics export.
- Segmented journal v2, issue store, fingerprints, diagnoses, and lifecycle.
- **414 per-probe contract cases** (clean install, determinism, privacy) and
  a **1.31 ms** fast pass on a 70-book fixture.

### Why it matters

The owner's data is now checked by a system that reports coverage honestly,
can explain every finding, and can reverse any repair it makes. The old
watchdog is no longer the product surface; it remains only for the Debug
Developer Console.

### What this does not mean

This is the **first tranche**, not the 700-probe ceiling. The SG7 gate is
**HOLD**, not passed:

- v1 `SentinelEngine` is retained for the Debug console.
- Localization is not started.
- The ten manual owner scenarios are not run.
- The menu bar surface was implemented, then removed because SwiftUI
  `MenuBarExtra` hung the test host.
- Accessibility automation and the 10× SQLite benchmark are missing.

### Evidence

- `docs/audits/12-sentinel-v2-tranche-2026-10-28.md`
- `docs/plans/sentinel/gates/README.md` (SG0–SG7 index)
- Unit census: **379 test functions / 1,024 passed cases / 9 skipped / 0 failed**
- Fast pass: **1.31 ms** (budget < 50 ms)
- Release build: exit 0
- Test isolation: `TEST ISOLATION OK — real app-support data is byte-identical.`
- Census artifact: `rt-census-20261028-152733.xcresult`
- **Postscript (SG8, 2026-10-28):** the catalog grew to **140 probes / 58 required**; the post-SG8 census is **432 tests / 671 runs / 9 skipped / 0 failed**. The 138 / 379 figures above are the SG7 snapshot this milestone records.

### Next

Owner acceptance run, v1 removal decision, localization, and a 10× SQLite
benchmark. See SG7 for the exact blockers.

## 007 — Mirage becomes a warm, library-scale system (ADR-13)

**Date:** 2026-10-29
**Decision record:** `docs/integration/adr/ADR-13-mirage-warm-engine-and-library-scale.md`
**Census:** 459 tests / 671 runs / 450 passed / 9 skipped / 0 failed, exit 0
(`./scripts/census.sh --unit-only`, xcresult
`rt-census-20261029-031816.xcresult`)

### What happened

Mirage stopped paying a cold-start handshake for every gesture. One
app-scoped session now stays warm, serializes every request through a FIFO
gate, and stops on idle, disable, or app background. On top of that session:

- a library-wide `books_list` scan caches `mirage/library-index.json` and
  reconciles lost editions into one atomic identity-map write;
- a batch sequencer analyzes every unlinked EPUB through the same one-book
  path, with cooperative cancel and failure-only retry;
- Settings ▸ Mirage became a control center for engine state, coverage, scan
  freshness, and batch progress.

### Why it matters

The earlier architecture could analyze one book per process lifetime; the
library-scale goal needed a session that survives across requests. This tranche
is the first one where "analyze my whole library" is a single explicit gesture
instead of a repeated cold start.

### What this does not mean

- No owner acceptance run, no UI interaction run, and no remote CI run for this
  working tree.
- The batch queue is session-scoped: it is not restored after an app relaunch.
- Spoiler-sensitive detail surfaces stay disabled under ADR-7; this tranche
  scales analysis storage and throughput, not disclosure.

### Evidence

- `docs/registers/03-fix-log.md` Stage AE (implementation + focused pins) and
  Stage AF (graph refresh).
- `AsterismaV2.5Tests/Mirage/MirageEngineServiceTests.swift`,
  `MirageLibraryIndexTests.swift`, `MirageBatchAnalyzerTests.swift` — 12 pins.

### Next

Owner acceptance of the warm engine and batch flow, then persistence and
restart resilience for the queue.

## 008 — Live environment and navigable diagnostics (2026-10-29)

**Date:** 2026-10-29
**Census:** 464 tests / 94 suites / 671 runs / 455 passed / 9 skipped / 0 failed,
exit 0 (`./scripts/census.sh --unit-only`, xcresult
`rt-census-20261029-033957.xcresult`)

### What happened

The environment stopped being a still image between slow palette ticks, and the
two diagnostic surfaces stopped being flat tab strips:

- the palette engine recomputes every **10 s** (was 45 s), and a 20 fps
  atmosphere layer drifts two ambient glows continuously;
- a real weather layer draws rain, heavy rain, snow, heavy snow, fog, cloud
  shadow, wind streaks, and a storm flash from the app's own captured snapshot;
- morning, midday, and afternoon palettes were deepened into their shadow range,
  and a luminance-derived readability veil (0.04 at night, capped at 0.42)
  protects white text and thin chrome;
- the Developer Console gained LIVE/PLANNED grouping, sidebar search, an
  **Environment Studio** that forces any hour or weather kind against the real
  renderer, and a searchable **Subsystem Explorer**;
- the Sentinel Health Center became a persistent sidebar with a band/coverage
  header, grouped destinations, issue search, severity filters, and a
  ⌘] **Next issue** control.

### Why it matters

A reading environment has to feel alive without becoming distracting, and a
broken state has to be diagnosable without hunting through tabs. This is the
first tranche where weather is visible, the scene moves continuously, and the
console can reproduce any environment state on demand.

### What this does not mean

- No owner visual acceptance and no screenshot; the macOS capture permission was
  not retried.
- Live precipitation needs a captured snapshot within the six-hour lookback; the
  Environment Studio is the deterministic view.
- Sentinel and console navigation is compile-verified only; no UI automation
  drove the new controls.
- Both graph views and remote CI were not refreshed at the milestone boundary.

### Evidence

- `docs/registers/03-fix-log.md` Stage AH.
- `docs/design/UI-UX-OVERHAUL-2026-10-29.md` §9.
- `AsterismaV2.5Tests/Environment/EnvironmentWeatherVisualTests.swift` — 5 pins.

### Next

Owner visual acceptance at morning, midday, and afternoon, plus a weather sweep
in the Environment Studio; then UI automation for the two diagnostic surfaces.

## 009 — Comic containers: manga, manhua, manhwa, webcomics (2.5, 2026-11-07)

### What happened

Asterisma can now import a **CBZ archive** or an **image folder** and read it in
one of three modes over the same page list: left-to-right for western comics,
right-to-left for manga/manhua/manhwa, and a continuous vertical strip for
webtoons. Page turns use the existing session/progress pipeline; page notes use
a durable comic-page anchor; covers, chapters, format filters, and annual-report
counts are wired. CBR, CB7, and CBT are rejected explicitly because the project
has no RAR/7z decoder.

### Why it matters

The product promised reading tracking, not EPUB tracking. Comic containers now
flow through the same library, sessions, estimates, achievements, notes, and
reports as prose, without a parallel progress system. Manga and webtoons are
treated as reading modes, so one container implementation covers all five
requested categories.

### What this does not mean

- No owner visual acceptance, screenshot, or real comic-library pass.
- No text-region highlights or in-book search for comic pages; notes are
  page-anchored.
- No CBR/CB7/CBT support, and no RAR/7z dependency was added.
- Mirage remained EPUB-only at 2.5; the 2.6 bridge adds comic analysis through OCR.
- The knowledge graph was not refreshed for the new files.

### Evidence

- `docs/audits/2026-11-07-comic-expansion.md`.
- `AsterismaV2.5Tests/Reader/ComicArchiveTests.swift`, `ComicImportTests.swift`,
  and `ComicReaderModelTests.swift` — 16 tests in 3 suites.
- Unit census: 568 tests in 110 suites, 0 failures, 10 skips, exit 0.

### Next

Owner acceptance with one real CBZ and one real webtoon folder; then graph
refresh and the separate commit/push decision.

## 010 — Comic reader experience: native paging, prefetch, zoom (2.5.1, 2026-11-07)

### What happened

The comic reader now behaves like a reading surface rather than a page
switcher. Paged LTR and RTL modes use native horizontal paging with the correct
visual order; adjacent pages are prefetched and decoded off-main; the floating
chrome fades away after three seconds; and a scrubber, chapter menu, full-screen
command, and double-click pan/zoom surface are available in every mode. Import
now suggests RTL for manga/manhua/manhwa titles and vertical for webtoons
without overriding an explicit choice.

### Why it matters

A manga should not feel like a different application from a novel. Native
paging removes the snap, prefetch removes the loading flash, auto-hiding chrome
removes the toolbar, and paper/brightness controls match the EPUB/PDF comfort
surface. The reading data path is unchanged: comic page turns still flow through
`SessionCoordinator`, and comic notes still write through `DataStore`.

### What this does not mean

- No owner visual acceptance, screenshot, or real 300-page comic pass.
- No Instruments frame-time trace; native paging and prefetch are verified by
  build, logic tests, and the full census, not by a measured p95 frame time.
- CBR/CB7/CBT remain unsupported; no RAR/7z decoder was added.
- Comic notes remain page-anchored; there are no text-region highlights.
- The knowledge graph was not refreshed for the 2.5.1 files.

### Evidence

- `docs/audits/2026-11-07-comic-expansion.md`.
- `AsterismaV2.5/Features/Reader/ComicReaderExperience.swift`.
- Comic suites: **19 tests in 3 suites passed**, exit 0.
- Unit census: **571 tests in 110 suites / 582 runs**, 572 passed, 10 skips,
  0 failures, exit 0.

### Next

Owner acceptance with a real CBZ and a real long-strip webtoon; then a frame-time
profile and a graph refresh before the separate commit/push decision.

## 011 — Comic metadata and Mirage comic analysis (2.6, 2026-11-07)

### What happened

ComicInfo.xml is now read at import: title, series, number, volume, writer,
penciller, publisher, summary, genre, language, declared page count, front-cover
page, and — the field that matters most for the requested categories — the
`Manga` reading direction. A malformed file is a metadata miss, never an import
failure. `Book.comicInfo` decodes tolerantly, so old library JSON still loads,
and the details inspector exposes the record.

Mirage now analyzes comics without an engine change. `ComicMirageBridge` runs
on-device Vision OCR over the page images, writes a byte-deterministic EPUB 3
text edition (fixed entry order and timestamps, stored `mimetype`, escaped
XHTML, one spine document per text-bearing page), and sends that edition through
the existing `import_epub` action. Tall webtoon strips are recognized in
overlapping native-resolution tiles; RTL manga orders same-line balloons
right-to-left. The original container remains the identity anchor, while the
derived EPUB's digest is what the engine receipt is checked against. Cached
editions are keyed by source digest and derivation version.

The path also holds the bookmark's security scope while it hashes and OCRs, and
splits any pathological OCR line below the engine's paragraph cap, so an app
restart or one bad page does not turn a comic into an analysis failure.

Comics are now eligible in the analyze sheet, the batch queue, and Settings ▸
Mirage coverage counts. The comic reader's chrome gains the same Analyze with
Mirage entry as the EPUB reader. Image-folder comics fingerprint their canonical
relative paths and file contents, so a moved or edited page drifts the link just
like a changed CBZ.

### Why it matters

A manga volume should arrive with its series, author, and direction already
known; a webtoon should be analyzable without pretending it is an EPUB. The
bridge keeps Mirage's EPUB-only wire contract intact while extending the
product's comic coverage to the analysis surface, not just the reader.

### What this does not mean

- No engine or protocol change. The staged Mirage runtime was not edited.
- Vision OCR is injected in tests; no real-image OCR accuracy run was made, and
  no tiled-webtoon OCR output was inspected.
- No real publisher ComicInfo.xml library or real 300-page comic was read.
- No app launch, screenshot, or visual acceptance.
- CBR/CB7/CBT remain unsupported; no RAR/7z decoder was added.
- The knowledge graph was not refreshed for the 2.6 files.

### Evidence

- `docs/audits/2026-11-07-comic-expansion.md`.
- `AsterismaV2.5/Features/Reader/ComicMetadata.swift`,
  `AsterismaV2.5/Features/Mirage/ComicMirageBridge.swift`.
- Focused suites: **25 tests in 5 suites passed**, exit 0.
- Unit census: **590 tests in 113 suites passed** (console); **591 passed /
  10 skipped / 0 failed**, 719 runs, exit 0.

### Next

Owner acceptance with real manga, manhua, manhwa, webtoon, and western-comic
files; an OCR accuracy pass (Japanese, Chinese, Korean, English); a graph
refresh; then the separate commit/push decisions.

## 012 — Mirage analysis report and measured strength (2.7, 2026-11-07)

### What happened

Mirage's stored analysis is now measurable across the library without exposing
its content. A new derived `MirageAnalysisReport` reads only engine-attested
inventory facts already cached by the read-only `books_list` scan plus RT's own
identity map. It reports coverage (active links over EPUB/comic books), indexed
editions, unit and claim totals, per-edition density, zero-claim editions,
paused links, active links missing from the last scan, and scan freshness.

Coverage is derived from active identity entries, not from a caller-supplied
set, so a stale or orphaned link cannot inflate it. A never-scanned index
reports zero unindexed links because missing evidence is not proof of a missing
edition.

Settings ▸ Mirage now shows the report with explicit provenance: counts are
engine-attested inventory facts, RT never promotes them into its own library,
and ADR-7 keeps claim text, evidence, entities, projection, and graph detail
behind the spoiler gate. The same surface shows the last successful analysis
duration, now recorded by `MirageEngineService` including a comic's OCR
preparation.

### Why it matters

Before this pass the app could say "linked" and, after a manual check, two
counts. It could not answer "how much of my library is analyzed?", "how dense is
the analysis?", "which links are paused?", or "did the last scan reconcile every
link?" without reading files by hand. The report turns those into one
read-only surface while keeping the spoiler contract intact.

### What this does not mean

- No engine or protocol change; the staged Mirage runtime was not edited.
- No analysis detail was enabled. ADR-7 remains in force.
- The report measures coverage and engine counts, not extraction accuracy,
  recall, or book quality.
- No app launch, Settings screenshot, real library scan, or real analysis run.
- The analysis duration is one wall-clock sample, not a benchmark distribution.
- The knowledge graph was not refreshed for the 2.7 file.

### Evidence

- `docs/audits/2026-11-07-mirage-analysis-report.md`.
- `AsterismaV2.5/Features/Mirage/MirageAnalysisReport.swift`.
- Focused suites: **24 tests in 4 suites passed**, exit 0.
- Unit census: **594 tests in 114 suites passed** (console); **595 passed /
  10 skipped / 0 failed**, 719 runs, exit 0.

### Next

Owner visual check of Settings ▸ Mirage, then a real library scan against a real
Mirage ledger. Enabling claim/evidence detail still requires the countersigned
ADR-7 calibration amendment; it is not a code toggle.

## 013 — Mirage reader graph at a verified chapter boundary (2026-11-07)

### What happened

The EPUB reader now has an explicit Mirage graph button. Summoning it mid-chapter
opens a sheet that loads cache-first, otherwise asks the engine for a read-only
chapter-boundary inventory and projects at the **last unit of the previous
chapter**. The graph never includes the chapter being read.

The owner requirement was literal: the graph must appear in at most two seconds.
The engine's measured cold-start envelope (55–72 ms) leaves room under that
budget, but the pinned engine has no `edition_chapters` action yet, so the app's
honest state is the typed capability gap rather than a real graph. The RT side
is complete: boundary model and strict decoder, boundary-only cursor gate,
strict snapshot decoder, 64-entry edition/chapter cache, cache invalidation on
re-analysis, cache-first controller, reader sheet, and deterministic layout.

### Why it matters

This is the first time the reader can ask for the Mirage graph without a page
estimate. The cursor's provenance is the engine's own chapter boundary, not a
percentage, a page, or a title. Claim, evidence, entity-detail, search, and
correction surfaces remain disabled. The first chapter intentionally has no
graph because there is no earlier boundary.

### What this does not mean

- No engine source or staged runtime was edited; `edition_chapters` is not
  implemented in the pinned engine.
- No real graph rendered. The app reports `engineUnsupported` until the engine
  action lands.
- No app launch, reader screenshot, visual acceptance, or real-library graph.
- No real-graph two-second measurement. The cache-hit controller test asserts
  < 2 s and completed in 0.001 s; that is not a UI frame-time receipt.
- The 24-unit engine probe produced 0 nodes / 0 edges, so its projection
  timings are transport-only.
- Comics have no graph: comic pages have no verified page→spine mapping.
- The knowledge graph was not refreshed for the amendment files.

### Evidence

- `docs/integration/adr/ADR-7-amendment-1-chapter-boundary-graph.md`.
- `AsterismaV2.5/Features/Mirage/MirageChapterBoundaries.swift`,
  `MirageGraphSnapshot.swift`, `MirageGraphCache.swift`,
  `MirageGraphController.swift`, `MirageGraphView.swift`;
  `AsterismaV2.5/Features/Reader/EPUBReaderScreen.swift`.
- Focused suites: **41 tests in 5 suites passed**, exit 0.
- Unit census: **610 tests in 115 suites passed** (console); **611 passed / 10 skipped / 0 failed / 719 runs**, exit 0.

### Next

Engine owner implements the read-only action in the amendment's §3.1, then a real
ledger graph and a two-second UI measurement. Only after that can this milestone
claim a rendered graph.
