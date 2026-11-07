# 03 · Fix Log

## What this document is

This is the project's repair diary. Every time someone fixes a bug in this codebase, they record it here in writing, following the project's fix protocol:

1. **Finality** — write down exactly what is being fixed and why it is the right fix
2. **Log entry** — add it here, organized by the order fixes were applied
3. **Pinned test** — add an automated test that proves the bug cannot come back

**Who should read this:** Anyone who wants to understand what has been fixed, verify that fixes are real, or follow the same protocol when fixing something new.

**How to read it:** The log is organized in stages. Each fix shows the file it touched, the root cause in plain English, the "Finality" statement (why this is the right fix), and how it was verified.

---

## Verification status

Every entry below passed a clean `xcodebuild build` at patch time. The app launches standalone from today's binary.

---

## Stage 1 — Application launch (compile blockers)

The app did not compile at the start of the remediation. All ten findings were High confidence (direct compiler evidence).

| # | Fix | File | Plain-English summary |
|---|-----|------|----------------------|
| 1.1 | Illegal stored property wrapper in extension | `Features/Discovery/OnlineBookSearchDrawer.swift` | A `@State` property was declared inside a `private extension`, which Swift forbids. Moved it into the struct body. |
| 1.2 | Missing `import Combine` | `Features/DeveloperConsole/DeveloperConsoleDashboardView.swift` | A timer publisher was used with only SwiftUI imported. Added the missing Combine import. |
| 1.3 | Extension of non-nominal type `Any` | `Features/BehaviorContext/BehavioralCategory.swift` | Retyped an extension to work with `Equatable` so chained call syntax compiled. |
| 1.4 | Impossible synthesized `Codable` on `ProcessInfo.ThermalState` | `Features/BehaviorContext/BehavioralCategory.swift` | Wrote manual Codable via raw Int value so invalid raw values throw cleanly. |
| 1.5 | Public declarations exposing internal types (×5) | `Features/BehaviorContext/BehaviorContextEngine2.swift` | Demoted five declarations to internal; zero external usages existed. |
| 1.6 | API drift: `generateTrendReport(from:)` → `(sessions:)` | `Features/Environment/Weather/WeatherInsightPanel2.swift` | Relabeled the argument to match the engine's declared signature. |
| 1.7 | Reference to removed `WeatherSnapshot.sessionID` | `Features/Environment/Weather/WeatherInsightPanel2.swift` | Deleted the exact-match index; kept closest-by-timestamp join. |
| 1.8 | `FullIntegrationInput` missing raw-evidence arrays | `Features/BehaviorContext/BehaviorContextEngine2.swift` | Added the missing members and populated them from the same kit arrays. |
| 1.9 | Misuse of IOKit C API in `systemIdleTime()` | `Features/BehaviorContext/BehavioralCategory.swift` | Rewrote with the correct out-pointer pattern; fixes compilation. |
| 1.10 | Inout through `if let` shadow binding | `Features/BehaviorContext/BehavioralCategory.swift` | Renamed the shadow binding so the outer mutable optional is targeted. |

---

## Stage 2 — Startup / storage loading / library list

| # | Fix | Severity | Plain-English summary |
|---|-----|----------|----------------------|
| 2.1 | Save/load failures completely silent in Release | 🔴 Critical | Added a published `persistenceHealth` status that degrades at every silent-catch site and renders as a persistent bottom banner — every failure is now visible in Release builds. |
| 2.2 | Unrepairable corruption silently re-persisted | 🟡 Medium | Branch on `hasUnrepairableErrors` before auto-save; surface instead of overwriting the last-good file. |
| 2.3 | Debounced save stalls during window tracking | 🟡 Medium | Timer added to `RunLoop.main` in `.common` mode so debounce keeps firing through event-tracking modes. |
| 2.4 | Multi-item delete corrupts/crashes on index reuse | 🔴 Critical | Capture the ID set from offsets *before* mutation; remove by identity to eliminate index-shift effects. |
| 2.5 | Achievement toast drops/re-shows on concurrency | 🟡 Medium | View-side FIFO fed by deduplicating `onReceive` + serial presenter + incremental consumption — each earned achievement shows exactly once. |
| 2.6 | Ghost estimate for deleted book | 🟡 Medium | Guard `dataStore.book(id:) != nil` inside the delayed work item. |

---

## Stage 3 — Monitoring, analytics date math, truth fixes, test wiring

| # | Fix | Severity | Plain-English summary |
|---|-----|----------|----------------------|
| 3.1 | Screen-lock observers leak & duplicate per foreground cycle | 🔴 Critical | Two block-based observer registrations discarded their tokens; `removeObserver(self)` was a silent no-op for them. Captured both tokens, added an idempotence guard, and remove them explicitly in `stopMonitoring`. |
| 3.2 | Force-unwrapped failable Calendar arithmetic (13 sites) | 🟠 High | `Calendar.current` reflects the user's region setting; `date(from:)`/`date(byAdding:to:)` are fallible. Every site force-unwrapped. Guarded each with documented degradation. |
| 3.3 | False integration-status comment | 🟢 Low | `EnvironmentBackgroundView2.swift` header claimed integration that did not exist. Replaced with a truthful STATUS CORRECTION note. |
| 3.4 | Investigated and DISPROVEN | — | `buckets.max(by:)!.key` looked like a zero-data crash, but the dictionary is seeded with all four keys and keys are never removed — max/min can never see an empty collection. Untouched, documented. |
| 3.5 | Real test suites wired into executing target | 🟠 High | Converted three `XCTestCase` suites to `@Suite`/`#expect`, migrated test-only shims, stripped 13,903 chars of dead block from `WeatherKitService2.swift`. |

---

## Stage 4 — Test infrastructure forensics & first-run findings

| # | Fix | Severity | Plain-English summary |
|---|-----|----------|----------------------|
| 4.1 | O-7 RESOLVED: every Debug launch crashed in `DeveloperConsoleRegistry` init | 🔴 Critical | `registerAll()` → `registerOne<T>` → global access from inside `.shared`'s own `dispatch_once` callout. libdispatch detected self-wait and trapped. Pass the registry instance into `registerAll`/`registerOne` instead. |
| 4.2 | Weather store could strand stale rows forever on crash-retry | 🔴 Critical | Table PRIMARY KEY is each snapshot's UUID, so `INSERT OR REPLACE` never deduped retries under the same `session_id`. Added explicit DELETE-by-session followed by INSERT inside one transaction. |
| 4.3 | Fixture correction: clearCalm storm-index test | 🟢 Test-authoring | Production analytics untouched. Fixture now uses true calm (`windKPH: 0`) so zero inputs ⇒ zero index. |
| 4.4 | Deinit resurrection abort in BehaviorContextAccessKit | 🔴 Critical | `deinit { Task { @MainActor in stopMonitoring() } }` captured `self` from inside its own deallocation, retained the dying object, and called methods on freed memory. Removed the self-capturing Task; empty documented deinit with explicit ownership contract. |
| 4.5 | Regression battery authored | — | `ReliabilityTests.swift`: Validator ×5, DataStore persistence ×4, Library mutation ×2, Observer lifecycle ×1. Every failure names its defect class. |

---

## Open / unresolved (Finality not reached)

| Ref | Item | Status / next step |
|---|------|-------------------|
| O-3 | New Year overlay timer chain can outlive `cleanup()` | Latent — feature unwired. Fix before Part-12 wiring; needs cancellation-token redesign. |
| O-6 | Weather SQLite rows keyed by `sessionID` while normaliser discards it | Design decision required; logged, untouched. |
| O-8 | Sync main-thread writes; `urls(...).first!` ×2; `turnToPage` weak-store divergence; duplicate-import silent no-op | Left untouched per confidence rules; prescribed fixes recorded in the retired audit report. |

---

## Phase 1 — Foundation Strike

Executed under the fix protocol against the defect register findings.

| Fix | File | Result |
|-----|------|--------|
| P1.1 — F-01 Calendar crash | `Features/Reports/AnnualReportData2.swift` | FIXED — guarded degradation + additive `calendar:` parameter; `NonGregorianCalendarTests` all pass |
| P1.2 — F-03 Numeric entity destruction | `Core/SharedTextUtilities.swift` | FIXED — removed pre-strip; existing correct decoder now receives intact entities; `TextExtractionTests` all pass |
| P1.3 — F-04 Gates A+B Schema evolution | `Core/DataStore3.swift`, `Core/Book2.swift` | FIXED — backup before reset + tolerant custom Decoders; `SchemaEvolutionTests` all pass |
| P1.4 — F-05 Location continuation leak | `Features/Environment/Weather/WeatherKitService2.swift` | FIXED — FIFO queue resumed exactly-once per continuation; inspection-verified |
| P1.5 — F-07 Observer double-registration | `Features/BehaviorContext/BehavioralCategory.swift`, `ReadingTrackerApp 2.swift` | FIXED — `isMonitoring` gate; `ObserverLifecycleTests` pass |
| P1.6 — F-02 New Year celebration chain | `Features/Reports/NewYearTransitionMonitor.swift` | FIXED — `CelebrationTimeline` extracted phase driver with one cancellable sequence task; `CelebrationTimelineTests` all pass |

Pins added this phase: `NonGregorianCalendarTests` (15 cases), `TextExtractionTests` (7), `SchemaEvolutionTests` (4), `CelebrationTimelineTests` (5), `ObserverLifecycleTests` double-start (+1).

Open after Phase 1: F-06, F-08–F-13, O-6, O-8 remainder.

---

## Phase 2 — The Great Wiring

| Fix | Result |
|-----|--------|
| P2.0 — Baseline re-verified green | ✅ |
| P2.1 — §8.2 gate: shared-engine refcount | FIXED+PINNED — consumer counting; `EnvironmentEngineTests` ×4 |
| P2.2 — D5 wiring: Environment Engine is LIVE | ✅ — `ContentView` owns the engine; `EnvironmentBackgroundView` composes as ZStack root |
| P2.3 — D5 wiring: Library Explorer live | ✅ — Explore toolbar presents `LibraryExplorerView`; collection CRUD with referential integrity; `LibraryCollectionTests` ×5 |
| P2.4 — Import Intelligence surfaces | ✅ — ~250 previously-unreachable lines now run on every real import |
| P2.5 — F-06 Chronological fatigue analysis | FIXED+PINNED — gap records carry real boundaries; `FatigueAnalyzerTests` ×7 |

Open after Phase 2: SpatialNavigator/FloatingCluster sub-surfaces ride inside Explorer already; remaining: F-08–F-13, O-6/O-8/D6, BCE V3 activation with UI, RSVP feature plan implementation.

---

## Live-test remediation (LT-001)

Source: Johan's manual stress-test report ("LIVE TESTING SESSIONS" — every action ×20 sessions). Root-caused from code; each fix built clean and the full suite stayed green throughout.

### Fixed

| # | Issue | Severity | Fix |
|---|-------|----------|-----|
| LT-1 | Discover Books bricked the app | 🔴 | Complete redesign as a proper modal (header + Close/Esc, prominent search, real results list, empty/loading/offline/error states, detail on selection) |
| LT-2 | Annual Reports bricked the app | 🔴 | Systemic `sheetDismissAffordance()` modifier (floating close + Escape) applied to ALL top-level sheets |
| LT-3 | Ghost books + phantom reading time | 🔴 | (a) Entitlements: app-scope bookmarks, user-selected RW, network.client — wired into both configurations via `CODE_SIGN_ENTITLEMENTS`. (b) Phantom time: EPUB starts timing only after package opens; PDF gains `onLoadSuccess` fired only when a document exists. |
| LT-4 | Insights pinned center / dragged main window | 🟠 | Insights now opens as its own real Window scene via `openWindow` |
| LT-5 | Report Prev/Next needed double/triple clicks | 🟡 | Hairline labels replaced with padded capsule targets + `contentShape` |
| LT-6 | Report clipped long sentences / ignored zoom | 🟡 | Slides render inside `GeometryReader`+`ScrollView`; narrative row uses `ViewThatFits`; truncation `lineLimit`s removed |
| LT-7 | Hover sluggish + wall-of-info | 🟡 | Delay 1.5s→0.55s; detail pane reveals in three animated waves |
| LT-8 | Demo profiles requested | ✅ DELIVERED | `DemoDataService` (DEBUG-only): 13-book deterministic catalog; `DemoProfileLabView` console pane with two-step armed install |

### Open (queued — next work before ANY Phase 3)
- LT-9 Settings: symbol color customization
- LT-10 Achievements gallery (all badges + totals)
- LT-11 Star visual polish ("just dots")
- LT-12 Broader de-blocking design pass

### Verification
BUILD SUCCEEDED after every stage; full suite TEST SUCCEEDED at close. Entitlement change requires a fresh Run (clean build folder if Xcode caches signing).

---

## P5 — Five Production Features

Johan authorized all five "next-level" production moves. Every phase passed full `xcodebuild test` at its boundary and was pushed as its own commit.

| # | Feature | Commit | What it does |
|---|---------|--------|--------------|
| P5-A | Weather intelligence made evidentiary | `28e9919` | Aggregate confidence derives from correlation scores + real data-coverage ratio; correlation date bounds chronological; "avoided genres" means sub-5%-share within a season |
| P5-B1 | Cover art + live reading HUD | `575a2fe` | Imports capture covers automatically (PDF first-page thumbnail; EPUB OPF-declared cover); sidebar rows show real covers; ReadingHUD floats with cover, title, live elapsed clock, page position, End Session |
| P5-B2 | RSVP speed reading | `f5ec995` | Full feature per `06-rsvp-feature-plan.md`: tokenizer → playback engine → UI → wiring; hare button streams current EPUB chapter or entire PDF |
| P5-C | First-run onboarding + library search/sort | `8fb1bea` | 3-step wizard for brand-new users; sidebar search across title/author/series; Sort menu (7 modes) |
| P5-D | Data durability: portable archive + auto-backups | `c4968cb` | `.readingarchive` format exports everything; Import Library shows pre-flight summary then restores; automatic dated backups (newest 10 kept) |

### Attempted & honestly reverted

| # | Feature | Commit | Why reverted |
|---|---------|--------|--------------|
| P5-G | Storage Engine 2.0 (SQLite) | — | First test-host launch dies SIGTERM mid-suite — a connection-lifecycle race under `SQLITE_ENABLE_THREAD_ASSERTIONS`. Per Confidence Rules, Finality not reached ⇒ reverted to the proven engine. Zero user impact; no commit shipped it. Reopened for a dedicated session. |

---

## P5-HOTFIX — App-freeze report

Five confirmed main-thread stall sources — four introduced by the P5 feature pass, one pre-existing dormant cousin promoted to live by usage patterns. All fixed, suite green (exit=0).

1. **HUD tick × whole-library re-sort** — `visibleBooks` was a computed property; the ReadingHUD's once-per-second timer re-evaluated the ENTIRE library every second on main. Memoized on books/search/sort signature.
2. **Cover capture on main during import** — PDF rasterization froze imports. Now detached; `importPDF` became async.
3. **RSVP whole-PDF extraction on main** — froze the app solid before the sheet appeared. Now detached with progress-cancellation checks.
4. **Launch-time backup I/O on main** — auto-backup file copies ran in `DataStore.init`. Now a background utility task; rotation API converted to nonisolated static.
5. **Location continuation could hang forever** — if `CLLocationManager` never calls back, every awaiting task wedged permanently. 30 s watchdog now fails the queue.

---

## P6 — THE SENTINEL

Johan's long-wanted admin system: a deterministic rule-driven bug watchdog that finds problems, auto-fixes the provably-safe ones, and stalls the rest for human review.

**Architecture:** PROBES (8, pure reads) → CLASSIFIER (autoFixed vs stalled) → DISPATCHER (audited APIs only) → JOURNAL (append-only JSONL). Runs on launch + every N minutes.

**Security doctrine (S1–S7):**
- **S1** Write confinement — engine's only writable artifacts are `sentinel-*` files
- **S2** Reversibility — backup rotation runs BEFORE any mutation; if snapshotting is impossible, repairs are skipped entirely
- **S3** Append-only journal, atomic temp+rename rotation at 500 entries
- **S4** Static Release strings only; no paths/errors/user text in user-facing copy
- **S5** Kill switch — `defaults write johan.Reading-Tracker sentinel.enabled -bool false`; `runCycle` fully inert when off
- **S6** Conservative defaults — Debug repairs always; Release = monitor+report until the user flips Settings ▸ Sentinel ▸ Allow automatic fixes
- **S7** Determinism — no network, no randomness in probes

Pins: `SentinelPinsTests` ×6 (orphan fix, phantom fix, stalled-stays-stalled, write-confinement SECURITY, kill-switch SECURITY, journal JSONL validity).

---

## P6-HOTFIX — Demo Profile installs froze the app

**Root cause:** `DemoProfileCatalog.install` ran synthesis + full-library encode on the MAIN ACTOR inside the button handler. Winter Romantic alone synthesizes ~621 sessions carrying ~185k page-timing chunks. Encode on main = multi-second lockup.

**Fixed:**
1. Install pipeline async: generation detached, swap-on-main trivial, staged progress UI
2. Re-entrancy guard + drain-before-swap in `debug_replaceLibrary`
3. Sentinel pauses during installs (bridge mutation flag)

---

## P6-HOTFIX v2 — THE ACTUAL ROOT CAUSE

