# 02 · Defect Register

## What this document is

This is the project's master list of everything known to be broken, risky, or misleading. Think of it as the project's "to-fix" list, but organized by importance with clear explanations of what each problem means in plain English.

**Who should read this:** Anyone who wants to fix bugs, improve the app, or understand where the project stands.

**How to use it:** Find an item marked OPEN, read its plain-English summary, then look at the "What to do" section for the fix. Items are numbered so you can refer to them by number (e.g., "F-01").

> **Refresh note (2026-10-19, post-merge):** this register's F/LT/O/D/NA/NEW-DE findings were untouched by the RT–Mirage merge campaign (that campaign ran under its own issue ledger in `docs/integration/`); every F-01…F-13 row below therefore still stands as written. The integration-era cross-references and disambiguation notes live at the bottom of this file.

> **Bedrock supersession (2026-10-24):** the audit-era NEW-DE-1…NEW-DE-8 punch list is now fixed and pinned (achievements, writer ordering, crash window, cache day bucket, onboarding, spatial covers, RSVP cancellation, weather honesty). Several F-series rows were already fixed in the audit/phase-1/2 logs; this register's “Open defects” block is historical and should be read with `docs/plans/bedrock/gates/` and `03-fix-log.md`. Do not treat every F-row as still open.

> **AsterismaV1.0 release (2026-10-24):** the release candidate was accepted, merged to `main` at `aba8aa4`, tagged `asterisma-v1.0-mvp`, and pushed. The last complete merged-worktree census at that boundary was **218/0/9**. The 2026-10-25 polish work added `ReaderAppearanceTests` (**5/5**); its UI-inclusive rerun was blocked by the macOS UI-test automation bootstrap. That baseline is now historical: at the 2026-10-26 CI boundary the census was **229 tests / 10 deliberate skips / 0 failures**; the current local census is **432 tests / 671 runs / 9 skipped / 0 failed** (2026-10-29). Remaining open work is tracked in `README.md` §5 and `docs/registers/04-handoff.md`.

> **CI-001 — GitHub census runner mismatch (fixed 2026-10-26):** the workflow used `macos-14` / Xcode 15.4, which cannot open the project's objectVersion 77. The runner moved to `macos-26` / Xcode 26.6, and on 2026-11-07 to the `xcode-27` image / Xcode 27.2. A subsequent Xcode 26.6 concurrency diagnostic on the Open-Meteo safe-subscript helper was fixed by marking the subscript `nonisolated`. GitHub run `40266848038` is green: 229 tests, 10 deliberate skips, 0 failures. UI placeholders are excluded from the deterministic CI unit receipt.

> **Owner-test findings (2026-10-24):** the owner's release-package test found three real defects the green census missed: (F1) the package was signed without entitlements, so it launched unsandboxed with an empty store; (F2) the onboarding Finish button never dismissed the sheet, a dead end at the goal step; (F3) the Add Book panel rejected iBooks-style unzipped `.epub` package directories. F1–F3 are fixed and pinned in `docs/owner-test-results/2026-10-24-session-1.md`; the folder-EPUB importer has a regression test. Owner retest is the acceptance gate.

---

## How to read the severity marks

| Mark | Meaning | In plain English |
|---|---|---|
| 🔴 | Critical | Crashes the app, loses data, or silently corrupts something during normal use |
| 🟠 | High | Breaks under realistic conditions, or corrupts guarantees the app makes |
| 🟡 | Medium | Breaks under uncommon-but-real conditions, or on dormant code that is wired for future use |
| 🟢 | Low | Narrow impact; mostly correctness or documentation inconsistencies |

Each finding also has a **confidence** rating:
- **High confidence:** We traced the problem in the actual code, end to end.
- **Medium confidence:** Strong evidence, but the exact execution has not been reproduced here.

---

## Open defects — what is broken right now

### Critical (fix first)

#### F-01 · Calendar crash in Annual Reports 🔴 Critical
**Plain English:** If you use a non-Gregorian calendar on your Mac (Japanese, Hebrew, Buddhist, Islamic, etc.), opening the Annual Reports section can crash the app. The code force-unwraps a date calculation that can fail for certain calendar systems.

