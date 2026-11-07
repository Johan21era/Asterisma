# 00 · AsterismaV2.0 — Project Report

> **TL;DR** — AsterismaV2.0 is a macOS reading-tracker app written entirely in Swift/SwiftUI. You import your PDF and EPUB books, read them inside the app, and it quietly records everything: per-page reading speed, time of day, live weather, and the app you were using just before opening the book. As of the October 2026 merge campaign, it also carries **Mirage** — a separately-owned companion engine for EPUB analysis, integrated behind a typed one-way boundary.

> **Bedrock update (2026-10-24):** the app now runs on a **GRDB/SQLite summary store** (JSON migrated to `.migrated`, load **5.06 ms** vs 493.7 ms), weather uses **Open-Meteo** with no WeatherKit entitlement, Mirage is **embedded and signed**, Behavior Context V3 is wired with an Advanced Context window, and real EPUB imports populate genre/series/word count. The full gate record lives in `docs/plans/bedrock/`. Current local census (2026-11-07, after the E8 estimate-facade, page/difficulty separation, and behavior-evidence SQLite tranche): **518 tests / 100 suites / 719 runs, 509 passed, 9 skips, 0 failures** on macOS 27.2 / Xcode 27.2 (`./scripts/census.sh --unit-only`, exit 0); CI also runs the surface-manifest freshness gate before the census.

> **Release status (2026-10-26, V1.0 era):** `AsterismaV1.0` remains merged to `main` at `aba8aa4` (release commit `6da2d81`, tag `asterisma-v1.0-mvp`). The owner accepted the full reader workflow on the `asterisma-v1.0-ux-audit-2` build. The ready tree adds the Apple Books-style Appearance panel, the preservation-first repository reorganization, and green CI hardening; app code is `1c88ae5`, tagged `asterisma-v1.0-ready-2026-10-26`. Package: `dist/AsterismaV1.0-1.0-arm64.zip`, SHA-256 `786832c8049e38ebe03d6220ae0a39b3a0005b010bdce4675e440cea65ef4643`. It is ad-hoc signed, not notarized; first launch requires right-click → Open. Owner visual retest of the Appearance panel and book plate remains the next acceptance gate.

> **Owner-test authority (2026-10-24):** results from Johan's personal testing are the **absolute source of truth** and override all previous benchmarks, censuses, gate receipts, and documentation claims. See `docs/12-owner-test-authority.md`; sessions are recorded in `docs/owner-test-results/` and pinned by tag `owner-test-authority-2026-10-24`.

---

## Contents

| § | Section |
|---|---------|
| 1 | What the app does |
| 2 | The project at a glance |
| 3 | Technical overview |
| 4 | Verified health status |
| 5 | Open work, in priority order |
| 6 | Documentation map |
| 7 | Build & run |
| 8 | The fix protocol (for contributors) |

---

## §1 · What the app does

**AsterismaV2.0** imports PDF and EPUB books — including iBooks-style unzipped `.epub` package folders — and lets you read them in-app, including an RSVP (Rapid Serial Visual Presentation) speed-reading mode that streams a chapter or a whole PDF one word at a time. While you read, the app records:

- **Per-page timing** — turn speed captured for every single page, feeding analytics and estimates
- **Temporal habits** — hour-of-day and day-of-week engagement patterns
- **Environmental context** — live Open-Meteo snapshots correlated with sessions
- **Behavioral context** — foreground-app observation (via `NSWorkspace`) to reconstruct *where and why* you read
- **Goals, streaks, and 25 achievements** — daily/weekly/annual targets with a toast system
- **Annual Reports** — a yearly review rendered as slides
- **Night-sky ambience** — a starfield background that tracks real time of day, weather, and location
- **Mirage analysis (optional, opt-in per gesture)** — for an imported EPUB, an explicit "Analyze with Mirage" gesture sends that single book to a separately-owned analysis engine and wires the results to your reading state; the engine keeps its own ledger and never writes RT's store (see §3.5)

There is also a hidden **Developer Console** (⌘⇧D, Debug builds only) for stress-testing with **16 deterministic fake reader personas**, and a built-in **Sentinel** watchdog that scans 140 checks across 15 data domains, verifies and snapshots every repair, and explains what happened while you were away. The Release Health Center (⌘⇧H) is the full surface.

---

## §2 · The project at a glance

