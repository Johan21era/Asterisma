# 05 · Remediation Roadmap

## What this document is

This is the project's long-term plan, organized by phase. Think of it as the "what comes next" document, but ordered so the heaviest structural work happens first — while attention and context are freshest — and each phase after that is smaller, safer, and suited to shorter sessions.

**Who should read this:** Anyone planning future work on the project.

**Governing rule:** Every phase opens with a clean build and a full test suite (verified, not assumed) and closes the same way. Every fix gets its own "Finality" statement (why this is the right fix), one fix-log entry, and nothing more. One defect, one Finality, one log entry.

> **Status note (2026-10-24, AsterismaV1.0 release):** the Bedrock program closed the audit-era correctness punch list, moved the live store to SQLite, and shipped the Asterisma rebrand. The census at that boundary was **212/0/9**, and the release is merged at `aba8aa4` (tag `asterisma-v1.0-mvp`). The phases below remain the long-term roadmap; the Mirage-era work is governed separately by `docs/integration/` and the TB-M0 cadence. Sentinel's own 700-probe program is tracked separately in [SENTINEL-ROADWORK.md](../plans/sentinel/SENTINEL-ROADWORK.md), starting with the SG0 truth-and-guardrails gate. As of 2026-10-31, the current unit census is **515 tests / 99 suites / 719 runs / 506 passed / 9 skipped / 0 failed** after the environment/Sentinel/console pass, the Book File Relink and Phase Zero probes, the reading-analytics recalibration, and the 200-round stress evaluation (`./scripts/census.sh --unit-only`, exit 0) (the ADR-13 boundary was 459 tests / 671 runs / 450 passed / 9 skipped / 0 failed); GitHub run `40811182851` passed the older 432 tests in 88 suites before the V2.0 rename, and gate evidence is indexed in [docs/plans/sentinel/gates/README.md](../plans/sentinel/gates/README.md).

---

## How to read the ID codes

Item IDs come from the audit:
- **NA-x** = new findings from RA-002
- **F-x** = legacy register findings
- **LT-x** = live-test items
- **O-x / D-x** = open/debt register items

Feature-track work (RSVP speed reading, BCE V3 UI activation, LT-10–LT-12 polish, achievements gallery) is explicitly **out of scope** here. See **Parallel Tracks** at the bottom.

---

## What the audit established

### A. Verified-stable (trust without re-investigating)

Every claim in the existing register checked out against live code, and the suite passes fresh:

| Area | Verdict |
|---|---|
| Calendar guard (F-01), celebration redesign (F-02), entity decode (F-03), schema gates (F-04), continuation queue (F-05), fatigue analysis (F-06), monitoring idempotence (F-07) | All real in code, all pinned by running tests |
| Stage 1–4 compile/behavioral fixes, dispatch-once fix, delete-by-ID, toast FIFO, ghost-hover guard, unrepairable gate, persistence banner, observer tokens, SQLite transaction, deinit fix | All real |
| Discovery redesign, sheet dismiss affordance, entitlements, phantom-time fixes, Insights window, report/hover polish, demo profiles v1+v2 | All real |
| Environment refcount, engine wiring, Library Explorer + collection CRUD, Import Intelligence surfacing, fatigue fix | All real |

### B. Open defects this roadmap resolves

| ID | Severity | One-line statement |
|---|----------|-------------------|
| NA-1 | 🟠 High | Weather "Fix 1/2/3" block is dead code; the live engine still hardcodes confidence, uses unsorted first/last observed dates, and labels rarest genres "avoided" |
| NA-2 | 🟠 High | Goals/deadlines unreachable end-to-end: `updateGoalSet`/`addDeadline` have zero callers; dashboard points to nonexistent settings; goal achievements structurally unearnable |
| NA-3 | 🟡 Medium | Report generation races: untracked detached tasks, last-finished-wins overwrites newer selection |
| NA-4 | 🟠 Medium | Audio monitoring ships without its declared-required apple-events entitlement and usage description; Info.plist is an empty stub |
| NA-5 | 🟠 Medium | No `PrivacyInfo.xcprivacy` anywhere |
| NA-7 | 🟢 Low | Documentation-truth set: phantom `AnalyticsCache` claim; nonexistent `Session Concept 1.md` references ×2; "never reads Date()" contradicted by expiry rule |
| NA-8 | 🟢 Low | Demo persona `??` on non-optionals (`DemoDataService.swift:206,308`) |
| NA-9 | 🟢 Low | Discovery sheet lacks the dismiss affordance claimed universal |
| F-08 | 🟢 Low | `weekGoalStreak` registered, never awarded |
| F-09 | 🟢 Low | Importer shadows canonical text utilities (divergent entity handling at import time) |
| F-10 | 🟢 Low | AudioProfileStore failures print-only |
| F-11 | 🟢 Low | Validator S-3 dead `tmp` + misleading "swapped"; S-1 rule that can never fire |
| F-13 | 🟢 Low | (a) dead estimation trio · (b) expiry rule reads wall clock despite injected-clock design · (c) sqlite3_open failure ignored · (d) inverted gap-record names |