**What to do:** Guard both date constructions so they degrade gracefully instead of crashing. Add a test that runs the report logic against several different calendar types.

**Where:** `Features/Reports/AnnualReportData2.swift`, function `analyticsPeriod(for:)`

---

### High

#### F-02 · New Year celebration timer chain 🟠 High
**Plain English:** The New Year's celebration overlay runs whenever the app is open at midnight on January 1. Its timer chain has a flaw: if you dismiss the celebration at just the wrong moment, part of the timer sequence can keep running against a screen that is no longer visible. The feature is turned on (wired into the app), so this is a live issue.

**What to do:** Redesign the celebration sequence so one cancellation stops the whole chain in any phase; invalidate timers before creating new ones; guard against double-starting the exit sequence.

**Where:** `ReadingTrackerApp 2.swift` and `Features/Reports/NewYearTransitionMonitor.swift`

---

#### F-03 · Numeric HTML entities destroyed in text 🟠 High
**Plain English:** When the app reads text from books, special characters written as numeric codes (like `&#160;` for a non-breaking space or `&#8217;` for a curly quote) are turned into bare digits (`160`, `8217`) instead of the correct character. This corrupts displayed text, word counts, and difficulty ratings.

**What to do:** Remove the bad pre-processing step entirely — the app already has a correct decoding step that handles these entities properly. Add test cases for `&#160;` → space, `&#8217;` → `'`, `&#x2014;` → `—`.

**Where:** `Core/SharedTextUtilities.swift`, function `decodeHTMLEntities(_:)`

---

#### F-04 · State file upgrades can destroy goals and achievements 🟠 High
**Plain English:** The app stores your goals, deadlines, and earned achievements in `library-state.json`. If that file was written by an older version of the app and is opened by a newer version, the app cannot decode it, resets everything to blank, and **silently overwrites the file with nothing** — permanently losing your goals and achievements. There is no backup before this reset happens.

**What to do:** (a) Back up the state file before any reset, exactly like the book data already does. (b) Make the decoder tolerant of older files so pre-version-3 libraries can still be read.

**Where:** `Core/Book2.swift` and `Core/DataStore3.swift`

---

#### F-05 · Location request can hang forever 🟡 Medium
**Plain English:** If the app asks for your location and two requests overlap, the second request overwrites the first's "callback slot." The first request's await never finishes — the task hangs permanently without crashing or reporting an error.

**What to do:** Track each location request separately (a queue keyed per request) so every request gets exactly one resume on success or failure.

**Where:** `Features/Environment/Weather/WeatherKitService2.swift`

---

#### F-06 · Fatigue analyzer is near-tautological (dormant) 🟡 Medium
**Plain English:** A part of the "context brain" (the feature that reconstructs where and why you read) has a fatigue detector that sorts gaps by duration and then counts increases. Because the list is already sorted by duration, nearly every adjacent pair counts as an "increase," so the signal fires almost regardless of reality. This code is not currently active, but it would produce wrong results the moment it is turned on.

**What to do:** Sort chronologically instead of by duration, derive dates from gap boundaries, and add fixtures that prove chronological discrimination works.

**Where:** `Features/BehaviorContext/BehaviorContextEngine2.swift`

---

#### F-07 · Observer double-registration 🟡 Medium
**Plain English:** When the app starts, two different startup paths can both register system observers (for app activate/deactivate, sleep/wake, etc.). If both fire before any stop, the observers exist twice for the life of the process, duplicating every usage record and skewing the context engine's aggregates.

**What to do:** Guard all registration paths behind an "already monitoring" flag so redundant starts are no-ops.

**Where:** `Features/BehaviorContext/BehavioralCategory.swift` and `ReadingTrackerApp 2.swift`

---

### Low

#### F-08 · "Goal Week" badge can never be earned 🟢 Low
**Plain English:** A badge for meeting your daily page goal seven days in a row is defined and visible, but no code path ever awards it. Users can see an unearnable badge slot.