**Root cause:** `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (project.pbxproj). Every function without an explicit annotation is main-actor-isolated — including closures inside `Task.detached` and every model initializer they call. The v1 "background" pipeline performed ~1 MILLION serialized hops back to the main thread. The heavy work never left the main thread.

**Fixed:**
- **A:** `nonisolated` on Book/ReadingSession/PageTiming/Chapter inits + `generateBooks` + `demoChapters` + `SeededRNG` methods + `spec()`. Synthesis now truly leaves main.
- **B:** Library ENCODE moved off-main — enqueueWrite takes an encode thunk executed inside the detached task.
- **C:** `debug_replaceLibrary` simplified to `scheduleSave()`; rapid hops coalesce behind one job.

The isolation fix is compiler-enforced: any future regression reintroduces a MainActor hop on these paths and the build breaks loudly.

---

## P7 — UI REVIEW EXECUTION

Johan's UI REVIEW executed end-to-end. All three HIGH priorities plus both MEDIUMs and the LOW refinement landed.

1. Gray title bar is GONE; starfield reaches the window's top edge and traffic lights float over it
2. Night-time sky blue glow no longer draws a visible circle behind the UI; it fades past the corners
3. Reading HUD has no accent ring anymore and matches toast/banner corner radius exactly
4. All floating surfaces share ONE radius + inset vocabulary from `DesignGrid.swift` — change one constant, everything follows

---

## P6.5 — Sentinel transparency + render-safety fix

Fixed bright-red console spam ("Modifying state during view update" every second):
1. `SentinelEngine.init` loaded journal counters into `@Published` — init runs during SwiftUI's first evaluation. Counters now hydrate lazily inside `runCycle`.
2. `runCycle` wrote published state synchronously when invoked from `.onAppear`/`.task`. All published writes now deferred one runloop turn.

**New surface:** Dev Console ▸ Sentinel — two faces:
- **Technical:** raw findings with timestamp/severity/probe.rule/outcome badges + full `debugDetail`, rule filter, lifetime metrics, auto-repair mode indicator, Run Probe Now, journal folder reveal
- **Plain English:** static userSummary sentences, duplicates collapsed with counts, fix vs needs-you icons

---

## Stage M — The RT–Mirage integration era (Oct 2026)

A separate work program executed under its own playbook (`docs/integration/RT_Mirage_Codebase_Merge_Playbook.md`) — recorded here by reference per the no-duplication rule, not restated. Eight terraced PRs (`PR-1`…`PR-8`, all receipts in `docs/integration/merge-log.md` M-014…M-028), each closed on a green default census; censuses 191/0/4 standing at close; owner-signed acceptance round at campaign close.

| Unit | What it landed | Pointer |
|---|---|---|
| PR-1…PR-3 | Campaign scaffolding → the typed wire (28 actions, `MirageWireTypes`) → transport conformance | `docs/integration/merge-log.md` |
| PR-4 | Sidecar lifecycle machinery: supervisor ladder (spawn→banner→exchange→teardown), EOF/timeout/reaping, BUG-stripe with full externalized repro receipts | PR4 closeout snapshot: `docs/integration/PR4-defect-analysis-2026-10-18.md` |
| PR-5 | Identity map (fail-closed, receipt-born entries, crash-atomic) + one-book import + real-engine identity proof | `docs/integration/PR5-execution-plan-2026-10-18.md` |
| PR-6 | Spoiler-status surface + the gated `MirageCursor` (ADR-7: detail surfaces disabled until verified calibration; typed refusal codes) | merge log M-025/M-026 |
| PR-7 | Feature lifecycle governance (`mirage.enabled`, disable-deletes-nothing byte-proof) + OPE-001 (owner-countersigned stub-cover deletion, ‑38 files, list archived) + the 4-rung boundary root-cause ladder (M-024→M-027) | merge log M-027 |
| PR-8 | The packaged runtime per ADR-3: staging script (pinned interpreter checksum, refusal pins), verified manifest, locator ladder, clean-machine gate, CI workflow (`census.yml`) + self-hosted spawn smoke | merge log M-028 |
| Closing round | Owner signatures: ADR-6 ratified, ADR-3 accepted, ADR-8+ADR-12 countersigned, single-branch adoption, first TB-M0 ledger receipts (verify GREEN + tamper-refused) | merge log M-032/M-033/M-034 |

**Documented, deliberately unfixed (owning decisions attached):** the wire exposes no ledger-backup surface (engine-side duty; named owner); Mirage app-embed exercise awaits the first CI run; R1's remaining three rollback rehearsals (procedure recorded, scheduled).

**Retirement receipted here (for traceability):** the BUG-001 repro `.xcresult` (104 MB, externalized during Stage 4-era bookkeeping) was retired by the owner on 2026-10-18 when the campaign folder was deleted; no unique information was lost (the receipt's metadata lives at `docs/integration/evidence/BUG-001-LogStoreManifest-2026-10-18.plist`).

---

## Stage B — Bedrock / Asterisma (2026-10-24)

The Bedrock program closed the audit-era correctness punch list, moved the live
store to SQLite, and finished with the Asterisma rebrand. Gate receipts live in
`docs/plans/bedrock/`.

| Gate | What landed | Receipt |
|---|---|---|
| G0 | Baseline, worktree, data snapshot, test isolation, benchmark | `BASELINE.md` |
| G1 | NEW-DE-1…NEW-DE-5 fixed and pinned: writer ordering, crash-window clamp, cache day bucket, onboarding import/goal merge, spatial covers, RSVP cancellation | `gates/GATE-G1.md` |
| G2 | App icon, entitlements, shared scheme, ad-hoc signed package | `gates/GATE-G2.md` |
| G2B | Mirage runtime embedded, signed, manifest-verified, bundle-smoke green | `gates/GATE-G2B.md` |
| G3A/B/C | GRDB schema, lazy summary store, real-library cutover, JSON retired to `.migrated` | `gates/GATE-G3A.md`, `GATE-G3B.md`, `GATE-G3C.md` |
| G4 | Open-Meteo provider + live session→snapshot→SQLite pipeline; no WeatherKit entitlement | `gates/GATE-G4.md` |
| G5 | EPUB genre/series/word count, Book Details, notes, tags, collections | `gates/GATE-G5.md` |
| G6 | Behavior Context V3 report + Advanced Context window + JSON evidence archive | `gates/GATE-G6.md` |
| G7 | −1,157 lines of dead code; Swift 6 deferred (148 actor-isolation errors) | `gates/GATE-G7.md` |
| G8 | Release candidate accepted: census 213/0/9, package + launch smoke | `gates/GATE-G8.md` |
| R1 | AsterismaV1.0 rebrand + `ReadTracker` → `Asterisma` data-root migration | `docs/REBRAND-ASTERISMA.md` |
| OT | Owner-test fixes: packaged entitlements, onboarding dismissal, folder-form EPUB import | `docs/owner-test-results/2026-10-24-session-1.md` |

**Live-data receipt after migration:** 7 books / 292 sessions / 138,459 page
timings. The app relaunched successfully from `Application Support/Asterisma/`.

**Release receipt:** `main` at `aba8aa4` (release commit `6da2d81`, tag
`asterisma-v1.0-mvp`). The owner accepted the reader workflow on the
`asterisma-v1.0-ux-audit-2` build. The ready tree carries app code `1c88ae5`
(tag `asterisma-v1.0-ready-2026-10-26`), package
`dist/AsterismaV1.0-1.0-arm64.zip`, SHA-256
`786832c8049e38ebe03d6220ae0a39b3a0005b010bdce4675e440cea65ef4643`.

**Still deferred:** Swift 6 strict mode, reader selection highlights/quotes,
behavior evidence in SQLite, collection rename UI, legacy artifact cleanup,
and Developer ID signing/notarization.


### Polish batch — reader appearance and library surface (2026-10-25)

| Area | What landed | Receipt |
|---|---|---|
| Reader appearance | Six theme presets, font family, bold, 80–200% size, line/character/word spacing, margins | `ReaderAppearance.swift`, `ReaderAppearanceTests` |
| Reader layout | Justify, hyphenation, Auto/One/Two columns, Slide/Fade/Instant page turns, optional page numbers | `EPUBReaderScreen.paginationScript` |
| Reader chrome | Theme-adaptive capsules; top-left controls still auto-hide | `EPUBReaderScreen.swift` |
| Page turning | Document-level left/right edge clicks without blocking trackpad scrolling or links | `EPUBReaderScreen.paginationScript` |
| Library | Selected-book book plate with large cover/progress/actions; quieter sidebar rows | `NewContentView.swift` |

**Verification:** Debug and Release builds green; package signed with sandbox
entitlements and bundle smoke green; `ReaderAppearanceTests` 5/5 with WCAG AA
contrast checks. At the time, the full UI-inclusive census rerun was blocked by
macOS `testmanagerd` automation bootstrap, not by an app assertion. The
2026-10-26 close-out later turned the deterministic unit gate green; the
UI-inclusive gate remains unclaimed.

**Candidate:** `a8ebf2ec1efd0b3513dd59a04a1efb8a830aefb2007b32632539906ba0517009`
(code `3bff002`, tag `asterisma-v1.0-polish-1`).

---

## Stage R — Repository reorganization and CI hardening (2026-10-26)

| Item | What changed | Verification |
|---|---|---|
| R-001 | App shell moved from the flat app root to `AsterismaV2.0/App/` | 2 `git mv` operations; before/after SHA-256 equal |
| R-002 | 48 flat test files grouped into `App`, `Behavior`, `Core`, `DeveloperConsole`, `Environment`, `Library`, `Mirage`, and `Reader` | 48 `git mv` operations; 100% renames, 0 content edits |
| R-003 | 280-file baseline reconciled; path-dependent, signing, user-data, release, and historical files left in place | 0 missing, 0 mismatched, 0 unapproved changes; report in `docs/reorganization/` |
| R-004 | GitHub `census` moved from `macos-14` / Xcode 15.4 to `macos-26` / Xcode 26.6 | Xcode 15.4 cannot open project format 77; Xcode 26.6 opens and builds it |
| R-005 | `OpenMeteoProvider` safe-array subscript marked `nonisolated` | Xcode 26.6 correctly enforced the project's `MainActor` default; behavior unchanged |
| R-006 | Bundled-runtime app-host assertion self-gates on `.mirage-runtime` | Clean CI builds without the ignored 47 MB runtime; synthetic runtime-contract tests still run |

**Final verification:** Debug build green; local unit census **220 passed /
0 failed / 9 skipped**; GitHub run `40266848038` green with **229 tests,
10 deliberate skips, 0 failures**; reorganized tree reconciles every baseline
file with no content change.

**Ready package:** rebuilt from app code `1c88ae5` —
`dist/AsterismaV1.0-1.0-arm64.zip`, SHA-256
`786832c8049e38ebe03d6220ae0a39b3a0005b010bdce4675e440cea65ef4643`.
The package signature, sandbox entitlements, embedded Mirage smoke, and
Gatekeeper-rejection expectation were re-verified by `scripts/package-release.sh`.

**Supersession:** this ready package supersedes the `a8ebf2ec…` polish
candidate for owner retesting. Reader behavior is unchanged; the only app-code
change is the `nonisolated` concurrency annotation.

## Stage S — SG8 surface coverage and repository hygiene (2026-10-28)

| Item | What changed | Verification |
|---|---|---|
| S-001 | `SQL-016` contract-checks every table in a source-generated manifest (existence, readability, primary key) | 11 surface pins; full census green |
| S-002 | `SELF-011` raises a required gap when a family loses its registered owner | Removal of `SQL-016` produces 15 required gaps in test |
| S-003 | `scripts/sentinel-surface.py` generates the surface catalog; CI freshness gate runs before the census | Simulated new table/preference made `--check` exit 1; restored check exit 0 |
| S-004 | Published history rewritten to remove AI co-author trailers from five commits | Trees byte-identical; GitHub contributors API now lists only the owner |
| S-005 | Build junk removed: `.DS_Store` files and the stale 84 MB `dist/` output | `git status --ignored` shows no build directory left |
| S-006 | Graphify refreshed from the new code | 7,510 nodes · 19,023 edges · 369 communities; HTML retired at the 5,000-node limit |
| S-007 | Sentinel catalog grew to 140 probes / 58 required; local census 432 tests / 671 runs / 9 skipped / 0 failed | `./scripts/census.sh --unit-only` passed; Debug and Release builds succeeded |

## Stage S follow-up — repository hygiene (2026-10-29)

| Item | What changed | Verification |
|---|---|---|
| S-008 | Removed regenerable graphify cache/backup, a byte-identical root playbook copy, and OS metadata | 102 MB → 77 MB; tracked tree clean; `graph.json`/`GRAPH_REPORT.md` and the Mirage runtime intact |
| S-009 | Refreshed the stale GitHub homepage contributor cache with a temporary same-SHA default branch | Sidebar lists 1 contributor (`Johan21era`); temp branch deleted; default branch restored to `main` |
| S-010 | Generated the missing `graph.html` from the existing graph; the 7,510-node graph auto-aggregated to 369 community nodes / 1,372 cross-community edges | 435 KB; browser preview renders one canvas; `graph.json`/`GRAPH_REPORT.md`/`manifest.json`/`.graphify_labels.json` hashes unchanged |
| S-011 | Added a deterministic offline 3D graph export: `scripts/build-graph-3d.py`, a vendored `3d-force-graph` 1.80.0 bundle with its MIT notice, and a tracked community page (`graph-3d.html`, since deleted) plus a gitignored full-node view | `--check` matches both outputs; Playwright rendered 369 nodes / 1,372 links and 7,510 / 19,023 with zero console errors after the favicon fix; full view sends only the document request; source/renderer hashes embedded instead of a timestamp |
| S-012 | 3D views made usable on a double-click in Safari: `[hidden]` now wins over the layout `display: grid` | WebKit `file://` load shows the canvas, `#fallback` computed `display: none`; the card had been covering a working WebGL canvas |
| S-013 | 3D render and navigation rework (quality, feel, full-sphere orbit) | See Stage T |

## Stage T — 3D graph render and navigation rework (2026-10-29)

Scope: the three owner follow-ups on the 3D graph views — sharper nodes, calmer
pointer feel with arrow keys, and an unrestricted orbit with far less per-frame
work. All changes are in `scripts/graph3d-template.html`; both outputs were
regenerated from `graphify-out/graph.json`.

| Item | What changed | Verification |
|---|---|---|
| T-001 | Node bodies, halos, and highlights are drawn by analytic impostor quads instead of per-node sphere/ring instances | Full view: 5,949,312 → 450,660 triangles, 4 draw calls; community view keeps 369 nodes / 1,372 links on the same impostor path |
| T-002 | A coarse depth shell occludes links behind node bodies, so links no longer bleed through the balls | Visual check at close range in Chromium and WebKit; body/halo radii scale with distance instead of growing into discs |
| T-003 | Orbit pitch is no longer clamped by the stock controller; the camera traverses the full sphere and flips its up vector at the poles | 260 pitch steps of π/48 (5.4π total): camera radius held at 1740.1, worst step dot product 0.9979, no lock-up; 240 yaw steps: 0.0000 up-vector drift |
| T-004 | Drag and zoom are normalized to viewport size and device pixel ratio, with damped rotate/zoom and arrow-key orbiting (Shift boosts) | Same drag distance turns the same visual angle at 1× and 2× DPR; arrow keys change yaw/pitch at every orientation |
| T-005 | The settled layout is cached in `localStorage` and restored on reopen | Full view cache 159,669 bytes; warm first interactive frame 256–340 ms vs 2,817 ms cold |
| T-006 | Frame pacing: idle **59.3–60 fps** (p95 18 ms), drag **59.6 fps** (p95 18 ms), versus 54.3 idle / 46.5 drag (p95 26–29 ms) before | Playwright in Chromium, 2560×1440 at DPR 2 with MSAA; community view also 60 fps |

**Verification commands:** `python3 scripts/build-graph-3d.py` then
`python3 scripts/build-graph-3d.py --check` — `ok` for both outputs (1.86 MiB
community, 7.71 MiB full). Hover, click-to-select, isolate, and reset were
exercised in the browser on both views with zero console errors and no external
requests. Arrow keys were measured on the shipped community file: yaw and pitch
both moved, camera radius stayed 964.2, no console errors.

**Output hashes:** `graph-3d.html`
`5eb179e77f55d0ff38d87dd8bd14b033c6a31c5fb3f2f2f4910642bde7a7495d`;
`graph-3d-full.html`
`ab9a19b6407b2a703d80c302701938f71d86a8c74f393f8927619f8265f67971`.

**Limitations:** the community view's cross-community links are still
`Line2` meshes, so it carries roughly 2.7k draw calls — fast on this machine
but more per-frame CPU than the full view's 4. Frame-rate figures are from
Chromium at DPR 2 on this Mac; Safari was verified for correctness (WebGL,
both views, `file://`), not benchmarked. The full view remains gitignored and
must be rebuilt locally.

### Repository policy (same session)

`AGENTS.md` gained a **CI gate** section: before calling a code task complete,
run `./scripts/verify-sentinel-surface.sh` and `./scripts/census.sh --unit-only`;
after an approved push, watch `census.yml` and keep fixing until the run is
green, never by skipping or weakening a check.

## Stage U — single 3D view (2026-10-29)

| Item | What changed | Verification |
|---|---|---|
| U-001 | Deleted the tracked community 3D page `graph-3d.html` (369 nodes, 1.86 MiB) at owner request; the full-node view is now the only 3D export | File removed from disk and git index; `graph.html` (2D) and `graph-3d-full.html` remain |
| U-002 | `scripts/build-graph-3d.py` no longer takes `--mode`; it builds, writes, and checks only `graph-3d-full.html` (−127 lines, the `community_view` builder and the multi-output loop) | `python3 -m py_compile` clean; `--check` → `ok` for the single output; no `community_view` / `--mode` references left |
| U-003 | `.gitignore` no longer un-ignores `graph-3d.html`; the full view keeps its ignore entry with the new single-view wording | `git status --ignored` shows no community 3D file; rebuild writes only the full view |