Carried unchanged (correctly logged, scheduled below or deferred): **O-6** (weather session-key design), **O-8 remainder**, **D6** (no archival/pruning), **D7** (hand-rolled SQLite — materially improved).

### C. Dead code inventory (~310 LOC, ~0.9%)

`WeatherKitService2.swift:1032–1104` fix-block (+ `coverageRatio(for:)`) · `AnnualReportArchiveView2.swift:186+` JanuaryFirstBannerView (~200 LOC, never instantiated) · `BehavioralCategory.swift` `Equatable.takeIf` + unassigned `systemPowerObserver` branch · `EstimationEngine` dead trio (`totalWeight`, instance `clamp`, `mapConfidence`) · demo fallback RHS ×2. Dispositions assigned in Phases 1/3/4.

### D. Scalability thresholds

| Volume | Effect |
|---|---|
| ~10× today's volume | Uncached whole-library analytics fan-out starts dropping frames; JSON monolith rewrite begins to stall per save burst |
| ~100× today's volume | Store rewrite dominates; analytics scans dominate launch; weather store grows unpruned |

Degradation stays graceful throughout (validator + backup + tolerant decoders hold).

### E. Preserve-list — do not "improve" these while fixing anything else

Persistence hardening cluster (backup/decoder/gate/transaction + their pins) · Documentation-truth norm (status-correction comments with history) · Defect-class-pinned test suites · DataMaturityEngine architecture · Minimal entitlement grant from LT-3a.

---

## Dependency map

```
Phase 1                          Phase 2                 Phase 3                Phase 4
─────────────────────────────    ───────────────────     ───────────────────    ──────────────
1.1 NA-1 weather (gate A)  ─┐
1.2 NA-2 goals a → b → c ───┼──►  2.1 D6 async saves ──►  3.1–3.3 readiness ──► 4.1–4.5 niche
    (1.2c F-08 needs 1.2b) ─┘     2.2 O-8 batch            + small fixes        hygiene only
                                   2.3 F-12 rebinds         (independent)        (independent)
```

Phase 2 does not depend on Phase 1's outcomes except where noted. Phase 3 items are independent leaves. Phase 4 is pure hygiene with zero behavioral risk.

---

## PHASE 1 — Structural Corrections 【XL】

*Two heavyweight items. Expect multiple sessions. Everything else in the repo is lighter than this phase.*

### 1.1 · NA-1 — Resolve the weather-fix contradiction (wire or delete)

**Decision gate FIRST (small, decides the route):** read `WeatherInsightPanel2.swift` line-by-line and determine whether report-level confidence fields are displayed anywhere. Correlation *rows* are already evidence-gated; only report-level confidence is at issue.

**Route A (wire — recommended if report confidence is user-visible):** three independent Finalities:
1. Replace `calculateAggregateConfidence` internals with real derivation (accept a `dataCoverageRatio` parameter; compute from correlation scores + coverage ratio over session IDs actually analyzed).
2. Sort sessions by timestamp before extracting `firstObserved`/`lastObserved` in `buildCorrelation` and `buildBinaryConditionCorrelation` — call the already-authored `temporalBounds(of:)`.
3. Replace `suffix(3)` rarest-genre selection with the ≤5% threshold logic from the dead `avoidedGenres(from:totalSessions:)`, then delete the dead block.

**Route B (delete — acceptable if report confidence is nowhere displayed):** Delete `WeatherKitService2.swift:1032–1104` entirely; reopen the three underlying defects in the defect register as OPEN with today's evidence.