**What to do:** Implement detection (7 consecutive days meeting the daily target) or remove the definition.

**Where:** `Features/Achievements/AchievementEngine2.swift`

---

#### F-09 · Inconsistent text processing at import 🟢 Low
**Plain English:** The book importer has its own private copy of text-processing functions instead of using the shared, canonical ones. This means import-time word counts and difficulty estimates use different rules than reader-time text extraction — results can disagree.

**What to do:** Point the importer at the shared functions (after F-03 is fixed), and correct the shared file's header to stop listing the importer as a caller.

**Where:** `Features/Library/BookImporter.swift` and `Core/SharedTextUtilities.swift`

---

#### F-10 · Audio profile save failures are silent 🟢 Low
**Plain English:** If saving audio metadata fails, the app only prints to the developer console — the user never sees anything. This is secondary data, so it is low severity, but it is the same silent-loss class that the persistence banner was invented to prevent.

**What to do:** Route failures through the persistence status pattern, or explicitly document the downgrade.

**Where:** `Features/Audio/AudioTrackerMetadata2.swift`

---

#### F-11 · Validator cosmetic and logic defects 🟢 Low
**Plain English:** The data validator has a rule (S-3) that declares an unused variable and logs "swapped" while actually clamping; another rule (S-1) checks a condition that can never exist. No functional harm, but misleading repair reports cost future debugging time.

**What to do:** Correct the message, remove the dead variable, delete or repurpose the dead rule.

**Where:** `Core/DataIntegrityValidator.swift`

---

#### F-12 · Repeated subscriptions pile up 🟢 Low
**Plain English:** Closing and reopening app windows adds new subscription sinks without cancelling old ones. The effect is redundant refresh work and slow growth, not duplicated notifications.

**What to do:** Cancel previous subscriptions at the top of each bind function (`cancellables.removeAll()`).

**Where:** `Features/Goals/ReadingGoalManager2.swift` and `Features/Sessions/SessionEventRouter2.swift`

---

#### F-13 · Dead and misleading fragments 🟢 Low
**Plain English:** A bundle of small hygiene issues:
- (a) Unused computations in the estimation engine (`totalWeight`, an instance `clamp`, `mapConfidence`)
- (b) The maturity engine's expiry rule reads wall-clock time instead of its injected test clock — breaks deterministic testing
- (c) The weather store ignores database open failures — degradation works, but you cannot tell why
- (d) Two gap-record names are inverted relative to their semantics

**What to do:** Remove unused code, fix the clock injection, check the database open return value, and rename the inverted records.

**Where:** Multiple files — see the full audit at `docs/audits/08-deep-audit.md`

---

## Documentation vs reality (status corrections)

| What the docs/logs claim | What the code actually shows | Disposition |
|---|---|---|
| New Year celebration is "unwired/latent" | It is wired at the app root; the F-02 defect is live | Corrected — treat as OPEN-live |
| Test header says "16/16 pass" | Close-out records show 27/27 (16 weather + 12 reliability) | Header drift — update when logs are next touched |
| `SharedTextUtilities` header lists BookImporter as a caller | BookImporter shadows with its own divergent copy (F-09) | Corrected by this audit |
| Old audit said severity "High (once wired)" | Now wired → effective severity High-live (F-02) | Promoted by this audit |

---

## Testing posture

### What exists and is trusted
- The test target is real and synchronized; `ReliabilityTests` maps onto the risk table and every test names its defect class.
- `WeatherTests` carries converted suites including an idempotent-save pin.
- **Honest caveat:** This audit did not re-execute the suite. "28 passing" is carried from the close-out record; the first action of any future fix session should be a baseline build and test before touching code.