**Rebuild receipt:** `python3 scripts/build-graph-3d.py` wrote
`graphify-out/graph-3d-full.html` (7,510 nodes / 19,023 links, 7.71 MiB);
`--check` returned `ok`. Hash unchanged from Stage T:
`ab9a19b6407b2a703d80c302701938f71d86a8c74f393f8927619f8265f67971`.

**Supersedes:** Stage T's T-001/T-006 rows, its output-hash list, and the
S-011/S-013 records still describe the deleted community view; that is the
historical record. From this stage on, one 3D page is generated and kept.

## Stage V — one-hop retrieval index and the cold-reader gate (2026-10-29)

Goal: make a context-free reader reach a niche fact in one hop, and prove it
with a gate that fails on drift. Two new artifacts and one CI step:

| Item | What changed | Verification |
|---|---|---|
| V-001 | `docs/INDEX.md`: one table per subsystem; every row links the owning file, and 22 rows link the exact `#L` line that settles the question. The index points at owners instead of restating values; the one deliberate exception is the destructive menu's own name ("Erase Library & Data"), because that label is the action. | `--validate-only` checked every path and anchor bound; the facts gate resolved all 30 questions through the index with 0 fallbacks |
| V-002 | `scripts/comprehension-bench.py` + `scripts/comprehension-questions.json`: 30 niche questions and 12 overview facts, each validated against the file that owns it; naive (grep-first) vs indexed (map-first) policies, 3 repetitions, calibrated gate | 24-question baseline with no index: naive **48.7 ms / 26,907 B / 88% accuracy** (3 misses). After the index: **0.1 ms / 4,681 B / 100% / 0 fallbacks**, speedup **351.8×**, byte ratio 0.17 |
| V-003 | Six harder questions added after the first pass (notification key, CI run id, erase-data action, snapshot counts, generator flag, data root) to stop the bank from matching only the rows it was written beside | Repeated 30-question runs: **344–352×**, byte ratio 0.20, **100%**, 0 fallbacks; three anchors were wrong on the way (CI line, retired-3D line, data-root line) and the gate caught each one |
| V-004 | Full-context scan test: 246 tracked files vs four entry documents (README, INDEX, handoff, MILESTONES) | naive **74.6 ms / 3,121,726 B / 246 files**; indexed **0.8 ms / 62,819 B / 4 files**; **97.2×**, coverage 100%, byte ratio 0.02 |
| V-005 | Cold-reader defect: README said 138 checks / 56 required, while the SG8 catalog receipt says 140 / 58. README lines 41 and 106 corrected to 140 / 58; the 138 figure remains only in the historical milestone/gate prose. | Found by the cold-reader brief, confirmed against `docs/registers/04-handoff.md:25` and `03-fix-log.md` S-007, then corrected |
| V-006 | CI: `census.yml` gains a “Comprehension index freshness” step running `python3 scripts/comprehension-bench.py --validate-only` between the surface gate and the unit census; `AGENTS.md` local mirror lists the same three steps | GitHub run `40811182851` on `c2c669d`: green in 3m26s, with the new step before a passing unit census |

**Gate definition (calibrated, not advisory):** one-hop accuracy 100%, zero
grep fallbacks, indexed median ≤ 25 ms and ≤ 2 linked files, ≥ 4× faster than
grep, ≤ 0.5× the bytes; overview coverage 100%, ≥ 5× faster, ≤ 0.2× the bytes.

**Final measured runs (30 questions + 12 overview facts, rep 3, full mode):**
repeated runs measured facts naive **51.2–51.3 ms / 27,264 B** versus indexed
**0.1 ms / 5,398 B** — **344.5–351.6×**, byte ratio 0.20, accuracy 100%, 0 grep
fallbacks. Overview naive **74.6–75.6 ms / 3,121,726 B / 246 files** versus
indexed **0.8 ms / 62.8–63.3 KB / 4 files** — **97.2–97.8×**, coverage 100%.
The gate passed on the command's own exit status each time; the earlier
24-question build measured 48.7 ms / 26,907 B / 88% before the index, which is
the baseline row above.

**Push receipt:** commit `c2c669d` (13 files, +2,529/−1,190) pushed to
`origin/main`; census run `40811182851` succeeded, so the index-freshness step
has now executed on a GitHub runner exactly as the workflow declares it.

**Cold-reader trial:** three dispatch attempts with the same brief prompt,
timed from dispatch to report. Run 1 produced a 400-word, 12-citation brief in
~85 s and found the README 138/56 contradiction; run 2 returned a meta-summary
instead of reading files (~245 s, invalid sample); run 3, after the counts were
fixed and the index existed, produced a correct brief in ~48 s and found two
further inconsistencies (the Xcode version wording and the owner-gate order),
both since fixed. Wall-clock includes dispatch and model variance, so these are
not a clean before/after curve. Spawned workers inherit this session's
conversation — which is why run 2 failed — so the genuinely context-free,
repeatable measurement is the fresh-process harness, not the worker.

**Residual risks:** anchors are hand-maintained line numbers; CI's
`--validate-only` checks existence and bounds but cannot tell that a line moved
within the file. That drift is caught only by the local `--mode facts` gate, so
run it after any edit above an indexed line. Two anchors drifted during the
final doc edits (AGENTS retired-3D, README graph paragraph) and were re-pointed;
the full 30-question gate was then rerun and passed with zero fallbacks.

## Stage W — graph refresh and the Markdown truth audit (2026-10-29)

Goal: leave the navigation artifacts and the documentation byte-accurate for
the next engineering session, with every refreshed figure carrying a receipt.

| Item | What changed | Verification |
|---|---|---|
| W-001 | Graphify refreshed from the current tree. A root `.graphifyignore` now excludes `scripts/vendor/`, the minified 3D renderer, so its 3,371 AST nodes do not dominate the graph. | `graphify update . --force` exit 0: **7,599 nodes / 19,164 edges / 361 communities**, corpus 338 files / ~593,191 words; vendor nodes **0**; previous graph 7,510 / 19,023. |
| W-002 | 2D export regenerated as an aggregated community view; the 3D page rebuilt from the new graph. | `graphify export html` → 361 community nodes / 1,425 cross-community edges, 452,499 B; `python3 scripts/build-graph-3d.py` → 8,135,754 B (7.76 MiB); `--check` → `ok`. |
| W-003 | `AGENTS.md` graph verification corrected: it claimed both HTML pages were offline, but `graph.html` loads vis-network from unpkg by design. | The sentence now separates the self-contained 3D page from the networked 2D page. |
| W-004 | Markdown truth-audit rule, weighted rubric, append-only ledger, and evidence collector landed earlier this session; this stage records the close-out audit and refreshes the graph-cited counts. | `scripts/audit-markdown.py` OK on every edited file; `--validate-only` 30 facts / 12 overview facts; ledger rows appended. |

**Graph artifact hashes (2026-10-29):** `graph.json`
`fc4728f076bf080e175e2ad30d1a949c39c9ded4f4d0d55e380d9343c545f7bb`;
`graph.html` `05c85819dc15cace17c60213543a3a8cb6bd2cdc2ecf5130d358ff03ae86d3e7`;
`GRAPH_REPORT.md` `0db98f786082e0bb3a2954f02c58713f126dc5197ae1736a98d02ec179e314f4`;
`manifest.json` `813aa62cb845526feb64b4b956fe3152ea5d18df94ed9f3f0b096eea720bf806`.
The gitignored 3D page is
`360f961b681319b52a960fb01c08800a4d84eb31a10fd7c1fb39ba48756332ee`.

**Browser receipt:** the full 3D view loaded over loopback in Chromium with a
1280×720 canvas, WebGL true, **0 console errors**, and no external asset
references; the 2D page rendered through its documented unpkg renderer (one
local favicon 404).

**Local CI mirror:** surface OK (15 tables / 8 defaults keys / 5 notification
names); `--validate-only` OK; unit census **432 tests / 671 runs / 423 passed /
9 skipped / 0 failed**, exit 0.

**Limits:** the refresh used graphify's incremental AST update. A full semantic
re-extraction of docs was not run because no Gemini/Google backend is
configured; doc changes were re-extracted structurally by the update. The
tracked Markdown files outside this audit remain scheduled for the full sweep
recorded in `docs/registers/05-doc-audit.md`.

## Stage X — AsterismaV2.0 rename (2026-10-29)

| Item | What changed | Verification |
|---|---|---|
| R-002 | Product, project, app target, scheme, test targets, Swift module, source/test/UI folders, Info.plist, entitlements, release script, CI, and current docs renamed to `AsterismaV2.0` / `AsterismaV2_0`. Bundle ID and data root deliberately unchanged. | Debug and Release builds both `** BUILD SUCCEEDED **`; unit census 432 / 671 / 423 / 9 / 0; surface manifest OK; comprehension bank OK; 83 Markdown files audit OK; `verify-test-isolation.sh` byte-identical. |
| R-003 | `MARKETING_VERSION` raised to 2.0 and `CURRENT_PROJECT_VERSION` to 2; generated Sentinel surface catalog regenerated after the module rename. | `xcodebuild -list` shows targets `AsterismaV2.0`, `AsterismaV2.0Tests`, `AsterismaV2.0UITests`; surface report 15 tables / 8 defaults keys / 5 notification names. |
| X-001 | Graph refreshed after 256 path moves and the doc rewrite. | `graphify update . --force` on the working tree (base commit `fced076`) → **7,621 nodes / 19,186 edges / 355 communities**; aggregated `graph.html` 355 community nodes / 1,339 cross-community edges (432,802 B); `build-graph-3d.py` 8,146,098 B (7.77 MiB), `--check` → `ok`. |

**Historical preservation:** V1.0 package filenames, tags, SHAs, milestone
receipts, and the frozen 2026-10-26 baseline/relocation JSON files were left
as V1.0. The V1.0 paragraphs in `README.md`, the defect register, the roadmap,
the handoff, and the rebrand record are explicitly labelled V1.0-era history.

**Graph artifact hashes (2026-10-29, post-rename):** `graph.json`
`dc49302ffdaf58666b202469c83dad7744042cd6dbefbfecb86b1c474a1f51cc`;
`graph.html` `7054868abb13fc1ddc5c0ec602a7ef33da5d021c35750007ac93909a3e14f3db`;
`GRAPH_REPORT.md` `94977b70406a5200ce7038053a6ee831ec44bc8c78a2973a53ab97c788a5425a`;
`manifest.json` `f929e8c2a325516a7e2df9318266c0a0ad2588a4b2e3008c0304f0f83779d4e8`.
The gitignored 3D page is
`af54b24099a359e9b77d5912805d6b6b2dba468c9b955d70dd9b2c42f187c2ef`.

**Remote CI:** not run for this rename. The last green workflow is
`40816019439` on `fced076`, which predates it; the rename must pass the same
`census.yml` gate before release.

## Stage Y — Home/Library UI shell (2026-10-29)

**Goal:** replace the management-first launch state with a reading-first shell,
remove the duplicate library mental model, and keep the reader untouched.

| Item | What changed | Verification |
|---|---|---|
| Y-001 | Added a weighted multi-criteria model and the design record for the shell, including the 20,000-draw ±15% weight sensitivity run. | `docs/design/UI-UX-OVERHAUL-2026-10-29.md`; shell/Home/Library were top three in 100% of draws. |
| Y-002 | New Home reading desk: resume-first hero, today/streak/in-progress/finished stats, in-progress and next-up shelves, empty and caught-up states. | `AsterismaV2.0/Features/Home/ReadingDeskView.swift`; Debug build succeeded. |
| Y-003 | New unified Library browser: adaptive grid, list toggle, search, five shelf filters, selected-book dock, empty/no-match states. | `AsterismaV2.0/Features/Library/LibraryBrowserView.swift`; Debug build succeeded. |
| Y-004 | Replaced the book-list sidebar with four destinations (Home, Library, Insights, Goals, ⌘1–⌘4); embedded Insights/Goals; retained secondary actions in More; kept Add Book one click away. | `AsterismaV2.0/App/AppSection.swift`, `AsterismaV2.0/App/NewContentView.swift`; Debug build succeeded. |
| Y-005 | Removed the spatial-explorer entry point from the main window. The unreferenced spatial files remain in the tree for a separate cleanup decision. | `rg -n "LibraryExplorerView" AsterismaV2.0` returns only the definition/comments; no app call site. |
| Y-006 | Refreshed graphify and the full 3D page after the new Swift files and design record. | `graphify update . --force` → **7,677 nodes / 19,284 edges / 359 communities**; `graphify export html` → 359 community nodes / 1,362 cross-community edges, 439,168 B; `python3 scripts/build-graph-3d.py` → 8,182,614 B (7.80 MiB), `--check` → `ok`. |

**Graph artifact hashes (2026-10-29, Stage Y):** `graph.json`
`bf59ee18ded073a121f3a5318f068af60caff662adc7f66f337b38026efbf4b8`;
`graph.html`
`eec7f2663b11032de2d04fee68ac393885dd1eff14bdbdf990f87e42b5d0a45b`;
`GRAPH_REPORT.md`
`ea784d9ec4a98080f59deeaa646d7ba10a7429d1fc99fec1b5f33ce6aba7d0ec`;
`manifest.json`
`0232c5c4353149c39f93d4ab78b5c486e38dac7e8f52fb3ebcfced4e7e32dca2`.
The gitignored 3D page is
`4a0e77cec3a1fe20fdbe38e72ad0792aefab9f00e43034936eb7dc98626720ae`.

**Browser receipt:** the 3D page loaded over loopback with a 1175×1281 canvas,
WebGL true, **0 network requests**, and one informational console line
(`full view ready: 7677 nodes, 19284 links`); no console errors. The 2D page was
exported but not re-opened in this stage.

**Local verification:** Debug build `** BUILD SUCCEEDED **` (exit 0);
`./scripts/census.sh --unit-only` → **432 tests / 671 runs / 423 passed / 9
skipped / 0 failed** (exit 0, xcresult `rt-census-20261029-004752.xcresult`);
app source **169 Swift files / 63,448 raw lines / 56,051 non-blank**, test folder
**66 Swift files**.

**Limits:** no owner visual acceptance; no screenshot because macOS denied
`screencapture`; no VoiceOver/keyboard-only/200% text pass; no remote CI. The
graph was refreshed before the final README/project-tree pointer edits and this
receipt were appended, and graphify warned that 7 non-code files produced zero
nodes (asset manifests and frozen baseline JSONs). The V2.0 rename and Stage Y
are uncommitted in the working tree.

## Stage Z — Quick Open and adaptive shell (2026-10-29)

**Goal:** make the first-tranche shell hold up at the real window floor and
give keyboard users one surface that reaches every destination, book, and
secondary action without hunting.

| Item | What changed | Verification |
|---|---|---|
| Z-001 | Added `CommandPalette.swift`: a pure index over four destinations, three actions, and the library; empty query omits books; exact title > prefix > title token > subtitle ranking; all tokens must match. The 620 × 430 overlay opens from a visible **Quick open** button or ⌘K. | Debug build succeeded; five `CommandPaletteTests` pass. |
| Z-002 | Home hero now uses `ViewThatFits` with a wide cover-beside-copy shape and a stacked narrow shape. The wide shape needs 554 pt of content; the stacked shape is used at the maximum sidebar width. | Build succeeded; arithmetic recorded in the design record §7.2. |
| Z-003 | Library dock width is clamped to 236–292 pt (about one third of the canvas) instead of a fixed 292 pt. Below 270 pt the cover shrinks, the title gets four lines, and Info/Estimate stack. | Build succeeded; layout arithmetic in design record §7.2. |
| Z-004 | Today's stat card is goal-aware: daily pages first, daily time second, otherwise today's pages with “Set a daily goal.” The card opens Goals. Added a **Recently finished** shelf. | Build succeeded; uses existing `GoalProgressViewModel.statuses` and `Book` fields only. |
| Z-005 | Added ⌘F to focus Library search, Escape to clear/leave the field, and accessibility labels/values on shelf filters. | Build succeeded. |
| Z-006 | Added `CommandPaletteTests` covering empty-query scope, exact-title rank, author/all-token matching, subtitle matches, and the result cap. | `./scripts/census.sh --unit-only` → **437 tests / 671 runs / 428 passed / 9 skipped / 0 failed**, exit 0, xcresult `rt-census-20261029-005620.xcresult`. |
| Z-007 | Re-ran the source-size count after the new files. | `find AsterismaV2.0 -name '*.swift' \| wc -l` → **170**; concatenated raw lines **64,084**; non-blank **56,626**; test folder **67** Swift files. |
| Z-008 | Refreshed graphify and the full 3D page after the new Swift files and docs. | `graphify update . --force` → **7,734 nodes / 19,424 edges / 369 communities**; `graphify export html` → 369 community nodes / 1,363 cross-community edges, 443,890 B; `python3 scripts/build-graph-3d.py` → 8,226,681 B (7.84 MiB), `--check` → `ok`. |

**Graph artifact hashes (2026-10-29, Stage Z):** `graph.json`
`626eef6023f7d76fab72a30818a37b5884e0e77f2470180ba011ade31bebdc6d`;
`graph.html`
`c02c554a0649bafc0af08906c7504e140c981a8e7f6b3fcfe39012d8bc49d13f`;
`GRAPH_REPORT.md`
`b207175c4852425bae5c7db77a7e65f023a5bf476260f577a9b648cb646bf19e`;
`manifest.json`
`fd73d8c17b3886ae5a669ff628cb59cd4b7a73bb4970cee8dec4a208951da196`.
The gitignored 3D page is
`06306521bb431998e197bfa50fc38c08b12c0118dbdb30f93eb787c5a6d439ea`.