| | |
|---|---|
| **What it is** | A sandboxed macOS AppKit/SwiftUI app for tracking your reading — plus the integrated Mirage companion engine (optional feature) |
| **Language** | Swift 5 mode, SwiftUI + AppKit only |
| **Build config** | `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`, deployment target macOS 26.5, Xcode 27.1 locally; CI pins Xcode 26.6 |
| **Dependencies** | Exactly one Swift dependency: ZIPFoundation 0.9.20 (SPM, pinned via `Package.resolved` — used for unzipping EPUBs). Mirage ships as a self-contained bundled runtime (its own Python interpreter), not a Swift dependency |
| **App size** | 180 Swift files · 68,185 raw lines (60,366 non-blank) — counted from the tree on 2026-10-31 |
| **Tests** | **518 tests / 100 suites / 719 runs · 509 passed · 9 skips · 0 failures** in the local unit census (2026-11-07, after the E8 estimate facade, page/difficulty separation, and behavior-evidence SQLite tranche); CI runs the surface-freshness gate before the census |
| **How it is tested** | Swift Testing (`@Suite` / `@Test` / `#expect`) — not XCTest |
| **History** | ~30 working sessions (Jun–Oct 2026), 45+ commits, then the **RT–Mirage merge campaign** (Oct 2026): the 8-PR integration ladder PR-1…PR-8, closed with owner signatures; then the **Bedrock / AsterismaV1.0 release** (2026-10-24) |
| **Where your data lives** | Sandbox container: `~/Library/Containers/johan.Reading-Tracker/Data/Library/Application Support/Asterisma/` (see §3) — plus Mirage's own stratum (§3.5) |

---

## §3 · Technical overview

### 3.1 Architecture

The codebase is split into three layers, all pure Swift — no bridges, no C extensions:

| Layer | Path | What lives there |
|---|---|---|
| **Core** | `Core/` | `DataStore3` (persistence), `Book2` (models), `PersistenceWriter` (serial disk writes), `AnalyticsCache` (memoization), `CoverStore` (content-addressed cover files + NSCache), `DataIntegrityValidator`, `SentinelRuntime` (v2 watchdog), `LibraryArchiveManager` (`.readingarchive` I/O) |
| **Engines** | `Engines/` | Pure static-namespace analytics: `AnalyticsEngine`, `EstimationEngine` (page-timing-based estimates), `DataMaturityEngine` (evidence gating with injected clocks) |
| **Features** | `Features/` | Everything user-facing: Library, Reader (PDF/EPUB), RSVP, Reports, Insights, Goals, Achievements, BehaviorContext, Environment (weather/stars), Discovery, Sessions, Audio, Notifications, Onboarding, DeveloperConsole, **and `Mirage/` — the integration surface (14 typed Swift files)** |

### 3.2 Concurrency model

The project's defining (and historically most destructive) build setting is `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`: **every function is main-actor-isolated unless explicitly annotated `nonisolated`**. The freeze era is documented in `docs/history/10-profiler-fix.md`. The discipline now in place:

- Heavy paths (demo synthesis, library encode, cover capture, RSVP extraction, backup I/O, and **all Mirage transport/pruning work**) are explicitly stamped `nonisolated` so they truly leave the main thread
- The fix is **compiler-enforced** — a regression reintroducing a main-actor hop breaks the build loudly, rather than freezing at runtime

### 3.3 Data & persistence surface

All user data lives in one place (sandbox container):

```text
~/Library/Containers/johan.Reading-Tracker/Data/Library/Application Support/Asterisma/
├── library.json              Every book → session → individual page-turn timing (pretty-printed JSON monolith)
├── library-state.json        Goals, deadlines, earned achievements, collections
├── library.bak.json          Automatic same-name backup written before corruption resets
├── library.sqlite3 (+wal/shm) SQLite weather snapshot store (keyed by session ID)
├── covers/                   Content-addressed cover files (NSCache-fronted)
├── Backups/                  Automatic dated backups — newest 10 kept, hash-gated
├── mirage/                   Mirage's OWN stratum (created on first use): ledger db, identity map, supervisor guard file — Mirage-write territory, RT never writes it
└── Sentinel/               Sentinel v2 journal segments, issue state, plans, quarantine
```