### Remaining coverage gaps, in priority order
1. **Non-Gregorian Calendar parameterized matrix** — pins the 13 fixed calendar sites *and* F-01. Highest-value missing test in the repo.
2. **Achievement-toast FIFO concurrency pin** — the fix is live and subtle; it has no test.
3. **Numeric-entity decoding fixtures** — trivial to write, prevents F-03 from recurring.
4. **Persistence-banner UI-layer assertion** — pinned indirectly but no UI test exists; acceptable to defer until UI tests exist.
5. **New Year celebration chain under a controllable scheduler** — blocked behind F-02's redesign.
6. **F-04 legacy-JSON decode acceptance** — once the decoding strategy is decided.

---

## Unwired / dormant systems (Part-12 planning input)

Verified as unreachable from the running app today:

| System | State |
|---|---|
| Environment Engine + stars/weather visuals | Complete and self-consistent; unwired |
| Spatial Library (three-tier adaptive layout) | Complete, unwired |
| Progressive Filtering types | Model layer shipped; filter UI unwired |
| Import Intelligence layer | ~250 lines, zero callers — decide surface-or-delete at wiring time |
| BehaviorContextEngine Phase-2 | Gated but uncalled; contains rough edges — harden before activation |
| BehavioralCategory support infrastructure | Speculative scaffolding, mostly zero callers |

---

## Integration-era cross-references (added 2026-10-19, post-merge)

**ID-space disambiguation — important:** this register's audit-era IDs (`NEW-DE-1 … NEW-DE-8`) are the *October audit punch list* (§5 of the README carries it). The merge campaign's own issue ledger ALSO used `NEW-DE` IDs for merge-discrepancy findings (e.g. its `NEW-DE-5` = import-independence discharge, closed by `ADR-6a`). Same prefix, different ledgers — check the document before searching.

| Campaign ID | One-liner | Disposition & pointer |
|---|---|---|
| BUG-001 | The manifest-read failure receipted by the repro bundle | Fixed & fully receipted during the PR-4 stripe (`docs/integration/PR4-defect-analysis-2026-10-18.md`, postscript §R0–§R5). The 104 MB repro `.xcresult` was **retired by the owner on 2026-10-18** (bookkeeping-folder deletion); its companion `BUG-001-LogStoreManifest-2026-10-18.plist` survives in `docs/integration/evidence/`. |
| BUG-003 | Code-signing corruption from iCloud stamps on custom derived-data paths | Root-caused (`com.apple.fileprovider.fpfs#P`); standing discipline = default DerivedData on Desktop/iCloud checkouts, documented in README §7 and `07-testing-strategy.md`. |
| BUG / NEW-DE (merge ledger) | All other campaign-discrepancy rows, their defeats, and discharges | The campaign of record is `docs/integration/merge-log.md` (M-014…) with the PR-4 analysis — do not duplicate their contents here. |

**Mirage-era standing constraints that touch this register's future work** (from the merge playbook, unchanged):
- Never unify Mirage's store with RT's; the `Features/Mirage/` band is Mirage-owned outside RT's defect ledger.
- One sidecar lifecycle per gesture; the census receipts (M-014…M-028) are the enforcement evidence.
- The old rectify table row "test header says 16/16" is historical — the current census is **432 tests / 671 runs / 9 skipped / 0 failed** locally; the 2026-10-26 CI boundary was **229 tests / 10 deliberate skips / 0 failures** (see `07-testing-strategy.md`).

---

## Recommended order for the next fix session

1. **Baseline:** `xcodebuild build` + `xcodebuild test` (confirm green before touching anything).
2. **Commit protection** for the working tree.
3. **F-01** — Critical calendar crash (smallest blast radius, immediate user-facing class).
4. **F-03** — Entity destruction (small, high-leverage correctness fix + fixtures).
5. **F-02** — New Year chain redesign + status correction.
6. **F-04** — State-file backup gate first (one Finality); decoding strategy decision second.
7. **F-07** — Idempotence extension (cheap, closes evidence-duplication class).
8. **F-05 through F-13** in severity order as capacity allows.

---

## Related documents

- `docs/registers/03-fix-log.md` — Everything that has been fixed, with proof
- `docs/registers/04-handoff.md` — What to do next, in order
- `docs/audits/08-deep-audit.md` — The full independent audit (Oct 2026)