**Browser receipt:** the 3D page loaded over loopback in Chromium with a
1304×1423 canvas, WebGL true, **only the document request** (200), one
informational console line (`full view ready: 7734 nodes, 19424 links`), and no
console errors. The 2D page was exported but not re-opened in this stage.

**Limits:** no owner visual acceptance; no screenshot because macOS denied
`screencapture`; no VoiceOver/keyboard-only/200% text pass. The palette's pure
index is tested; the overlay's focus/⌘K behavior is compile-only. No remote CI
run for Stage Z. The V2.0 rename, Stage Y, and Stage Z remain uncommitted in the
working tree.

## Stage AA — Reader customization (2026-10-29)

**Goal:** bring Apple Books/MangaDex-grade controls to both readers, applied
live without reloading the chapter or reopening the PDF, and preserve the
reader's position while the page is re-framed.

| Item | What changed | Verification |
|---|---|---|
| AA-001 | `ReaderAppearance` gained `ReaderReadingMode` (Paged / Scrolling), a `readingMode` key in the settings JSON, and the `ReaderBrightnessOverlay`/`ReaderComfort` helpers (35–100%, page-only veil). | Debug build exit 0; `ReaderAppearanceTests` green. |
| AA-002 | EPUB Appearance panel gained Mode, Both Margins Advance, and Brightness. The chapter's WKWebView applies changes through `window.__epubApplySettings`; Scrolling switches the same DOM to vertical flow and back without reloading. | Browser harness: 23 paged pages, 21 scrolling viewport-pages, page 3 at `scrollY = 2160`, switch-back at `scrollLeft = 3840`. |
| AA-003 | New `PDFReaderSettings.swift`: `PDFPageLayout` (single/continuous/facing/facing+scroll), `PDFFitMode` (page/width/height/actual), `PDFReadingDirection`, background, page gap 0–80 pt, cover-alone. | `ReaderAppearanceTests.pdfSettingsMap`, `pdfPageGap`, `pdfReadingDirection`; Debug build exit 0. |
| AA-004 | `ReaderPDFView` now applies `displaysRTL`, `displaysAsBook`, `pageBreakMargins`, background, fit height, and layout in `updateNSView`; the current page is not reopened. Arrow keys and chevrons follow RTL. | Debug build exit 0; model pins above; no live PDF UI automation. |
| AA-005 | Extended `ReaderAppearanceTests` from six to nine tests: theme contrast/migration/defaults, full settings injection, brightness clamping, PDF mapping, page-gap margins, RTL presentation, Original-font preservation. | Focused suite: **9 tests in 1 suite passed**, exit 0, xcresult `Test-AsterismaV2.0-2026.10.29_01-29-24--0400.xcresult`. |
| AA-006 | Updated README, project tree, index, testing strategy, reader design record, UI postscript, handoff, and this log. | `python3 scripts/audit-markdown.py` clean; audit rows appended. |
| AA-007 | Refreshed graphify and the full 3D view after the new Swift file and docs. | `graphify update . --force` → **7,792 nodes / 19,534 edges / 373 communities**; `graphify export html` → 373 community nodes / 1,419 cross-community edges, 456,587 B; `python3 scripts/build-graph-3d.py` → 8,265,095 B (7.88 MiB), `--check` → `ok`. |

**Focused reader-suite receipt:** `xcodebuild test -project AsterismaV2.0.xcodeproj
-scheme AsterismaV2.0 -destination 'platform=macOS'
-only-testing:AsterismaV2.0Tests/ReaderAppearanceTests CODE_SIGNING_ALLOWED=NO` →
`✔ Test run with 9 tests in 1 suite passed`, exit 0.

**Full census receipt:** `./scripts/census.sh --unit-only` → **441 tests / 671
runs / 432 passed / 9 skipped / 0 failed**, exit 0, xcresult
`rt-census-20261029-012648.xcresult`. The 9 skips are unchanged: 4 Mirage
real-engine, 1 benchmark, 2 real-library SQLite parity, and 2 live Open-Meteo.

**Browser harness receipt:** Chromium at 1280×720, harness page with 160
paragraphs. Paged mode: `scrollWidth = 14920`, `pages = 23`. Scrolling mode:
`documentElement.scrollHeight = 14623`, `pages = 21`, page 3 → `scrollY = 2160`;
switching back → page 3 at `scrollLeft = 3840`, `scrollY = 0`. The harness is not
a committed CI test; it was a one-off check and was deleted after the run.

**Source-size receipt:** `find AsterismaV2.0 -name '*.swift' | wc -l` → **171**;
concatenated raw lines **64,758**; non-blank **57,220**; test folder **67** Swift
files. Previous Stage Z was 170 / 64,084 / 56,626.

**Graph artifact hashes (2026-10-29, Stage AA):** `graph.json`
`0e633b95105a4f43d634be04c62f02ae74a553fe3d2c3b0145274478c99c618a`
(11,582,850 B); `graph.html`
`785a1bde4b4bf00e1156de2ae29100c51ab16c4c0add5031fa005ec41b47cfa7`
(456,587 B); `GRAPH_REPORT.md`
`b5ac79bad65547c25232c5b4608b860115916c91590a743046a61cffb3be0f68`
(95,656 B); `manifest.json`
`38b0ce3529cf6cf0c812c4dfa77e80edf1999abb57b87a846f884b1a18395589`
(64,045 B). The gitignored 3D page is
`d470c3d5ce77a98ef8772cc425d7c98ac2803c1daf661bb89f389eb93e963c73`
(8,265,095 B).

**Browser receipt (3D):** `file://` was blocked by the Playwright Chromium
profile, so the page was served over loopback instead. At 1400×1000 the canvas
was 1400×1000, WebGL true, `performance.getEntriesByType('resource')` returned
`[]`, and the only console line was `[graphify 3d] full view ready: 7792 nodes,
19534 links`; no errors. The 2D page was exported but not re-opened.

**Changed files:** `AsterismaV2.0/Features/Reader/ReaderAppearance.swift`,
`EPUBReaderScreen.swift`, `PDFReaderSettings.swift` (new), `PDFReaderView2.swift`,
`AsterismaV2.0Tests/Reader/ReaderAppearanceTests.swift`, `README.md`,
`docs/01-project-tree.md`, `docs/INDEX.md`, `docs/design/READER-POLISH-2026-10-25.md`,
`docs/design/UI-UX-OVERHAUL-2026-10-29.md`, `docs/method/07-testing-strategy.md`,
`docs/registers/03-fix-log.md`, `docs/registers/04-handoff.md`,
`docs/registers/05-doc-audit.md`, and the generated graph artifacts.

**Limits:** no owner visual acceptance, no screenshot, no real EPUB/PDF pass; the
WKWebView mode switch is covered by a one-off harness, not CI; the PDF UI is
model-tested only; no remote CI for this working tree; the V2.0 rename, UI
tranches, and this reader pass remain uncommitted. PDFs keep publisher typography:
font, size, spacing, and reflow controls are EPUB-only by design.

## Stage AB — Offline contract (2026-10-29)

**Goal:** prove the local library, EPUB/PDF readers, goals, analytics, and
settings remain fully available with no route to the internet, and make the two
optional network features fail fast and quietly instead of holding a spinner or
delaying local work. Offline is a product contract here, not a launch-only
smoke test.

| Item | What changed | Verification |
|---|---|---|
| AB-001 | Added `DiscoveryNetworking.swift`: an ephemeral `URLSession` with a 10 s request cap, 15 s resource cap, `waitsForConnectivity = false`, and no request cache. Both discovery providers accept an injected session; every request also carries the 10 s timeout. | `AsterismaV2.0/Features/Discovery/DiscoveryNetworking.swift`; Debug build `** BUILD SUCCEEDED **`, exit 0. |
| AB-002 | `BookDiscoveryService` now queries Open Library and Gutendex concurrently, checks cancellation before/after both waits, and keeps the existing ISBN/title-author dedupe and ranking. `BookProvider` and `OnlineBook` are `Sendable`; both providers are `nonisolated`. | `OnlineBookDiscoveryService.swift`, `OnlineBookProvider.swift`, `OnlineBook.swift`, provider files; offline tests below. |
| AB-003 | `BookDiscoveryViewModel` cancels the in-flight search as soon as `NWPathMonitor` reports no route, clears the duplicate offline/error banner, and renders one explicit offline state that says the local library, goals, insights, and readers still work. | `OnlineBookDiscoveryViewModel.swift`, `BookDiscoveryView.swift`; Debug build exit 0. |
| AB-004 | Open-Meteo requests are capped at 10 s (`OpenMeteoProvider.requestTimeout`), and the post-session weather capture runs in its own task instead of ahead of notification evaluation and behavioral analysis. Offline weather failure is swallowed and cannot delay local work. | `OpenMeteoProvider.swift`, `SessionEventRouter2.swift`; Debug build exit 0. |
| AB-005 | Added six network-free pins: five in `DiscoveryOfflineTests` (bounded session, Open Library offline, Gutendex offline, cross-provider dedupe, cancellation of both providers) and one Open-Meteo offline case, plus a timeout assertion in the existing mapping test. | Focused run: **11 tests in 2 suites passed**, 0 failed, 0 skipped, exit 0, xcresult `Test-AsterismaV2.0-2026.10.29_01-48-57--0400.xcresult`. |
| AB-006 | Re-derived the offline surface and source counts. The only live network code is Open-Meteo, Open Library, Gutendex, the discovery cover `AsyncImage`, and the discovery path monitor; the reader, library, goals, insights, engines, and core groups emit no `URLSession`/`Network`/`NWPathMonitor` matches. | `rg -n "https://|URLSession|NWPathMonitor|AsyncImage" AsterismaV2.0 --glob '*.swift'`; app **172 Swift files / 64,868 raw lines / 57,315 non-blank**; test folder **68 Swift files**. |

**Focused offline receipt:** `xcodebuild test -project AsterismaV2.0.xcodeproj
-scheme AsterismaV2.0 -configuration Debug -destination 'platform=macOS'
-parallel-testing-enabled NO -only-testing:AsterismaV2.0Tests/DiscoveryOfflineTests
-only-testing:AsterismaV2.0Tests/OpenMeteoProviderTests` → **11 tests in 2
suites passed**, 0 failures, exit 0. The discovery tests inject an
`OfflineURLProtocol` that fails with `URLError(.notConnectedToInternet)`; both
providers return `[]` in under a second. The cancellation test starts two
2-second providers, cancels after 50 ms, and completes in 0.053 s.

**Census receipts:** `./scripts/census.sh --unit-only` → **447 tests / 671
runs / 438 passed / 9 skipped / 0 failed**, exit 0, xcresult
`rt-census-20261029-020548.xcresult`. Full UI-inclusive `./scripts/census.sh` →
**450 tests / 673 runs / 441 passed / 9 skipped / 0 failed**, exit 0, xcresult
`rt-census-20261029-020643.xcresult`. The skips are unchanged: 4 Mirage
real-engine, 1 benchmark, 2 real-library SQLite parity, and 2 live Open-Meteo.

**Process-level offline check — SKIPPED:** `sandbox-exec -f
/tmp/asterisma-deny-external.sb xcodebuild test-without-building -xctestrun …`
hung before the test runner established its connection (346–352 s), and launching
the built app directly under `sandbox-exec` ended with `Trace/BPT trap: 5`; the
app is already App-Sandboxed. Xcode's own package resolution also
fails under `sandbox-exec` (`sandbox_apply: Operation not permitted`). The
targeted offline tests and the source audit above are the available evidence;
this is not a whole-suite deny-network pass.

**Changed files:** `AsterismaV2.0/Features/Discovery/DiscoveryNetworking.swift`
(new), `OnlineBookDiscoveryService.swift`, `OnlineBookDiscoveryViewModel.swift`,
`OnlineBookProvider.swift`, `OnlineBook.swift`,
`Providers/OpenLibraryProvider.swift`, `Providers/GutenbergProvider.swift`,
`BookDiscoveryView.swift`, `AsterismaV2.0/Features/Environment/Weather/OpenMeteoProvider.swift`,
`AsterismaV2.0/Features/Sessions/SessionEventRouter2.swift`,
`AsterismaV2.0Tests/Discovery/DiscoveryOfflineTests.swift` (new),
`AsterismaV2.0Tests/Environment/OpenMeteoProviderTests.swift`, `README.md`,
`docs/01-project-tree.md`, `docs/INDEX.md`,
`docs/method/07-testing-strategy.md`, `docs/registers/03-fix-log.md`,
`docs/registers/04-handoff.md`, and `docs/registers/05-doc-audit.md`.

**Limits:** no owner offline acceptance, no real-book pass with Wi-Fi disabled,
no remote CI run, and no commit for this working tree. The graph was not
refreshed at this boundary because the change set is code/docs only; it was
refreshed immediately afterward in Stage AC, whose receipt follows. Discovery
remains an online-only browse surface by design; the local library is the
offline alternative.

## Stage AC — Graph refresh after the offline contract (2026-10-29)

**Goal:** put the new offline code and documentation into the knowledge graph,
then rebuild both graph views so the next session starts from the actual tree.

| Item | What changed | Verification |
|---|---|---|
| AC-001 | Rebuilt the code graph from the current tree. | `graphify update . --force` exit 0; **7,836 nodes / 19,618 edges / 387 communities**. The run re-extracted 29 uncached code files and warned that seven source files produced zero nodes: three `Contents.json`, `subset-manifest.gen-0001.json`, `baseline-tracked-2026-10-26.json`, and two more; no Swift source failed extraction. |
| AC-002 | Rebuilt the 2D community export and the full-node 3D page. | `graphify export html` exit 0 → 387 community nodes / 1,407 cross-community edges, 460,646 B; `python3 scripts/build-graph-3d.py` → 8,298,484 B (7.91 MiB); `python3 scripts/build-graph-3d.py --check` → `ok`. |
| AC-003 | Opened the 3D page over a loopback server and inspected it in Chromium. | 1,175×1,173 canvas, WebGL true, `performance.getEntriesByType('resource')` returned `[]`, one info log (`[graphify 3d] full view ready: 7836 nodes, 19618 links`), no errors. |
| AC-004 | Updated the live graph counts and receipt pointers in README, the project tree, the handoff, and this log. | `audit-markdown.py` clean; `comprehension-bench.py --validate-only` exit 0. |

**Artifact hashes and sizes (2026-10-29, Stage AC):** `graph.json`
`bf3612829def50e3e0a502e9eb198a3c2a8317ba003a709e58518b166926fd67`
(11,637,810 B); `graph.html`
`78ecaf5bc72cff9d3876a9a09aca303886e285b9c8eefa2b9b5fed9cb6169ad3`
(460,646 B); `GRAPH_REPORT.md`
`e770b95ce3973bfc51dd691ede51ff3945b0bd18bdddf28f971ad36e2dfb7af0`
(98,121 B); `manifest.json`
`cc9e7cd12057b34ac95a1fe5751f5637c797740d621b5a56d71ef4cd7821ab4b`
(64,265 B). The gitignored 3D page is
`af7e5edbb3c67a8cc096a5fe56dbef8c857f95d24103bf51310c7bdf12193aaa`
(8,298,484 B).

**Changed files:** generated `graphify-out/graph.json`, `graphify-out/graph.html`,
`graphify-out/GRAPH_REPORT.md`, `graphify-out/manifest.json`; gitignored
`graphify-out/graph-3d-full.html`; `README.md`, `docs/01-project-tree.md`,
`docs/registers/03-fix-log.md`, `docs/registers/04-handoff.md`, and
`docs/registers/05-doc-audit.md`.

**Limits:** no owner review of the refreshed 3D page; the `file://` launch was
not retried because Playwright Chromium blocks that protocol, so the receipt is
from a loopback server. The 2D page is generated and hashed but was not opened
in this stage. The graph still omits the seven empty JSON inputs above; it does
contain the new offline Swift files.

## Stage AD — Stable local run command (2026-10-29)

**Goal:** replace the drifting workflow — double-click the Xcode project, press
Run, then run whatever `xcodebuild` command an assistant suggested that day —
with one command that always builds the current working tree and launches the
exact bundle it just built.

| Item | What changed | Verification |
|---|---|---|
| AD-001 | Added `scripts/run-latest.sh`: finds the newest `AsterismaV*.xcodeproj` by version, derives its scheme, builds the current tree, resolves the product path from `xcodebuild -showBuildSettings`, and opens that app bundle. | `bash -n` exit 0; `--help` exit 0; real run built `/Users/johanrembeci/Library/Developer/Xcode/DerivedData/AsterismaV2.0-dvllmxwmwdknajegockzapvjsuxs/Build/Products/Debug/AsterismaV2.0.app` and launched pid 2286, exit 0. |
| AD-002 | The runner uses Xcode's **default DerivedData** and documents why: a custom `-derivedDataPath` on this Desktop/iCloud checkout breaks code signing (BUG-003). | Source comment in `scripts/run-latest.sh`; README §7. |
| AD-003 | The runner quits a running instance through the app's bundle identifier, waits for termination, and refuses to force-kill it because that could lose reading data. A second real run quit pid 2286 and launched pid 2396, exit 0. | `./scripts/run-latest.sh` output; `pgrep -fl AsterismaV2.0` showed the replacement process. |
| AD-004 | After `open`, the runner waits for a live process and rechecks after one second, so a bundle that dies during startup fails the command instead of reporting a false launch. | Third real run quit pid 2396, launched pid 2496, and exited 0 after the settle check. |
| AD-005 | Documented the command in README §7 and the scripts row of the project tree. | `python3 scripts/audit-markdown.py` clean; `comprehension-bench.py --validate-only` exit 0. |

**Changed files:** `scripts/run-latest.sh` (new), `README.md`,
`docs/01-project-tree.md`, `docs/registers/03-fix-log.md`, and
`docs/registers/05-doc-audit.md`.