At the time of writing, the author's own working library weighs **~28 MB of `library.json`** with ~43 MB of backups — and these numbers scale linearly with pages turned forever (zero pruning exists). That scaling ceiling is the app's main architectural open item (§5).

Writes go through `PersistenceWriter` on a serial utility queue behind a debounce. All analytics reductions are static and pure; `AnalyticsCache` memoizes the five hottest whole-library reductions behind a mutation-epoch counter.

### 3.4 Sentinel (self-repair watchdog)

**Current coverage, matched to the shipped v2 code:**

| Surface | Reality in the current tranche |
|---|---|
| **Probes** | **140** deterministic checks across **15 domains** (library, sessions, goals, collections, database, backups, files, weather, audio, behavior, Mirage, app state, Sentinel itself, security, capacity). 58 are required; the rest are optional deep checks |
| **Repairs** | **25** implemented plans with preview, safety snapshot, generation/subject re-read, verification, rollback, and undo. R3 recovery is never one-click; auto-fix is R1-only and opt-in |
| **Surfaces** | Launch report card; **Release Health Center** (⌘⇧H: a persistent sidebar for Overview, Issues, Recovery, History, Checks, and Settings, with issue search, severity filters, and a Next issue control); Settings ▸ Sentinel; Developer Console pane in Debug |
| **Classifier** | Persistent issue store with fingerprints, owner/contributor evidence, lifecycle (open, acknowledged, snoozed, ignored, resolved), regression detection, and root-cause diagnoses |
| **Journal** | v2 segmented JSONL with checksums, rotation, retention, and v1 migration. Only the safe projection is stored; `debugDetail` never reaches the journal |
| **Settings** | Autonomy A0–A3, fast/deep cadence, quiet hours, per-domain toggles, notification opt-in, undo window |
| **Known limits** | Menu bar surface is not shipped (SwiftUI `MenuBarExtra` hung the test host); English-only; manual owner acceptance pending; the 700-probe / 120-domain / 350-repair program target is not yet reached; no 10× SQLite benchmark |

Security doctrine S1–S7 is pinned by tests, including write-confinement, the kill switch, snapshot-before-mutation, rollback, undo, and journal/diagnostics redaction. The writability check proves a write in a system replacement directory; it never writes a test file into the data root. Release defaults to **Assist** (suggest, user clicks); choose **Off** in Settings ▸ Sentinel to disable entirely, or set it directly:

```bash
defaults write johan.Reading-Tracker sentinel.autonomy.v2 -string off
```

The program, the 120-subdomain atlas, and the 700-probe ceiling are in [SENTINEL-ROADWORK.md](docs/plans/sentinel/SENTINEL-ROADWORK.md). Evidence for every gate is indexed in [gates/README.md](docs/plans/sentinel/gates/README.md); SG7 records the remaining holds honestly.

### 3.5 The Mirage integration (October 2026)

Mirage is a **separately-owned companion engine** (Python) that integrates over a single spawn boundary: RT launches its sidecar on an explicit user gesture, speaks a typed NDJSON wire to it, and consumes typed outcomes. The enforcement rules, in plain English:

- **Ownership**: RT's store belongs to RT; Mirage's ledger belongs to Mirage. The only thing crossing the boundary is the analyzed-context handoff. Mirage entries in RT are born **only** from a validated import receipt — nothing is invented on either side.
- **Language**: the wire contract is immutable (`MirageWireTypes`) and version-gated; conformance test suites pin every shape.
- **Lifecycle**: one analyze gesture = one clean sidecar lifecycle (spawn → work → SIGTERM; no zombie processes, no persistence leavings).
- **Optional & safe**: a single Settings switch (`mirage.enabled`) turns the feature off entirely — which deletes nothing; disabled state spawns nothing. Spoiler-sensitive detail surfaces are disabled by design until a verified chapter→cursor mapping exists (fail-closed; typed refusal codes).
- **Packaged**: the engine ships inside the app as a digest-verifiable bundled runtime (staging script + manifest + SHA-256 checks + clean-machine gate).

The full campaign of record — playbook, ADR register (ADR-2…ADR-8, ADR-12), merge log M-014…M-034, evidence bundle, §22/TiB charter — lives in `docs/integration/` (see §6).

---

## §4 · Verified health status

Checked directly against the working tree on 2026-10-29 (V2.0 rename pass), with historical release receipts labelled:

- ✅ `xcodebuild build` (Debug and Release, default DerivedData, V2.0 scheme) → **BUILD SUCCEEDED**
- ✅ Local unit census (2026-11-07, after the V2.0 rename, the UI/reader/offline/Mirage/Sentinel tranches, the reading-analytics recalibration, and the E8 estimate-facade + behavior-SQLite tranche): **518 tests / 100 suites / 719 runs / 509 passed / 9 skipped / 0 failed**, Debug build exit 0 (`./scripts/census.sh --unit-only`, exit 0). Evidence: [Stage AH](docs/registers/03-fix-log.md) for the 464-test environment/Sentinel/console tranche, [Stage AE](docs/registers/03-fix-log.md) for the 459-test Mirage tranche, [Stage AB](docs/registers/03-fix-log.md) for the 447-test offline tranche, [Stage AA](docs/registers/03-fix-log.md) for the 441-test reader tranche, [Stage Z](docs/registers/03-fix-log.md) for the earlier 437-test tranche, and [SG8 gate](docs/plans/sentinel/gates/SG8.md) for the older 432-test baseline. The nine `ReaderAppearanceTests`, five `CommandPaletteTests`, six offline/network pins, twelve ADR-13 Mirage pins, and five environment/weather pins are part of the 518, as are the four Book File Relink tests, the one Phase Zero probe, 24 reading-analytics tests (page-duration policy, estimation provenance, page-estimation model, difficulty calibration), the two E8 estimate-facade pins, and the G6 SQLite persistence pin. The 9 skips are 4 Mirage real-engine, 1 benchmark, 2 real-library SQLite parity, and 2 live Open-Meteo. CI runs `scripts/verify-sentinel-surface.sh` before the census, so a stale surface manifest fails the run. UI tests remain placeholder launch stubs and are excluded from the deterministic unit receipt.
- ✅ E8 estimate facade and behavior SQLite (2026-11-07): every estimate surface uses one canonical pace, difficulty no longer changes page count, and behavior evidence writes through the existing SQLite tables with the JSON archive retained as a seed/mirror. Pinned by 16 focused tests (2 E8, 5 page-model, 7 provenance, 2 G6) and the full census above.
- ✅ V2.0 rename verified: app/product/display name **AsterismaV2.0**, Swift module `AsterismaV2_0`, project/targets/scheme **AsterismaV2.0**, and source folders `AsterismaV2.0/` / `AsterismaV2.0Tests/` / `AsterismaV2.0UITests/`. Debug builds and the current 518-test census ran under the new scheme. The bundle ID `johan.Reading-Tracker` and the `Application Support/Asterisma/` data root are unchanged so existing libraries survive.
- ✅ UI shell tranches (2026-10-29): a resume-first Home, a four-destination sidebar (⌘1–⌘4), a unified grid/list Library with a selected-book dock, embedded Insights/Goals, and a ⌘K Quick Open palette. The second tranche makes the Home hero and Library dock adaptive, makes Today goal-aware, and adds a Recently finished shelf. Debug build **BUILD SUCCEEDED**; the local unit census at that boundary was **441 / 671 / 432 passed / 9 skipped / 0 failed**. Owner visual acceptance is pending; the macOS screen-capture permission was denied, so no screenshot receipt exists. Design record: [UI-UX-OVERHAUL-2026-10-29.md](docs/design/UI-UX-OVERHAUL-2026-10-29.md).
- ✅ Environment, Sentinel, and console navigation (2026-10-29): the environment engine now recomputes every 10 s instead of 45 s; a 20 fps atmosphere layer drifts two ambient glows continuously; a new deterministic weather layer draws rain, heavy rain, snow, heavy snow, fog, cloud shadow, wind streaks, and a storm flash from the engine's own weather snapshot; morning/midday/afternoon palettes were deepened and the engine adds a luminance-derived readability scrim (0.04 at night, at least 0.15 in the bright-morning pin). The Sentinel Health Center is now a persistent sidebar with an always-visible band/coverage header, issue search, severity filters, a ⌘] Next issue control, and a per-pane detail header. The Developer Console sidebar groups LIVE and PLANNED panes and has its own search; the new Environment Studio renders the real background, forces any minute or weather kind, and shows provenance; the new Subsystem Explorer searches id, purpose, activity, warnings, and metrics with a full detail pane. Five environment tests pin the mapping, override store, forced state, and scrim ordering; the full unit census at that boundary was **469 / 671 / 460 passed / 9 skipped / 0 failed**. Owner visual acceptance is pending, and no screenshot was captured. Design record: [UI-UX-OVERHAUL-2026-10-29.md](docs/design/UI-UX-OVERHAUL-2026-10-29.md) §9.
- ✅ Reader customization (2026-10-29): the EPUB Appearance panel now has Paged/Scrolling mode, page turn animation, Both Margins Advance, and a 35–100% brightness dimmer; the PDF panel adds single/continuous/facing/facing+scroll layouts, fit page/width/height/actual, cover-alone, LTR/RTL page order, a 0–80 pt page gap, three mat colors, and the same brightness dimmer. Debug build **BUILD SUCCEEDED**; the reader-boundary census was green; a Chromium harness exercised 23 paged pages, 21 scrolling viewport-pages, `goToPage(3)` → `scrollY = 2160`, and the switch back to page 3 at `scrollLeft = 3840`. Owner visual acceptance and a real-book pass remain pending.
- ✅ Offline contract (2026-10-29): the local library, EPUB/PDF readers, goals, analytics, and settings have no network code. The only live network surfaces are Open-Meteo weather, Open Library and Gutendex discovery, and remote discovery cover images. Discovery now uses a bounded 10 s request / 15 s resource ephemeral session, queries both providers concurrently, and cancels both when the path drops; weather uses a 10 s request bound and runs in its own task so an offline session close cannot delay notifications or local analysis. Six new network-free tests passed; the full unit census at that boundary was **447 / 671 / 438 passed / 9 skipped / 0 failed**. A whole-suite OS-level network-denial run could not be executed because Xcode's test runner hung before connecting and a direct App-Sandboxed launch trapped; that limitation is recorded in Stage AB, not presented as a pass.
- ✅ Live library after the owner’s erase/reset and reading sessions: **1 book / 3 sessions / 77 page timings**.
- ✅ Release packaging is reproducible with `scripts/package-release.sh`; generated `dist/` output is no longer retained in the working tree (removed during the 2026-10-28 artifact cleanup). The last documented package SHA-256 remains in the handoff and fix log as a historical receipt.
- ✅ `main` contains the release merge at `aba8aa4`, the owner-accepted reader build, the preservation-first repository reorganization, the Sentinel v2 first tranche, and the SG8 surface layer; ready tag `asterisma-v1.0-ready-2026-10-26`, release tag `asterisma-v1.0-mvp`; local `.obsidian/` configuration is ignored.
- 👑 **Owner-test authority:** the owner's personal test results outrank every item above. See `docs/12-owner-test-authority.md`.