**Either way:** no file may continue claiming bugs are fixed when they are not.

**Pin to add (Route A):** a test asserting `dataCoverageScore` reflects an injected coverage ratio rather than constant 1.0.

---

### 1.2 · NA-2 — Goals end-to-end (three sequential Finalities)

**1.2a · Settings shell.** New Window scene ("Settings", `Cmd+,`) hosting a tabbed pane; the only mandatory resident for this roadmap is the goal editor. Keep the shell generic so later customization can land without restructuring. *Finality: a reachable, closable Settings window exists with one functional pane.*

**1.2b · Goal editor wired to tested APIs.** Editor pane binds `ReadingGoalSet` fields (daily pages / daily time / annual books / weekly days) and per-book deadlines to the already-correct and already-persisted `DataStore.updateGoalSet(_:)` / `addDeadline(_:)` / `removeDeadline(bookID:)`. On save, refresh `GoalProgressViewModel` state. *Finality: a goal set in the editor persists across relaunch and changes `GoalsDashboard` cards on next open.* **Pin:** round-trip test — set goals via store API → reload store → assert statuses reflect them.

**1.2c · F-08 — Implement `weekGoalStreak` detection.** Derive "days meeting daily page target" history from `AnalyticsEngine.dailyActivity` + the now-settable `goalSet.dailyPageTarget`; award when 7 consecutive qualifying days exist; extend `detectGoalAchievements`. Depends on 1.2b. *Finality: synthetic 7-day history earns the badge exactly once; interleaved misses do not.* **Pin:** earn-once + miss-breaks pair.

**Phase exit:** build + full suite green; both new pins green; fix-log entries for 1.1 route taken and each of 1.2a/b/c.

---

## PHASE 2 — Persistence Scaling Batch 【L】

*One architectural change plus its registered companions. Narrower blast radius than Phase 1.*

### 2.1 · D6 — Move disk writes off the main actor

`DataStore` is `@MainActor`; the fix captures the books/libraryState *values*, encodes+writes inside a detached task, hops back only to set `persistenceHealth`. Debounce semantics preserved. Reuse the existing degraded-surface path for write failure — no new error channel.

*Finality: `scheduleSave()` performs zero disk I/O synchronously on the main actor; a failed write still degrades the banner exactly as today.*

**Pin:** concurrent save-storm test (20 rapid mutations → exactly one observable write cycle, health healthy at end).

### 2.2 · O-8 batch — guarded lookups + divergence checks

1. `urls(for:).first!` ×2 (`DataStore3.swift:73`, `WeatherKitService2.swift:430`): guard with a documented fallback directory (temp-dir + degraded banner).
2. Investigate-then-Finality: the registered `turnToPage` weak-store divergence claim — verify against current `SessionCoordinator.turnToPage` + readers before touching anything.
3. Duplicate-import silent no-op: decide the UX (surface "Already in library" info alert via the existing `importWarnings` channel).

### 2.3 · F-12 — rebind subscription accumulation

One-line-each Finalities: `cancellables.removeAll()` at the top of `GoalProgressViewModel.bind(to:)` and `SessionEventRouter.bind(to:)`.

**Phase exit:** suite green; save-storm pin green; O-8 items individually logged (fixed or investigated-disproven — both are valid protocol outcomes).

---

## PHASE 3 — Submission Readiness & Small Correctness 【M】

*Independent leaves. If App Store submission ever becomes imminent, pull 3.1–3.2 forward — they are small enough to do any day.*

### 3.1 · NA-5 — Privacy manifest

Create `PrivacyInfo.xcprivacy`. **Verify-then-declare, invent nothing:** enumerate accessed-API categories against Apple's current required-reason list (UserDefaults use is confirmed). Judgment call requiring verification: whether WeatherKit location transmission triggers a collected-data declaration — resolve by reading Apple's current guidance before declaring. Log the reasoning in the fix log.

### 3.2 · NA-4 — Audio automation legality

Add `com.apple.security.automation.apple-events` to `Reading Tracker.entitlements` and `NSAppleEventsUsageDescription` to Info.plist (replacing the empty stub), **or** excise the Music/Spotify AppleScript paths and document CoreAudio-presence-only detection. Recommendation: grant the entitlement; the feature is real and the header already specifies exactly what's missing.