**Limits:** no automated shell-test harness exists for this script; the receipt
is three real build-and-launch runs from the current tree. The runner builds the
local working tree only — it does not `git pull`, change branches, or install
dependencies. It requires Xcode and a working local signing setup; a build or
launch failure is printed with the last 80 log lines from
`~/Library/Logs/AsterismaV2.0/run-latest.log`.

## Stage AE — Mirage warm engine + library scale (2026-10-29)

**Goal:** move Mirage from one-spawn-per-gesture to one warm, serialized engine
that can scan the whole library and analyze it in a batch, without weakening the
wire contract, the identity stratum, the never-auto-run rule, or the
"disable deletes nothing" guarantee. Decision record:
`docs/integration/adr/ADR-13-mirage-warm-engine-and-library-scale.md`.

| Item | What changed | Verification |
|---|---|---|
| AE-001 | `MirageEngineService` owns at most one warm session, serializes every request through a FIFO gate, stops after 10 idle minutes, and stops on Settings disable or app background. The old per-gesture teardown in `MirageAnalyzeSession.performImport` is removed. | `MirageEngineServiceTests`: explicit start reuses one session (acquire count 3 for start + two requests); two overlapping calls peak at concurrency 1; idle warm-down stops once; disabled feature builds no session; stop-while-busy defers. |
| AE-002 | `MirageLibraryIndex` refreshes the whole `books_list` inventory in one read, persists `mirage/library-index.json` atomically, and reconciles active identity links to `edition-gone` in one map write. Malformed rows refuse the whole scan. | `MirageLibraryIndexTests`: one scan caches 2 rows and totals; 1 missing edition orphans with `editionGone`; second identical scan leaves map bytes identical; malformed row throws `unexpectedShape`; absent/wrong-schema states; injected save interruption leaves old bytes. |
| AE-003 | `MirageBatchAnalyzer` sequences EPUB jobs through `MirageEngineService.analyze`; cancel is cooperative, retry re-queues failures only, and planning skips PDFs/already-linked books. | `MirageBatchAnalyzerTests`: in-order run with peak concurrency 1; cancel analyzes only the first job and marks 3 cancelled; retry re-runs only the failed book; planner returns only the unlinked EPUB. |
| AE-004 | Settings ▸ Mirage is a control center: warm/asleep engine row, start/stop/retry, coverage, last scan, one-gesture library scan, batch progress/cancel/retry, and a storage-folder button. The reader sheet and status check now lease the warm service. `AsterismaApp` stops the engine on `.background`. | `./scripts/run-latest.sh --build-only` exit 0. No UI interaction run in this stage. |
| AE-005 | Added 12 focused pins in three suites. | `./scripts/census.sh --unit-only` exit 0: **459 tests / 671 runs / 450 passed / 9 skipped / 0 failed**, xcresult `/var/folders/27/v3xbp1813kb2vj7k2gycvp8w0000gn/T//rt-census-20261029-024948.xcresult`. The three new suites pass 12/12 in 3.229 s in a focused run. |
| AE-006 | Documented the decision and refreshed the lookup surface: ADR-13, ADR-6 decision-5 supersession note, the deep-dive §2.3/§3.2/§10 revision, the index rows, the project-tree file/test counts, and this log. | `python3 scripts/audit-markdown.py` and `python3 scripts/comprehension-bench.py --validate-only` receipts are recorded in the Stage AE close-out and the audit ledger. |

**Changed files (code):** `AsterismaV2.0/Features/Mirage/MirageEngineService.swift` (new),
`AsterismaV2.0/Features/Mirage/MirageLibraryIndex.swift` (new),
`AsterismaV2.0/Features/Mirage/MirageBatchAnalyzer.swift` (new),
`AsterismaV2.0/Features/Mirage/MirageAppImportMount.swift`,
`AsterismaV2.0/Features/Mirage/MirageStatusSurface.swift`,
`AsterismaV2.0/Features/Mirage/MirageAnalysisSheetView.swift`,
`AsterismaV2.0/Features/Goals/SettingsRootView.swift`,
`AsterismaV2.0/App/AsterismaApp.swift`.

**Changed files (tests):** `AsterismaV2.0Tests/Mirage/MirageEngineServiceTests.swift` (new),
`AsterismaV2.0Tests/Mirage/MirageLibraryIndexTests.swift` (new),
`AsterismaV2.0Tests/Mirage/MirageBatchAnalyzerTests.swift` (new).

**Limits:** no owner acceptance run; no real-engine opt-in smoke of the warm
session (the opt-in real-engine suites remain environment-gated and were among
the 9 skips); no UI interaction run; no remote CI run for this working tree. The
batch queue is session-scoped and is not restored after an app relaunch. The
warm engine holds one child process while active; the idle/background/disable
boundaries above are the only automatic stops.

## Stage AF — Graph refresh after ADR-13 (2026-10-29)

**Goal:** put the warm-engine, library-index, and batch files into the knowledge
graph and rebuild both graph views from the actual tree.

| Item | What changed | Verification |
|---|---|---|
| AF-001 | Rebuilt the code graph from the current tree. | `graphify update . --force` exit 0; **8,037 nodes / 20,085 edges / 378 communities**; 28/28 uncached code files extracted. The same seven empty JSON inputs as Stage AC produced zero nodes; no Swift source failed extraction. |
| AF-002 | Rebuilt the aggregated 2D export and the full-node 3D view. | `graphify export html` exit 0 → 378 community nodes / 1,333 cross-community edges, 442,035 B; `python3 scripts/build-graph-3d.py` exit 0 → 8,468,130 B; `python3 scripts/build-graph-3d.py --check` → `ok`. |
| AF-003 | Opened the 3D page over the existing loopback server (`127.0.0.1:8765`, serving `graphify-out/`). | 1,175×1,173 canvas; WebGL true; `performance.getEntriesByType('resource')` contained no off-origin URL; console showed one info line (`[graphify 3d] full view ready: 8037 nodes, 20085 links`) and no error line in the captured console stream. |
| AF-004 | Updated the live counts and receipt pointer in `README.md`, `docs/01-project-tree.md`, and this log. | Values above; `audit-markdown.py` and `comprehension-bench.py --validate-only` re-run at close-out. |

**Artifact hashes and sizes (2026-10-29, Stage AF):** `graph.json`
`a78a93ede137eed1404f448165ff3104a24e9351dcee771cc0fb947cba90aae9`
(11,921,738 B); `graph.html`
`489f6774525535ee4d363e0abd64b2ca1c6682d1753836969df9cfe499c5cc6a`
(442,035 B); `GRAPH_REPORT.md`
`5e063b68a34ac7c51024933bd5c46904fa3e57b84c7c1b5f206d4e565fef2c6f`
(96,420 B); `manifest.json`
`d494a6eac3d857ab6545a5242f3358acc90979a8673f0615d0d90f3aef187e74`
(65,652 B). The gitignored 3D page is
`74c1b6cb4d6760c936036901de0203e2688504df57dc97c6dcaa841aaad6b92c`
(8,468,130 B).

**Changed files:** generated `graphify-out/graph.json`, `graphify-out/graph.html`,
`graphify-out/GRAPH_REPORT.md`, `graphify-out/manifest.json`; gitignored
`graphify-out/graph-3d-full.html`; `README.md`, `docs/01-project-tree.md`,
`docs/INDEX.md`, `docs/registers/03-fix-log.md`, `docs/registers/04-handoff.md`,
`docs/registers/05-doc-audit.md`, and `scripts/comprehension-questions.json`
(the two graph-count questions and the overview pattern now read the Stage AF
numbers).

**Limits:** no owner review of the refreshed 3D page; the network panel capture
was not obtained (the tab was released after the console read), so the
off-origin receipt is the `performance` evaluate above. The 2D page is generated
and hashed but was not opened in this stage. The graph still omits the seven
empty JSON inputs.

## Stage AG — Closeout Initiative (2026-10-29)

**Goal:** run the named close-out sequence — documentation sweep, Markdown
truth audit, checks/census, junk removal, both graph refreshes, then commit and
push — after the ADR-13 Mirage warm-engine tranche.

| Item | What changed | Verification |
|---|---|---|
| AG-001 | Renamed the AGENTS.md protocol to **Closeout Initiative** and reconciled every document that still stated the pre-ADR-13 census: `README.md`, `docs/method/07-testing-strategy.md`, `docs/roadmap/05-remediation-roadmap.md`, `docs/design/UI-UX-OVERHAUL-2026-10-29.md`, `docs/01-project-tree.md`, `docs/registers/04-handoff.md`; added milestone 007. Current totals: **459 tests / 671 runs / 450 passed / 9 skipped / 0 failed**, 93 suites, app source **175 Swift files / 66,050 raw lines / 58,378 non-blank**, test folder **71 Swift files**. | `python3 scripts/audit-markdown.py` and `python3 scripts/comprehension-bench.py --validate-only` exit 0; `--mode all` exits 0 at 100% facts accuracy with 0 fallbacks. |
| AG-002 | Removed regenerable junk only: the repository's `.DS_Store` inside `.git`; the 12 MiB dated graphify backup directory (2026-10-29); and the 14 MiB extractor cache directory. Both removed directories were regenerated automatically by the refresh and are not source. | `graphify-out` went **61,740 KiB → 20,536 KiB** in the first pass (41,204 KiB freed), then **46,980 KiB → 20,572 KiB** after the refresh recreated its cache/backup (26,408 KiB freed); 67,612 KiB total. Kept: `graph.json`, `graph.html`, `GRAPH_REPORT.md`, `manifest.json`, `.graphify_labels.json`, `cost.json`, the gitignored 3D page, `.mirage-runtime/` (48 MiB), `.obsidian/`, `.freebuff/`, lockfiles, and the ignored root `merge-log.md` (64 KiB, **not** byte-identical to `docs/integration/merge-log.md` — preserved as unknown, not deleted). |
| AG-003 | Ran the three CI-mirror steps plus the comprehension gate. | `./scripts/verify-sentinel-surface.sh` → `sentinel-surface: OK — 15 tables, 8 defaults keys, 5 notification names`, exit 0. `python3 scripts/comprehension-bench.py --validate-only` → `bank ok: 30 facts, 12 overview facts`, exit 0. `./scripts/census.sh --unit-only` → **459 tests / 671 runs / 450 passed / 9 skipped / 0 failed**, exit 0, xcresult `rt-census-20261029-031816.xcresult`. `python3 scripts/comprehension-bench.py --mode all` → `GATE PASSED`, 100% accuracy, 0 fallbacks, median 244.7× indexed speedup, overview 94.3×. |
| AG-004 | Rebuilt the regular graph, the aggregated 2D export, and the full 3D view from the current tree (cache deliberately cold). | `graphify update . --force` exit 0 → **8,045 nodes / 20,093 edges / 381 communities**; seven empty JSON inputs still produce zero nodes and are named in the log. `graphify export html` exit 0 → **381 community nodes / 1,413 cross-community edges**, 459,440 B. `python3 scripts/build-graph-3d.py` exit 0 → 8,474,994 B; `--check` → `ok`. |
| AG-005 | Opened the 3D page over the existing loopback server (`127.0.0.1:8765`, serving `graphify-out/`). | Canvas 1,175×1,281; WebGL true; `performance.getEntriesByType('resource')` had no off-origin URL; console contained one info line (`[graphify 3d] full view ready: 8045 nodes, 20093 links`) and no errors; the page reports **8,045 nodes**. |
| AG-006 | Recorded artifact identity for this generation. | `graph.json` `0ee7bff9713609139a633102491274472b9228077752c80510996f7b636023d3` (11,930,813 B); `graph.html` `a4b28aa1dd5b38f33d98aef45dfdd4a2c549ab845b949f72528b2901407a629a` (459,440 B); `GRAPH_REPORT.md` `be9004cdf950137e52ea22cc372f9a79fa180b1f4ffae1c57b910003cb856403` (97,865 B); `manifest.json` `d3c07adc355d3960ef21c283c46362ad59aea357f0db996cdc2b5a3c9c849e40` (65,651 B); gitignored `graph-3d-full.html` `f2aa418cc0548260caee524e8170a8cfc1c35c60e0fd47dd7c83769a48db976f` (8,474,994 B). |

**Changed files:** `AGENTS.md`; the six documents above plus this log and
`docs/registers/05-doc-audit.md`; `scripts/comprehension-questions.json` (graph
answers now 8,045 / 20,093); generated `graphify-out/graph.json`,
`graphify-out/graph.html`, `graphify-out/GRAPH_REPORT.md`,
`graphify-out/manifest.json`, and the gitignored 3D page.

**Limits:** the aggregated `graph.html` was regenerated and hashed but not
opened in a browser this stage (its vis-network renderer loads from unpkg and
needs network access). No owner acceptance run, no UI interaction run, and no
remote CI run before the commit; the workflow is watched after the pushed run.

## Stage AH — Environment, Sentinel, and console UI overhaul (2026-10-29)

**Goal:** make the environment actually move and show weather, restore
readability over the bright daylight palettes, and give Sentinel and the
Developer Console navigation that scales.

| Item | What changed | Verification |
|---|---|---|
| AH-001 | The environment engine's default recompute cadence is **10 s** (was 45 s). Every palette blend is still eased, so the shorter tick removes the visible jump between keyframes instead of snapping. A new `LiveAtmosphereView` draws two large ambient glows on a 20 fps `TimelineView`, independent of the palette tick. Studio overrides now sit behind `#if DEBUG` in `EnvironmentEngine.recompute()`, so a stale debug key cannot repaint a Release launch. | Read-back of `AsterismaV2.0/Features/Environment/Engine/EnvironmentEngine2.swift` and `AsterismaV2.0/Features/Environment/EnvironmentBackgroundView2.swift`; Debug build succeeded inside the census run below. |
| AH-002 | Added `WeatherVisual` (snapshot → clear/cloudy/fog/rain/heavyRain/snow/heavySnow/storm/wind, with intensity, wind, cloud, and live/forced provenance) and `WeatherEffectView` (deterministic rain streaks, snow, fog banks, cloud shadow, wind streaks, storm flash). `WeatherEnvironmentModifier` now carries the whole captured snapshot and exposes `visual`; a missing condition stays `.clear`. `.clear` draws nothing and reduced motion freezes the layer. | `WeatherVisual.from(...)` pins in `EnvironmentWeatherVisualTests`; read-back of both new files. |
| AH-003 | Deepened the morning, midday, and afternoon reference snapshots into their shadow range and added a luminance-derived readability scrim (clamped 0.04…0.42) drawn above the gradient and below content. Morning/midday/afternoon no longer depend on pale wallpaper for contrast. | `brightPalettesCarryMoreScrimThanNight` asserts night ≤ 0.06, morning > 0.15, afternoon > night, and morning luminance > night luminance. |
| AH-004 | Rebuilt the Sentinel Health Center as a `NavigationSplitView`: persistent band/headline/coverage header, grouped sidebar (Health, Library, Records, Configure) with issue/check badges, pinned **Check now** (⌘R), per-pane title/subtitle, **Review N issues** and **Full check** actions, issue search, severity filter, and **Next issue** (⌘]). | Debug build; read-back of `AsterismaV2.0/Features/Sentinel/SentinelHealthCenterView.swift`. No UI automation. |
| AH-005 | Developer Console sidebar now groups LIVE and PLANNED panes and filters by name or phase. Added **Environment Studio** (real background + real engine; force any minute or weather kind, intensity, provenance, computed readout, reset, clear on disappear) and **Subsystem Explorer** (search over id/name/category/purpose/activity/status/warnings/errors/metrics, category filter, detail pane). | Debug build; read-back of `DeveloperConsoleRootView.swift`, `EnvironmentStudioView.swift`, and `SubsystemExplorerView.swift`. |
| AH-006 | Added five deterministic environment tests covering the condition→visual mapping, the override store round-trip, forced time/weather reaching `EnvironmentState`, scrim ordering, and modifier provenance. | `xcodebuild test -project AsterismaV2.0.xcodeproj -scheme AsterismaV2.0 -configuration Debug -destination 'platform=macOS' -parallel-testing-enabled NO -only-testing:AsterismaV2.0Tests/EnvironmentWeatherVisualTests` → 5 tests in 1 suite passed, exit 0. |
| AH-007 | Ran the local CI mirror after the changes. | `./scripts/verify-sentinel-surface.sh` → `sentinel-surface: OK — 15 tables, 8 defaults keys, 5 notification names`, exit 0. `python3 scripts/comprehension-bench.py --validate-only` → `bank ok: 30 facts, 12 overview facts`, exit 0. `./scripts/census.sh --unit-only` → **464 tests / 94 suites / 671 runs / 455 passed / 9 skipped / 0 failed**, exit 0 (`rt-census-20261029-033957.xcresult`). |

**Changed files:** `AsterismaV2.0/Features/Environment/Engine/EnvironmentEngine2.swift`,
`EnvironmentState.swift`, `EnvironmentPalette.swift`, `EnvironmentAnchorPeriod.swift`,
`AsterismaV2.0/Features/Environment/EnvironmentBackgroundView2.swift`,
`AsterismaV2.0/Features/Environment/Weather/WeatherEnvironmentModifier.swift`,
new `Weather/WeatherVisual.swift`, new `Weather/WeatherEffectView.swift`,
`AsterismaV2.0/Features/Sentinel/SentinelHealthCenterView.swift`,
`AsterismaV2.0/Features/DeveloperConsole/DeveloperConsoleRootView.swift`,
new `DeveloperConsole/EnvironmentStudioView.swift`, new
`DeveloperConsole/SubsystemExplorerView.swift`, new
`AsterismaV2.0Tests/Environment/EnvironmentWeatherVisualTests.swift`, plus
`README.md`, `docs/01-project-tree.md`, `docs/INDEX.md`,
`docs/design/UI-UX-OVERHAUL-2026-10-29.md`, `docs/registers/04-handoff.md`, and
this log.