---

## §5 · Open work, in priority order

The audit-era **NEW-DE-1 … NEW-DE-8 punch list was fixed and pinned** during Bedrock (see the supersession note in `docs/registers/02-defect-register.md` and the G1/G4 gate receipts). What remains is:

| # | Item | Why it matters | Estimate |
|---|------|----------------|----------|
| 0 | **Owner acceptance — Library Recovery G6 first, then Sentinel SG7** | The G6 nine-step script on a copied library is the first gate; the ten manual Sentinel scenarios, v1 removal, and localization block SG7 after it. | One focused session each |
| 1 | **Distribution readiness** | The build is ad-hoc signed, not notarized, so first launch needs right-click → Open. Public/friend distribution needs Developer ID signing and notarization. The bundle ID is still `johan.Reading-Tracker` for MVP container compatibility; changing it needs a dedicated container migration. | Signing/account setup + migration session |
| 2 | **Swift 6 strict concurrency** | Flipping to Swift 6 produced 148 actor-isolation errors; the project stays in Swift 5 mode until those surfaces are fixed. | Multi-session arc |
| 3 | **Reader selection highlights/quotes** | Notes, tags, page anchors, and collections work; EPUB/PDF text-selection highlighting is not wired. | 1–2 sessions |
| 4 | **Collection rename UI** | Create/delete/membership work; rename has no UI. | Small |
| 5 | **Legacy artifact cleanup** | Repository graphify cache/backup, duplicate playbook, and OS metadata were removed on 2026-10-29 (102 MB → 77 MB); old P5-G `library.sqlite3`/`.migrated` app-support artifacts remain outside the repo and are not live. | App-support check |
| 6 | **Remaining dead code** | Some zero-caller fragments remain after G7's −1,157-line sweep. | 3–5 h |
| 7 | **Mirage era — standing items** | TB-M0 observation cadence; a perf-budget report; the engine-side backup-surface gap. The packaged app-embed exercise is now done (runtime embedded and signed). | Process, not code |