### 3.3 · NA-3 — Report-generation race guard

Capture a monotonically increasing `generationIndex` before the detached task; on the main-actor landing, apply results only if index matches current selection; cancel-and-replace otherwise. ~10 lines. *Finality: rapid year switching always renders the newest selection's data.*

### 3.4 · Small correctness cluster (each its own Finality)

- **NA-7:** three comment-truth corrections (delete phantom `AnalyticsCache` claim; replace `Session Concept 1.md` references with real pointers; fix "never reads Date()" header OR fix behavior — fold F-13(b) here).
- **NA-8:** delete the two dead `??` fallbacks (`DemoDataService.swift:206,308`).
- **NA-9:** add `.sheetDismissAffordance()` to the Discovery presentation (after confirming `BookDiscoveryView`'s internal close control, so we're not duplicating UI).
- **F-09:** point `BookImporter`'s word-count/difficulty sampling at `SharedTextUtilities`; the canonical header then becomes true.
- **F-10:** route AudioProfileStore failures through the `PersistenceStatus` pattern (or make the documented-downgrade decision explicit in the file header).
- **F-11:** fix S-3 message + remove dead `tmp`; delete never-firing S-1 (verify pins stay green).
- **F-13(c):** check `sqlite3_open` return + schema-exec result; add `.openFailed` to `StoreError`.
- **F-13(d):** rename `precededSession/followedSession` on the dormant path (zero-caller verified).

**Phase exit:** suite green; register updated to reflect every disposition above.

---

## PHASE 4 — Niche & Hygiene 【S】

*Zero-risk sweep, suitable for a short session.*

1. **Dead code removals (product decision on one):** `Equatable.takeIf`; `systemPowerObserver` property + its unreachable removal branch; `EstimationEngine` dead trio remnants not consumed in 3.4; demo fallback residue if any survived. **Decision required:** `JanuaryFirstBannerView` — wire it (it implements a real spec'd feature) or delete it (~200 LOC). Default recommendation: delete; resurrect from git history if the January-banner feature is ever prioritized.
2. **O-6** — weather session-key design question: revisit ONLY once real multi-season snapshot data exists to inform it (deliberately deferred; do not solve speculatively).
3. **Profiling watch-item:** `SessionEventRouter.runPostSessionCascade` whole-library scan per `$books` emission — measure under Phase 2's async regime before optimizing; optimize only on evidence.
4. **Cruft:** delete `Reading Tracker/default.profraw`; confirm `.gitignore` coverage holds.
5. ~~**Folder rename:** drop the trailing space in `Reading Tracker Main /`~~ — **DONE 2026-10-24**: the worktree is now `/Users/johanrembeci/Desktop/AsterismaV1.0`.

**Phase exit:** final register pass — defect register superseded sections marked resolved with pointers to fix-log stages; handoff rewritten per Session Close-Out contract.

---

## Parallel tracks (explicitly out of scope here)

Feature work continues independently of this roadmap and should interleave AFTER Phase 1:
- ~~RSVP speed reading~~ — **SHIPPED** (P5-B2, commit `f5ec995`; the per-gesture workhorse now carries the production engine and a hare button; `06-rsvp-feature-plan.md` is its preserved design record)
- ~~BCE V3 activation with its UI~~ — **SHIPPED** in Bedrock G6: V3 report, Advanced Context window, and evidence archive are live; remaining evidence-SQLite migration is tracked in README §5.
- Achievements gallery (LT-10), star visual polish (LT-11), broader de-blocking pass (LT-12), symbol-color settings (rides Phase 1's shell) — all open
- ~~"Integrate Mirage"~~ — executed as its own campaign outside this roadmap and CLOSED (`docs/integration/`); future Mirage-era work is governed by ADR-12/TB milestones, not by this document

**Do not mix feature commits with remediation commits** — the fix log's traceability depends on it.

---

## Definition of done (repo-wide)

1. Every NA/F item above is fixed-verified-and-logged or explicitly dispositioned in the register.
2. Suite green at every phase boundary (verified runs, never assumed).
3. Fix log carries a complete entry per pass; defect register superseded sections marked; handoff answers the seven close-out questions.
4. No file in the repo asserts a wiring/fixed state that code contradicts — spot-checkable via the three known-good patterns (status-correction comments, truthful headers, pinned behaviors).