**Limits:** no owner visual acceptance and no screenshot (the macOS capture
permission was denied in the earlier UI tranche and was not retried). Live
weather visuals need a real snapshot within the six-hour lookback; the studio is
the deterministic way to inspect every kind. The Sentinel/console navigation is
compile-verified only — no UI automation drove the sidebar, search fields, or
Next issue. Both graphs and remote CI were not refreshed for this tranche.

## Stage AI — Closeout Initiative after the environment/Sentinel/console pass (2026-10-29)

**Goal:** run the named close-out sequence — documentation sweep, Markdown truth
audit, checks and census, junk removal, both graph refreshes, then the
commit/push gate.

| Item | What changed | Verification |
|---|---|---|
| AI-001 | Documented the environment, Sentinel, and console work: `README.md`, `docs/01-project-tree.md`, `docs/INDEX.md`, `docs/MILESTONES.md` (new milestone 008), `docs/design/UI-UX-OVERHAUL-2026-10-29.md` §9, `docs/method/07-testing-strategy.md`, `docs/roadmap/05-remediation-roadmap.md`, `docs/registers/04-handoff.md`, and this log. | Counts re-derived: 179 app Swift files / 67,757 raw / 59,942 non-blank; 72 test files; 464 tests / 94 suites / 671 runs / 455 passed / 9 skipped / 0 failed. |
| AI-002 | Junk audit. The inventory found no loose `.DS_Store`, `.xcresult`, `.profraw`, or `.playwright-cli` artifacts. Removed only regenerable graphify output: the dated 2026-10-29 backup directory created by this refresh (11,832 KiB) and the AST extractor cache directory (14,836 KiB). Both were deleted after their contents were superseded by the verified outputs below; their names are recorded here so the deletion is auditable. | `graphify-out` went **47,524 KiB → 20,856 KiB** (26,668 KiB, 26.0 MiB freed). Preserved `graph.json`, `graph.html`, `GRAPH_REPORT.md`, `manifest.json`, `.graphify_labels.json`, `cost.json`, `.graphify_python`, `.graphify_root`, the gitignored 3D page, `.mirage-runtime/` (48 MiB), `.obsidian/`, `.freebuff/`, lockfiles, and the ignored root `merge-log.md` (64 KiB; still not byte-identical to `docs/integration/merge-log.md`, so preserved as unknown). |
| AI-003 | Rebuilt the code graph from the current tree (cold cache). | `graphify update . --force` exit 0 → **8,156 nodes / 20,371 edges / 389 communities**; 360 uncached files re-extracted. The same seven empty JSON inputs produced zero nodes and are named by the tool. `graphify export html` exit 0 → **389 community nodes / 1,435 cross-community edges**, 467,514 B. `python3 scripts/build-graph-3d.py` exit 0 → 8,579,333 B; `--check` → `ok`. |
| AI-004 | Opened both generated views in headless Chromium (Playwright 1.64.1 driving the cached Chromium 1223 headless shell). | **3D, `file://`:** URL resolved to `graph-3d-full.html`, canvas **1280 × 720**, WebGL true, `performance.getEntriesByType('resource')` empty (zero off-origin HTTP), console line `[graphify 3d] full view ready: 8156 nodes, 20371 links`, no page errors. Four `GL Driver Message` performance warnings and one headless `CONTEXT_LOST_WEBGL` / restored pair were the only other console output. **2D:** canvas **1000 × 720**, vis-network loaded from `https://unpkg.com/vis-network@9.1.6/standalone/umd/vis-network.min.js`, no page errors and no failed requests; one informational improved-layout message. |
| AI-005 | Ran the local CI mirror and the documentation checks after all edits. | `./scripts/verify-sentinel-surface.sh` → `sentinel-surface: OK — 15 tables, 8 defaults keys, 5 notification names`, exit 0. `python3 scripts/comprehension-bench.py --validate-only` → `bank ok: 30 facts, 12 overview facts`, exit 0. `python3 scripts/comprehension-bench.py --mode all` → `GATE PASSED`, 100% facts accuracy, 0 fallbacks, 244.3× median indexed speedup, 81.6× overview. `./scripts/census.sh --unit-only` → **464 / 94 / 671 / 455 / 9 / 0**, exit 0 (`rt-census-20261029-033957.xcresult`). `python3 scripts/audit-markdown.py` on every changed Markdown file → `OK`, exit 0. |

**Artifact identity (2026-10-29, Stage AI):** `graph.json`
`859e3a39151c26d504ca55352bcbe1b14e423a1d9f045d58bde0edd42501d9b4`
(12,105,207 B); `graph.html`
`acbc681c99e8f3aeb70e06dd35aeba99a8b992594c2536ff83b103d95d69f495`
(467,514 B); `GRAPH_REPORT.md`
`8bfde41a24c3920632d8267f1de8094a03bb24d0b19420a526d241c0c74a6ab5`
(99,546 B); `manifest.json`
`59a916c89867c14cf9cdfb89512e3e75e7df2bcb8c1bf84d7fc8c79effe7c0cb`
(66,600 B); gitignored `graph-3d-full.html`
`e423596ae1c5d1fe904cb87b5c97c22dc1e0a352104cb92352949bd5fc51d85b`
(8,579,333 B).

**Changed files:** the environment/Sentinel/console source and test files listed
in Stage AH; generated `graphify-out/graph.json`, `graphify-out/graph.html`,
`graphify-out/GRAPH_REPORT.md`, `graphify-out/manifest.json`; gitignored
`graphify-out/graph-3d-full.html`; `README.md`, `docs/01-project-tree.md`,
`docs/INDEX.md`, `docs/MILESTONES.md`,
`docs/design/UI-UX-OVERHAUL-2026-10-29.md`,
`docs/method/07-testing-strategy.md`, `docs/roadmap/05-remediation-roadmap.md`,
`docs/registers/04-handoff.md`, `docs/registers/05-doc-audit.md`, and
`scripts/comprehension-questions.json` (the census answer now reads 464).

**Limits:** no owner visual acceptance and no screenshot of the native app. The
headless Chromium run is a rendering/console check, not a human design review.
The two removed directories are intentionally regenerable; the next `graphify
update` will recreate its AST cache, and a forced refresh recreates a dated
backup. Remote CI is watched only after the approved push.

## Stage AJ — real-library hand grading completed (2026-10-29)

> **Superseded by Stage AK, later the same day:** every grading result in this
> stage was declared **VOID** by the owner. The stage is kept as history; its
> receipts are not results. Reasons and surviving evidence: Stage AK below and
> `docs/audits/new-era-testing.md` §31.

**Trigger:** the owner directed that the real-book pass be executed to the end
with **no automated grading**: every engine result read against the prose and
graded by a human, then a cross-examination against the synthetic pass.

**What changed (documentation and tooling only):**

| Path | Change |
|---|---|
| `docs/audits/new-era-testing.md` | Completed: §11–§24 fourteen grading batches, §25 method-consistency audit, §26 complete field, §27 cross-examination, §28 findings F1–F6, §29 limitations, §30 status. Header and §5/§6/§8.5 corrected from "not started" to their executed state, with superseding notes rather than silent rewrites. |
| `docs/audits/new-era-grades.tsv` | **New.** 135 rows, one per distinct work: pages / difficulty / estimate verdict. The authoritative verdict record. |
| `scripts/real-book-sample.py` | **New.** Read-only helper that prints metadata, engine row and a mid-document excerpt. It assigns no verdict; it exists so every grade can cite the window that was read. |
| `docs/INDEX.md` | Row 61 re-pointed to the completed file and its verdict record. |

**Grading receipts:**

| Measure | Result |
|---|---|
| Packages inventoried | 149 |
| Byte-identical duplicates | 14 (SHA-256 over archive bytes / package tree) |
| Distinct works | **135** |
| Distinct works hand-graded | **135** — no gaps, verified by index-set comparison |
| Page counts wrong | 73 / 135 (54%) |
| Difficulty labels wrong | 58 / 135 (43%); 49 of 53 categorical misses overstate |
| Estimates pessimistic | 126 / 129 judgeable (98%) |
| Estimates plausible | 3, all children's books where two errors cancel |

**Checks (local CI mirror, this stage):**

| Command | Result |
|---|---|
| `./scripts/verify-sentinel-surface.sh` | `sentinel-surface: OK — 15 tables, 8 defaults keys, 5 notification names`, exit **0** |
| `python3 scripts/comprehension-bench.py --validate-only` | `bank ok: 30 facts, 12 overview facts`, exit **0** |
| `./scripts/census.sh --unit-only` | `✔ Test run with 493 tests in 99 suites passed`; metadata `totalTestCount 494`, `passedTests 485`, `skippedTests 9`, `failedTests 0`; exit **0**; `rt-census-20261029-194024.xcresult` |

**Limits of this stage:** no engine code was changed in this stage; the
recalibration in §8.2–§8.3 was already in the tree. The reader side is still
synthetic (§29.1) — every driver row carried a fabricated session, so
provenance read `personalized` on all 149 rows. No real reading session exists.
Nothing is committed or pushed; the working tree held 33 changed or untracked
paths from this session's Phase Zero and real-library work at that stage
and `git status --porcelain | wc -l` read 35 at the close of Stage AK.

## Stage AK — real-library grading results declared VOID (2026-10-29)

**Trigger:** the owner voided the Stage AJ grading results and directed that
testing restart from scratch, and that no retest happen, until a genuinely heavy
formulaic rubric for book difficulty exists.

**What changed (documentation and one read-only script; no engine, weight or
test code touched):**

| Path | Change |
|---|---|
| `docs/audits/new-era-testing.md` | VOID banner above the header; new §31 recording the declaration, the three reasons, and a status per surviving item. Nothing above §31 was deleted or reworded. |
| `docs/INDEX.md` | Real-book row now leads with **VOID 2026-10-29** and points at §31 and the banner instead of presenting the file as results. |
| `docs/registers/04-handoff.md` | Header sentence corrected; new session close records the void and the surviving evidence. |
| `docs/audits/13-reading-analytics-phase-zero-2026-10-29.md` | The “nothing graded yet” line carries a superseding note in place; the original sentence is retained. |
| `scripts/real-book-pagination.py` | **New.** Read-only checker, assigns no verdict: 149 packages, 21 with ≥ 5 page markers, 128 without, 0 declaring a page count. Exit 0. |
| `docs/audits/new-era-grades.tsv` | **Unchanged.** Not opened for writing during Stage AK; retained as raw evidence with no authority. |

**Why the results were voided — three defects:**

1. The difficulty grade was one reader's judgement. §4 fixed the axes and the
   legal verdict values but not the arithmetic, so no second person can reproduce
   a verdict from the same bytes.
2. No inter-rater statistic exists. The only reliability figure is that **7 of 20**
   verdicts changed when the same books were re-read through a different window
   (§25.1 of the void file).
3. The page axis scored reflowable EPUBs against print editions. Measured now:
   **128 of 149** packages carry no page markers and **0** declare a page count,
   so a page count is not a property the engine can be scored against.

**What must not be done with the void file:** it is not a baseline, its accuracy
percentages are not findings, and its F1–F6 are not a work queue. What survives is
listed in its §31: the 149→135 package arithmetic, the engine's own output as
engine behaviour, the pagination counts, and the source reading of
`ReadingDifficultyProfile`.

**Checks (local CI mirror, this stage):**

| Command | Result |
|---|---|
| `./scripts/verify-sentinel-surface.sh` | `sentinel-surface: OK — 15 tables, 8 defaults keys, 5 notification names`, exit **0** |
| `python3 scripts/comprehension-bench.py --validate-only` | `bank ok: 30 facts, 12 overview facts`, exit **0** |
| `./scripts/census.sh --unit-only` | `✔ Test run with 493 tests in 99 suites passed`; metadata `passedTests 485`, `skippedTests 9`, `failedTests 0`, 719 test runs; exit **0**; `rt-census-20261029-201107.xcresult` |
| `python3 scripts/real-book-pagination.py "asterisma new testing suite"` | `packages: 149` / `with >= 5 pagebreak markers: 21` / `with fewer than 5: 128` / `declaring a page count in the OPF: 0`; exit **0** |

**Limits of this stage:** only documentation and the one read-only checker
changed, so these checks confirm the repository still gates green; they do not
validate anything about estimator accuracy. No results were produced by this
stage and none may be cited from it. Nothing is committed or pushed.

## Stage AL — Cognitive Difficulty Engine, Phase 1 audit (2026-10-29)

**Trigger:** the owner directed a complete reconstruction of book difficulty
estimation, with Phase 1 being an investigation only — no destructive change,
and no production behaviour modified before evaluation.

**What changed (audit and read-only tooling; no Swift source touched):**

| Path | Change |
|---|---|
| `docs/plans/cde/PHASE-1-AUDIT.md` | **New.** The Phase 1 deliverable: end-to-end pipeline audit, the model as implemented, thirteen measured defects with receipts, the proposed CDE architecture, validation framework, feasibility matrix, phased gates, and six owner decisions. |
| `scripts/cde-phase1-audit.py` | **New.** Read-only measurement script: closed-form check, multiplier distribution, extraction comparison, sample coverage. Assigns no verdict. |
| `scripts/real-book-pagination.py` | Added in Stage AK; reused here for the page-marker count. |
| `docs/INDEX.md` | New one-hop row pointing at the audit and the measurement script. |

**Measured findings (all from commands run this stage):**

| Finding | Measurement |
|---|---|
| The audited estimate is a two-variable product | `hours ≈ 8.888e-5 × words × multiplier`; R² **1.0000** against words×m, 0.9823 against words alone |
| The multiplier is almost entirely one readability formula | r = **+0.975** against Flesch–Kincaid grade |
| Difficulty decides a whole book from a sliver of it | 5,000-char sample = **0.75%** of the book at the median (0.02%–2.83%) |
| The shipped splitter over-counts sentences | **1.34×** vs the project's own canonical splitter; grade level **+2.26** if corrected; 130/135 books affected |
| Difficulty is applied to length | `ContentAnalysis.swift:81` multiplies words by the multiplier before the page conversion |
| Two estimate paths disagree | `EstimationEngine.swift:262` vs `AnalyticsEngine.swift:58`; they differ by a factor of the multiplier, up to **1.77×** here |
| Label resolution is poor | 87% of books in Light/Moderate; Narnia spans **1.64×** within one series |
| Word counting is sound | Swift vs independent Python: **0.0000** median relative deviation across 135 books |

**What was deliberately not done:** no weights were tuned, no formula was
proposed as validated, no production engine was modified or replaced, and no
reading-speed claim is made — the repository still contains no observed reading
session.

**Checks:** `verify-sentinel-surface.sh` exit 0;
`comprehension-bench.py --validate-only` exit 0;
`census.sh --unit-only` exit 0 (493 tests, 99 suites, 0 failed,
`rt-census-20261029-201107.xcresult` — re-stated from Stage AK because no Swift
source changed in this stage).

**Limits:** the second estimate path is proven from source, not exercised end to
the end through a UI. No literature was reviewed in this phase, so the audit
asserts no citations.

## Stage AM — Cognitive Difficulty Engine, Phase 2 and 4 (2026-10-29)

**Trigger:** the master directive for a new Cognitive Difficulty Engine, and the
owner's instruction to continue until the formula was built. The Stage AK
declaration stands: **the previous round of human grades is void**, and nothing
in this stage revives it or claims accuracy against it.

**What this stage is:** a new, independently executable estimator that does not
touch the shipped engine, plus the specification of the formula it implements.

| Path | Change |
|---|---|
| `tools/cde/cde_extract.py` | **New.** Spine enumeration, text extraction, the exclusion ledger, and 12-window stratified sampling. |
| `tools/cde/cde_text.py` | **New.** Canonical sentence splitter, paragraph splitter, prose test. |
| `tools/cde/cde_features.py` | **New.** 18 raw features over six dimensions, plus the corpus-frequency index. |
| `tools/cde/cde_model.py` | **New.** Dimension demand, peak weighting, percentile normalisation, weighted aggregation, bootstrap interval, refusal path. |
| `tools/cde/cde_run.py` | **New.** `frequency`, `calibrate`, `evaluate`, `report` subcommands. |
| `tools/cde/cde_eval.py` | **New.** Determinism, sampling stability, ablation, weight sensitivity, independence, series spread. |
| `tools/cde/test_cde.py` | **New.** 9 tests over aggregation, weighting, interval ordering, refusal, and independence from input order. |
| `tools/cde/config/lexicon-v1.json` | **New.** Top 20,000 word forms measured from the corpus's own windows. |
| `tools/cde/config/reference-v1.json` | **New.** Frozen per-dimension quantile grids and provisional band cuts. |
| `docs/audits/evidence/cde-v0-features-2026-10-29.json` | **New.** Per-book, per-window feature records. |
| `docs/audits/evidence/cde-v0-scores-2026-10-29.json` | **New.** Per-book score, interval, band, dimension breakdown, explanation. |
| `docs/plans/cde/FORMULA.md` | **New.** The canonical specification. |
| `docs/plans/cde/PHASE-3-VALIDATION.md` | **New.** The human-rating protocol and the pre-registered pass/fail gate. |
| `docs/INDEX.md` | Six new one-hop rows: five in a new CDE section, one in the evidence table. |

**The formula, in one line:** six dimensions (lexical load, syntactic load,
entity interaction, continuity, information density, dialogue load), each
`(1−0.35)·mean + 0.35·Q90` over 12 windows, each mapped to a percentile against
a frozen reference grid, summed at equal weights, with a 1,000-resample
bootstrap interval. Exact equations, all 18 feature definitions, and the
configuration schema are in `docs/plans/cde/FORMULA.md#L87`.