**Closed 2026-11-07 — Behavior evidence to SQLite:** the four existing behavior tables (`behavior_events`, `application_sessions`, `inactivity_records`, `device_state_events`) are now the live store. The JSON archive is retained only as an import seed and compatibility mirror; see Stage AR in `docs/registers/03-fix-log.md`.

CI runner alignment is complete (2026-10-26): the workflow runs on `macos-26` / Xcode 26.6. The 2026-10-29 `census` runs are green: `40813891217` on `0310c0f`, and `40815638835` on the documentation-sweep commit `737033a`.

The full defect register remains the source of truth for the F-series items; the old NEW-DE block is historical and should not be read as still open.

**Reader status:** the EPUB reader uses CSS-column pagination with one/two-page layouts, left/right page turns, exact chapter/page position persistence, cover/titlepage filtering, and compact in-content controls instead of the native toolbar. The 2026-10-29 reader pass adds the Apple Books-style Appearance panel (six themes, eleven font choices, bold, 80–200% text size, line/character/word spacing, margins, justification, hyphenation, page-turn style, optional page numbers, Both Margins Advance), a vertical Scrolling mode, and a page-only brightness dimmer. The PDF Appearance panel adds single/continuous/facing/facing+scroll layouts, fit page/width/height/actual, cover-alone, LTR/RTL page order, a 0–80 pt page gap, system/paper/slate mat colors, and the same dimmer. PDFs keep their publisher typography; font, spacing, and reflow controls are EPUB-only. The owner accepted the underlying reader workflow; visual acceptance of the expanded panels is pending. Highlights, notes, in-book search, page-curl animation, and a whole-book physical page map remain future work.

**UI shell status (2026-10-29):** the app now opens on a resume-first Home rather than a book list, and the Library is a single adaptive grid/list with a selected-book dock. The second tranche adds ⌘K Quick Open, a goal-aware Today card, a Recently finished shelf, an adaptive Home hero, and a dock that clamps to 236–292 pt; ⌘F focuses Library search. Insights and Goals are embedded destinations; discovery, reports, recommendations, achievements, history, environment/context, import/export, and erase are secondary actions in the sidebar's **More** menu. The reader was deliberately left unchanged. The next UI gate is owner visual acceptance at 900×640, 900×640 with a 300 pt sidebar, and 1200×780; a screenshot could not be captured because macOS denied the screen-capture request.

---

## §6 · Documentation map

Every deeper document has its own numbered ID and plain-English introduction. Start at any of them without guessing what a file is for:

```text
README.md                                    ← you are here
docs/
├── INDEX.md                                 One-hop lookup: question → exact file/line (start here)
├── 01-project-tree.md                       Where every file lives
├── registers/                               Living truth
│   ├── 02-defect-register.md                Everything known to be broken or risky
│   ├── 03-fix-log.md                        Everything fixed, with verification proof
│   └── 04-handoff.md                        What to do next, in order
├── roadmap/
│   ├── 05-remediation-roadmap.md            The long-term plan, phase by phase
│   └── 06-rsvp-feature-plan.md              Historical design record — RSVP SHIPPED (P5-B2)
├── method/
│   └── 07-testing-strategy.md               How tests are written and why
├── audits/
│   ├── 08-deep-audit.md                     Full independent audit (Oct 2026) — file:line evidence for every claim
│   └── 11-completion-and-health-report-2026-10-24.md  Bedrock-era completion and health snapshot
├── plans/bedrock/                           G0–G8 gate record, master plan, baseline, distribution notes
├── reorganization/                          AV1-ROR baseline, relocation ledger, and execution report
├── design/fullscreen-surface-audit.md       Fullscreen surface audit, border inventory, after capture
├── design/UX-BETA-AUDIT-2026-10-25.md       Beta UX audit, finding register, remediation phases
├── design/READER-POLISH-2026-10-25.md       Apple Books benchmark + Phase 1/2 reader customization record
├── design/UI-UX-OVERHAUL-2026-10-29.md      Weighted UI model, Home/Library shell, receipts, limits
├── 12-owner-test-authority.md               Owner results are the absolute source of truth
├── MILESTONES.md                            Pinned capability milestones, with exact timestamps
├── owner-test-results/                      Personal test sessions + template
├── REBRAND-ASTERISMA.md                     Asterisma rename + data-root migration record
├── integration/                             THE RT–MIRAGE MERGE CAMPAIGN (Oct 2026)
│   ├── RT_Mirage_Codebase_Merge_Playbook.md The governing playbook — still executes the §22/TiB era
│   ├── merge-log.md                         The campaign log of record (M-014… M-034+)
│   ├── final-acceptance-2026-10-18.md       §18 acceptance checklist with receipts
│   ├── evidence/                            §19 evidence bundle manifest + handoff bundle + receipt artifacts
│   ├── adr/                                 The ADR register (transport, packaging, stratum, identity, lifecycle, spoiler contract, repo strategy, TiB charter)
│   ├── phase1/                              Pre-ladder extraction: wire protocol, touchpoints, normative docs
│   ├── rehearsals/                          §15 rehearsal log (rollbacks, backup restore, runtime swap)
│   └── tib/                                 §22 Titanium Bridge — TB-M0 gate plan + observation ledger
└── history/
    ├── 09-final-traces.md                   Performance upgrade diary
    ├── 10-profiler-fix.md                   The freeze post-mortem
    ├── freeze.txt                           Raw 5-second `sample` capture taken during the actual freeze
    ├── diagnostics-2026-08-26.txt           Raw build output from Aug 26
    └── LAST_DEFEAT_demo_profiles.txt        The freeze hunt, told to be read by anyone
```

Campaign bookkeeping note: the root copies `merge-log.md` and `RT_Mirage_Codebase_Merge_Playbook.md` are the owner's personal kept snapshots — canonical, versioned copies live in `docs/integration/` and move forward there; the root copies are frozen at the campaign's close.

**If you are new to the project,** read `docs/INDEX.md` first when you have a specific question, then `docs/registers/04-handoff.md` — it answers what was done, why, and what comes next in order. The index is verified by `scripts/comprehension-bench.py`, which fails on a stale path or anchor.

---

## §7 · Build & run

Requires a Mac with Xcode installed.

### Run the latest working tree

```bash
./scripts/run-latest.sh
```

The runner picks the newest `AsterismaV*.xcodeproj` (V2.0 today), builds the current working tree with Xcode's default DerivedData, quits a running instance gracefully, and launches the exact bundle it just built. `--build-only` builds without launching; the log is at `~/Library/Logs/AsterismaV2.0/run-latest.log`. Use this instead of remembering a changing `xcodebuild` command or double-clicking the project and pressing Run when you need the terminal to be the source of truth.

1. **Open the project:** double-click `AsterismaV2.0.xcodeproj`
2. **Run:** ⌘R (or the Play button)
3. **Developer Console:** ⌘⇧D (Debug builds only)
4. **Settings:** ⌘, — includes the **Mirage pane** (feature switch, engine availability)

To verify from the command line:

```bash
xcodebuild build -project "AsterismaV2.0.xcodeproj" \
  -scheme "AsterismaV2.0" \
  -configuration Debug \
  -destination 'platform=macOS'

xcodebuild test -project "AsterismaV2.0.xcodeproj" \
  -scheme "AsterismaV2.0" \
  -configuration Debug \
  -destination 'platform=macOS'
```

Both should end with `BUILD SUCCEEDED` / `TEST SUCCEEDED`. Run these **before and after every change** — the suite must be green at every boundary. Canonical census numbers come from `xcrun xcresulttool get test-results summary --path <latest .xcresult>`.

Mirage real-engine development (opt-in only, never part of the default suite):

```bash
TEST_RUNNER_MIRAGE_REAL_ENGINE_DIR=/path/to/MirageV1.0 \
  xcodebuild test -project "AsterismaV2.0.xcodeproj" \
  -scheme "AsterismaV2.0" -configuration Debug \
  -destination 'platform=macOS' \
  -only-testing:"AsterismaV2.0Tests/MirageIdentityRealEngineImportTests"
```

Mirage runtime staging (required for a fresh clone; the packaged release already contains it):

```bash
./scripts/stage-mirage-runtime.sh "$PWD/.mirage-runtime"
```

This creates the gitignored `.mirage-runtime/mirage-runtime` stage (CPython + the pinned engine). Without it, the Xcode build prints a warning and builds without Mirage.

Release package:

```bash
./scripts/package-release.sh
# → dist/AsterismaV2.0-2.0-arm64.zip + .sha256
```

The package is ad-hoc signed, not notarized. First launch on another Mac requires right-click → Open. See `docs/plans/bedrock/DISTRIBUTION.md`.

### Knowledge graph (offline 2D + 3D)

`graphify-out/graph.html` is the 2D vis-network export and loads its renderer from unpkg. The 3D export is fully self-contained — no CDN, server, or network request:

```bash
open graphify-out/graph-3d-full.html
```

Rebuild it from `graphify-out/graph.json` at any time (Python standard library only):

```bash
python3 scripts/build-graph-3d.py                 # full node-level view
python3 scripts/build-graph-3d.py --check         # fail if the output is stale
```

`graph-3d-full.html` is the only 3D view; it is generated locally and gitignored. The code-refreshed graph has **9,232 nodes / 21,963 edges / 451 communities** (2026-11-07); the full-node 3D page is 9,233,880 B (8.80 MiB). Graph hashes and the documentation-refresh limitation are recorded in `docs/registers/03-fix-log.md`. `graph.html` remains the 2D community export (aggregated because the full graph exceeds the 5,000-node 2D limit). The 3D page embeds `3d-force-graph` 1.80.0 with its MIT notice; the renderer is vendored under `scripts/vendor/`, and the page template is `scripts/graph3d-template.html`. A root `.graphifyignore` keeps that minified bundle (3,371 AST nodes) out of the graph, so the counts describe project code and docs. `--check` is deterministic because the generator embeds the source and renderer hashes, not a build timestamp. The aggregated community view (`graph-3d.html`) was retired on 2026-10-29.

The 3D view orbits a full 360° in pitch and yaw (the camera flips its up vector at the poles), the arrow keys drive the same rotation, and the settled layout is cached locally, so a reopen is interactive in a few hundred milliseconds instead of replaying the force simulation.

### Testing reset

For clean test sessions, open the sidebar **More (…)** menu and choose
**Erase Library & Data…**. It requires an explicit destructive confirmation and
wipes the library, reading history, page timings, goals, achievements, notes,
collections, covers, weather/audio/behavior records, backups, caches, and
Mirage data. App preferences and window layout are kept.

Builds under Desktop/iCloud paths must use the **default DerivedData** — a custom `-derivedDataPath` there breaks code signing (BUG-003's iCloud stamp root cause; see the defect register).

---

## §8 · The fix protocol (for contributors)

Every fix in this repo's history followed the same three-step protocol, and new fixes must too:

1. **Finality** — write down exactly what you are fixing and *why this fix is the right one*, before touching code
2. **Log it** — record the entry in `docs/registers/03-fix-log.md`, with the root cause and proof of verification
3. **Pin it** — add a named regression test that proves the bug cannot return (the test name should cite the defect ID)

House rules:

- **Start at the handoff** (`docs/registers/04-handoff.md`) and pick one small item from the register — each is marked with severity, confidence, and effort
- **Baseline green first:** run the §7 commands and confirm the suite passes before editing anything
- **Commit at every boundary** — never leave a fix uncommitted for more than a day
- **During a freeze, profile first:** run `sample <pid>` before reasoning about performance (`docs/history/10-profiler-fix.md` is the proof this works)
- **Honest reverts are successes:** a fix that never reaches Finality gets reverted and documented, never shipped half-broken
- **Mirage-specific rules (from the merge playbook, standing):** never unify Mirage's store with RT's; never spawn a second sidecar lifecycle while one lives; work on `main`, one commit at a green census boundary

---

## Status

**AsterismaV2.0 is renamed, has a new reading-desk shell, and is honest about what remains.** The V1.0 release line above keeps its own receipts. The V2.0 tree has re-earned its build and census receipts; a launch receipt and a green remote run are still required before it can claim a release. The UI tranche is compiled and unit-tested, not visually accepted. The next session starts at `docs/registers/04-handoff.md` — owner visual acceptance first, then distribution hardening, reader highlights, Swift 6, or the Mirage standing cadence — baseline green first, commit at every boundary, exactly as every session before it did.