**Two calibration defects found and fixed inside this stage** (recorded because
the change is part of the evidence):

| Defect | Why it mattered | Fix |
|---|---|---|
| Proper nouns counted as rare vocabulary | A character name absent from the word list is indistinguishable from a genuinely rare word, so books with large invented casts were penalised purely for naming their characters | Non-name tokens only for lexical rarity |
| Z-score normalisation compressed the index | A z-score keeps each dimension's tail, so a fixed-weight sum is dominated by whichever dimension happens to have the widest spread rather than by anything about the book | Percentile against a frozen 101-point grid per dimension |

A third correction replaced a static dictionary lookup with frequency rank
measured from this corpus, because a fixed word list encodes the date it was
built and would penalise modern prose by construction.

**Measured, this stage** (`python3 tools/cde/cde_eval.py`, exit 0, 47 s):

| Property | Result |
|---|---|
| Determinism | 135 / 135 books reproduce bit-for-bit |
| Sampling stability (3 disjoint 4-window subsets) | within-book SD: median **0.046**, p90 0.085, max 0.156 |
| Ablation | removing any dimension costs 3.8–5.3 index points; Spearman vs full ≥ 0.885 |
| Weight sensitivity | ±50% on any single weight: min rank correlation **0.974** |
| Independence from the shipped multiplier | Spearman **+0.643** |
| Within-series SD vs corpus SD | Narnia 0.041, Spy Classroom 0.058, Naruto 0.061 vs corpus **0.113** |
| Interval width | median 0.160, p90 0.236, max 0.382 |

**Checks:** `verify-sentinel-surface.sh` exit 0 (`15 tables, 8 defaults keys, 5
notification names`); `comprehension-bench.py --validate-only` exit 0 (`bank ok:
30 facts, 12 overview facts`) with the new index rows in place; `census.sh
--unit-only` exit 0 — **493 tests, 99 suites, 719 runs, 485 passed, 9 skipped, 0
failed**, `rt-census-20261029-204123.xcresult`. `python3 -m unittest discover -s
tools/cde -p 'test_*.py'`: 9 tests, 0.024 s, OK.

**Limits, stated where the claims live:** there is **no human validation** of
this index and therefore no accuracy figure — the 135 books were scored, not
graded. Six of the twelve dimensions in the directive are absent (semantic
complexity, information withholding, prior knowledge, structural memory,
register, reader familiarity). Syntactic load is a proxy, not a parse. Lexical
rarity is corpus frequency, not a published norm. The index is corpus-relative,
so a book unlike the reference set saturates. The refusal path is exercised by
unit tests only; no corpus book triggered it. No Swift source and no production
behaviour was changed in this stage.

## Stage AN — external review of the CDE, answered with measurements (2026-10-29)

**Trigger:** an external engineer graded the *description* of the CDE at 62.84/100
and asked for the code and JSON. The grade itself was not disputed; the review
raised specific statistical objections that could be settled by measurement, and
two that were aimed at behaviour the code does not have.

**What changed (no coefficient, weight, grid or committed score was altered):**

| Path | Change |
|---|---|
| `tools/cde/cde_critique.py` | **New.** 293 lines. Sampling coverage, feature-correlation matrix, five aggregation schemes rebuilt end to end, λ sweep, split-half disagreement against the reported interval. |
| `docs/audits/evidence/cde-critique-2026-10-29.json` | **New.** Raw output of every figure quoted in the response. |
| `docs/plans/cde/REVIEW-RESPONSE.md` | **New.** Point-by-point reply: what is accepted, what was refuted with a line reference, what is unfixable inside this design, the file manifest with SHA-256, and the ranked list of what would move the grade. |
| `docs/plans/cde/FORMULA.md` | Interval renamed **sampling stability interval** with an explicit scope statement (§7); coverage distribution and the short-book overlap precondition (§5); split-half check (§11.8); feature-redundancy table (§11.9); aggregation and λ comparison (§11.10); two new limitations (§12.9–10); new §15 answering the review. |
| `docs/plans/cde/PHASE-3-VALIDATION.md` | New §5.1 fixes the unit of analysis before any data exists: mixed model with random intercepts for book, passage-within-book and rater; variance decomposition reported first; ICC(2,5) floor of 0.40; cluster bootstrap over books; random-effects logistic model for pairwise choices. |
| `docs/INDEX.md` | Two more one-hop rows: the review response and the adversarial measurements. |

**Measured this stage** (`python3 tools/cde/cde_critique.py`, exit 0, `real 0m0.158s`):

| Question | Answer |
|---|---|
| How much of a book is actually sampled? | median **23.2%** of words, p10 6.6%, p90 63.0%, range 0.5%–82.2% |
| Are the 18 features independent? | No. `A_morph`/`A_abstract` **+0.954**, `B_sentence`/`B_clause` **+0.951**, `I_content`/`I_np` **+0.905**; the six *dimensions* stay below \|r\| 0.40 |
| Does the aggregation choice matter? | Q85/70-30 gives Spearman **0.994** and an identical top ten; mean-only 0.978; CVaR90 0.906; max 0.836 |
| Does λ matter? | No: 0.972–1.000 across λ 0–1 |
| Does the interval cover window sampling? | Yes, conservatively: median half-to-half gap **0.0567** vs median width 0.1600, ratio 0.38; 3.0% of books exceed the width |

**Two errors in my own description, corrected:** the summary said the sampler
covered "20% to 97%" (actual 5.96%–93.04%) and "35% of the worst chunk" (actual
Q90, never the max). The specification had both right; the prose did not. Both
are corrected in `REVIEW-RESPONSE.md` §2 and the second is now explicit in
`FORMULA.md` §15.

**What was not done:** no weights were re-tuned, no reference grid rebuilt, no
score regenerated. The review produced no evidence that a different coefficient
would be better, and moving one to appear responsive is the failure mode the
project exists to avoid.

**Checks:** `comprehension-bench.py --validate-only` exit 0 (`bank ok: 30 facts,
12 overview facts`) with the new rows; `python3 -m unittest discover -s
tools/cde -p 'test_*.py'` exit 0 (9 tests, 0.024 s); `cde_critique.py` exit 0.
No Swift source changed, so the census was not re-run in this stage.

## Stage AO — CDE v0.3 recalibration (2026-10-29)

**Trigger:** the owner asked for a recalibration that takes both the external
review and this project's own audits into account. The constraint was that a
recalibration without a human target can only be justified by properties that are
measurable without one: internal reliability, feature redundancy, independence
between dimensions, and interval coverage.

**Frozen before changing anything:** `tools/cde/config/cde-v0.2.json`, the exact
configuration that produced every v0.2 score. The new `refit` subcommand rebuilds
grids and scores from stored window features, so a released score can be
reproduced without the EPUB library. Verified first: running refit under v0.2
reproduced `reference-v1.json` grids with **max absolute difference 0.00000000**
per dimension, the same band cuts, and **135/135 identical scores**.

| Path | Change |
|---|---|
| `tools/cde/config/cde-v0.2.json` | **New.** Frozen previous configuration. |
| `tools/cde/config/reference-v3.json` | **New.** Ref-v3 grids and provisional bands. |
| `tools/cde/cde_model.py` | `peak_kind` per config (`peak85`/`peak90`/`cvar`), equal within-dimension β, `joint_interval` covering window **and** reference resampling. |
| `tools/cde/cde_run.py` | New `refit` subcommand: features → grids → scores, with two-source intervals, `sampled_share` and `low_coverage`; `evaluate` now reports coverage too. |
| `tools/cde/cde_recalibrate.py` | **New.** Compares aggregation schemes by split-half reliability and measures what deduplication costs. |
| `tools/cde/cde_critique.py` | Reads the shipped peak operator instead of assuming Q90; reports how many features are in use. |
| `docs/audits/evidence/cde-v0.3-scores-2026-10-29.json` | **New.** 135 scored books, joint intervals, coverage flags. |
| `docs/audits/evidence/cde-critique-v0.3-2026-10-29.json` | **New.** Adversarial checks against v0.3. |
| `docs/audits/evidence/cde-recalibration-2026-10-29.json` | **New.** Reliability table behind the operator choice. |
| `docs/plans/cde/FORMULA.md` | Rewritten as v0.3: equations, 15 in-use features, two-source interval, new battery, §16 change record. |
| `docs/plans/cde/REVIEW-RESPONSE.md` | Postscript: that reply documents v0.2; v0.3 is canonical where they differ. |

**Changes and what each bought (all measured this stage):**

| Change | Effect |
|---|---|
| Within-dimension β equal, replacing 0.55/0.25/0.20-style splits | split-half disagreement 0.0567 → **0.0550** |
| `A_morph`, `B_sentence`, `I_np` retired (r ≥ 0.90 with a sibling) | reliability unchanged at 0.0550; fewer near-duplicate indicators |
| Peak operator Q90 → **Q85** at λ = 0.35 | 0.0617 → **0.0550** for that operator; Q90 and CVaR were worse (0.0617, 0.0633) |
| Interval resamples the reference corpus as well | median width 0.150 → **0.158**; reference-only component alone is 0.055 |
| `sampled_share` + `low_coverage` per book | six long compilations flagged below 3% coverage |

**Battery, v0.2 → v0.3:**

| Property | v0.2 | v0.3 |
|---|---:|---:|
| Determinism | 135/135 | **135/135** (and the full refit is bit-identical on rerun, intervals included) |
| Split-half median | 0.0567 | **0.0550** |
| Sampling SD median / p90 / max | 0.046 / 0.085 / 0.156 | **0.045 / 0.082 / 0.135** |
| Ablation, worst Spearman | 0.885 | **0.910** |
| Weight sensitivity, min | 0.974 | **0.977** |
| Independence from shipped multiplier | 0.643 | **0.626** |
| Interval width median | 0.160 | 0.158 joint (0.150 window-only) |
| Halves beyond the interval | 3.0% | **1.5%** |

**What got worse, stated plainly:** the strongest between-dimension correlation
rose from A/I **+0.20 to +0.43**, because A and I now both lean on content-word
measures; equal weighting therefore double-counts a little more shared variance
than before. The ranking moved: Spearman against v0.2 is **0.929**, mean |ΔD|
**0.031**, max **0.182**, top ten **8/10**. There is no human target that can say
which version is closer to a reader, and no such claim is made.

**Deliberately not done:** no weight was fitted to any outcome; no interaction
term was added; the bands remain corpus quintiles; no reader model was invented.
Fitting six weights against no target would produce numbers, not evidence.

**Checks:** `python3 -m unittest discover -s tools/cde -p 'test_*.py'` exit 0
(9 tests, 0.025 s); `refit` exit 0 (`real 0m12.304s`, 200 draws) and bit-identical
on rerun; `cde_eval.py` exit 0 (`real 0m50.719s`); `cde_critique.py` exit 0
(0.133 s); `cde_recalibrate.py` exit 0 (0.177 s);
`comprehension-bench.py --validate-only` exit 0. The census was **not** re-run:
no Swift source changed in this stage.

## Stage AP — the formula gets a name: Asterisma Difficulty Formula (ADF) (2026-10-29)

**Trigger:** the owner asked for one handle that can be cited across the
codebase instead of a per-document description.

**Why a name was needed, not just a label.** "CDE" (Cognitive Difficulty
Engine) had been naming two different things: the *instrument* — corpus,
extractor, frozen lexicons, reference grids — and the *formula* those
instruments feed. Any sentence of the form "CDE scores a book at 0.63" is
ambiguous about which of the two it means, and that ambiguity gets worse when a
v0.2 and a v0.3 both exist.

**The name, registered once.** Full name **Asterisma Difficulty Formula**,
handle **ADF**, versioned **ADF v0.3**, machine identifier
`asterisma-difficulty-formula@0.3`. The mapping to the three nearby names that
are *not* the formula is written out in `docs/plans/cde/FORMULA.md#L20`:

| Term | What it names |
|---|---|
| CDE | the instrument (`tools/cde/`) |
| ADF | the model the instrument computes |
| `DifficultyAnalyzer` | the legacy in-app engine ADF replaces, not a version of it |
| `D` | the number, `D ∈ [0,1]`, produced by one run of ADF on one book |

The bare word "difficultyformula" was considered and not adopted: it collides
with the 130 existing `difficulty` hits in the Swift sources
(`grep -rio difficulty --include=*.swift AsterismaV1.0 AsterismaV2.0 | wc -l`
→ `130`), and it carries no version, while v0.2 and v0.3 must both stay
nameable for reproducibility.

**Where it lives now:**

| Path | Change |
|---|---|
| `docs/plans/cde/FORMULA.md` | Title carries the name; new §0 "Name" (line 20) holds the canonical table and the three-way distinction. |
| `tools/cde/cde_model.py` | `FORMULA_NAME`, `FORMULA_HANDLE`, `FORMULA_VERSION`, `FORMULA_ID` (lines 44–47), beside the existing `DEFAULT_CONFIG` at line 66. |
| `docs/INDEX.md` | New one-hop row: "What the difficulty formula is called, and the three names it is **not**". |

**What deliberately did not change.** `DEFAULT_CONFIG["version"]` still reads
`cde-v0.3`, so every evidence artefact keeps the bytes and hashes already cited
in Stages AM–AO. No score, band, interval or grid moved. §0 records that the
artefact string and `FORMULA_ID` are two forms of one name, which is the reason
the constant was not renamed underneath the receipts.

**Anchors re-pointed, one defect repaired.** Inserting §0 shifted every later
heading by 32 lines. The five `FORMULA.md#L*` anchors in `docs/INDEX.md` were
re-derived from the new headings: equations `L55→L87`, measured behaviour
`L338→L370`, scope `L422→L454`, review `L511→L543`. While doing it, a stale
anchor in Stage AM was found: it cited `FORMULA.md#L47` for "the equations",
which had already moved to line 55 before this stage. Corrected to `#L87`.
`docs/plans/cde/REVIEW-RESPONSE.md:353` was refreshed to the new
`cde_model.py` size and digest.

**Checks (all from the repository root):**

| Command | Result |
|---|---|
| `python3 -m unittest discover -s tools/cde -p 'test_*.py'` | exit 0, `Ran 9 tests in 0.026s`, `OK` (status captured with `set -o pipefail`) |
| `python3 scripts/comprehension-bench.py --validate-only` | exit 0, `bank ok: 30 facts, 12 overview facts` |
| `python3 -c "import cde_model; print(FORMULA_ID)"` | exit 0, prints `asterisma-difficulty-formula@0.3` |
| `sha256sum tools/cde/cde_model.py` | `9ffcc9635a1299694a236f596c0d7c29a049ed1f2c8398c2d631038caec92d75`, 13,323 bytes |

**Not re-run, and why:** `cde_run.py refit`, `cde_eval.py` and `cde_critique.py`
were not re-executed — no formula, feature, weight, grid or sampling code
changed, so their outputs would be bit-identical by construction (Stage AO
already proved the refit reproduces bit-identically). The Swift census was not
run: no Swift source changed. `PHASE-3-VALIDATION.md` is untouched; the name is
new, the validation plan is not.

## Stage AQ — ADF retest: all 149 packages, 16 blind grades (2026-10-29)

**Trigger:** the owner asked whether ADF is wired to anything, to wire it into
the relevant engines, to run the tests in `oct-december plans.md`, and to run all
149 books and hand-grade each one.

**Where the governing plan actually lives.** `docs/audits/new-era-testing.md:12`
cites `oct-december plans.md` as its governing plan, but no such file exists in
the repository, in history, or on disk at the project root. It was found inside
the corpus folder on the Desktop (`asterisma new testing suite/oct-december
plans.md`, 2,339 lines). The reference is therefore dangling for anyone reading
the repo alone; it is left as-is because the file is the owner's and relocating
it is not this stage's business. Its §15 (human evaluation) governs this retest.

**Answer to "is it wired?": no.** `grep -rn "asterisma-difficulty-formula\|FORMULA_ID\|\bADF\b"
--include=*.swift --include=*.py --include=*.sh .` outside `tools/cde/` and
`docs/` returns nothing. ADF was a standalone tool.

**Decision: not wired into reading-time estimation, deliberately.** The retest
below found a mean band error of −0.875 and −2.4 bands at the top of the scale.
At that point the four engines listed here consumed
`ReadingDifficultyProfile.difficultyMultiplier`; the main `EstimationEngine`
no longer applies that profile to its measured page pace. The formula is wired
to a stable JSON contract instead, and the app-facing step is deferred with the
reason recorded in `docs/plans/cde/RETEST-2026-10-29.md` §9.

| Path | Change |
|---|---|
| `tools/cde/cde_sheet.py` | **New.** Scores every package in a corpus including `dup_of` copies, proves duplicate identity by content digest, emits JSON + a readable sheet. |
| `tools/cde/cde_grade.py` | **New.** Builds a blind worksheet plus a separate score key; analyses verdicts, band distance and self-consistency. |
| `docs/plans/cde/GRADING.md` | **New.** The protocol: labels, blindness, two passes, adjudication, calibration, metrics. |
| `docs/plans/cde/RETEST-2026-10-29.md` | **New.** Results and diagnoses. |
| `docs/audits/evidence/adf-149-*` | **New.** Features, scores, sheet, worksheets, pass A and pass B grades, grade report. |

**The 149 run.**

| Measure | Value |
|---|---:|
| Packages / scored / failures | 149 / 149 / 0 |
| Distinct content digests | 135 |
| Duplicate groups / copies | 14 / 14 |
| Duplicate score mismatches | **0** |
| Byte-identical reruns | **2 of 2**, `907b4f19bb70ae62ac7534ec8ce5f8c9c4456397dc48df1b0df3910ca6416394` |
| Elapsed | 46.29 s, 45.80 s |

Duplicate identity is computed from package digests (zip bytes, or a sorted
tree digest for unzipped packages), so the 14 copies match their host by
measurement rather than by being skipped. `cde_run.py calibrate` cannot do this
because it drops `dup_of` entries by design.

**The grading pass, and what it is worth.** 16 distinct books, selected by
SHA-256 of filename so the sample could not be steered toward easy cases, graded
blind from a worksheet carrying no `D` or band. Result: 11 `OK`, 5 `TOO_HIGH`,
0 `TOO_LOW`; 68.8% within one band; mean band delta −0.875, median −0.5, worst
over-call 4 bands, worst under-call 1.

| ADF band | Mean band delta | Rows |
|---|---:|---:|
| Light | +0.25 | 4 |
| Moderate | 0.00 | 3 |
| Demanding | −1.00 | 1 |
| Heavy | −0.67 | 3 |
| Very heavy | −2.40 | 5 |

Three failures diagnosed from their own dimension percentiles, all recorded in
the retest file: `Live by Night` (cast and dialogue at 0.90/0.85), `The Beginning
After the End` book 10 (density 0.96 on plain action prose, four bands off), and
`Fire and Blood` (`People / things` at 1.00). The common shape is that crowded
genre fiction is read as hard.

**A metric defect found and fixed inside this stage.** `cde_grade.py` first
scored "signed bias" from the verdict's sign, so a one-band `OK` and a four-band
`OK` counted identically and the reported error was −0.31. The grader's own band
is now recorded per row (`band_as_i_would_call_it`) and distance is computed from
it, which is where −0.875 comes from. The worksheet schema, `GRADING.md` §1/§7
and both pass files were updated together.

**Self-consistency is recorded and declared inadmissible.** Pass B, from window
6, agreed 16/16 (κ = 1.00). Both passes were made by the same grader in the same
session, so the band call was remembered; `GRADING.md` §4 requires a day or an
intervening task, which was not done. The number is in the artifact and is not
cited as reliability.

**Not done, and why:**

- **133 books ungraded.** The worksheet for all 149 exists and is blind; grading
  16 took the available session. A second reader is the constraint, not the tool.
- **No Swift port and no engine wiring.** Justified by the bias above, not by
  time.
- **No accuracy number.** `oct-december plans.md` §15.2 forbids treating document
  judgements as reading-time measurements, and no session data exists for these
  books. §12.1 forbids synthetic labels. An accuracy percentage here would be
  invented.

**Checks:**

| Command | Result |
|---|---|
| `python3 tools/cde/cde_sheet.py --corpus "asterisma new testing suite" …` | exit 0, twice; JSON byte-identical (`907b4f19bb70ae62ac7534ec8ce5f8c9c4456397dc48df1b0df3910ca6416394`) |
| `python3 tools/cde/cde_grade.py worksheet … --window 0` | exit 0, 149 blind rows |
| `python3 tools/cde/cde_grade.py analyze … --second-pass …` | exit 0, report written |
| `python3 -m unittest discover -s tools/cde -p 'test_*.py'` | exit 0, `Ran 9 tests in 0.026s`, `OK` (status captured with `set -o pipefail`) |
| `python3 scripts/comprehension-bench.py --validate-only` | exit 0, `bank ok: 30 facts, 12 overview facts` |

The Swift census was not run: no Swift source changed in this stage.

## Synthetic reading-time harness closeout — 2026-10-30

The synthetic experiment, its scenario limits, and results are recorded in
`docs/audits/synthetic-reading-evaluation.md`. The full batch inputs and
outcomes are retained under `tools/cde/synthetic-batch-762944`, with the
summary in `docs/audits/evidence/synthetic-reading-eval-762944.json`.
The experiment does not establish real-reader accuracy.

Closeout inventory: the explicitly named temporary `.synthetic-*` test logs
and exit files occupied 620 KiB by `du -ck` before removal; afterwards
`find . -maxdepth 1 -name '.synthetic-*' -print | wc -l` printed `0`.
No existing `.DS_Store` files, runtime staging, prior work, or other unknown
artifacts were removed. The three batch directories were retained: `du -sk`
reported 10,928 KiB, 10,924 KiB and 16,228 KiB respectively for
`tools/cde/synthetic-batch-762943`,
`tools/cde/synthetic-batch-762943-final`, and
`tools/cde/synthetic-batch-762944`.

`graphify update .` exited 0 and reported 8,956 nodes, 21,465 edges, and 433
communities, with 35 inputs producing no nodes. The tool states it refreshed
code only; semantic documentation refresh is **SKIPPED** because the local
CLI did not perform it. `graphify export html` exited 0 and produced an
aggregated 2D view. `python3 scripts/build-graph-3d.py` and
`python3 scripts/build-graph-3d.py --check` exited 0; the full 3D output was
9,048,900 bytes by `wc -c`. The mandated browser rendering, WebGL, console,
and network checks are **SKIPPED**: this task did not request a visual
inspection. The graph is not a complete fresh semantic index of documentation.

Current SHA-256 from `shasum -a 256`: `graphify-out/graph.json`
`e2d1123123260fc1bb4c0cfdc7a91df8ee131c302ff1a4b471f02f46488380ab`;
`graphify-out/graph.html`
`07c96bcd229b066f352391d1df2d494e000725868dba3a6e6bcbdecf2b03aff9`;
`graphify-out/graph-3d-full.html`
`30916811f6bf209aa7ef5b9888b1550399d0d0379d7fe58d4ca1f70eac1c3098`;
`graphify-out/GRAPH_REPORT.md`
`3457a47ffe7e97a9423670b0c6ed6476746317c4acb4cafdb7f79df934f057ef`.

## Fresh 200-round stress evaluation — 2026-10-31

**Changes before the run.** Two production changes: per-book normalization and
consensus in `AnalyticsEngine.crossBookReadingSpeed`
(`AsterismaV2.0/Engines/AnalyticsEngine.swift#L83`) with
`PageDurationPolicy.consensusSeconds` (`#L459`), and the
`max(median, lowerQuartile × 3)` ceiling in `robustMeanSeconds` (`#L424`)
and `upperBound` (`#L444`). Two candidate-adapter rules: the three-timing
minimum (`AsterismaV2.0Tests/Engines/AdversarialEvaluationTests.swift#L71`)
and the two-sided `0.35/3.0` guard (`#L73`). The first two are production
code; the last two are evaluation-adapter rules and are not wired into the app.

**What ran.** `bash tools/cde/run_fresh_200.sh` produced 40 batches of five
rounds, 9,914 main cases per round, plus 200 demo rounds of 16 personas:
1,982,800 main predictions and 3,200 demo predictions. The driver was
interrupted after batch 175 and resumed at batch 176; already graded batches
were skipped. `run.exit` is `0` and the log ends
`ALL DONE 2026-10-31T02:12:20Z`. `python3 tools/cde/analyze_fresh_200.py`
exited 0; it verified 1,982,800 rows across 40 batches with no duplicate IDs,
invalid numbers, arithmetic mismatches or candidate-rule mismatches, and 3,200
demo rows with no errors. The complete report is
`docs/audits/fresh-reading-stress-200-2026-10-30.md`
(SHA-256 `76ba1ba0bc050566bcfef62219c7c218d1edcac1850193bd8222ef806f58e582`,
356 lines).

**Comparator result.** Same-case synthetic errors, all 1,982,800 main cases:

| Model | Median % | Mean % | Spikes |
|---|---:|---:|---:|
| Fixed production baseline | 18.98 | 35.45 | 170,404 |
| Legacy comparator (hybrid) | 21.42 | 38.21 | 185,341 |
| Candidate at fitted 0.979 | 23.09 | 41.35 | 220,164 |
| Candidate at pre-registered 0.5 | 26.70 | 43.35 | 223,724 |

The fixed baseline improves on the differing subset too (median 9.40% against
12.12%; 14,724 spikes against 26,009), but `corpus-evaluation` is an exception
(median 16.51% against 15.62%; mean unchanged at 21.13%). The comparator is not
a clean ceiling A/B: it equals the baseline on `same_book` (5.48%/7.64%/158 for
both) because personal-speed books call the current per-book policy, and the
gain is concentrated in the no-personal-speed pooling path (`sparse` 16.67%
against 24.88%; `cross_book` 27.18% against 27.67%). The candidate loses at
both weights. The fitted weight is 0.979013257067 because the calibration
objective decreases toward recent-only on the 244,514 eligible development
cases; that subset excludes every 2-sample fallback and guard rejection.

**Why the candidate loses.** In `sparse`, 472,404 of the 484,600 two-timing
cases differ; the candidate returns the cross-book prior while the baseline
includes the target book. Median rises from 16.67% to 27.11% and spikes from
12,206 to 39,528. In `same_book`, the last-eight window adds variance (mean
7.64% to 14.82%; spikes 158 to 21,060). In `corpus`, the guard rejects a clean
recent pace when the prior is about ten times larger; the worst differing case
is 873.36% (round 46, target 590.60 s, recent 588.62 s, prior 5,748.67 s). The
`adversarial` family is the exception where the candidate wins (median 10.04%
against 18.38%; 0 spikes against 200). The report records all tables and the
tail; the candidate is rejected rather than promoted.

**Artifacts.** The 200-round tree was hashed into
[the evidence archive](../audits/evidence/fresh-stress-evidence-archive-2026-10-31.md)
and deleted on 2026-10-31: 1,773 files, 4,989,897,276 bytes, global manifest
SHA-256 `df1a42e0e77b2c2b65006fc9c5974054314118b89f1fa43dad32b7fd782b441f`.
`verified-summary.json` SHA-256
`b543efc740decc0e581f32291cdc43be73ff90cac7c72d9061e8a21b807a6847`;
`weight-sweep-summary.json`
`61fcf5f877b642d102b77593411d10ddfdf6e795360edd645ec75356957360c4`;
`worst-differing-cases.json`
`caacae80b5dc1485df07cdcd2e74cc4342fc0b29af788d0d3fd9a3b5ef35d0f1`.
The report generator is `tools/cde/write_fresh_200_report.py`.

**Checks.** `python3 -m unittest discover -s tools/cde -p 'test_*.py'` exit 0,
`Ran 28 tests`, `OK`. `./scripts/verify-sentinel-surface.sh` exit 0.
`python3 scripts/comprehension-bench.py --validate-only` exit 0, `bank ok: 30
facts, 12 overview facts`. `./scripts/census.sh --unit-only` exit 0; Xcode
summary `result Passed; 515 total, 506 passed, 0 failed, 9 skipped; 719 test
runs`. The nine skips are not passes.

**Not done.** No independent hand grading of every case; no real-reader or
live-app validation; no stop-on-spike restart; no clean uninterrupted 200-round
invocation; no graph refresh, commit or push in this session. The junk cleanup
and evidence archival were done. The outcomes are synthetic, not measurements
of people.

## Junk cleanup — 2026-10-31

`du -sk .` measured 6,885,764 KiB before cleanup and 6,472,512 KiB after,
reclaiming 413,252 KiB (about 403.6 MiB). Removed 260 KiB of `.DS_Store` files
and 372 KiB of unreferenced root-level `.adversarial-*` logs. The 403 MiB
`demo-200-predictions.json` was byte-identical to
`demo-200-attachments/456E1DB7-5B93-413F-8464-A510728A6421.json` (SHA-256
`80ab33f679f766aeb9692315df5717b8882babfa001397340be62cd8d149c793`); it was made
a hardlink to the attachment before the tree was deleted, so both paths,
contents and digest were preserved at that step.

After that dedupe, the 100- and 200-round trees were archived and deleted. The
archive is `docs/audits/evidence/fresh-stress-evidence-archive-2026-10-31.md`
(SHA-256 `aba62346888056aff88a40c6686d7a8cc05e22b038e9305acfd5899d8db2e875`,
341 lines): 2,407 files, 6,778,962,719 bytes, with global manifest hashes
`df1a42e0e77b2c2b65006fc9c5974054314118b89f1fa43dad32b7fd782b441f` (200-round)
and `7ace80ff67f686b7b268847315cb8973ebf02ab02c1e1bb154dc6423d689a1d2`
(100-round). Raw per-case JSON and `.xcresult` bundles are not recoverable.
`du -sk .` then fell from 6,885,764 KiB to 257,504 KiB at deletion, a total reduction of
6,628,260 KiB (about 6.32 GiB).

Kept `graphify-out/` (60M), `.mirage-runtime/` (48M), `.cloud-attachments/`,
and all source, tests and docs. A follow-up scan found no remaining `.DS_Store`,
`.profraw`, `DerivedData`, `.playwright-cli`, or root adversarial logs.

## Stress-evidence archive — 2026-11-07

**What moved.** The full generated stress fixture and the CDE run bulk were moved
out of the repository to
`/Users/johanrembeci/Desktop/AsterismaV2.0-Evidence-Archive-2026-11-07`:

- `AsterismaV2.0Tests/Engines/FreshStressInput.json` — 38,660,433 B / 49,570
  cases, SHA-256 `8d08822b9c6bee1eed2923d0a1c186a5c59e2ca5858dfb2c7fcced2bd801e110`.
  It is replaced in-tree by a 200-case representative sample (157,597 B) so the
  bundled-batch decode, unique-ID, and prediction assertions still run.
- `tools/cde/final-stress-20261030`, `synthetic-batch-762943`,
  `synthetic-batch-762943-final`, `synthetic-batch-762944`,
  `adversarial-development-81521`, `adversarial-development-81522`,
  `adversarial-evaluation-92743`, `corpus-development-430122`, and
  `corpus-evaluation-430123` — 65 MB of generated run data.
- `.cloud-attachments/` — 10 MB of imported-conversation attachment data.

**Before/after.** The repository was 257,504 KiB at the 2026-10-31 deletion-time
measurement; after this archive `du -sh .` reports 140 MB. The archive itself is
112 MB across 449 files. The source, tests, `docs/audits/evidence` (3.6 MB),
`tools/cde` source/config (644 KB), and graph artifacts were kept.

**Checks after the move.** `python3 -m unittest discover -s tools/cde -p 'test_*.py'`
exit 0 (28 tests); `./scripts/verify-sentinel-surface.sh` exit 0;
`python3 scripts/comprehension-bench.py --validate-only` exit 0;
`./scripts/census.sh --unit-only` exit 0 (515 total / 506 passed / 9 skipped /
0 failed / 719 runs); the full Markdown audit over 103 files exit 0. No commit or
push occurred at archive time.

## Stage AR — E8 estimate facade, page/difficulty separation, behavior SQLite (2026-11-07)

**Trigger.** Phase 3 of the reading-analytics program: the audit had proved two
estimate paths disagreed, difficulty was being multiplied into page count, and
behavior evidence still wrote only JSON.

**What changed (source/test commit `f9b8686`):**

| Path | Change |
|---|---|
| `AsterismaV2.0/Engines/EstimationEngine.swift` | Added `effectiveSecondsPerPage(for:allBooks:)`; `estimate` and the chapter/page helpers resolve that one pace. |
| `AsterismaV2.0/Engines/AnalyticsEngine.swift` | `effectiveReadingSpeed`, `predictions`, `bookForecast`, and `chapterPredictions` delegate to the canonical pace; removed `normalizedPages`, the difficulty-as-pages helper. |
| `AsterismaV2.0/Features/Library/ContentAnalysis.swift` | `PageEstimationModel` no longer accepts a difficulty multiplier; words convert to pages at 250 wpp. |
| `AsterismaV2.0/Features/Library/BookImporter.swift`, `tools/real-book-audit/main.swift` | Call sites updated; difficulty remains metadata. |
| `AsterismaV2.0/Features/BehaviorContext/BehavioralCategory.swift` | `BehaviorContextAccessKit` reads/writes the existing `behavior_events`, `application_sessions`, `inactivity_records`, and `device_state_events` tables; JSON is the import seed and compatibility mirror. |
| `AsterismaV2.0/Core/DataStore3.swift`, `AsterismaV2.0/App/AsterismaApp.swift` | The app injects its canonical `LibraryDatabase` into the behavior kit. |
| `AsterismaV2.0Tests/Engines/EstimateFacadeTests.swift` | New E8 pins: measured and cross-book pace parity. |
| `AsterismaV2.0Tests/Library/PageEstimationModelTests.swift` | Difficulty-is-not-pages pin replaces the old difficulty-increases-pages pin. |
| `AsterismaV2.0Tests/Behavior/G6EvidencePersistenceTests.swift` | New SQLite-wins-over-JSON pin. |

**Checks.**

| Command | Result |
|---|---|
| Focused `xcodebuild test` (E8, E7, E6, G6 suites) | 16 tests in 4 suites passed, exit **0**, `TEST SUCCEEDED` |
| `./scripts/verify-sentinel-surface.sh` | `sentinel-surface: OK — 15 tables, 8 defaults keys, 5 notification names`, exit **0** |
| `python3 scripts/comprehension-bench.py --validate-only` | `bank ok: 30 facts, 12 overview facts`, exit **0** |
| `./scripts/census.sh --unit-only` | `result Passed`; **518 total / 509 passed / 9 skipped / 0 failed / 719 runs**, 100 suites, exit **0**, `rt-census-20261106-213119.xcresult` |

**Limits.** The behavior migration is tested against a temporary `LibraryDatabase`,
not the owner's live library; the JSON mirror is intentionally retained for older
builds and Sentinel's BHV-001 probe. No owner visual or real-device acceptance
was run. The estimate changes are unit-pinned; no independent reader or real-book
accuracy claim is made.

**Next.** Push this commit and the documentation commit, then watch `census.yml`
to green. The remaining Phase 3 work is owner-visible acceptance of the new
behavior store and the collection rename UI; Swift 6 and distribution remain
separate programs.
