# Sentinel Roadwork

**Program:** Sentinel 1000 — make Asterisma's watchdog a thousand times stronger, smarter, and easier to use.

**Status:** FIRST TRANCHE IMPLEMENTED (2026-10-28), awaiting owner acceptance. Gate evidence is indexed in [gates/README.md](gates/README.md). This document remains the program plan and the 700-probe ceiling; the shipped tranche is 140 probes / 15 domains / 25 repairs (SG7's 138 plus SQL-016 and SELF-011 from SG8). SG8 also adds the source-derived surface inventory; see [gate SG8](gates/SG8.md).

**Date:** 2026-10-26 (plan); execution receipt 2026-10-28.

**Baseline:** `main` at `6099e4e` for the tranche. Post-SG8 local census: **432 tests / 671 runs, 9 skipped, 0 failed** (`./scripts/census.sh --unit-only`, macOS 26.6.1). Release builds with exit 0; test isolation is byte-identical. The SG7 receipt records the criteria that remain unmet (v1 removal, localization, manual owner scenarios); SG8 adds structural surface coverage but does not close them.

**Scope of this document:** the complete Sentinel program — product definition, as-is audit, target architecture, probe and repair catalogs, user experience, safety doctrine, testing, scheduling, rollout phases, gates, and success metrics. It is intentionally larger than a normal roadmap. Sentinel is the only subsystem whose failure is invisible, so its plan has to be unusually explicit.

**Relationship to existing doctrine:** this document *appends to* P6's security doctrine S1–S7 (`SentinelEngine.swift` header), the Bedrock master plan, and the audit/fix registers. It does not replace them. Where the current implementation violates its own doctrine, that is recorded as a defect, not quietly redefined.

**How to use it:** read §0–§4 for the argument, §5–§7 for the design, §8–§10 for the work, §11–§15 for the execution and gates. Every proposed component, probe, and repair has a stable ID so future sessions can cite it without re-litigating the whole plan.

---

## 0. The brief

Sentinel today is a **deterministic smoke alarm with a small mop**. It wakes on launch and every 15 minutes, reads a narrow in-memory snapshot, runs eight read-only checks, fixes four kinds of damage through existing APIs, and appends findings to a JSONL journal. Its security instincts are excellent. Its coverage, memory, verification, and user surface are not.

Sentinel 1000 turns it into an **immune system**:

1. **It sees the whole body, not just the skin.** Every store the app owns — SQLite, JSON artifacts, covers, backups, weather, audio, behavior evidence, Mirage's stratum, settings, and Sentinel itself — becomes a first-class probe domain.
2. **It diagnoses instead of listing.** Findings become stable, deduplicated *issues* with evidence, confidence, impact, root-cause grouping, and a lifecycle that survives relaunch.
3. **It proves its work.** Every mutation is planned, snapshotted, applied through an audited API, verified by re-running the same probe, and reversible with one click.
4. **It talks like a person.** Release users get a real Health Center: what happened, why it matters, what Sentinel did, what they can do, and what happens if they do nothing.
5. **It stays quiet.** No alarm fatigue, no duplicate findings every 15 minutes, no false "needs you" for something already fixed, no notification for information that is not actionable.
6. **It costs almost nothing.** Tiered cadence, incremental scans, strict time budgets, no main-thread I/O, and an honest "not checked" state when a probe could not run.

The target is not "more alerts." The target is **fewer, truer, more useful signals, backed by stronger guarantees**.

### The 1000× equation

The owner's three words map onto three independent leaps. The 1000× equation is the floor, not the ceiling: the current targets are 700+ probes, 120 domains, 350+ repair plans, and 1000+ rule codes.

| Axis | From | To | The leap |
|---|---|---|---|
| **Better** (judgment) | 12 rule codes, binary severity, no memory | 1000+ rule codes, evidence graphs, confidence × impact, issue lifecycle, root-cause grouping, trend detection | Rules become diagnoses |
| **Stronger** (coverage + guarantees) | 8 probes, 3 data domains, 4 repairable rules, best-effort fixes | 700+ probes, 120 domains, 350+ repair plans, verification, rollback, backup drills | Detection becomes a proof system |
| **Easier** (experience) | 1 Debug-only pane, 1 launch card, 3 settings | Health Center, menu bar, notifications, issue detail, history, undo, per-rule controls, plain language | A developer tool becomes a product surface |

10 × 10 × 10 = 1,000 is the minimum interpretation. The owner's current targets push each axis well past 10×. The rest of this document is how those targets are earned.

### What "done" means

Sentinel 1000 is done when all of the following are true:

- **Coverage:** every owned persistence artifact and every derived-data class has at least one probe; a machine-readable coverage report says what ran, what was skipped, and why.
- **Truth:** every finding has a stable fingerprint, an evidence list, a confidence, and an impact. No finding is created from a message string or a timestamp.
- **Repair:** no mutating repair can run without a pre-repair snapshot, a declared verification probe, and a recorded undo handle. A failed verification rolls back automatically.
- **UX:** a Release user can see current health, review open issues, understand one in plain English, fix or snooze it, and undo a repair — without opening a Debug console.
- **Quiet:** a permanently broken condition produces **one open issue**, not 96 journal entries per day. Repeated cycles update `lastSeen` and `occurrenceCount`.
- **Cost:** the launch pass stays under 50 ms of main-actor time; the deep pass runs off-main under a hard budget; no probe can block the reader.
- **Safety:** the security pins prove write confinement, snapshot-before-mutation, rollback, no user text in shareable output, and a kill switch that is actually inert.
- **Truth in docs:** README, Settings copy, and this document match the shipped behavior. No Release copy points at a surface Release does not have.

---

## 1. Why this exists now

### 1.1 The data layer changed underneath Sentinel

P6 was designed in the JSON era. It reads `dataStore.books`, which used to contain every session and every page timing in memory. After the G3C cutover, the live library is SQLite (`Application Support/Asterisma/library.grdb.sqlite3`), and the in-memory `Book` values are summaries: sessions are present, but **per-page timings are lazy** ([Book2.swift](../../../AsterismaV2.5/Core/Book2.swift) documents the cached-speed contract; `DataStore.loadFromDatabase` loads summaries only).

That single change invalidates a core Sentinel assumption:

- The orphan-session repair chooses `endTime` from the last page timing in memory. In SQLite mode that array is empty, so the repair falls back to `session.startTime` and closes the session at **start + 5 minutes** — under-counting hours of real reading.
- Validator rules S-4 and S-5 ("no active timings in a closed session", "no negative timing duration") inspect `session.pageTimes`. In SQLite mode there is nothing to inspect, so 138,459 timing rows are effectively outside Sentinel's universe.
- `IntegrityProbe` calls `DataIntegrityValidator.validate`, which *repairs copies* and reports them as repaired, but Sentinel discards those copies (`let (_, report) = ...`) and only dispatches four hand-written rules. Most validator repairs are therefore reported as stalled even though the app already knows how to fix them.

This is the single most important reason to rebuild Sentinel now. The watchdog is guarding yesterday's shape of the data.

### 1.2 The release made Sentinel a promise, not a debug toy

`README.md` tells users Sentinel "scans for data problems at launch, auto-repairs the provably-safe ones, snapshots everything before touching anything, and reports what happened while you were away." Release users can enable automatic fixes in Settings. But the only place with full findings is the Developer Console, which is **Debug-only** (`#if DEBUG` in `SentinelPaneView` and the console root). The "while you were away" headline for stalled issues says they are "waiting for you in the Console" — a place Release users cannot go.

That is not a missing feature. It is a broken promise, and it is fixed in Phase 4 of this plan.

### 1.3 The current engine cannot grow safely

The engine is a 625-line `@MainActor` singleton with synchronous probes, no per-probe isolation, no time budget, no finding identity, no post-repair verification, and no persisted issue state. Adding twenty probes to this shape would multiply main-thread work, duplicate findings, and journal volume without improving trust.

The right move is not to bolt more probes onto v1. It is to build the v2 spine first, port the existing eight probes, prove behavior in shadow mode, then expand coverage.

### 1.4 The fail-closed load change raises the stakes

The 2026-10-26 hardening makes a corrupt SQLite book or library-state row abort the load and pause ordinary saves, preserving the rows instead of overwriting them. That is the correct safety behavior, but it creates a new user state: **library visible as empty, persistence degraded, saves paused, data intact but unavailable**. Sentinel currently has no dedicated probe, no diagnosis, and no recovery path for this state. The watchdog must become the guide out of it, not just another red row.

---

## 2. What exists today (honest as-is audit)

### 2.1 Inventory

| Component | File | Current role |
|---|---|---|
| Engine | `AsterismaV2.5/Core/SentinelEngine.swift` (625 lines) | Singleton, lifecycle, cycle, repairs, journal, report card data |
| Read bridge | `AsterismaV2.5/Core/SentinelDataBridge.swift` (38 lines) | Weak `DataStore` reference + mutation-in-flight flag |
| Probes | Same file, bottom | 8 structs: integrity, persistence, writability, orphan sessions, bookmarks, disk, deadlines, achievements |
| Repairs | Engine methods | 4 repairable rules; dispatch is a single multi-book pass |
| Journal | `Application Support/Asterisma/sentinel-journal.jsonl` | Append-only JSONL, 500-line cap, cycle summary line |
| Debug UI | `Features/DeveloperConsole/SentinelPaneView.swift` | Two faces (Technical / Plain English), rule filter, run now |
| Release UI | `Features/DeveloperConsole/SentinelReportCardView.swift` | Launch card with fixed/stalled counts and a headline; dismiss only |
| Settings | `Features/Goals/SettingsRootView.swift` (`SentinelSettingsPane`) | Enable, interval, allow automatic fixes (Release only), privacy line |
| Launch wiring | `App/NewContentView.swift` | `sentinel.start()`, immediate `runCycle()`, `overnightReport()` on appear |
| Tests | `AsterismaV2.5Tests/Core/SentinelPinsTests.swift` | 6 behavior/security pins + 2 demo-swap safety pins |

### 2.2 Runtime flow today

```text
App launch / timer / "Run Probe Now"
            │
            ▼
     SentinelEngine.runCycle()  [@MainActor, synchronous]
            │
   guard enabled, not mutating, store present
            │
   load lifetime counters from journal (once)
            │
   build SentinelContext (books, state, health, AppSupport URL)
            │
   for probe in 8 probes → [SentinelFinding]   (all on main)
            │
   any detected + repairable + repairs allowed?
            │ yes
   createSafetySnapshot() ── false ──▶ mark all detected as stalled
            │ true
   dispatchRepairs()  → updateBook(...) per book → debounced save
            │
   leftovers → stalled
            │
   appendJournal(findings + cycle summary) → rotate at 500 lines
            │
   defer @Published updates one runloop turn
            │
   report card counts (last 12 h) on next launch
```

### 2.3 What is genuinely strong

1. **The doctrine is explicit and unusually good.** S1–S7 define write scope, reversibility, append-only journaling, privacy, kill switch, conservative defaults, and determinism in the file header and README.
2. **Probes are pure reads.** `SentinelProbe.run` returns findings; it does not mutate. That is the correct seam.
3. **Repairs go through `DataStore` APIs.** `updateBook` is the only mutation path today; the engine never writes model files directly.
4. **Snapshot-before-mutation is structural.** If `createSafetySnapshot()` fails, every detected finding is marked stalled and no repair runs.
5. **The kill switch is pinned inert.** `killSwitchDisablesEverything` is one of the most valuable tests in the repo.
6. **Write confinement is pinned.** `writeScopeIsConfined` asserts only `sentinel*` artifacts appear after a cycle.
7. **Determinism is a stated goal.** No network, no randomness, no LLM, no clock-dependent branching beyond age checks.
8. **The journal is human-readable and machine-readable.** JSONL plus a cycle summary is the right primitive for an audit log.
9. **The Dev Console pane already has two faces.** The plain-English idea exists; it just is not a Release surface and has no actions.
10. **The code is small enough to replace.** There is no need for a multi-quarter migration; the v2 spine can coexist behind a flag.

### 2.4 What is limiting

**Detection**
- Eight probes, three real domains (library integrity, persistence health, disk). No SQLite, backup, cover, book-file, weather, audio, behavior, Mirage, notification, or self-health coverage.
- `IntegrityProbe` reports validator issues but does not carry the validator's repaired books forward.
- Duplicate conditions: `IntegrityProbe` B-4 and `OrphanedActiveSessionProbe` both report stale sessions.
- No checks for session overlap, future timestamps, impossible page numbers, duplicate sessions, dangling references, missing book files, orphan covers, backup freshness, or backup integrity.
- No coverage record. "No findings" cannot distinguish "healthy" from "did not run".

**Judgment**
- Severity is `info/warning/critical`; there is no confidence, impact, reversibility, or stability.
- No fingerprint. Every cycle creates new UUIDs, so the same condition is a new finding forever.
- No issue lifecycle, acknowledgement, snooze, regression detection, or trend.
- `markFixed` marks only the **first** finding for a rule; if two books are repaired, the second is reported as stalled.
- Repairs are optimistic: `updateBook` may no-op for a missing id, and nothing re-checks the invariant.
- Informational conditions (`deadline-overdue`, `low-disk-space`) are conflated with pathology. The UI calls all of them "NEEDS YOU".

**Memory**
- `recentFindings` is in-memory only and resets on relaunch.
- The journal has history, but nothing replays it into open issues.
- `lifetimeAutoFixed` / `lifetimeStalled` are not lifetime: they are recomputed from the retained 500 lines, and rotation drops older cycle summaries.
- No repair record ties a mutation to a snapshot, a verification, or an undo.

**Safety**
- S1 says the engine writes only the journal and `SentinelQuarantine/`; `StoreWritabilityProbe` writes and deletes `.sentinel-write-test` at the data root.
- S4 says the journal stores counts, ids, and rule names, never user text; repair details include book titles, and validator descriptions can include chapter text.
- Journal append uses `try?` with no fsync or file lock; rotation is remove-then-move. A crash can lose the tail or the file.
- No rollback path. A pre-repair snapshot exists, but no UI or API maps it to the repair that used it.
- No quiescence guarantee beyond `isMutationInFlight`; an ordinary reading session does not set that flag.
- No post-repair verification.
- No per-repair consent or preview.

**Usability**
- Release gets a card that can only be dismissed, and a Settings toggle. No issue list, no details, no action, no history, no undo.
- The stalled headline points Release users to a Debug-only console.
- The report card's "Review" behavior is described in a comment but not implemented; only "Got it" exists.
- Settings has three controls and no "run now", last-run time, coverage, per-rule control, quiet hours, retention, export, or reset.
- Plain-English grouping collapses by `userSummary` string, so different causes with the same sentence merge, and the same cause with different counts does not.
- No menu bar presence, no notifications, no VoiceOver-specific labels, no localization, no reduced-motion consideration.
- The 9-point monospaced technical face is a developer surface, not a user surface.

**Operations**
- All probes and journal I/O run in one synchronous `@MainActor` pass.
- Launch calls `start()` (which schedules a cycle next runloop) **and** `runCycle()` immediately — two cycles per launch.
- Timer does not react to Settings changes, sleep/wake, app activation, or low-power mode.
- No reentrancy guard; manual and timer cycles can overlap.
- No timeouts, budgets, partial-failure isolation, or circuit breaker.
- No watchdog for the watchdog: a hung probe hangs the cycle with no finding.
- `probeCount` is hardcoded to 8 in the UI; it will lie the moment a probe is added.
- `isEnabled` has identical `#if DEBUG` branches (dead conditional).
- Release repair behavior cannot be exercised in Debug because `allowsRepair` returns `true` unconditionally there.

### 2.5 Doctrine drift, stated plainly

| Doctrine | What it says | What the code does | Consequence |
|---|---|---|---|
| **S1** | Writes only journal + quarantine | Writability probe creates `.sentinel-write-test` in the data root | A narrow but real violation; also no symlink/canonical-path guard |
| **S3** | Append-only, never rewritten | Rotation rewrites the retained tail via remove + move; append is unlocked and not fsynced | A crash during rotation can lose history; concurrent writers can interleave |
| **S4** | Journal stores counts/ids/rule names, never user text | `debugDetail` includes book titles; validator details can include chapter titles | User text is persisted in a file the user may share |
| **S6** | Release = monitor + report only until opt-in | True, but "report" has no Release surface beyond a dismissible card | The report cannot be acted on |
| **S7** | Deterministic, no time-dependent flakiness | Six probes call `Date()` directly; no injected clock | Staleness/deadline/disk tests are hard and time-dependent |
| **Lifetime** | Implied by the counter names | Counters come from retained journal lines, capped at 500 | Numbers silently shrink after rotation |

### 2.6 The SQLite blind spot, in detail

This deserves its own section because it changes what "repair" means.

**What loads in SQLite mode:** `DataStore.loadFromDatabase` calls `LibraryDatabase.loadBooks()` and `loadState()`. `loadBooks` decodes the `books.payload_json` summary, which contains sessions but **no page-timing rows**. `Book.cachedSecondsPerPage` and `ReadingSession.cachedAverageSecondsPerPage` preserve analytics, but the individual timings live only in the `page_times` table.

**What the probes see:** `IntegrityProbe` validates the in-memory summaries. S-4 sees a closed session with no timings and finds nothing. S-5 sees no timings and finds nothing. `OrphanedActiveSessionProbe` sees `session.isActive` but not the last page activity.

**What the orphan repair does:**

```swift
let lastActivity = b.sessions[sIdx].pageTimes
    .compactMap { $0.endTime ?? $0.startTime }
    .max() ?? b.sessions[sIdx].startTime
let end = min(Date(), lastActivity.addingTimeInterval(300))
```

In SQLite mode the array is empty, so `lastActivity` is the session start. A 3-hour session killed by a crash is closed at **start + 5 minutes**. The analytics then lose 2 h 55 m of real reading, and Sentinel reports the repair as successful.

**What v2 must do:** probes that need timings must query the database read-only (`pageTimings(forSessionID:)` already exists), or the snapshot must carry a bounded timing index. Repairs must re-read the exact timings they rely on, not infer from summaries. This is a non-negotiable acceptance criterion for Phase 5.

### 2.7 Current defect register

Priorities: **P0** = can silently damage data or trust now; **P1** = blocks the 1000× program; **P2** = important quality/UX; **P3** = polish.

| ID | P | Defect | Evidence (as of 2026-10-26) | Impact | Phase |
|---|---|---|---|---|---|
| SENT-001 | P0 | SQLite summary mode hides page timings from probes and repairs | `DataStore.loadFromDatabase`; `Book2` summary contract; `SentinelEngine.dispatchRepairs` last-activity fallback | Under-closes crash sessions; S-4/S-5 blind to 138k rows | 5 |
| SENT-002 | P0 | Release tells users to look in a Debug-only console | `SentinelEngine.overnightReport`; `SentinelReportCardView`; `README` ("Debug builds only") | Dead end, broken trust promise | 4 |
| SENT-003 | P0 | No recovery path for the new fail-closed save-paused state | `DataStore.sqliteLoadFailure` / `blockedSQLiteSaveMessage`; only a generic `PersistenceHealthProbe` | User sees empty library and no next step | 3 |
| SENT-004 | P1 | No post-repair verification | `markFixed` flips outcome without re-probing | "Fixed" can be false | 3 |
| SENT-005 | P1 | `markFixed` marks only the first finding per rule | `firstIndex(where: rule && detected)` | Repaired items still show as needing the user | 1 |
| SENT-006 | P1 | Validator-repaired books are discarded | `IntegrityProbe` uses `let (_, report) = validate(...)` | Known-safe repairs reported as stalled | 2 |
| SENT-007 | P1 | No fingerprint or dedupe; every cycle makes new findings | `SentinelFinding.id = UUID()`; no stable key | 96 duplicate entries/day at 15 min; counters inflate | 1 |
| SENT-008 | P1 | "Lifetime" counters reset/truncate with the journal | `journalMaxEntries = 500`; rotation keeps suffix; counters re-read lines | Numbers silently shrink | 1 |
| SENT-009 | P1 | Journal append/rotation is not crash-safe | `try? handle.write`; remove + move; no fsync/lock | Tail loss, interleaving, partial JSON line | 1 |
| SENT-010 | P1 | Writability probe violates S1 write scope | `.sentinel-write-test` at data root | Doctrine drift; no canonical/symlink guard | 1 |
| SENT-011 | P1 | Journal contains user text | Repair details interpolate `book.title`; validator details include titles | Privacy/S4 violation; shared diagnostics leak | 1 |
| SENT-012 | P1 | Whole cycle runs synchronously on main | `@MainActor SentinelEngine.runCycle`; probes + journal I/O | Launch/periodic stall risk as coverage grows | 2 |
| SENT-013 | P1 | Every launch runs two cycles | `NewContentView` calls `start()` (which schedules one) and `runCycle()` | Duplicate journal entries and wasted work | 0 |
| SENT-014 | P1 | Scheduling is static and timer-only | `start()`/`stop()`, no config observers, no wake handling | Settings changes don't take effect; sleep loses cycles | 2 |
| SENT-015 | P1 | No persisted issues; `recentFindings` is ephemeral | `@Published recentFindings` only | Cannot review later, ack, snooze, or see regressions | 1 |
| SENT-016 | P1 | No user actions | Card only dismisses; pane only filters/runs | "Needs you" with nothing to do | 4 |
| SENT-017 | P1 | No repair record, undo handle, or rollback | `createSafetySnapshot` is generic; no repair ID | Snapshot exists but cannot be tied to a repair | 3 |
| SENT-018 | P1 | Backup failures are invisible | `LibraryArchiveManager` and SQLite backup `print` only | Silent loss of the safety net | 5 |
| SENT-019 | P1 | No database integrity/maintenance probes | No `integrity_check`, `foreign_key_check`, WAL, orphan-row checks | SQLite can rot undetected | 5 |
| SENT-020 | P1 | No asset/file probes | No checks for missing book files, orphan covers, duplicate file URLs | Library entries can point at nothing | 5 |
| SENT-021 | P1 | No derived-data consistency probes | No overlap, future-timestamp, page-range, duplicate-session checks | Analytics can be quietly wrong | 5 |
| SENT-022 | P1 | No weather/audio/behavior/Mirage probes | Only library + persistence + disk today | Subsystem rot is invisible | 5 |
| SENT-023 | P2 | No Sentinel self-health | Journal parse errors, rotations, overruns unmonitored | The watchdog can fail silently | 6 |
| SENT-024 | P2 | `probeCount` hardcoded to 8 | `SentinelPaneView` | UI lies when probes change | 0 |
| SENT-025 | P2 | Release repair gate untested; `isEnabled` dead conditional | `#if DEBUG` identical branches; `allowsRepair` always true in Debug | Release behavior is unproven | 1 |
| SENT-026 | P2 | Report card "Review" is not implemented | Comment says it opens the console; only "Got it" exists | Misleading affordance | 4 |
| SENT-027 | P2 | Settings are too thin | Enable/interval/repair only | No control, coverage, history, or recovery | 4 |
| SENT-028 | P2 | Plain-English face lacks why/action | Static `userSummary` only; grouping by text | Users cannot decide what to do | 4 |
| SENT-029 | P2 | Accessibility/localization gaps | 9pt monospaced UI; inline English strings | Poor VoiceOver/text-size/localization | 7 |
| SENT-030 | P2 | Dev Console has no history/dry-run/probe matrix | Pane shows only current findings | Hard to debug Sentinel itself | 6 |
| SENT-031 | P2 | `Date()` is called directly in probes | Orphan, deadline, disk, bookmark paths | Time-dependent tests; no clock injection | 2 |
| SENT-032 | P2 | Disk threshold is a hidden 200 MB constant | `DiskSpaceProbe` | No trend, no config, no test seam | 2 |
| SENT-033 | P2 | Bookmark probe resolves every bookmark every cycle | `StaleBookmarkProbe` | Security-scope/file I/O on main; grows with library | 5 |
| SENT-034 | P2 | Informational findings are treated as pathology | `deadline-overdue` is `.stalled` | Alarm fatigue; health score impossible | 1 |
| SENT-035 | P2 | Duplicate orphan findings | `IntegrityProbe` B-4 + `OrphanedActiveSessionProbe` | Double counts, double journal lines | 1 |
| SENT-036 | P2 | Deadline probe repeats forever; interpolated summary | No snooze/completion filter; `"\(count) deadlines"` | S4 inconsistency; permanent noise | 2 |
| SENT-037 | P2 | Hand-built JSON summary line | `appendJournal` string interpolation | Fragile schema; no escaping path | 1 |
| SENT-038 | P2 | No journal writer lock | FileHandle per cycle | Interleaving if two writers exist | 1 |
| SENT-039 | P2 | Bridge is a last-attach-wins singleton | `SentinelDataBridge.shared` | Tests/stores can cross-contaminate | 2 |
| SENT-040 | P2 | No store generation/provenance | Findings don't record which store snapshot they came from | Stale findings can be applied to a new library | 2 |
| SENT-041 | P2 | No diagnostics export/redaction | No bundle or copy-report path | Support is manual and leaky | 6 |
| SENT-042 | P2 | README/Settings overstate coverage | Claims timing repair that SQLite mode cannot see | Trust erosion | 0 |
| SENT-043 | P2 | Journal failure is silent | All writes `try?` | Sentinel "works" but records nothing | 1 |
| SENT-044 | P2 | No rate limiting or quiet hours | 4 cycles/hour at default | Journal churn; notification fatigue later | 2 |
| SENT-045 | P2 | Test gaps: no UI, dedupe, verify, rollback, release-mode tests | `SentinelPinsTests` covers 6 behaviors | The 1000× claims would be unproven | 7 |
| SENT-046 | P3 | Deadline/calendar semantics use `Calendar.current` | `DeadlineOverdueProbe` | Time-zone/DST edge cases | 2 |
| SENT-047 | P3 | No coverage metric | "No findings" is ambiguous | False confidence | 6 |
| SENT-048 | P3 | No reset/export controls for Sentinel state | Settings has no Sentinel maintenance | User cannot clear a bad state | 4 |

That is the honest baseline: a strong doctrine wrapped around a small, JSON-era engine, now standing in front of a SQLite app and a Release audience it was not built for.

Every ID above is traceable. **Appendix J** maps each defect to its closing gate, the probe(s) that must detect it, the repair that fixes it, and the regression pin that proves it stays closed. A defect with no probe and no pin is not scheduled; it is merely written down.

---

## 3. The product: Sentinel as an immune system

### 3.1 The three promises

Every design decision in this plan serves one of three user-facing promises:

1. **"Your library is watched."**
   Sentinel checks every store Asterisma owns, not just the one array that used to hold everything. It knows what it did not check and says so.

2. **"Sentinel does not guess when it can prove."**
   A repair is a plan with preconditions, a snapshot, an audited mutation, and a verification. If it cannot prove the invariant, it reports and waits.

3. **"You are always one click from undo."**
   Every automatic repair has a restore handle. The user can see what changed, when, and why — and put it back.

### 3.2 Jobs to be done

| Persona | Job | What Sentinel must provide |
|---|---|---|
| **Reader** | "Keep my history safe without making me think about it." | Quiet monitoring, honest all-clear, one plain sentence when something matters, one-click fix |
| **Reader (technical)** | "Show me what happened and let me decide." | Issue detail, evidence, preview, snooze, undo, history |
| **Owner/developer** | "Prove the watchdog works and never harms data." | Deterministic probes, dry-run, fixture injection, verification records, security pins |
| **Future maintainer** | "Understand the contract without reverse-engineering 600 lines." | Stable IDs, probe/repair catalogs, schemas, gates, traceability |

### 3.3 The trust equation

**Trust = competence × honesty × reversibility × quietness.**

A single zero in any term zeroes the product:

- Competence without honesty is false confidence ("all clear" when nothing ran).
- Honesty without reversibility is anxiety ("something is wrong, good luck").
- Reversibility without quietness is a nagging assistant.
- Quietness without competence is a decorative shield.

Sentinel 1000 is designed so each term is independently testable.

### 3.4 Non-goals

Sentinel will **not**:

- clean up the user's disk, optimize performance, or manage memory beyond its own footprint;
- repair third-party files or mutate book contents;
- delete books, notes, highlights, goals, achievements, or backups automatically;
- rewrite Mirage's ledger or identity map (Mirage owns that stratum; Sentinel may report only);
- use the network, an LLM, telemetry, or a remote service;
- replace Time Machine or the app's backup rotation;
- become a general macOS system monitor;
- hide problems to make the health score look good.

### 3.5 Success from the user's chair

A first-time Release user should be able to answer these five questions in under 30 seconds, without documentation:

1. Is my library okay right now?
2. What did Sentinel find?
3. What did it do about it?
4. What do I need to do, if anything?
5. How do I undo it?

Today, none of those questions has a Release answer. That is the usability gap the Health Center closes.

---

## 4. The 1000× model in detail

### 4.1 Better: rules become diagnoses

**Today:** a probe emits a flat finding with a rule name, a static sentence, and a severity. Two findings are "the same" only if a human reads them.

**Target:** every issue is a small diagnosis:

```text
Issue: A reading session has been open for 38 hours
Domain: sessions
Rule: SES-004 orphan-active-session
Subject: book 7F2A… / session C91B…
Evidence:
  - session.startTime = 2026-10-24T21:14:03Z
  - last page activity  = 2026-10-24T22:41:19Z (page_times row 38)
  - current time        = 2026-10-26T11:02:10Z
  - activeSessionID still points at this session
Confidence: 1.00 (structural, no inference)
Impact: medium (inflates session duration and streak if left open)
Reversibility: full (snapshot + undo handle)
Root cause group: crash-during-read (3 related issues)
Recommended action: close at last page activity + 5 min
Verification: SES-004 returns zero findings for this subject
```

The extra fields are not decoration. They determine whether Sentinel may auto-fix, how the issue is grouped, what the user sees, and how the fix is proven.

**The moves:**

1. **Stable identity.** Fingerprint from domain + rule + sorted subject IDs + evidence discriminator. No timestamps, messages, counts, or severity in the key.
2. **Evidence model.** Typed evidence items (timestamps, counts, paths hashed, record IDs, query results) with a safe/debug split.
3. **Confidence and impact.** Confidence describes how sure the detector is; impact describes what the user loses if it is real. They are independent.
4. **Root-cause grouping.** Correlate issues by shared subject, shared subsystem, and time window. "Low disk + backup failed + save degraded" is one cascade, not three alarms.
5. **Lifecycle.** `open → acknowledged → repairing → resolved` with `snoozed`, `regressed`, `ignored`, and `unactionable` branches. One issue persists across cycles.
6. **Trends.** First seen, last seen, occurrence count, severity trend, "new since last launch", "worse than yesterday".
7. **Verification.** A repair is not done until the detecting probe returns zero for that subject. Otherwise rollback and record a failed verification.
8. **Coverage honesty.** A clean report says how many probes ran, how many were skipped, and why. "Unknown" is a first-class state.
9. **Deterministic clock.** All age/deadline calculations use an injected `SentinelClock`.
10. **Explainability.** Every issue can render a plain-language "what/why/now/what-if" from structured fields, not from a hardcoded sentence per rule.

### 4.2 Stronger: detection becomes a proof system

**Coverage target:** 700+ probes across 120 domains (15 domain families expanded into subdomains). The number is not the goal by itself; the goal is that every persisted artifact, derived-data class, and failure mode has at least one invariant. §8 defines the first tranche; the registry is designed to scale to the full target.

**Repair target:** 350+ repair plans, each with a risk class. Only R1 (reversible normalization) is eligible for automatic execution. R2 requires a preview and a user click. R3 is never automatic.

**Guarantee target:** no mutation without:

- a fresh snapshot of the active store;
- a quiescence check (no active reading session, no in-flight mutation, no demo install);
- a pre-repair re-read of the exact records;
- an audited API call;
- a post-repair verification;
- a journal record with a restore handle;
- a rollback on any failure.

**The moves:**

1. **Every store is a source.** SQLite, JSON fallback, backups, covers, weather DB, audio profiles, behavior evidence, Mirage stratum, preferences, and Sentinel's own state.
2. **SQL-native checks.** Timing and session invariants run as indexed aggregate queries, not by materializing 138k rows on the main actor.
3. **Backup verification.** A daily drill opens the newest backup read-only in a temp directory, runs `PRAGMA integrity_check`, loads book/state counts, and records the result. A backup that cannot restore is not a backup.
4. **Filesystem checks.** Missing book files, stale bookmarks, orphan covers, duplicate file URLs, and security-scope failures.
5. **Derived-data checks.** Session overlap, duplicate sessions, future timestamps, impossible page ranges, DST/calendar anomalies, cached-speed contradictions.
6. **Subsystem checks.** Weather store freshness, audio profile sanity/retention, behavior evidence readability, Mirage identity-map readability (report only).
7. **Self-checks.** Journal parse, state-store integrity, cycle overruns, disk growth, clock skew.
8. **Fault isolation.** One probe throwing/timing out cannot abort the cycle; it becomes a `probe-failed` issue with coverage impact.
9. **Shadow mode.** The v2 engine runs beside v1 and compares findings before it is allowed to act.
10. **Regression corpus.** Every historical data bug becomes a fixture that the probe suite must catch, forever.

### 4.3 Easier: a developer tool becomes a product surface

**Today:** one Debug pane, one launch card, three settings.

**Target surfaces:**

| Surface | Default | Purpose |
|---|---|---|
| Menu bar shield | Off by default, opt-in | Ambient health, one-click Health Center |
| Launch report card | On when there is something new | "While you were away" summary, Review / Dismiss |
| Health Center window | On demand (toolbar + menu + card) | Overview, Issues, History, Checks, Settings |
| Issue detail | On demand | Explain, evidence, preview, fix, snooze, undo |
| Notifications | Off by default, opt-in | Only P1+ new issues, once per issue, quiet hours |
| Settings ▸ Sentinel | Always | Autonomy, cadence, quiet hours, retention, reset |
| Developer Console ▸ Sentinel | Debug only | Probe matrix, dry run, fixtures, raw journal |

**The moves:**

1. **Plain language first.** Every issue has a title, a one-sentence "what happened", a "why it matters", and an action. Technical detail is one disclosure away.
2. **Actions, not statuses.** Fix now, Review fix, Snooze, Dismiss, Undo, Locate book, Restore backup, Export diagnostics.
3. **One issue, one card.** Duplicate findings collapse into a single issue with `occurrenceCount`.
4. **History that survives relaunch.** A timeline of issues and repairs, not a 500-line tail.
5. **Undo visible where the fix happened.** The repair receipt says what changed and offers "Undo".
6. **Honest all-clear.** "Checked 63 things at 9:41. No issues." Not a vague "healthy".
7. **Quiet by default.** No notification for informational items. No repeated alert for an acknowledged issue.
8. **Progressive disclosure.** Reader sees one sentence; power user expands evidence; developer opens raw JSON.
9. **Accessible by construction.** Dynamic Type, VoiceOver labels, keyboard navigation, reduced motion, contrast.
10. **Localizable by construction.** Copy templates keyed by rule, not concatenated English in views.

### 4.4 Program scorecard

| Dimension | Today | Sentinel 1000 target | Multiple |
|---|---:|---:|---:|
| Probe structs | 8 | 700+ | ~87× |
| Domains covered | 3 | 120 | 40× |
| Rule codes with a stable ID | ~12 | 1000+ | ~83× |
| Repairable rule classes | 4 | 350+ | ~87× |
| Repairs with verification | 0 | 350+ | ∞ |
| Repairs with undo | 0 | 350+ | ∞ |
| Release surfaces | 2 | 7 | 3.5× |
| Issue lifecycle states | 3 outcomes | 9 states | 3× |
| Findings per persistent issue per day | ~96 | 1 | 96× less noise |
| Main-thread cycle budget | unbounded | <50 ms launch / 0 deep | bounded |
| Coverage reporting | none | per-probe, per-cycle | new |
| Tests | 8 Sentinel-specific | 400+ first tranche; 2,000+ full | 50× / 250× |

The "1000×" is the product of the three axes, not a claim that every row is 10×. The scorecard exists so the program can be judged on evidence.

### 4.5 How the four targets relate

The scorecard lists 700+ probes, 120 domains, 1000+ rule codes, and 350+ repair plans. They are not four independent counts, and they should not be "reconciled" into one another. They measure different units:

| Unit | Definition | Counts toward | Invariant |
|---|---|---|---|
| **Subdomain** | A bounded area of invariants inside a family (for example, "session page-range monotonicity") | 120 | Exactly 8 per family; named in §8.11 |
| **Probe** | One read-only check struct that can emit findings | 700+ | One owner invariant; four contract tests |
| **Rule** | One diagnosed condition with a stable ID, evidence schema, copy, and severity | 1000+ | Every rule has exactly one owner probe; no orphan rules |
| **Issue** | One diagnosable subject under one rule | not a target | Bounded by subjects, not by ambition |
| **Repair plan** | One typed mutation with preconditions, verification, and undo | 350+ | Every plan names at least one rule; no orphan plans |

Three consequences follow, and they are enforceable:

- **A probe may dispatch several rules.** A single pass over sessions can emit `SES-001`, `SES-002`, and `SES-003`; that is one probe and three rules, not a contradiction. The ratio in this plan is roughly 1.4 rules per probe.
- **A repair may serve several rules.** `REP-001` closes `SES-004` and `SES-020`; `REP-016` serves `SES-015`, `SES-016`, and `SES-017`. That is why 350+ plans can cover 1000+ rules.
- **A rule with no probe is dead, and a probe with no rule is noise.** Registry tests assert both directions: every registered rule resolves to one owner probe, and every probe declares at least one rule on every path it can emit.

### 4.6 Program prerequisites

This program does not add a platform, a service, or a dependency. It assumes only what the app already has:

| Prerequisite | State | Consequence if it changes |
|---|---|---|
| macOS 26.5+ and Xcode 27 | Declared in D-009 | Older deployment targets invalidate the API assumptions in §6 |
| Swift 6 language mode | Delivered at SG7 (D-012) | Probe protocols must be `Sendable` from the first commit, not retrofitted |
| GRDB.swift | Already in `Package.resolved` | No new database layer; probes use the existing read-only pool |
| App sandbox + security-scoped bookmarks | Shipping | File probes may read metadata; repairs may not widen scope |
| No network in probes | Constitution L7 | Weather evidence comes from the owned store, never a live fetch |
| Single local user, no sync | Product decision | Issue identity is device-local; no merge conflicts to reconcile |
| Ad-hoc signed local distribution | D-001/D-002 | Release-mode tests must run on the packaged app, not only in Xcode |

If any row changes, the affected phases reopen. A dependency added "just for Sentinel" is a stop condition, not a convenience.

---

## 5. Constitution v2

The existing S1–S7 are a strong start. V2 keeps their spirit, closes their loopholes, and makes each one enforceable by a named test.

### 5.1 The laws

| Law | Statement | Enforcement | Pin |
|---|---|---|---|
| **L1 — Local only** | Sentinel never uses the network, an LLM, telemetry, or a remote service. | No URLSession/Network imports in Sentinel sources; link-time audit. | Source scan + review |
| **L2 — Observe before act** | No mutation without a fresh snapshot, a re-read of the subject, and a declared verification. | `RepairExecutor` is the only mutation path and requires a `RepairPlan`. | `repairRequiresPlan` |
| **L3 — Least privilege** | Mutations go through audited app APIs. Sentinel writes only its own state under `Sentinel/`. | Capability-based `SentinelDataBridge`; no `FileManager` writes outside `SentinelPaths`. | `writeScope` |
| **L4 — Reversibility** | Every R1/R2 repair records a restore handle; undo is available for the retention window. | `RepairRecord.undoHandle` is non-optional for mutating plans. | `undoRestoresByteEqualState` |
| **L5 — Evidence over inference** | Every issue carries typed evidence and a confidence. | `SentinelIssue.evidence` cannot be empty for severity ≥ warning. | `issueAlwaysHasEvidence` |
| **L6 — One issue, one identity** | Fingerprint excludes time, message, count, severity. Re-detection updates, never duplicates. | `SentinelFingerprint` is the only issue key. | `sameConditionSameFingerprint` |
| **L7 — Quiet by default** | Informational findings never notify; acknowledged/snoozed issues never re-alert; max one notification per issue. | Notification policy in presenter. | `notificationBudget` |
| **L8 — Explainability** | Every user-visible issue can render what/why/now/what-if from structured fields. | Copy templates required for every rule ID. | `everyRuleHasCopy` |
| **L9 — User agency** | Preview, approve, snooze, dismiss, undo, disable per rule. | Health Center actions; no silent R2/R3. | UI tests |
| **L10 — Fail closed** | Uncertainty → report only. Missing snapshot/verification/quiescence → no mutation. | `RepairExecutor` preconditions. | `uncertainRepairDoesNothing` |
| **L11 — Bounded cost** | Each probe has a timeout and cost class; each cycle has a deadline; deep work is off-main. | Scheduler + budget. | `cycleHonorsBudget` |
| **L12 — Deterministic** | Time, filesystem, disk capacity, and database reads are injected; no randomness. | `SentinelEnvironment` protocol. | `probesAreDeterministic` |
| **L13 — Privacy by separation** | User text never enters the journal or shareable report; debug detail lives in a separate Debug-only stream. | `SentinelEvidence.safe` vs `.debug`; redactor. | `journalHasNoUserText` |
| **L14 — Honest coverage** | "Clean" requires all required probes to have run; skipped probes produce `unknown`, not healthy. | Coverage model. | `skippedProbeIsNotHealthy` |
| **L15 — Testable** | Every probe has a positive, negative, boundary, and failure fixture. | Test matrix gate. | `probeContract` |
| **L16 — Self-monitoring** | Sentinel monitors its own cycle time, journal health, state integrity, and repair failures. | SELF probes. | `sentinelCanReportItself` |

### 5.2 Autonomy levels

| Level | Name | Behavior | Default |
|---|---|---|---|
| **A0** | Off | Kill switch; engine inert; no journal writes. | — |
| **A1** | Observe | Probes run, issues recorded, no mutations. | Release initial / safe mode |
| **A2** | Assist | R1 repairs require a preview + click; R2 always require preview. | **Recommended Release default** |
| **A3** | Auto-safe | R1 repairs run automatically after snapshot + verification; R2 requires click. | Debug default |
| **A4** | Auto-all | Never offered. R2/R3 never automatic. | Forbidden |

The current `sentinel.allowRepair` boolean becomes an autonomy level with migration:
`false → A1`, `true → A3`, absent → A2 in Release / A3 in Debug.

### 5.3 Risk classes

| Class | Definition | Examples | Autonomy |
|---|---|---|---|
| **R0** | Read-only diagnosis | Low disk, stale bookmark, coverage gap | Report only |
| **R1** | Reversible normalization of derived/duplicated state | Dedupe collection IDs, pin negative timing, close orphan timings | Auto-safe eligible |
| **R2** | User-visible state change or file operation | Relink a moved book, quarantine orphan cover, prune old profiles | Assist only |
| **R3** | Destructive/irreversible or recovery-level | Restore a backup, delete a book, merge duplicate books, rewrite DB payload | Explicit confirmation only; never automatic |

### 5.4 The repair contract

Every mutating repair must satisfy this sequence:

```text
1. DETECT     probe reports issue with fingerprint + evidence
2. RE-READ    executor loads the exact subject(s) again
3. PRECONDITION  store generation unchanged; no active session; no mutation in flight
4. SNAPSHOT   consistent backup of the active store; verify it opens
5. PLAN       typed plan: rule, subjects, expected before/after, API calls, risk class
6. APPLY      through audited APIs only; one logical transaction where possible
7. VERIFY     re-run the detecting probe for the same fingerprint; must be zero
8. COMMIT     write RepairRecord with before/after hashes + undo handle
9. PUBLISH    update issue lifecycle; notify only if policy allows
10. RETAIN    snapshot kept for undo window; then normal backup rotation
```

Failure at any step after 4 triggers rollback (step 6 partial) and records a `repair-failed` issue. Failure before 4 records `repair-skipped` with a reason. Neither is silent.

### 5.5 What must never be automatic

- Deleting any book, note, highlight, goal, deadline, achievement, or backup.
- Moving or deleting user files.
- Rewriting `library.grdb.sqlite3` payloads.
- Importing an archive or restoring a backup.
- Changing Mirage's identity map or ledger.
- Merging two books or resolving duplicate book IDs.
- Clearing a user's collections or goals.
- Anything whose verification cannot be expressed as a probe.

---

## 6. Target architecture

### 6.1 Shape

```text
┌─────────────────────────────────────────────────────────────────────┐
│ Presentation (SwiftUI)                                              │
│  HealthCenterView · IssueDetailView · ReportCard · MenuBarExtra     │
│  SettingsPane · SentinelViewModel (observes, never probes)          │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ published state
┌──────────────────────────────▼──────────────────────────────────────┐
│ SentinelRuntime (actor)                                            │
│  Scheduler · CycleCoordinator · Budget · Clock · Configuration      │
│  IssueStore · Journal · HealthModel · Presenter · Notifier          │
└───────┬──────────────────────┬──────────────────────┬───────────────┘
        │ snapshot             │ probes               │ repairs
┌───────▼─────────┐   ┌────────▼────────┐   ┌─────────▼──────────────┐
│ Source adapters │   │ Probe registry  │   │ Repair registry        │
│ DataStore       │   │ LIB · SES · SQL │   │ Plan · Preview · Apply │
│ LibraryDatabase │   │ BAK · FILE · WX │   │ Verify · Rollback      │
│ CoverStore      │   │ AUD · BHV · MIR │   └─────────┬──────────────┘
│ Backups         │   │ APP · SELF      │             │
│ Weather/Audio   │   └─────────────────┘             │
│ Behavior/Mirage │                                   │
└─────────────────┘                                   │
        │                                             │
┌───────▼─────────────────────────────────────────────▼───────────────┐
│ Sentinel domain (pure, testable, no I/O)                            │
│  Issue · Evidence · Fingerprint · Severity · Confidence · Impact     │
│  Lifecycle · Copy templates · Health score · Coverage               │
└─────────────────────────────────────────────────────────────────────┘
```

### 6.2 Layer rules

1. **Domain has no I/O and no SwiftUI.** Pure structs and functions. This is where fingerprints, lifecycle transitions, scoring, grouping, and copy selection live. It is the most heavily tested layer.
2. **Runtime owns time, scheduling, persistence, and mutation.** One actor, one serial executor. It never touches SwiftUI directly; it publishes snapshots.
3. **Sources are read-only adapters.** They expose typed snapshot data and SQL queries. They do not mutate.
4. **Repairs are the only mutation path.** They call audited app APIs. They do not write files or models directly.
5. **Presentation is a view model + views.** It reads published issues, health, and coverage. It never runs a probe or touches a store.

### 6.3 Proposed files

| File | Layer | Responsibility |
|---|---|---|
| `SentinelDomain/Issue.swift` | Domain | Issue, lifecycle, evidence, confidence, impact |
| `SentinelDomain/Fingerprint.swift` | Domain | Stable identity algorithm |
| `SentinelDomain/HealthModel.swift` | Domain | Domain scores, coverage, bands |
| `SentinelDomain/Copy.swift` | Domain | Rule → localized what/why/now/what-if |
| `SentinelDomain/Rules.swift` | Domain | Rule registry with IDs, domains, severities |
| `SentinelRuntime/SentinelRuntime.swift` | Runtime | Actor, cycle orchestration |
| `SentinelRuntime/Scheduler.swift` | Runtime | Launch/periodic/wake/idle cadence |
| `SentinelRuntime/CycleBudget.swift` | Runtime | Timeouts, deadlines, cancellation |
| `SentinelRuntime/IssueStore.swift` | Runtime | Persisted issues, ack/snooze, replay |
| `SentinelRuntime/JournalV2.swift` | Runtime | Safe journal, segments, checksums |
| `SentinelRuntime/RepairExecutor.swift` | Runtime | Plan/apply/verify/rollback |
| `SentinelRuntime/RepairRegistry.swift` | Runtime | Plan catalog |
| `SentinelSources/SentinelSnapshot.swift` | Sources | Immutable snapshot + generation |
| `SentinelSources/DataStoreSource.swift` | Sources | Books, state, health, generation |
| `SentinelSources/DatabaseSource.swift` | Sources | Read-only SQL probes |
| `SentinelSources/FileSource.swift` | Sources | Covers, book files, backups |
| `SentinelSources/SubsystemSources.swift` | Sources | Weather, audio, behavior, Mirage |
| `SentinelProbes/LibraryProbes.swift` | Probes | LIB, SES, COL, GOL |
| `SentinelProbes/StorageProbes.swift` | Probes | SQL, BAK, FILE |
| `SentinelProbes/SubsystemProbes.swift` | Probes | WX, AUD, BHV, MIR, APP |
| `SentinelProbes/SelfProbes.swift` | Probes | SELF, SEC, CAP |
| `SentinelUI/HealthCenterView.swift` | UI | Main window |
| `SentinelUI/IssueDetailView.swift` | UI | Explanation + actions |
| `SentinelUI/SentinelViewModel.swift` | UI | Observable bridge |
| `SentinelUI/SentinelSettingsPane.swift` | UI | Controls |
| `SentinelUI/SentinelReportCardView.swift` | UI | Launch card (upgraded) |

This is a proposal, not a mandate on file count. The hard boundary is **domain/runtime/sources/repairs/presentation**, not the exact folders.

### 6.4 Cycle protocol

```text
scheduler tick
  → acquire cycle lock (skip if running)
  → check autonomy + kill switch + app state
  → capture snapshot:
       dataStore.generation (epoch)
       books/last state (main actor, cheap)
       sqlite read transaction for SQL probes
       file metadata batch
  → select probes by tier and due time
  → run probes concurrently with per-probe timeout (utility QoS)
  → normalize findings → fingerprints
  → correlate → diagnoses
  → merge into IssueStore (open/update/resolve/regress)
  → compute health + coverage
  → for eligible auto repairs:
        plan → quiesce → snapshot → apply → verify → commit/rollback
  → journal safe records + repair receipts
  → publish view model snapshot
  → notify per policy
  → release cycle lock
```

### 6.5 Snapshot consistency

Sentinel must never diagnose a torn state. V2 introduces a **snapshot generation**:

- `DataStore` exposes a monotonically increasing `libraryGeneration` (the existing `analyticsEpoch` can be promoted or mirrored).
- The runtime captures books/state and the generation on the main actor, then hands copies to probes.
- If the generation changes before a repair applies, the repair is abandoned (`store-changed`) and re-planned next cycle.
- SQL probes run inside a read transaction per probe group; they never span a write.
- File probes capture an mtime/size manifest and re-check before acting.
- `SentinelDataBridge.isMutationInFlight` remains as a coarse gate but is no longer the only one.

### 6.6 Concurrency model

- `SentinelRuntime` is an `actor` (or a `nonisolated` class with an owned serial queue, matching the project's existing `PersistenceWriter` pattern).
- `SentinelSnapshot` and all evidence are `Sendable` value types.
- Probes are `nonisolated` and synchronous over the snapshot; they may perform read-only SQL through a source handle that is explicitly `Sendable`.
- SwiftUI observes a `@MainActor` view model that receives immutable `SentinelState` snapshots.
- No `Date()`, `FileManager.default`, or `UserDefaults.standard` inside probes; use `SentinelEnvironment`.
- No probe may call `DataStore` mutating APIs. Only `RepairExecutor` may.
- A probe that exceeds its timeout is cancelled and recorded as `probe-timeout`; the cycle continues.

### 6.7 Configuration

```json
{
  "schemaVersion": 2,
  "autonomy": "assist",
  "cadence": {
    "launch": true,
    "fastMinutes": 15,
    "deepMinutes": 180,
    "maintenanceHour": 3
  },
  "quietHours": { "enabled": true, "start": "22:00", "end": "08:00" },
  "notifications": { "enabled": false, "minimumSeverity": "warning" },
  "domains": {
    "library": true, "sessions": true, "storage": true,
    "backups": true, "files": true, "weather": true,
    "audio": true, "behavior": true, "mirage": true,
    "self": true
  },
  "retention": { "resolvedIssueDays": 90, "journalMegabytes": 10, "undoDays": 30 },
  "probeOverrides": { "SES-011": { "enabled": false } }
}
```

Migration from the three existing keys is explicit and tested:
- `sentinel.enabled=false` → autonomy off.
- `sentinel.allowRepair=false` → A1; `true` → A3.
- `sentinel.intervalMinutes` → `fastMinutes`.

A sibling file, `Sentinel/disabled`, is a hard stop read before scheduling and before any repair. It exists because a corrupt config must not be the only way to turn Sentinel off, and because the owner needs a way to disable it when the app will not launch. Removing it is the only way back on; it is never deleted by migration.

### 6.8 Coexistence and shadow mode

The v2 engine ships behind a build/runtime flag:

- **Shadow:** v1 remains the actor; v2 runs read-only on the same snapshot. The journal records both finding sets and a diff. No v2 repair executes.
- **Assist:** v2 is the source of truth; v1 probes are disabled; v2 repairs require user action.
- **Auto-safe:** v2 may execute R1 repairs.
- **Retire:** v1 code and journal format are removed after one release of shadow parity.

Shadow mode is how the plan avoids a big-bang rewrite. It also produces the false-positive/negative data needed to tune confidence.

### 6.9 Failure handling

| Failure | Behavior | User-visible result |
|---|---|---|
| Probe throws | Isolate; record `probe-failed`; continue | Coverage shows one skipped check |
| Probe times out | Cancel; record `probe-timeout`; back off | Coverage shows one skipped check |
| Snapshot generation changes | Abort cycle; retry next tick | Nothing (no false issue) |
| Journal unwritable | Fall back to in-memory buffer; record self-issue; retry | "Sentinel could not record its last check" |
| Issue store corrupt | Quarantine, rebuild from journal, report self-issue | History may be partial, clearly stated |
| Backup fails | Mark repair unavailable; record critical issue | "Automatic repair is paused because a backup could not be made" |
| Verification fails | Roll back; record repair-failed with evidence | "Sentinel tried to fix this and put it back" |
| App terminating | Stop scheduling; flush journal; no new repairs | — |

---

## 7. Data model and persistence

### 7.1 The issue

An issue is the durable unit of Sentinel's memory. Findings are transient observations. Issues are what the user sees, acknowledges, snoozes, fixes, and resolves.

```text
SentinelIssue
  schemaVersion       2
  id                  iss_<ULID>
  fingerprint         16 lowercase hex characters
  ruleID              SES-004
  ruleVersion         3                 // the probe generation that produced it
  rootCauseKey        sql.orphan-timing // grouping only, never identity
  domain              sessions
  titleKey            issue.ses004.title
  status              open | acknowledged | snoozed | repairing |
                      resolved | regressed | ignored | unactionable
  severity            info | warning | critical
  confidence          0.00 ... 1.00
  impact              low | medium | high
  subjects            typed references, e.g. book:UUID, session:UUID
  evidence            [SentinelEvidence]
  firstSeen           Date
  lastSeen            Date
  occurrenceCount     Int
  attemptCount        Int
  lastRepairID        UUID?
  resolvedAt          Date?
  snoozedUntil        Date?
  safeSummary         one static sentence, no user text
  debugDetail         debug-only string, never written to the safe journal
```

Rules:

- `id` is internal and may change when an issue is rebuilt from the journal. `fingerprint` is the stable identity used for dedupe, acknowledgement, snooze, and verification.
- `safeSummary` is static or template-selected from `ruleID`; it contains no titles, paths, bookmarks, app names, or counts that could identify reading content.
- `debugDetail` may contain identifiers but not user text. Titles and chapter names move to a separate debug capture that is never persisted in the journal or shareable report.
- `subjects` are typed so a repair can re-read exactly what the issue refers to. A subject is never a free-form string path.
- `confidence` is about the detector, not the impact. A low-confidence, high-impact issue is a report-only issue.
- `impact` is about what the user loses if the issue is real. It is independent of severity. A missing cover is low impact; a corrupt library row is high impact.
- `occurrenceCount` increments once per cycle in which the issue is observed. It does not increment for each record inside one issue.
- `ruleVersion` records the probe version that created or last re-evaluated the issue. It is not part of the fingerprint; it exists so a rule change can be reconciled deliberately (§7.3a.3).
- `rootCauseKey` is a registry constant shared by rules that describe the same underlying failure (for example, `sql.orphan-timing`). It is used for grouping, suggested repairs, and trends. It never enters the fingerprint, never merges two issues, and never authorizes a repair on its own.

### 7.2 Evidence

Evidence is what makes an issue explainable and verifiable. Each item is typed and split into safe and debug halves.

```text
SentinelEvidence
  kind        timestamp | count | aggregate | recordRef | invariant |
              fileRef | queryResult | coverage
  labelKey    evidence.ses004.lastActivity
  safeValue   ISO date, integer, band, boolean, or hashed identifier
  debugValue  optional detail, debug builds only
  observedAt  Date
  source      DataStore | SQLite | FileSystem | Subsystem
```

Examples:

| Kind | Safe value | Debug value | Why |
|---|---|---|---|
| `timestamp` | `2026-10-24T22:41:19Z` | row id | Proves the age claim without exposing content |
| `count` | `138459` | same | Capacity and consistency |
| `aggregate` | `max(end_time) = 22:41:19` | SQL | Proves SQL-derived repair inputs |
| `recordRef` | `book:7F2A…` | full UUID | Repair can re-read exactly |
| `invariant` | `end_time >= start_time` | none | Verification contract |
| `fileRef` | `sha256(path):9c1e…` | path in Debug only | File identity without leaking paths |
| `coverage` | `probe SES-011 skipped: timeout` | stack? no | Honest unknown state |

Evidence must not contain:

- book titles, author names, chapter titles, note text, highlight text;
- raw file paths (hash them in safe output);
- weather coordinates or precise location;
- application names from behavior capture;
- anything that cannot be rendered to the user without redaction.

The journal stores safe evidence only. A separate `debug` stream, enabled only in Debug builds, may store identifiers and paths for development. It is excluded from the diagnostics bundle by default.

### 7.3 Fingerprint

```text
fingerprint = SHA256(
    domain + "|" +
    ruleID + "|" +
    sorted(subjectKeys).joined(",") + "|" +
    stableDiscriminator
).prefix(16)
```

Rules:

- `subjectKeys` use typed prefixes (`book:`, `session:`, `collection:`, `volume:`), sorted, deduplicated.
- `stableDiscriminator` is rule-defined and must be stable across cycles. Examples: none for a record-level issue; `page:42` for a page-timing issue; `volume:hashedPath` for a disk-volume issue; `artifact:weather-db` for a subsystem issue.
- Never include `Date`, occurrence count, severity, message, title, or debug detail.
- If a rule can match multiple records in one subject (for example, three negative timings in one session), either emit one issue per record with the record id in subjects, or one issue with a stable list of record ids in the discriminator. Do not use a count.
- A fingerprint is stable across relaunch, app update, and store migration as long as the subject survives. If a book is re-imported with a new UUID, it is a new issue; the old one is resolved with reason `subject-gone`.

Examples:

| Rule | Subjects | Discriminator | Fingerprint changes when |
|---|---|---|---|
| SES-004 orphan session | `book:<id>, session:<id>` | none | Never, while both ids exist |
| SES-011 negative timing | `book:<id>, session:<id>, timing:<id>` | none | Never, while ids exist |
| FILE-001 missing book file | `book:<id>` | `file:<hashedURL>` | The recorded path changes |
| CAP-001 low disk | `volume:<hashedPath>` | none | Volume changes |
| BAK-002 backup stale | `artifact:library-db` | none | Never |
| WX-003 weather store empty | `artifact:weather-db` | none | Never |

### 7.3a Ownership, root-cause grouping, and rule versioning

This section closes the two gaps that only appear at scale. At eight probes, it is acceptable for two checks to describe the same damage. At seven hundred, it is not: duplicates inflate counts, repairs race each other, and a user sees four issues for one broken session.

#### 7.3a.1 One invariant, one owner

Every invariant has exactly one **owner probe**. Other probes may observe the same subject, but they do not open issues.

| Role | May open an issue | May attach evidence | May resolve | Example |
|---|---|---|---|---|
| **Owner** | Yes, one per subject per fingerprint | Yes | Yes, by verification | `LIB-005` phantom `activeSessionID` |
| **Contributor** | No | Yes, to the owner's issue | No | `LIB-006` multiple active sessions |
| **Corroborator** | No | Adjusts confidence only | No | `SES-020` long session without activity |

Rules:

- The registry stores `role`, `ownerProbeID`, and `rootCauseKey` per probe. A contributor without an owner is a registry error, not a silent duplicate.
- The diagnoser drops a contributor finding when its owner has no open issue. It does not synthesize an owner issue, because the contributor does not know the owner's evidence contract.
- A corroborator may raise confidence by a documented step (for example, +0.1 per independent signal, capped at 1.0). It may never promote a report-only rule to repairable.
- Ownership is decided by root cause, not by detection order. `SES-004` owns "open session past the age boundary"; `SES-020` contributes "no timing inside that session" as evidence.
- A registry test fails the build if an invariant has zero owners or more than one.

**Known overlaps, resolved now.** These exist in the shipped catalog and would otherwise double-count on day one:

| Overlap | Owner | Contributor(s) | Shared key | Resolution |
|---|---|---|---|---|
| `SES-004` / `SES-020` | `SES-004` | `SES-020` | `session.orphan` | One issue; `SES-020` adds the inactivity timestamp |
| `LIB-005` / `LIB-006` | `LIB-005` | `LIB-006` | `state.phantom-active-session` | One issue per book; both signals in evidence |
| `SES-015` / `SES-016` / `SES-017` | `SES-015` | `SES-016`, `SES-017` | `sql.orphan-timing` | One issue per orphan timing, not one per query |
| `COL-002` / `COL-003` | `COL-002` | `COL-003` | `collection.membership` | Duplicate membership owns; dangling id contributes |
| `FILE-001` / `FILE-002` / `FILE-007` | `FILE-001` | `FILE-002`, `FILE-007` | `file.missing-asset` | Missing file owns; stale bookmark and scope failure explain why |
| `GOL-005` / `GOL-006` | `GOL-005` | `GOL-006` | `goal.deadline-reference` | Missing book owns; duplicate deadline contributes |
| `SELF-001` / `SELF-002` | `SELF-001` | `SELF-002` | `self.journal` | Journal corruption owns; stale issue store contributes |
| `LIB-010` / `SES-014` | `LIB-010` | `SES-014` | `derived.cached-speed` | Book-level cache owns; session average contributes |

#### 7.3a.2 Root-cause grouping is presentation, not identity

`rootCauseKey` is a dot-namespaced registry constant. It answers one question: "which issues would a competent engineer fix together?"

| Key | Rules | Repair | Why grouped |
|---|---|---|---|
| `sql.orphan-timing` | `SES-015`, `SES-016`, `SES-017`, `SQL-002` | `REP-016` | One referential gap produces all four symptoms |
| `state.phantom-active-session` | `LIB-005`, `LIB-006`, `SES-004` | `REP-001`, `REP-002` | One stale id produces all three observations |
| `file.missing-asset` | `FILE-001`, `FILE-002`, `FILE-005` | `REP-012` | One unresolvable path |
| `derived.cached-speed` | `LIB-010`, `SES-014` | `REP-029` | One stale cache |
| `self.journal` | `SELF-001`, `SELF-002`, `SELF-006` | `REP-018`, `REP-034` | One journal/store pair |

Rules:

- Grouping changes the view and the suggested batch, never the identity. Two issues with the same key remain two fingerprints with two verification contracts.
- The Health Center may offer "Fix all in this group" only when every member is the same risk class and every plan has a verification probe. Otherwise it offers them one at a time.
- Grouping never crosses privacy classes. A `file.*` issue and a `privacy.*` issue may share a root cause in theory; they do not share a card.
- A key is assigned once per rule and is immutable within a major version. Renaming a key is a migration, not a string edit.

#### 7.3a.3 Rule versioning and mass reconciliation

Probe logic will change after it ships. The goal is that improving a check never silently rewrites the user's history, and never floods them with reopened work.

**Version rules**

- `ruleVersion` is a monotonic integer per rule, stored in the probe descriptor and copied into the issue.
- Bump it when the predicate, threshold, subjects, discriminator, evidence contract, or recommended repair changes meaningfully.
- Do not bump it for copy, documentation, formatting, logging, or a performance-only refactor.
- Every bump requires a one-line migration note in the rule's docs page: `v2: threshold 24h → 12h; 3 open issues re-evaluated`.
- The registry keeps `ruleHistory` with `from`, `to`, `change`, `fingerprintAliases`, `migrationNote`, and `test`.

**Reconciliation on launch**

`RuleReconciler` compares the shipped registry with `Sentinel/state/rule-versions.json` once per app version, before the first cycle.

| Change | Reconciliation | User-visible |
|---|---|---|
| Predicate tightened (more findings) | Re-evaluate resolved issues once against the new predicate; reopen only those still true | One summary row: "N items reopened after a check update" |
| Predicate loosened (fewer findings) | Do not auto-resolve. Re-evaluate open issues on the next cycle; resolve with reason `no-longer-detected` | None, unless an issue stays open past its stale window |
| Subjects or discriminator changed | Migrate open issues through the alias table; keep resolved issues resolved | None |
| Rule split into two | Retire the old rule; open both children; resolve the parent `superseded` | One grouped notice, not one per issue |
| Two rules merged | Winner keeps the fingerprint; loser retires `superseded`; evidence is merged, not dropped | One grouped notice |
| Rule removed | Resolve open issues `rule-retired`; keep them in history | None |
| Repair target changed | Invalidate undo handles that point at the old plan; mark them "manual undo only" | Shown on the affected repair receipts |

**Guardrails**

- A single version bump may open at most **20** issues in one cycle. Beyond that, the cycle pauses, opens one self-issue tagged `rule-update-review`, and reports the count. A human decides whether to accept the new baseline.
- A mass event produces **one** notification and **one** history row, never one per issue.
- An ignored rule stays ignored across a version bump. Only the global reset clears it.
- Reopening never resets `firstSeen`; it sets `reopenedAt` and preserves the original date. History must show that this is old damage, not new damage.
- A version bump that changes repair behavior requires a fresh fault-injection run before it can auto-repair, even if the rule was previously in the R1 set.
- The reconciler writes a `rule-version` journal record with `from`, `to`, `opened`, `reopened`, `retired`, and `suppressed`. This is the receipt that makes a mass change auditable.

**Tests**

- `RuleVersionReconciliationTests`: each row of the table above produces the stated transition.
- `MassReopenGuardrailTests`: 21+ candidates pauses, opens one self-issue, and sends one notification.
- `FingerprintAliasMigrationTests`: an alias-migrated issue keeps acknowledgement, snooze, and history.
- `OwnershipRegistryTests`: every rule has exactly one owner; every contributor names one.

### 7.4 Lifecycle

```text
                         ┌───────────────┐
        new observation  │     open      │
        ────────────────▶│               │
                         └───┬───┬───┬───┘
                             │   │   │
                 acknowledge │   │   │ ignore (rule or issue)
                             ▼   │   ▼
                    ┌──────────┐ │ ┌──────────┐
                    │acknowledge│ │ │ ignored  │
                    └────┬─────┘ │ └──────────┘
                         │       │
                    snooze│       │ repair begins
                         ▼       ▼
                    ┌────────┐  ┌───────────┐
                    │snoozed │  │ repairing │
                    └───┬────┘  └──┬────┬───┘
                        │          │    │
              time elapses│   verify│    │ verify fails
                        │          ▼    ▼
                        │     ┌────────┐ ┌──────────────┐
                        └────▶│resolved│ │ repair-failed│
                              └───┬────┘ └──────┬───────┘
                                  │             │
                       re-detected│             │ stays open
                                  ▼             ▼
                              ┌──────────┐   (open)
                              │regressed │
                              └──────────┘
```

| Transition | Actor | Condition | Journal record |
|---|---|---|---|
| `open → acknowledged` | User | "Got it" without fixing | `ack` |
| `open → snoozed` | User | Snooze 1 day / 1 week / until next launch | `snooze` |
| `open → ignored` | User | "Don't check this rule" | `ignore` |
| `open → repairing` | Runtime | Plan accepted, preconditions met | `repair-start` |
| `repairing → resolved` | Runtime | Verification returns zero for fingerprint | `repair-commit` |
| `repairing → open` | Runtime | Verification fails or rollback succeeds | `repair-failed` |
| `resolved → regressed` | Runtime | Fingerprint observed again | `regress` |
| `open → unactionable` | Runtime | Subject gone, or rule cannot apply to this store | `unactionable` |
| `snoozed → open` | Runtime | `snoozedUntil` passed and still observed | `wake` |
| `acknowledged → open` | Runtime | Severity escalates or regression | `reopen` |

State rules:

- A user acknowledgement is not a fix. It suppresses notification and moves the issue out of the "needs you" count, but the issue remains visible in history and is re-opened if severity escalates.
- A snooze must be bounded. No "forever" snooze; that is what ignore is for.
- `ignored` is per rule, with a global reset in Settings. It is not per issue, because users do not want to ignore one book's corruption while keeping the rule for others. A future per-subject ignore can be added if evidence demands it.
- `resolved` is only entered by verification or by explicit user action ("Mark resolved"). User resolution is recorded separately from repair resolution.
- `regressed` is a distinct state for one cycle, then becomes `open` with `regressedAt`. It triggers a notification even if the issue was acknowledged, because the fix did not hold.

### 7.5 Health and coverage

The health model exists to communicate, not to diagnose. It must never hide an issue or invent precision.

**Inputs:**

- open issues, weighted by severity and confidence;
- coverage: required probes that ran, were skipped, timed out, or are unavailable in this build;
- repair health: failed verifications and rollbacks in the retention window;
- persistence health from `DataStore` (degraded states override the band).

**Domain scores:** each domain gets a band from its open issues:

| Band | Meaning |
|---|---|
| `clear` | No open issues above info |
| `watch` | Info or low-impact warnings only |
| `attention` | At least one warning with impact ≥ medium |
| `critical` | Any critical issue, failed verification, or save-paused state |
| `unknown` | Required probes did not run |

**Overall band:**

1. Any critical → `critical`.
2. Any required domain `unknown` → `unknown`.
3. Any `attention` → `attention`.
4. Any `watch` → `watch`.
5. Otherwise `clear`.

The UI shows the band plus a short reason, not a fake 97/100. A numeric score can be shown in the Developer Console for trend analysis, but it is not the primary user-facing signal.

**Coverage:**

```text
CoverageReport
  cycleID
  startedAt, finishedAt
  probesPlanned, probesRan, probesSkipped, probesFailed, probesTimedOut
  domainsCovered
  skippedReasons: [probeID: reason]
  requiredMissing: [probeID]
  dataGeneration
```

The launch card and Health Center say "Checked 63 things" only when the count is true. If a required probe was skipped, the copy says "Checked 61 of 63; 2 checks could not run." That is the honesty law L14.

### 7.6 Persistence layout

All Sentinel-owned state lives under the app data root:

```text
Application Support/Asterisma/
  sentinel-journal.jsonl              legacy v1 journal (read-only after migration)
  Sentinel/
    state/
      issues.json                     atomic snapshot of open + recent issues
      coverage.json                   last cycle coverage
      config.json                     optional mirror of UserDefaults config
    journal/
      2026-10.jsonl                   safe journal, monthly segments
      debug-2026-10.jsonl             Debug builds only, never shared
    repairs/
      <repairID>.json                 plan, before/after hashes, verification, undo
    snapshots/
      <repairID>/                     pre-repair copies, outside the backup rotation
    quarantine/
      2026-10-26/
        <issueID>/                    quarantined bytes, manifest, reason
    reports/
      latest.json                     machine-readable health report
      latest.txt                      human-readable export
```

Rules:

- The existing `sentinel-journal.jsonl` is read once, migrated into `Sentinel/journal/`, and left untouched as a historical artifact. It is never appended to again.
- `Sentinel/` is the only directory Sentinel may create or write. `SentinelPaths` is the only type allowed to construct URLs under it.
- Every path is canonicalized and checked to be inside the data root before use. Symlinks are rejected for writes.
- No user text is written anywhere under `Sentinel/`, except the Debug-only journal, which is excluded from diagnostics.
- Quarantine holds bytes only after an R2 operation; R1 state repairs do not create quarantined files.

### 7.7 Journal records

The safe journal is JSONL with a versioned envelope:

```text
{ v: 2, id: <ULID>, at: <ISO8601>, kind: issue-open, safe: { ... } }
{ v: 2, id: <ULID>, at: <ISO8601>, kind: issue-update, safe: { ... } }
{ v: 2, id: <ULID>, at: <ISO8601>, kind: issue-resolve, safe: { ... } }
{ v: 2, id: <ULID>, at: <ISO8601>, kind: repair-start, safe: { ... } }
{ v: 2, id: <ULID>, at: <ISO8601>, kind: repair-commit, safe: { ... } }
{ v: 2, id: <ULID>, at: <ISO8601>, kind: repair-failed, safe: { ... } }
{ v: 2, id: <ULID>, at: <ISO8601>, kind: cycle, safe: { ... } }
{ v: 2, id: <ULID>, at: <ISO8601>, kind: coverage, safe: { ... } }
{ v: 2, id: <ULID>, at: <ISO8601>, kind: self, safe: { ... } }
```

The `cycle` record contains counts, duration, generation, and probe outcome summary. It does not contain findings; findings have their own `issue-*` records. This prevents the v1 problem where a cycle summary and every finding are mixed in one undifferentiated stream.

Envelope rules:

- One JSON object per line, no pretty printing.
- `v` is mandatory; unknown major versions are quarantined, not parsed.
- `id` is a ULID for sortability and uniqueness.
- `at` is UTC ISO8601 with milliseconds.
- Every line ends with a newline; a partial final line is ignored on replay and recorded as a self-issue.
- Optional `checksum` is a CRC32 of the canonical `safe` object; a mismatch is a self-issue, not a crash.
- The safe journal never includes `debugDetail`, book titles, chapter names, note text, paths, or precise location.

### 7.8 Repair record

Every mutating repair writes one record, even on failure:

```text
SentinelRepairRecord
  schemaVersion       2
  repairID            UUID
  issueFingerprint    16 hex
  ruleID              SES-004
  riskClass           R1 | R2 | R3
  startedAt, finishedAt
  plan                { actions: [RepairAction], expectedBefore, expectedAfter }
  snapshot            { path, sha256, bytes, createdAt, verifiedOpen: Bool }
  affectedSubjects    [subject]
  beforeHashes        [subject: hash]
  afterHashes         [subject: hash]
  verification        { probeID, result: passed | failed | skipped, evidence }
  rollback            { attempted: Bool, succeeded: Bool, reason }
  undoHandle          { repairID, snapshotPath, restoreAPI }
  userVisibleSummaryKey
```

Rules:

- `snapshot` is mandatory for any mutation. A missing snapshot means the repair is skipped, not attempted.
- `snapshot.verifiedOpen` requires opening the snapshot read-only and running `PRAGMA integrity_check` for SQLite, or decoding the JSON for the legacy store.
- `beforeHashes` and `afterHashes` are content hashes of the affected records, not whole-file hashes, so an undo can be checked precisely.
- `verification` must name the probe that can prove the invariant. If no such probe exists, the repair is R2/R3 and manual.
- `undoHandle` must be sufficient to restore the affected records without the user finding a file.
- Repair records are retained for the undo window (default 30 days), then pruned; the journal keeps the summary forever (subject to segment retention).

### 7.9 Crash safety, migration, and retention

**Atomic state writes:**

```text
write <path>.tmp
fsync file
rename <path>.tmp → <path>
fsync directory
```

Use one writer, one file lock, and a schema version. A corrupt `issues.json` is quarantined and rebuilt from the journal; the self-issue says how much history was recovered.

**Journal append:**

- Open one append handle per segment, keep it for the cycle, write all lines, `fsync`, close.
- Serialize writers with a lock file or a single runtime actor.
- Rotate by size (default 10 MB) or month, not by truncating a live file.
- Never rewrite a segment. Retention deletes whole old segments after the configured age.
- On startup, replay segments in order, ignoring a partial final line.

**Legacy migration:**

1. Read `sentinel-journal.jsonl` line by line.
2. Convert each finding/cycle line into a v2 `issue-*` or `cycle` record with `legacy: true`.
3. Do not invent fingerprints for legacy findings; create synthetic issues with `legacyID` so they are visible in history but cannot be auto-repaired.
4. Write a migration marker with source hash and counts.
5. Leave the legacy file in place, read-only, for one release; then move it to `Sentinel/legacy/` on user request.

**Retention defaults:**

| Artifact | Default | Rationale |
|---|---|---|
| Open issues | Forever | Current health must not disappear |
| Resolved issues | 90 days | Enough to see regressions |
| Journal safe segments | 12 months or 10 MB/month | Auditability without unbounded growth |
| Repair records | 30 days | Undo window |
| Quarantine | 30 days | Recoverable, then gone |
| Snapshots | Newest 10 (existing rotation) + undo-window snapshots | Avoid backup explosion |
| Debug journal | 7 days, Debug builds only | Development convenience |

## 8. Probe catalog

### 8.1 Probe contract

```text
protocol SentinelProbeV2 {
    var descriptor: SentinelProbeDescriptor { get }
    func run(snapshot: SentinelSnapshot,
             environment: SentinelEnvironment) async throws -> [RawFinding]
}

SentinelProbeDescriptor
    id              LIB-004
    domain          library
    titleKey        probe.lib004.title
    ruleVersion     3
    role            owner | contributor | corroborator
    ownerProbeID    LIB-005            // required unless role == owner
    rootCauseKey    state.page-range   // registry constant, immutable in a major version
    supersedes      [LIB-004a]         // optional, for splits and merges
    tier            T1
    timeout         250 ms
    required        true
    dependencies    [.librarySnapshot]
    introduced      Sentinel 2.0
```

Rules:

- A probe is a pure read. It may query a read-only database handle, read file metadata, or inspect a snapshot, but it must not mutate a store.
- A probe returns zero or more `RawFinding` values. It does not assign an issue id, fingerprint, or lifecycle state; the diagnoser does that.
- A probe declares its tier, timeout, and whether it is required for an "all clear" claim.
- A probe must be deterministic for the same snapshot and injected environment. No `Date()`, no random, no network.
- A probe that throws is isolated and recorded as `probe-failed`; it cannot abort the cycle.
- A probe that times out is cancelled and recorded as `probe-timeout`; it backs off exponentially on repeated timeouts.
- A probe that cannot run because a source is disabled is `skipped` with a reason, not `clean`.
- Exactly one probe owns each invariant (§7.3a.1). A contributor or corroborator emits findings marked `evidenceOnly`; the diagnoser attaches them to the owner's issue instead of opening a new one.
- `ruleVersion` is bumped for any semantic change to the predicate, threshold, subjects, discriminator, evidence, or repair binding. Copy and performance changes do not bump it. Every bump ships with a migration note.
- `rootCauseKey` is assigned from the registry namespace, never constructed at runtime, and never used as an identity key.

### 8.2 Tiers and cadence

| Tier | When | Budget | Examples |
|---|---|---|---|
| **T0 — instant** | Launch, before first paint | < 10 ms total | Persistence health, kill-switch state, save-paused latch, last cycle summary |
| **T1 — fast** | Launch + every 15 min | < 50 ms per probe | In-memory library invariants, config sanity, journal tail |
| **T2 — normal** | Launch + every 60 min, idle | < 250 ms per probe | SQL aggregates, file metadata, backup freshness |
| **T3 — deep** | Daily, idle + on demand | < 2 s per probe | Restore drill, full file inventory, behavior/audio/Mirage checks |
| **T4 — maintenance** | Weekly, explicit window | < 30 s total | Backup verification matrix, growth projections, journal compaction |

The fast cycle never runs T3/T4. The launch card is based on T0/T1 results available within 50 ms; deeper results stream into the Health Center as they finish.

### 8.3 The catalog

Severity is the default; a probe can escalate based on evidence. "Repair" lists the repair IDs from §9.

This catalog is the first tranche: **138 probe IDs** — LIB 15, SES 20, GOL 8, COL 6, SQL 15, BAK 10, FILE 12, WX 7, AUD 5, BHV 5, MIR 8, APP 8, SELF 10, SEC 4, CAP 5 — spanning all 15 domain families. The program target is **700+ probes across 120 subdomains**. §8.11 names every subdomain and assigns it to one of six coverage waves, so "wave 3" is a countable backlog rather than an adjective. New waves add probes without changing the runtime, issue model, or repair executor.

#### LIB — library graph

| ID | Check | Invariant / method | Tier | Severity | Repair |
|---|---|---|---|---|---|
| LIB-001 | Duplicate book ids | Sort ids; adjacent equality | T1 | critical | none |
| LIB-002 | Duplicate file URLs | Canonicalize path; count > 1 | T2 | warning | none |
| LIB-003 | Invalid page count | `totalPages > 0` | T1 | error | none |
| LIB-004 | Current page out of range | `0 <= currentPage < totalPages` | T1 | warning | REP-006 |
| LIB-005 | Phantom active session id | `activeSessionID` not in sessions | T1 | warning | REP-002 |
| LIB-006 | Multiple active sessions | At most one `endTime == nil` | T1 | warning | REP-001 |
| LIB-007 | Completion inconsistency | Completed but not at last page; report only | T1 | info | none |
| LIB-008 | Chapter range invalid | Start in range; end ≥ start; no overlap | T1 | info | none |
| LIB-009 | Dangling collection reference | `collectionIDs` all exist in state | T1 | warning | REP-010 |
| LIB-010 | Cached speed contradiction | Summary speed vs recomputed from available data; tolerance | T2 | info | REP-029 |
| LIB-011 | Orphan note reference | Note book id matches parent | T1 | warning | none |
| LIB-012 | Duplicate note ids | No duplicate note ids per book | T1 | warning | none |
| LIB-013 | Empty library with non-empty state | Books empty but goals/collections exist; possible failed load | T0 | critical | none |
| LIB-014 | Genre/series metadata decay | Valid enum values; no unknown raw strings | T1 | info | none |
| LIB-015 | Reading progress monotonicity | Current page not behind last completed session end without a re-read marker | T2 | info | none |

#### SES — sessions and timings

| ID | Check | Invariant / method | Tier | Severity | Repair |
|---|---|---|---|---|---|
| SES-001 | Negative session duration | `endTime >= startTime` | T1 | warning | REP-003 |
| SES-002 | Negative page range | `endPage >= startPage` | T1 | warning | REP-007 |
| SES-003 | Session page out of book range | `0 <= startPage, endPage < totalPages` | T1 | warning | REP-007 |
| SES-004 | Orphan active session | Active > 24 h (configurable) | T1/T2 | warning | REP-001 |
| SES-005 | Active timing in closed session | No `endTime == nil` timing when session closed | T2 | warning | REP-005 |
| SES-006 | Negative timing duration | `timing.endTime >= timing.startTime` | T2 | warning | REP-004 |
| SES-007 | Timing page out of range | Page in `[0, totalPages-1]` | T2 | warning | REP-004 |
| SES-008 | Timing outside session window | Timing start/end within session plus grace | T2 | warning | REP-003 |
| SES-009 | Overlapping sessions | Same book, intervals overlap beyond tolerance | T2 | info | none |
| SES-010 | Duplicate session ids | No duplicate ids across books | T1 | critical | none |
| SES-011 | Timing gap / extreme duration | Page duration > 30 min or negative gap | T2 | info | none |
| SES-012 | Future timestamps | No session/timing start > now + 5 min | T1 | warning | none |
| SES-013 | Zero-duration sessions | Start == end; likely crash artifact | T1 | info | REP-003 |
| SES-014 | Cached average contradiction | Cached average vs SQL average; tolerance | T2 | info | REP-029 |
| SES-015 | Orphan timing rows (SQL) | `page_times.session_id` has no session | T2 | critical | REP-016 |
| SES-016 | Orphan session rows (SQL) | `sessions.book_id` has no book | T2 | critical | REP-016 |
| SES-017 | Duplicate timing indices | Unique `(session_id, idx)` | T2 | warning | REP-016 |
| SES-018 | Page timing coverage | Sessions with pages but zero timings; report ratio | T2 | info | none |
| SES-019 | Clock skew | Now < newest session or now > newest + 1 year | T0 | warning | none |
| SES-020 | Long session without activity | Open session with no timing for > 2 h | T1 | info | REP-001 |

#### GOL / COL — goals, achievements, collections

| ID | Check | Invariant / method | Tier | Severity | Repair |
|---|---|---|---|---|---|
| GOL-001 | Duplicate achievement kinds | One earned record per kind | T1 | warning | REP-009 |
| GOL-002 | Unknown achievement kind | Kind exists in registry | T1 | info | none |
| GOL-003 | Achievement references missing book | Related book id exists | T1 | info | none |
| GOL-004 | Impossible goal values | Targets > 0; no negative periods | T1 | warning | none |
| GOL-005 | Deadline references missing book | Book id exists | T1 | warning | REP-011 |
| GOL-006 | Duplicate deadline per book | At most one active deadline per book | T1 | info | REP-011 |
| GOL-007 | Overdue deadline | Target date in past; informational | T1 | info | none |
| GOL-008 | Goal/achievement contradiction | Badge earned for goal not configured; report only | T2 | info | none |
| COL-001 | Duplicate collection ids | No duplicate ids | T1 | warning | none |
| COL-002 | Duplicate collection membership | `collectionIDs` unique per book | T1 | warning | REP-008 |
| COL-003 | Dangling collection id | Every id exists in state.collections | T1 | warning | REP-010 |
| COL-004 | Empty collection names | Non-empty after trim | T1 | info | none |
| COL-005 | Collection name collision | Duplicate names; report only (allowed by product) | T2 | info | none |
| COL-006 | Note ordering / timestamp inversion | `modifiedAt >= createdAt` | T1 | info | none |

#### SQL — database and normalized rows

| ID | Check | Invariant / method | Tier | Severity | Repair |
|---|---|---|---|---|---|
| SQL-001 | Integrity check | `PRAGMA integrity_check` returns `ok` | T3 | critical | none |
| SQL-002 | Foreign key check | `PRAGMA foreign_key_check` returns no rows | T3 | critical | none |
| SQL-003 | Payload vs row counts | Book/session/timing counts in payload match normalized rows | T2 | warning | none |
| SQL-004 | Duplicate normalized ids | Primary keys unique (schema should enforce) | T1 | critical | none |
| SQL-005 | WAL size / checkpoint age | WAL < threshold; checkpoint within 24 h | T2 | info | REP-015 |
| SQL-006 | Schema version | `meta.schema_version` matches expected; migrations complete | T0 | critical | none |
| SQL-007 | Unreadable rows | Decode every payload row; fail-closed load would abort | T3 | critical | none |
| SQL-008 | Library-state root | Root exists if books exist; absent only on fresh store | T1 | warning | none |
| SQL-009 | Database growth | Size trend over 7/30 days; projection | T3 | info | none |
| SQL-010 | Free pages / fragmentation | `PRAGMA freelist_count`; report only | T4 | info | none |
| SQL-011 | Timestamp bounds | No NaN/infinite epoch values | T1 | warning | none |
| SQL-012 | Updated-at sanity | No future `updated_at` beyond 5 min | T1 | info | none |
| SQL-013 | JSON payload parse | Every payload decodes with the current decoder | T3 | critical | none |
| SQL-014 | Backup is not the live file | Snapshot path differs; hashes differ | T1 | warning | none |
| SQL-015 | Read-only access | Probes never open a write transaction | every cycle | critical | none |

#### BAK — backups and recovery

| ID | Check | Invariant / method | Tier | Severity | Repair |
|---|---|---|---|---|---|
| BAK-001 | Any backup exists | At least one valid backup | T0 | critical | none |
| BAK-002 | Backup freshness | Newest backup < 7 days when data changed | T1 | warning | none |
| BAK-003 | Newest backup opens | Read-only open + decode/`integrity_check` | T3 | critical | none |
| BAK-004 | Restore drill | Temp copy opens, counts match, state decodes | T4 | critical | none |
| BAK-005 | Marker consistency | Backup marker points at an existing file | T1 | warning | none |
| BAK-006 | Backup size anomaly | Newest < 50% or > 200% of previous; report | T2 | warning | none |
| BAK-007 | Rotation count | No more than configured newest N | T2 | info | REP-033 |
| BAK-008 | Pre-repair snapshot | Every repair record has a verified snapshot | T1 | critical | none |
| BAK-009 | Undo availability | Repair within undo window has a readable snapshot | T1 | warning | none |
| BAK-010 | JSON fallback artifacts | `.migrated` files present and readable when expected | T2 | info | none |

#### FILE — books, covers, bookmarks

| ID | Check | Invariant / method | Tier | Severity | Repair |
|---|---|---|---|---|---|
| FILE-001 | Book file exists | Resolve bookmark or recorded URL; file readable | T2 | warning | REP-012 |
| FILE-002 | Stale bookmark | Bookmark exists but resolves nil | T2 | warning | REP-012 |
| FILE-003 | Duplicate bookmark target | Two books resolve to same file | T2 | info | none |
| FILE-004 | Orphan cover | Cover file with no matching book id | T3 | info | REP-013 |
| FILE-005 | Missing cover | Book has no cover and no embedded data | T3 | info | none |
| FILE-006 | Corrupt cover | Zero bytes or undecodable image | T3 | info | REP-014 |
| FILE-007 | Security scope failure | `startAccessingSecurityScopedResource` fails | T2 | warning | REP-012 |
| FILE-008 | Data root permissions | Root is writable by the app; not world-writable | T1 | critical | none |
| FILE-009 | Book file type mismatch | Extension vs detected PDF/EPUB | T2 | info | none |
| FILE-010 | Duplicate book file URL | Same canonical path on two books | T2 | warning | none |
| FILE-011 | Cover cache size | Cache + files within budget | T3 | info | none |
| FILE-012 | Book file modified after import | mtime/size changed; report only | T3 | info | none |

#### WX — weather and environment

| ID | Check | Invariant / method | Tier | Severity | Repair |
|---|---|---|---|---|---|
| WX-001 | Weather store opens | SQLite open + schema exists | T1 | warning | none |
| WX-002 | Required columns | Schema has all columns the reader expects | T2 | warning | none |
| WX-003 | Coverage vs sessions | Sessions with weather snapshots ratio; report, no fake 1.0 | T2 | info | none |
| WX-004 | Orphan snapshots | Snapshot session id has no session | T3 | info | REP-021 |
| WX-005 | Timestamp sanity | No future or pre-2000 timestamps | T1 | warning | none |
| WX-006 | Store growth | Size trend; snapshots per session | T3 | info | none |
| WX-007 | Location honesty | No silent fallback city when location denied | T2 | warning | none |

#### AUD / BHV — audio and behavior evidence

| ID | Check | Invariant / method | Tier | Severity | Repair |
|---|---|---|---|---|---|
| AUD-001 | Profiles decode | `audio-profiles.json` decodes | T2 | warning | none |
| AUD-002 | Duplicate session profiles | One profile per session | T2 | warning | REP-023 |
| AUD-003 | Implausible duration | Duration < 5 s or > session duration | T2 | info | none |
| AUD-004 | Orphan profiles | Profile session id has no session | T3 | info | REP-023 |
| AUD-005 | Unbounded growth | Count/size vs retention budget | T3 | info | REP-023 |
| BHV-001 | Evidence archive decodes | `behavior-evidence.json` decodes | T2 | warning | none |
| BHV-002 | Orphan evidence | Evidence session id has no session | T3 | info | none |
| BHV-003 | Retention | Evidence older than policy | T3 | info | none |
| BHV-004 | Fabricated sampling timestamps | Narrative evidence timestamps match real session dates | T3 | warning | none |
| BHV-005 | Store corruption fallback | Corrupt archive is quarantined, not silently emptied | T2 | warning | REP-020 |

#### MIR — Mirage boundary

| ID | Check | Invariant / method | Tier | Severity | Repair |
|---|---|---|---|---|---|
| MIR-001 | Identity map readable | Known schema + valid entries | T2 | warning | none |
| MIR-002 | Unknown schema | Fail-closed state is surfaced, not hidden | T2 | warning | none |
| MIR-003 | Ledger presence | Map entries have a backing ledger when required | T3 | warning | none |
| MIR-004 | Runtime presence | Enabled + missing runtime = actionable | T2 | warning | none |
| MIR-005 | Stale guard file | Supervisor guard pid is dead | T2 | info | none |
| MIR-006 | Disable deletes nothing | Byte-identical stratum across an off/on toggle | T4 | critical | none |
| MIR-007 | Duplicate mappings | No duplicate book/epub ids | T2 | warning | none |
| MIR-008 | Sentinel never writes Mirage | Source audit + runtime write-scope pin | every cycle | critical | none |

Mirage issues are **report-only**. Sentinel may explain that the map is unreadable or the runtime is missing; it never edits the stratum.

#### APP — application state

| ID | Check | Invariant / method | Tier | Severity | Repair |
|---|---|---|---|---|---|
| APP-001 | Selected book exists | Selected id in library | T1 | info | none |
| APP-002 | Onboarding state | Dismissed/empty state consistent | T1 | info | none |
| APP-003 | Notification permission | Enabled in app but denied in system | T2 | warning | none |
| APP-004 | Stale import temp files | Temp files older than 24 h | T3 | info | REP-024 |
| APP-005 | Demo residue | Demo profiles/personas present in a non-demo store | T1 | warning | none |
| APP-006 | Config validity | Unknown keys preserved; invalid values clamped | T1 | warning | none |
| APP-007 | Test-store leakage | No test root path in production data | T0 | critical | none |
| APP-008 | Launch crash loop | Three consecutive abnormal launches | T0 | critical | none |

#### SELF — Sentinel's own health

| ID | Check | Invariant / method | Tier | Severity | Repair |
|---|---|---|---|---|---|
| SELF-001 | Journal parse | Every complete line decodes; partial tail reported | T1 | warning | none |
| SELF-002 | Issue store | Decodes, schema version known, not stale | T1 | warning | REP-034 |
| SELF-003 | Cycle overrun | Last cycle exceeded its budget | T1 | warning | none |
| SELF-004 | Probe failure rate | Repeated timeout/failure for one probe | T1 | warning | none |
| SELF-005 | Repair failure spike | Verification failures > threshold in 7 days | T1 | critical | none |
| SELF-006 | Sentinel disk growth | Journal/state/quarantine within budget | T2 | warning | REP-018 |
| SELF-007 | Clock skew | System clock jump > 5 min between cycles | T0 | warning | none |
| SELF-008 | Coverage gap | Required probe did not run | every cycle | warning | none |
| SELF-009 | Kill switch state | Disabled state is honest (no timer, no writes) | T0 | info | none |
| SELF-010 | Debug stream size | Debug journal within retention | T3 | info | none |

#### SEC / CAP — security and capacity

| ID | Check | Invariant / method | Tier | Severity | Repair |
|---|---|---|---|---|---|
| SEC-001 | Safe journal has no user text | Scan against known title/note fields | T2 | critical | none |
| SEC-002 | Write scope | Only `Sentinel/` paths written by Sentinel | every cycle | critical | none |
| SEC-003 | Symlink rejection | No writes through symlinked paths | T2 | critical | none |
| SEC-004 | Diagnostics redaction | Export contains no paths/titles/locations | on export | critical | none |
| CAP-001 | Low disk | Important-usage capacity < threshold (default 500 MB) | T1 | warning | none |
| CAP-002 | Disk growth projection | Days until full at current growth | T3 | info | none |
| CAP-003 | Library scale | Book/session/timing counts vs performance tiers | T2 | info | none |
| CAP-004 | Backup free-space headroom | Backups + DB < 50% of free space | T2 | warning | none |
| CAP-005 | Journal growth | Safe journal MB/day vs budget | T2 | info | REP-018 |

### 8.4 Deep dive: SQL timing invariants

The SQL probes are the answer to the 138k-row blind spot. They run against the live GRDB pool, read-only, inside a short transaction, with `EXPLAIN QUERY PLAN` tests to prove index use.

Orphan timing rows:

```sql
SELECT pt.session_id, COUNT(*)
FROM page_times pt
LEFT JOIN sessions s ON s.id = pt.session_id
WHERE s.id IS NULL
GROUP BY pt.session_id;
```

Timing outside its session:

```sql
SELECT pt.id, pt.session_id
FROM page_times pt
JOIN sessions s ON s.id = pt.session_id
WHERE pt.start_time < s.start_time - 60
   OR (s.end_time IS NOT NULL AND pt.start_time > s.end_time + 60)
LIMIT 500;
```

Negative durations:

```sql
SELECT id, session_id
FROM page_times
WHERE end_time IS NOT NULL AND end_time < start_time;
```

Active timing in a closed session:

```sql
SELECT pt.id, pt.session_id
FROM page_times pt
JOIN sessions s ON s.id = pt.session_id
WHERE s.end_time IS NOT NULL AND pt.end_time IS NULL;
```

Page range:

```sql
SELECT pt.id, pt.page_number, b.payload_json
FROM page_times pt
JOIN sessions s ON s.id = pt.session_id
JOIN books b ON b.id = s.book_id
WHERE pt.page_number < 0
LIMIT 500;
```

The page upper bound is harder because `totalPages` lives in the payload. Two options:

1. Decode the payload for the affected book only when a timing page is negative or suspicious (bounded, cheap).
2. Add a `total_pages` column to `books` in a future migration (the normalized direction the Bedrock plan already anticipated).

Until option 2 lands, the probe uses a bounded per-book decode and reports a coverage note for large libraries. It never claims a clean page-range check it did not perform.

**Budget:** each query uses an index (`idx_page_times_session`, `idx_sessions_book`, primary keys). The probe runs `EXPLAIN QUERY PLAN` in tests and fails if a full scan appears on `page_times`. For 138k rows, the target is < 100 ms per aggregate on the reference library; for 1M rows, < 500 ms, off-main.

### 8.5 Deep dive: orphan sessions with real last activity

The v2 probe returns a finding with two timestamps: session start and last activity. The last activity comes from SQL, not the summary:

```sql
SELECT MAX(COALESCE(end_time, start_time))
FROM page_times
WHERE session_id = ?;
```

The repair plan re-reads that value at apply time and closes at `min(now, lastActivity + 5 min)`. Verification re-runs SES-004 and SES-005 for the same session. This is the direct fix for SENT-001.

If the session has no timings at all (a session started but no page turn), the plan closes at `startTime + 5 min` and records `no-timing` evidence. It does not invent hours of reading.

### 8.6 Deep dive: backup restore drill

A backup that has never been opened is a hypothesis. The T4 drill:

1. Select the newest backup and the newest pre-repair snapshot.
2. Copy each to a temp directory (never open the backup in place).
3. Open the SQLite copy read-only (`Configuration.readonly = true`).
4. Run `PRAGMA integrity_check` and `foreign_key_check`.
5. Load book count, session count, page-timing count, and state root; decode the state.
6. Compare against the live store's counts with a tolerance for the time since the backup.
7. Record a `backup-drill` result with duration, bytes, counts, and a pass/fail.
8. Delete the temp copy.

Failure is critical: the app has a backup directory that cannot restore. The Health Center copy says "Your last backup could not be opened. Sentinel has not changed anything."

The drill is read-only and can run while the app is in use; it copies first, so it never locks the live DB.

### 8.7 Deep dive: book files and bookmarks

`Book.resolveURL()` is the existing resolution path. The probe must not resolve every bookmark on the main actor every 15 minutes. V2:

- T2 checks only books opened recently or whose recorded file mtime changed.
- The full inventory is T3, off-main, batched, with `startAccessingSecurityScopedResource` balanced in a `defer`.
- Results cache the last successful resolution and timestamp; a failure is rechecked once, with backoff.
- A missing file produces a warning with an action: "Locate book…" which opens a file picker and, on success, updates the book through an audited API (REP-012, R2).
- Sentinel never moves or deletes a user file.

### 8.8 Deep dive: payload vs normalized rows

The `books.payload_json` summary is the read source of truth; normalized rows power SQL. They can drift after a partial write or an older migration.

The probe compares:

- `COUNT(*) FROM books` vs the number of decodable payloads;
- `COUNT(*) FROM sessions` vs the sum of sessions in payloads;
- `COUNT(*) FROM page_times` vs the sum of timing rows the payload claims (if the payload carries counts) or a session-level existence check;
- `library_state` root presence vs book count;
- collection membership rows vs payload `collectionIDs`.

It reports a **mismatch**, not a direction. Sentinel must not decide that the payload or the rows are "right" without evidence. The repair is report-only until a deterministic reconciliation rule exists; the plan for that is REP-030 (R3, manual, backup required).

### 8.9 Deep dive: subsystem probes

- **Weather:** open read-only, check schema, count snapshots joined to real sessions, detect future timestamps. Never modify the store.
- **Audio:** decode profiles, check session ids and durations, count growth. A 1-second profile is informational, not corruption.
- **Behavior:** decode the evidence archive, check retention and session references. A corrupt archive is quarantined (R2), not silently reset.
- **Mirage:** read the identity map and ledger presence. Report only. Sentinel must prove it never writes `mirage/` (SEC-002 + MIR-008).
- **App state:** selected book, onboarding, notification permission, demo residue, test-path leakage. These are cheap and catch real user confusion.

### 8.10 RawFinding contract

```text
RawFinding
  ruleID
  subjects
  severity
  confidence
  impact
  evidence
  safeSummaryKey
  recommendedRepairID?
  verificationProbeID?
  debugDetail?          // never journaled
```

No probe may set an issue id, fingerprint, status, firstSeen, or occurrence count. Those are diagnoser responsibilities. This separation is what makes dedupe and replay possible.

### 8.11 The 120-subdomain atlas

**What this is.** The program target is 120 domains. That number has been a slogan because nothing named the 120. This section names every one, assigns it a wave, and states the invariant it must establish.

Each of the 15 families has exactly **eight subdomains**. The first is what the shipped catalog already covers; the other seven are planned. That gives **15 shipped + 105 planned = 120**, and the arithmetic is checkable rather than asserted.

**A subdomain is not a probe.** A subdomain is a bounded area of invariants; it will usually carry five to eight probes and roughly twice as many rules. Naming it fixes scope, fixture ownership, copy ownership, and the docs page. It does not fix an implementation.

**Waves are lenses, not family slices.** A wave applies one kind of question across the families that can answer it. That is why `LIB` appears in waves 1, 2, and 3 while `WX` appears in 3, 4, and 5. Organizing by family would have produced fifteen thin verticals; organizing by lens produces six reviewable horizontal passes, each with one definition of done.

| Wave | Lens | The question it answers | New subdomains | New probes | Cumulative probes |
|---|---|---|---:|---:|---:|
| **W1** | Completeness | Does the record exist, and is it well formed? | 17 | 94 | 232 |
| **W2** | Consistency | Do the two sources of truth agree? | 18 | 94 | 326 |
| **W3** | Temporal & lifecycle | Is time, order, and staleness coherent? | 16 | 94 | 420 |
| **W4** | Subsystem depth | Does each subsystem behave as designed? | 19 | 94 | 514 |
| **W5** | Degraded & adversarial | What happens when the world is hostile? | 17 | 93 | 607 |
| **W6** | Scale, recovery & meta | Does it still hold at size, after disaster, over time? | 18 | 93 | 700 |
| | | **Total** | **105** | **562** | **700** |

The first tranche is 140 probes, so 700 − 140 = 560 new probes. SG8's two probes are infrastructure, so the original 94/94/94/94/93/93 wave budgets total 562 and will be rebalanced by two at W1 rather than rewritten here. Those are budgets, not estimates of effort: a wave that cannot fit its budget splits into two gates rather than borrowing from the next wave.

**Family allocation per wave.** Each cell is the number of new subdomains that family contributes to that wave; every row sums to seven.

| Family | W1 | W2 | W3 | W4 | W5 | W6 | Total |
|---|---:|---:|---:|---:|---:|---:|---:|
| LIB | 3 | 2 | 2 | — | — | — | 7 |
| SES | — | 2 | 3 | 2 | — | — | 7 |
| GOL | 2 | 2 | 3 | — | — | — | 7 |
| COL | 2 | 3 | — | — | — | 2 | 7 |
| SQL | — | 3 | — | — | 2 | 2 | 7 |
| BAK | — | — | 2 | — | 2 | 3 | 7 |
| FILE | 3 | 2 | — | — | — | 2 | 7 |
| WX | — | — | 2 | 3 | 2 | — | 7 |
| AUD | 2 | — | — | 3 | 2 | — | 7 |
| BHV | — | 2 | — | 3 | — | 2 | 7 |
| MIR | — | 2 | — | 2 | 3 | — | 7 |
| APP | 3 | — | 2 | — | — | 2 | 7 |
| SELF | — | — | — | 2 | 3 | 2 | 7 |
| SEC | 2 | — | — | 2 | 3 | — | 7 |
| CAP | — | — | 2 | 2 | — | 3 | 7 |
| **Cells** | **17** | **18** | **16** | **19** | **17** | **18** | **105** |

#### LIB — library graph

| # | Subdomain | Wave | Invariant it must establish |
|---|---|---|---|
| LIB.1 | Identity & duplicates | shipped | Book ids are unique; no two records describe one book |
| LIB.2 | Metadata completeness | W1 | Title, author, and page count exist; genre, series, and word count are valid or explicitly unknown |
| LIB.3 | Import provenance | W1 | Every imported book records source kind, content hash, import date, and warnings |
| LIB.4 | Archived/deleted residue | W1 | Deleted or archived records never leak into counts, search, or analytics |
| LIB.5 | Payload↔summary parity | W2 | Summary fields match the normalized rows they came from |
| LIB.6 | Identifier uniqueness | W2 | ISBN, content hash, and canonical path each identify at most one book |
| LIB.7 | Collection membership graph | W3 | Memberships resolve, are acyclic, and are mirrored in both stores |
| LIB.8 | Progress arithmetic | W3 | Current page agrees with completed sessions and page count under a stated rule |

#### SES — sessions and timings

| # | Subdomain | Wave | Invariant it must establish |
|---|---|---|---|
| SES.1 | Orphan sessions | shipped | An open session is either genuinely active or closable at an evidenced boundary |
| SES.2 | Timing window validity | W3 | Every timing starts and ends inside its session's window |
| SES.3 | Session overlaps | W3 | No two sessions for one book overlap beyond tolerance |
| SES.4 | Session–book lifecycle consistency | W3 | Sessions never reference a deleted book; deleted books keep no live cursor |
| SES.5 | Page-range monotonicity | W2 | Start and end pages are ordered and inside the book |
| SES.6 | Duration vs page-delta plausibility | W2 | Duration and page delta imply a speed inside the human band, or are flagged |
| SES.7 | Session event ordering & router state | W4 | Queued events apply once, in order, to the intended session |
| SES.8 | Session teardown on quit/relaunch | W4 | Quitting mid-session leaves one recoverable active session, never two |

#### GOL — goals, deadlines, achievements

| # | Subdomain | Wave | Invariant it must establish |
|---|---|---|---|
| GOL.1 | Achievement invariants | shipped | One earned record per kind; every kind exists in the registry |
| GOL.2 | Goal set shape & defaults | W1 | Targets are positive, periods valid, defaults representable |
| GOL.3 | Achievement award reachability | W1 | Every registered achievement has a code path that can award it |
| GOL.4 | Deadline↔book references | W2 | Every deadline points at a live book |
| GOL.5 | Celebration idempotence | W2 | A celebration fires once per award, including after relaunch |
| GOL.6 | Deadline sanity & calendar semantics | W3 | Dates are valid in the user's calendar, DST-safe, and timezone-stable |
| GOL.7 | Streak computation truth | W3 | Streak equals the recomputation from sessions, not a cached guess |
| GOL.8 | Goal progress vs sessions | W3 | Progress derives from the same timings the analytics use |

#### COL — collections

| # | Subdomain | Wave | Invariant it must establish |
|---|---|---|---|
| COL.1 | Membership dedupe | shipped | A book appears at most once per collection |
| COL.2 | Orphan collection references | W2 | No book references a missing collection |
| COL.3 | Counts vs members | W2 | Displayed and stored counts equal the membership set |
| COL.4 | Cross-store membership drift | W2 | Payload and normalized membership agree |
| COL.5 | Empty/nested semantics | W1 | Empty collections are valid; nesting is supported or rejected consistently |
| COL.6 | Ordering stability | W1 | Order survives relaunch and edits |
| COL.7 | Delete/rename residue | W6 | Delete removes references; rename leaves no stale key |
| COL.8 | Discovery filter references | W6 | Saved filters reference live collections and genres |

#### SQL — database and normalized rows

| # | Subdomain | Wave | Invariant it must establish |
|---|---|---|---|
| SQL.1 | Schema & migration version | shipped | Schema version matches the binary; no migration is pending |
| SQL.2 | Payload decode integrity | W5 | Every payload row decodes; failures are surfaced, not skipped |
| SQL.3 | Save-path failure & latch | W5 | A failed save sets the latch and never reports success |
| SQL.4 | Payload↔normalized parity | W2 | Counts and ids agree between JSON payload and tables |
| SQL.5 | Foreign keys & orphan rows | W2 | No orphan sessions, timings, or collection links |
| SQL.6 | Integrity check & timing presence | W2 | `integrity_check` is ok; timings exist where sessions claim them |
| SQL.7 | WAL & transaction state | W6 | WAL is bounded; no open transaction; checkpoint age is sane |
| SQL.8 | Index & query-plan health | W6 | Required indexes exist; probes never force a full scan |

#### BAK — backups and recovery

| # | Subdomain | Wave | Invariant it must establish |
|---|---|---|---|
| BAK.1 | Presence & freshness | shipped | One valid backup exists inside the staleness window |
| BAK.2 | Backup integrity | W3 | The newest backup opens read-only and passes an integrity check |
| BAK.3 | Rotation & retention | W3 | Retention keeps the promised generations; nothing is silently evicted |
| BAK.4 | Restore drill | W6 | A copy restores into temp and matches counts and state |
| BAK.5 | Archive round-trip parity | W6 | Export → import reproduces books, sessions, goals, and collections |
| BAK.6 | Manifest & checksums | W6 | Every artifact has a manifest and a matching checksum |
| BAK.7 | Ownership & conflict copies | W5 | Backup ownership is unambiguous; no duplicate writer exists |
| BAK.8 | Size/growth anomalies | W5 | A sudden shrink or spike is flagged before it replaces a good backup |

#### FILE — books, covers, bookmarks

| # | Subdomain | Wave | Invariant it must establish |
|---|---|---|---|
| FILE.1 | Missing book file | shipped | Every book resolves to a readable file or is explicitly relinked |
| FILE.2 | Cover presence & orphans | W1 | Covers map one-to-one to books; no orphan files exist |
| FILE.3 | Cover decode & version | W1 | Cover bytes decode; cache version matches the store |
| FILE.4 | Format/container sanity | W1 | Extension, magic bytes, and parser agree for EPUB and PDF |
| FILE.5 | Metadata extraction residue | W2 | Extracted metadata matches the file; no stale cache entry survives |
| FILE.6 | Duplicate file URLs | W2 | One canonical path is never claimed by two books |
| FILE.7 | Security-scope reachability | W6 | Bookmarks resolve after relaunch, move, and sandbox restart |
| FILE.8 | Quarantine & relink history | W6 | Every moved or quarantined asset has an auditable record |

#### WX — weather and environment

| # | Subdomain | Wave | Invariant it must establish |
|---|---|---|---|
| WX.1 | Snapshot presence per session | shipped | A session has a snapshot or an honest absence reason |
| WX.2 | Snapshot schema/decode | W5 | Stored rows decode under the current schema |
| WX.3 | Duplicate/orphan snapshots | W5 | One snapshot per session; no row without a session |
| WX.4 | Location permission & honesty | W4 | Denied location yields a paused state, never a silent default city |
| WX.5 | Provider response validity | W4 | Stored responses are complete, plausible, and inside unit range |
| WX.6 | Environment engine refcount/teardown | W4 | Observers attach once and detach on close |
| WX.7 | Snapshot↔session key mapping | W3 | Keys are stable across relaunch and timezone change |
| WX.8 | Unit & timezone consistency | W3 | Stored units and local times round-trip without drift |

#### AUD — audio

| # | Subdomain | Wave | Invariant it must establish |
|---|---|---|---|
| AUD.1 | Profile decode | shipped | Audio profiles decode; malformed profiles are quarantined |
| AUD.2 | Profile session references | W1 | Every profile points at a live session |
| AUD.3 | Duplicate profiles | W1 | One profile per session per speaker |
| AUD.4 | Duration/bitrate sanity | W4 | Duration matches the session; bitrate is inside the supported band |
| AUD.5 | Entitlement & permission state | W4 | Declared audio entitlement and runtime permission agree |
| AUD.6 | Speaker/route metadata | W4 | Device labels are stable and contain no user text |
| AUD.7 | Retention & growth | W5 | Profiles obey retention; growth is bounded |
| AUD.8 | Playback state persistence | W5 | Resume state survives relaunch without inventing progress |

#### BHV — behavior evidence

| # | Subdomain | Wave | Invariant it must establish |
|---|---|---|---|
| BHV.1 | Archive decode | shipped | Evidence decodes or is quarantined, never silently emptied |
| BHV.2 | Evidence session references | W2 | Evidence points at real sessions |
| BHV.3 | Evidence↔analytics agreement | W2 | Narrative claims match the timings they cite |
| BHV.4 | Corruption & quarantine | W4 | A corrupt archive moves to quarantine with a manifest |
| BHV.5 | Report determinism | W4 | The same evidence produces the same report |
| BHV.6 | Context input completeness | W4 | V3 context declares missing inputs instead of guessing |
| BHV.7 | Retention & pruning | W6 | Retention is applied once and recorded |
| BHV.8 | Archive size/growth | W6 | The archive stays inside its budget |

#### MIR — Mirage boundary

| # | Subdomain | Wave | Invariant it must establish |
|---|---|---|---|
| MIR.1 | Identity map integrity | shipped | Map entries are unique and schema-valid |
| MIR.2 | Cursor monotonicity | W2 | Spoiler cursors never move backwards without an explicit rewind |
| MIR.3 | Ledger presence | W2 | Every mapped entry has the ledger it claims |
| MIR.4 | Runtime locator & signing | W5 | An enabled runtime exists, is signed, and matches the expected version |
| MIR.5 | Protocol version handshake | W5 | App and runtime agree on protocol, or refuse cleanly |
| MIR.6 | No-write guarantee | W5 | Sentinel never writes under `mirage/` (source audit + runtime pin) |
| MIR.7 | Import independence | W4 | Importing a book works with Mirage absent or disabled |
| MIR.8 | Sidecar lifecycle & teardown | W4 | Sidecars start once, stop cleanly, and leave no orphans |

#### APP — application state

| # | Subdomain | Wave | Invariant it must establish |
|---|---|---|---|
| APP.1 | Selected book & onboarding | shipped | Selected id exists; onboarding state is representable |
| APP.2 | Notification permission & state | W1 | App intent and system permission agree |
| APP.3 | Demo profile residue | W1 | Demo data never appears in a real store |
| APP.4 | Test-path leakage | W1 | No test root, fixture id, or debug path exists in production state |
| APP.5 | Reader path residue | W3 | Navigation restores to a valid book or clears |
| APP.6 | Settings coherence | W3 | Stored settings match the running engine's configuration |
| APP.7 | Import temp files | W6 | Temp files are bounded and removed after success or failure |
| APP.8 | Window/scene restoration | W6 | Restored windows reference live books or fall back safely |

#### SELF — Sentinel's own health

| # | Subdomain | Wave | Invariant it must establish |
|---|---|---|---|
| SELF.1 | Issue store & journal parse | shipped | Both decode; a partial tail is reported |
| SELF.2 | Issue store↔journal reconciliation | W5 | Replay reproduces the same open set |
| SELF.3 | Journal parse errors & partial tail | W5 | Every unreadable line is counted and surfaced |
| SELF.4 | Snapshot store integrity | W5 | Snapshots open and match their records |
| SELF.5 | Journal segments & rotation | W4 | Rotation is atomic and loses no committed line |
| SELF.6 | Journal size & retention | W4 | Segments stay inside budget without truncating history |
| SELF.7 | Scheduler & watchdog liveness | W6 | Cycles actually run; a stalled watchdog is visible |
| SELF.8 | Probe/repair registry consistency | W6 | Every rule, probe, and repair resolves; none is orphaned |

#### SEC — security, privacy, confinement

| # | Subdomain | Wave | Invariant it must establish |
|---|---|---|---|
| SEC.1 | Write confinement | shipped | All writes land under `Sentinel/` and nowhere else |
| SEC.2 | Privacy class & redaction | W1 | Every finding declares a class; safe output matches it |
| SEC.3 | Quarantine permissions | W1 | Quarantined bytes are app-only and readable by the owner |
| SEC.4 | Diagnostics bundle leakage | W4 | Export contains no titles, paths, locations, or tokens |
| SEC.5 | Sandbox entitlement drift | W4 | Declared entitlements match what the code uses |
| SEC.6 | Symlink/path traversal guard | W5 | No write follows a link or `..` outside the root |
| SEC.7 | Secret/token absence | W5 | No credential appears in any Sentinel artifact |
| SEC.8 | Signed build/runtime integrity | W5 | Binary and embedded runtime match their signatures |

#### CAP — capacity and performance

| # | Subdomain | Wave | Invariant it must establish |
|---|---|---|---|
| CAP.1 | Disk headroom | shipped | Free space stays above the repair and backup floor |
| CAP.2 | Journal size | W3 | Journal MB/day stays inside budget |
| CAP.3 | Cycle duration & budget | W3 | Every tier meets its budget on the reference fixture |
| CAP.4 | Main-thread stall | W4 | No probe blocks the main actor beyond the T0 budget |
| CAP.5 | Snapshot memory footprint | W4 | Snapshot retains bounded memory at 10× library size |
| CAP.6 | Database size & growth | W6 | Growth projection is measured, not guessed |
| CAP.7 | Backup storage footprint | W6 | Backups + DB stay inside the free-space ratio |
| CAP.8 | Long-run projections | W6 | 30/90-day projections carry error bars and are shown honestly |

#### 8.11.1 How a wave spends its 94 probes

- **Five probes per subdomain** is the working average (17 × 5 = 85), leaving a reserve of 9–12 for cross-domain invariants that need two sources.
- A **flagship subdomain** in the wave may take seven or eight probes when its invariant has several failure shapes (for example, `SQL.4` payload↔normalized parity).
- Every subdomain gets **at least one owner probe** and **no more than one owner per invariant**. Extra probes in the same subdomain are contributors or siblings on distinct rules, never duplicate owners.
- A wave may not add a rule without copy keys and a docs entry, and may not add a repair binding without a verification probe.

#### 8.11.2 Wave exit criteria

A wave is complete only when all of the following are true:

- [ ] Every assigned subdomain has at least one owner probe merged and registered.
- [ ] Each new probe has the four contract tests, a determinism test, a cost check, and a privacy scan.
- [ ] Every new rule has a stable ID, severity, confidence rule, impact, evidence fields, copy keys, and a docs page.
- [ ] The coverage report lists all assigned subdomains as `checked`, `skipped` (with reason), or `failed`; no silent absence.
- [ ] The wave's probe budget is met on the reference fixture without exceeding its tier budgets.
- [ ] At least one repair binding exists for every subdomain whose invariant can be normalized safely; report-only subdomains say why.
- [ ] The gate receipt records probe count, rule count, test count, budget numbers, and known gaps.

#### 8.11.3 What every subdomain record must declare

| Field | Example | Why |
|---|---|---|
| `id` | `SES.5` | Stable reference in gates and docs |
| `question` | "Are pages ordered and inside the book?" | Forces one invariant per record |
| `ownerProbe` | `SES-002` | Enforces single ownership |
| `sources` | `DataStore`, `SQLite` | Declares what must be readable |
| `privacyClass` | `library-metadata` | Drives redaction and export |
| `fixtureTier` | `small`, `scale`, `corrupt` | Prevents fixtures that only prove the happy path |
| `repairBinding` | `REP-007` or `report-only` | No orphan repairs, no silent non-action |
| `docsPath` | `docs/sentinel/rules/<rule-id>.md` | Docs-truth test target |
| `status` | `shipped`, `wave-3`, `blocked` | One source of truth for coverage |

A registry test asserts that every one of the 120 records has all nine fields and that the wave totals equal the table above. That test is what keeps this atlas from drifting into decoration.

**Phase gates versus program waves.** §16.3 counts what a *phase* delivers; this atlas counts the *program*. A wave may span two phases, and a phase may close part of two waves. Neither number overrides the other: the phase gate proves the increments are safe, and the atlas proves the coverage is complete.

## 9. Repair catalog

### 9.1 What counts as a repair

A repair is a typed plan that changes state through an audited API and can be verified. A report, a notification, or a UI action that only changes Sentinel's own issue state is **not** a library repair.

Three scopes:

1. **Library state** — books, sessions, timings, goals, collections, achievements. Mutated only through `DataStore` APIs.
2. **Owned artifacts** — covers, audio profiles, behavior evidence, weather rows, backups, temp files. Mutated only through their owning store APIs or a dedicated, reviewed file operation.
3. **Sentinel state** — issues, journal, repair records, quarantine. Mutated by the runtime under `Sentinel/`.

Every mutating plan declares its scope. The executor enforces that the API used matches the scope.

### 9.2 Repair classes

| Class | Meaning | Automatic? | Requirements |
|---|---|---|---|
| **R0** | Diagnose only | n/a | No mutation |
| **R1** | Reversible normalization of duplicated/derived state | Auto-safe eligible | Snapshot, re-read, verification, undo |
| **R2** | User-visible state or file operation | Assist only (preview + click) | Snapshot, preview, explicit action, verification, undo |
| **R3** | Recovery/destructive/structural | Explicit confirmation, never automatic | Backup, preview, typed confirmation, restart plan, manual verification |

R1 is deliberately narrow. It may only remove duplicates, clamp provably invalid values, close a session at an evidenced boundary, or rebuild a derived cache. It may not change user intent (goals, progress, notes, collections membership semantics).

### 9.3 The catalog

The catalog below is the first **36 repair plans**. The program target is **350+**; the risk-class and verification contract is the scalable part, not the initial count.

| ID | Repair | Class | Rules | Apply | Verify | Undo |
|---|---|---|---|---|---|---|
| REP-001 | Close orphan session at last activity + 5 min | R1 | SES-004, SES-020 | `DataStore.updateBook` | SES-004/SES-005 zero | Restore session end/active id |
| REP-002 | Clear phantom `activeSessionID` | R1 | LIB-005 | `DataStore.updateBook` | LIB-005 zero | Restore id |
| REP-003 | Pin invalid session end / zero duration | R1 | SES-001, SES-008, SES-013 | `DataStore.updateBook` | SES-001 zero | Restore end time |
| REP-004 | Pin negative/out-of-range timing | R1 | SES-006, SES-007 | `DataStore.updateBook` | SES-006/SES-007 zero | Restore timing fields |
| REP-005 | Close orphan timings in a closed session | R1 | SES-005 | `DataStore.updateBook` | SES-005 zero | Restore `endTime` nulls |
| REP-006 | Clamp `currentPage` into range | R1 | LIB-004 | `DataStore.updateBook` | LIB-004 zero | Restore page |
| REP-007 | Pin `endPage` / clamp session pages | R1 | SES-002, SES-003 | `DataStore.updateBook` | SES-002/SES-003 zero | Restore pages |
| REP-008 | Dedupe `collectionIDs` per book | R1 | COL-002 | `DataStore.updateBook` | COL-002 zero | Restore list |
| REP-009 | Dedupe earned achievements by kind | R1 | GOL-001 | `DataStore.updateLibraryState` | GOL-001 zero | Restore achievements |
| REP-010 | Strip dangling collection ids | R1 | LIB-009, COL-003 | `DataStore.updateBook` | LIB-009 zero | Restore ids |
| REP-011 | Remove deadlines for missing books / duplicates | R1 | GOL-005, GOL-006 | `DataStore.updateLibraryState` | GOL-005/006 zero | Restore deadlines |
| REP-012 | Relink a moved book file | R2 | FILE-001, FILE-002, FILE-007 | File picker + bookmark update | FILE-001/002 zero | Restore bookmark |
| REP-013 | Quarantine an orphan cover | R2 | FILE-004 | Move to `Sentinel/quarantine/` | FILE-004 zero | Move back |
| REP-014 | Rebuild a cover from embedded data | R1 | FILE-006 | `CoverStore` write | FILE-006 zero | Delete new file, restore old |
| REP-015 | Checkpoint WAL | R2 | SQL-005 | `PRAGMA wal_checkpoint(TRUNCATE)` via DB API | WAL size below threshold | No undo needed; it is a checkpoint |
| REP-016 | Delete orphan normalized rows | R3 | SES-015/016/017 | SQL delete in a transaction | Orphan queries zero + counts | Restore from snapshot |
| REP-017 | Vacuum / compact the library DB | R3 | SQL-010, CAP-003 | `VACUUM` in a maintenance window | Integrity check + size | Restore from snapshot |
| REP-018 | Rotate/compact the safe journal | R1 | SELF-006, CAP-005 | Segment roll + retention | Size below budget | Segments retained until prune |
| REP-019 | Prune the Debug journal | R1 | SELF-010 | Delete old debug segments | Size below budget | Not reversible; debug only |
| REP-020 | Quarantine a corrupt behavior archive | R2 | BHV-005 | Move file, write a new empty archive through the engine | BHV-001 zero | Move back |
| REP-021 | Quarantine orphan weather snapshots | R2 | WX-004 | Delete rows via weather store API | WX-004 zero | Restore from snapshot |
| REP-022 | Rebuild analytics cache | R1 | LIB-010, SES-014 | Invalidate `AnalyticsCache` | Cached vs recomputed agree | No state to undo |
| REP-023 | Dedupe/prune audio profiles | R2 | AUD-002, AUD-004, AUD-005 | `AudioProfileStore` save/remove | AUD-002/004 zero | Restore file from snapshot |
| REP-024 | Delete stale import temp files | R1 | APP-004 | Remove temp files under app temp | APP-004 zero | Not recoverable; temp only |
| REP-025 | Reset stale notification state | R1 | APP-003 | Notification scheduler API | APP-003 zero | Restore scheduler state |
| REP-026 | Rebuild missing library-state root from a backup | R3 | SQL-008 | Manual recovery flow | SQL-008 zero + state decodes | Keep backup |
| REP-027 | Restore the library from a backup | R3 | BAK-001..004, LIB-013 | Quit → replace DB → relaunch | Counts + state + integrity | Keep previous DB |
| REP-028 | Recover by importing an archive | R3 | LIB-013, SQL-013 | `LibraryArchiveManager` import | Counts + state | Keep previous DB |
| REP-029 | Recompute cached speed fields | R1 | LIB-010, SES-014 | Update books/sessions through DataStore | LIB-010/SES-014 zero | Restore cached fields |
| REP-030 | Reconcile payload and normalized rows | R3 | SQL-003 | Manual, evidence-led | Counts match + integrity | Snapshot |
| REP-031 | Restore a corrupt payload row from backup | R3 | SQL-007, SQL-013 | Manual, record-level | Decode + counts | Snapshot |
| REP-032 | Clear demo residue from a real store | R2 | APP-005 | Demo API removal | APP-005 zero | Snapshot |
| REP-033 | Prune old backups | R2 | BAK-007 | Backup rotation API | BAK-007 zero | Not reversible; retention only |
| REP-034 | Rebuild the issue store from the journal | R1 | SELF-002 | Replay segments | SELF-002 zero | Keep old state file |
| REP-035 | Reset Sentinel state | R2 | SELF-002, SELF-006 | Archive `Sentinel/state`, rebuild | Self probes zero | Archive retained |
| REP-036 | Undo a previous repair | R1/R2 | any repair record | Restore affected records via undo handle | Original probe returns pre-repair result | Re-apply the same repair |

### 9.4 Execution protocol

```text
RepairExecutor.execute(plan, issue):
  1. guard plan.riskClass != R3 || userConfirmed
  2. guard autonomy allows plan.riskClass
  3. guard bridge.isQuiescent (no active reading session, no demo install,
     no in-flight write, no open reader)
  4. guard store generation == plan.baseGeneration
  5. re-read subjects through the source adapter
  6. guard precondition still holds; if not -> repair-skipped (state-changed)
  7. create snapshot; verify it opens
  8. apply actions through audited APIs, recording before hashes
  9. run verification probe for the same fingerprint
 10. if verification passes:
        commit RepairRecord, mark issue resolved, keep undo handle
     else:
        rollback from snapshot/undo handle
        record RepairRecord(verification: failed, rollback: attempted/succeeded)
        set issue open, severity +1 if repeated failures
 11. publish and journal
```

Hard rules:

- Step 3 is the quiescence gate. A repair must not run while the reader is open, a session is active, a demo install is swapping the library, or a save is in flight.
- Step 4 prevents applying a plan built from a library that has since changed.
- Step 7 is mandatory. If snapshotting fails, no mutation.
- Step 8 is one plan, but may touch multiple books. The executor records per-subject before/after hashes.
- Step 9 uses the **same rule and fingerprint**, not a general health check. "Everything looks fine" is not verification.
- Step 10 rollback is automatic on verification failure. A rollback failure is a critical self-issue and a global repair pause.

### 9.5 Deep dive: REP-001 orphan session

This is the flagship R1 repair and the direct fix for the SQLite blind spot.

**Preconditions:**

- session `endTime == nil`;
- session is referenced by `book.activeSessionID` or is the only active session;
- age > configured threshold (default 24 h);
- no reader open, no active session coordinator;
- store generation unchanged since detection.

**Inputs:**

- session start;
- last timing activity from SQL (`MAX(COALESCE(end_time, start_time))` for the session);
- current time;
- grace (default 5 min).

**Plan:**

```text
before:
  session.endTime = nil
  book.activeSessionID = session.id
  page timings with endTime = nil -> unchanged
after:
  session.endTime = min(now, lastActivity + 300)
  active timings end at the same boundary
  book.activeSessionID = nil
```

**Verification:** SES-004 returns zero for the session; SES-005 returns zero for active timings in the closed session; LIB-005 returns zero for a phantom active id.

**Undo:** restore `endTime = nil`, restore `activeSessionID`, restore timing `endTime = nil`. The undo is exact and does not need to reconstruct anything.

**Failure modes:**

- No timings: close at `startTime + 300`, evidence `no-timing`. Never close at `now`.
- Last activity is after `now`: clamp to `now`, evidence `future-activity`; report a clock issue.
- The session belongs to a book that no longer exists: do not repair; mark unactionable and report orphan book.
- The user is reading right now: quiescence gate blocks; retry next cycle.

### 9.6 Deep dive: REP-008 / REP-009 dedupe

Duplicates are the safest R1 class because they remove only repeated references, not the underlying records.

- `collectionIDs`: preserve first occurrence order, remove later duplicates. Undo restores the exact previous array.
- `earnedAchievements`: group by `kind`, keep earliest `earnedAt`, tie-break by lowest id for determinism. Undo restores the exact previous array.
- Detect before applying, and verify the count decreased by exactly the duplicate count. A mismatch aborts and rolls back.
- Never dedupe `notes` or highlights; duplicate text may be intentional.

### 9.7 Deep dive: REP-012 relink a moved book

This is user-assisted by design.

1. Issue says the book cannot be found; action "Locate book…".
2. File picker opens with the book's original file type filter.
3. On selection, create a security-scoped bookmark using the existing `Book` API.
4. Update the book through `DataStore.updateBook`.
5. Verify FILE-001 and FILE-002 for the book.
6. Record the old bookmark hash and the new bookmark hash for undo.

Sentinel never searches the filesystem broadly, never follows aliases automatically, and never moves the user's file. If the user cancels, the issue stays open.

### 9.8 Deep dive: REP-016 orphan normalized rows

This is R3 because the payload is the read source of truth and normalized rows can be intentionally ahead during a migration.

Preconditions:

- `PRAGMA foreign_keys = ON`;
- a verified snapshot;
- a read-only audit that the orphan row is not referenced by any payload;
- no migration in progress;
- user confirmation with the exact count.

Plan: delete only rows whose parent is absent. Never cascade-delete a session that a payload still references. Verify counts and `foreign_key_check`. If the count does not match the audit, roll back.

### 9.9 Deep dive: REP-027 restore a backup

This is the highest-risk repair and never automatic.

1. Present a preview: backup date, bytes, book/session/timing counts, state summary, integrity result.
2. Require typed confirmation (`RESTORE`) or a deliberate two-step click.
3. Create a safety snapshot of the current store first.
4. Quit the reader, close the database pool, and replace the live DB only after the app is in a maintenance state.
5. Relaunch or reopen the pool and run the full load.
6. Verify counts, state, and integrity; run the restore drill.
7. Keep the replaced DB under `Backups/pre-restore-…` until the user confirms.

If any step fails, the previous DB is restored and the issue stays open with an explicit failure reason.

### 9.10 Never automatic

The following may never execute without an explicit user action, even in Auto-safe:

- delete a book, note, highlight, goal, deadline, achievement, or backup;
- move, rename, or delete a user file;
- restore or replace the library database;
- import an archive;
- reconcile payload and normalized rows;
- rewrite a payload row;
- edit Mirage's identity map or ledger;
- change a bookmark to a different file without the file picker;
- clear collections, goals, or achievements wholesale;
- disable a user setting.

### 9.11 Repair preview

Every R2/R3 repair exposes a preview before the button is enabled:

```text
What Sentinel will do
  Close a reading session that has been open for 38 hours.
  New end time: Oct 24, 2026 at 10:41 PM (last page activity + 5 min).

What will change
  1 session · 3 page timings · 1 active-session pointer
  Book: [title hidden in shared preview]

What will not change
  Your reading history, goals, notes, and collections.

Safety
  A backup will be taken first.
  You can undo this for 30 days.

[Cancel]  [Close session]
```

The preview is generated from the plan, not from prose. If the plan cannot produce a concrete before/after, the repair is not ready.

### 9.12 Repair receipts and undo

Every commit produces a receipt visible in the issue detail and History:

```text
Repaired Oct 26, 2026 at 11:04 AM
  Closed 1 orphan session at its last page activity.
  Verified by re-running SES-004: 0 findings.
  Backup: pre-repair-2026-10-26_110401.sqlite3
  [Undo]
```

Undo runs REP-036 with the stored handle, verifies the original condition is restored, and records a new receipt. It does not delete the history of the original repair. If the undo window has expired, the button is disabled and the snapshot retention is stated.

## 10. The Sentinel Health Center

### 10.1 Design principles

1. **Calm, not alarmist.** A warning is a decision, not an emergency. Red is reserved for data at risk.
2. **Action first.** Every card answers "what can I do?" or explicitly says "nothing; this is informational."
3. **One issue, one card.** No duplicate rows for the same condition.
4. **Progressive disclosure.** One sentence, then why, then evidence, then raw technical detail.
5. **Honest silence.** "All clear" always states what was checked and when. "Unknown" is visible.
6. **Reversible by default.** The undo is next to the receipt, not buried in a folder.
7. **No dead ends.** Every stalled issue has a next step, a snooze, or an explanation of why it cannot be fixed.
8. **Quiet by default.** No notification for information; no repeat alert for an acknowledged issue.

### 10.2 Surfaces

| Surface | Release | Debug | Purpose |
|---|---|---|---|
| Launch report card | Yes | Yes | "While you were away" summary |
| Health Center window | Yes | Yes | Overview, issues, history, checks, settings |
| Issue detail | Yes | Yes | Explain + act |
| Menu bar shield | Opt-in | Opt-in | Ambient status |
| Notifications | Opt-in | Opt-in | P1+ new issues only |
| Settings ▸ Sentinel | Yes | Yes | Autonomy, cadence, quiet hours, data |
| Developer Console ▸ Sentinel | No | Yes | Probe matrix, dry run, fixtures, raw journal |

Entry points:

- Toolbar shield button in the main window (always visible, shows band).
- Menu bar item (if enabled).
- Launch card "Review".
- Settings ▸ Sentinel ▸ Open Health Center.
- Keyboard shortcut `⌘⇧H` in Release, `⌘⇧D` remains the Developer Console in Debug.
- Help menu item "Sentinel Health".

### 10.3 Launch report card

The card appears only when there is something new since the last dismissal: a repair, a new issue, a regression, or a coverage failure. It does not appear every launch just because an old issue is still open.

States:

```text
┌────────────────────────────────────────────────────────────────────┐
│  ✓  Sentinel Report                                                 │
│     Sentinel fixed 2 issues while you were away.                   │
│                                            [Review]  [Dismiss]     │
└────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────┐
│  !  Sentinel Report                                                 │
│     1 issue needs your decision. Your library is otherwise clear.  │
│                                            [Review]  [Dismiss]     │
└────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────┐
│  ✓  Sentinel Report                                                 │
│     Checked 63 things. All clear.                                  │
│                                                       [Got it]     │
└────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────┐
│  ?  Sentinel Report                                                 │
│     Could not finish: 2 of 63 checks did not run.                  │
│                                            [Review]  [Dismiss]     │
└────────────────────────────────────────────────────────────────────┘
```

Rules:

- "Review" opens the Health Center to the relevant filter. It never opens the Debug console in Release.
- "All clear" is shown at most once per day and only when coverage is complete.
- "Dismiss" dismisses this report, not the issue. The issue remains in the Health Center.
- No user text, titles, or paths in the card.
- If persistence is degraded, the card is critical and cannot be dismissed without opening the Health Center.

### 10.4 Health Center — Overview

```text
┌────────────────────────────────────────────────────────────────────────────┐
│  Sentinel                                                        [Run now] │
│  ────────────────────────────────────────────────────────────────────────  │
│                                                                            │
│   ● Attention                                                              │
│   Your library is readable. One backup could not be opened.                │
│                                                                            │
│   Needs a decision                                             2           │
│   ┌──────────────────────────────────────────────────────────────────┐     │
│   │ !  A backup could not be opened                                  │     │
│   │    Your last backup is not restorable. Sentinel has not changed   │     │
│   │    anything.                                    [Review] [Snooze] │     │
│   └──────────────────────────────────────────────────────────────────┘     │
│   ┌──────────────────────────────────────────────────────────────────┐     │
│   │ !  A reading session has been open for 38 hours                  │     │
│   │    Sentinel can close it at your last page turn.  [Fix now]       │     │
│   └──────────────────────────────────────────────────────────────────┘     │
│                                                                            │
│   Recently fixed                                               1           │
│   ✓  Closed an orphan session · verified · [Undo]                         │
│                                                                            │
│   Watching                                                                 │
│   • Disk space: 2.1 GB free — enough for now                              │
│   • 3 overdue deadlines — informational                                   │
│                                                                            │
│   Last check 9:41 AM · 61 of 63 checks · Deep check tonight at 3:00 AM     │
│   [View all issues]  [History]  [Checks]  [Settings]                      │
└────────────────────────────────────────────────────────────────────────────┘
```

Overview rules:

- The band is the first thing; the reason is the second.
- "Needs a decision" contains only actionable issues, not information.
- "Recently fixed" shows verification and undo.
- "Watching" contains informational items, collapsed by default.
- The footer states last check, coverage, and next deep check. This is the honesty surface.
- Zero issues with complete coverage: a calm all-clear with the same footer.
- Zero issues with incomplete coverage: "Could not finish" band, never all-clear.

### 10.5 Health Center — Issues

```text
┌────────────────────────────────────────────────────────────────────────────┐
│  Issues                                                                    │
│  [Needs decision] [Recently fixed] [Watching] [Resolved]                   │
│  Filter: All domains ▾   Severity: All ▾   Search: [                ]       │
│  ────────────────────────────────────────────────────────────────────────  │
│  !  A backup could not be opened                                           │
│     Backups · critical · first seen Oct 24 · 2 occurrences                 │
│     Your last backup is not restorable.                    [Review]        │
│  ────────────────────────────────────────────────────────────────────────  │
│  !  A reading session has been open for 38 hours                           │
│     Sessions · warning · first seen today · 1 occurrence                   │
│     It can be closed at your last page turn.        [Fix now] [Snooze]     │
│  ────────────────────────────────────────────────────────────────────────  │
│  i  3 overdue deadlines                                                    │
│     Goals · informational · 5 occurrences                                  │
│     Informational only.                                     [Dismiss]      │
└────────────────────────────────────────────────────────────────────────────┘
```

List behavior:

- Sort by severity, then impact, then first seen.
- Group by root-cause cluster when correlation exists (a disclosure header, not separate rows).
- Show `occurrenceCount` only when > 1; it is a sign of persistence, not a new alarm.
- Search matches rule title, domain, and safe summary; never user text.
- Bulk actions: acknowledge all informational, snooze all matching a rule.
- No "select all and fix" for R2/R3.

### 10.6 Health Center — Issue detail

```text
┌────────────────────────────────────────────────────────────────────────────┐
│  ← Issues                                                                  │
│                                                                            │
│  A reading session has been open for 38 hours                              │
│  Warning · Sessions · First seen Oct 24, 2026 · 2 occurrences              │
│  ────────────────────────────────────────────────────────────────────────  │
│  What happened                                                             │
│  Asterisma was closed while a reading session was still active. The        │
│  session never received an end time, so it is still counted as open.      │
│                                                                            │
│  Why it matters                                                            │
│  If left open, the session can inflate your reading time and streak.       │
│  Your pages and bookmarks are not affected.                                │
│                                                                            │
│  What Sentinel can do                                                      │
│  Close the session at your last page turn, plus a 5-minute grace period.   │
│  A backup is taken first, and you can undo this for 30 days.               │
│                                                       [Fix now] [Snooze]   │
│                                                                            │
│  Evidence                                                         [Show]   │
│  • Session started Oct 24 at 9:14 PM                                       │
│  • Last page activity Oct 24 at 10:41 PM                                   │
│  • Current time Oct 26 at 11:02 AM                                         │
│  • 3 page timings would be closed                                          │
│                                                                            │
│  Technical details                                                [Show]   │
│  Rule SES-004 · fingerprint a3f19c2d7b4e8061 · probe sessions · verified  │
│  Related: 2 other issues from the same crash window                        │
└────────────────────────────────────────────────────────────────────────────┘
```

Detail rules:

- The three prose sections are generated from the rule copy template plus evidence values. No user text.
- Evidence is safe: timestamps, counts, invariants, hashed identifiers.
- Technical details are collapsed and include rule ID, fingerprint, probe, and repair record. No titles or paths.
- Related issues are grouped by root cause, not by text similarity.
- The primary action is singular. Secondary actions (snooze, acknowledge, ignore rule) are quieter.
- For report-only issues, the action area says "Nothing to fix" and offers "What you can do" (e.g., free disk space, locate a book, re-enable permission).

### 10.7 History

```text
┌────────────────────────────────────────────────────────────────────────────┐
│  History                                                    [Export…]      │
│  [All] [Repairs] [Issues] [Checks]                                         │
│  ────────────────────────────────────────────────────────────────────────  │
│  Today                                                                     │
│  11:04 AM  Fixed   Closed an orphan session · verified · [Undo]           │
│  11:04 AM  Check   63 checks · 0 failed · 122 ms                           │
│  Yesterday                                                                 │
│  9:00 PM   Issue   A backup could not be opened · open                    │
│  3:00 AM   Check   Deep check · 71 checks · 1 skipped (Mirage off)        │
└────────────────────────────────────────────────────────────────────────────┘
```

History rules:

- Timeline is built from safe journal records, replayed into the issue store.
- Repairs show verification and undo state.
- Checks show coverage and duration; skipped probes are visible.
- Export produces a redacted text/JSON bundle; no user text, paths, or locations.
- Retention is stated at the bottom: "Issues kept for 90 days; repairs for 30 days."

### 10.8 Checks

```text
┌────────────────────────────────────────────────────────────────────────────┐
│  Checks                                                                    │
│  Last full check 9:41 AM · 61 of 63 · next deep check 3:00 AM             │
│  ────────────────────────────────────────────────────────────────────────  │
│  Library                                                          12 / 12  │
│   LIB-001 Duplicate book ids          clear      9:41 AM                  │
│   LIB-005 Phantom active session      clear      9:41 AM                  │
│  Sessions                                                         15 / 15  │
│   SES-004 Orphan active session       1 issue    9:41 AM                  │
│   SES-006 Negative timing duration    clear      9:41 AM                  │
│  Storage                                                          10 / 10  │
│   SQL-001 Integrity check             clear      yesterday 3:00 AM         │
│   BAK-003 Newest backup opens         fail       yesterday 3:00 AM         │
│  ...                                                                       │
│  Skipped                                                                   │
│   MIR-006 Disable deletes nothing     Mirage disabled                     │
│   CAP-002 Disk growth projection      needs 7 days of history              │
└────────────────────────────────────────────────────────────────────────────┘
```

This surface exists so "all clear" is auditable. It is the answer to SENT-047.

### 10.9 Settings

```text
┌────────────────────────────────────────────────────────────────────────────┐
│  Sentinel                                                                  │
│  ────────────────────────────────────────────────────────────────────────  │
│  Protection                                                                │
│   ( ) Off       No checks, no records.                                     │
│   ( ) Observe   Check and report. Never changes anything.                  │
│   (•) Assist    Suggest fixes; you approve each one.         Recommended   │
│   ( ) Auto-safe Fix safe, reversible issues automatically.                 │
│                                                                            │
│  Schedule                                                                  │
│   Fast check: [15 minutes ▾]   Deep check: [Daily at 3:00 AM ▾]           │
│   Pause while reading [on]                                                 │
│                                                                            │
│  Quiet hours                                                               │
│   [on]  From [10:00 PM] to [8:00 AM]     Notifications [off]               │
│                                                                            │
│  What Sentinel watches                                           [Customize]│
│   Library, sessions, storage, backups, files, weather, audio,              │
│   behavior, Mirage, app state, Sentinel itself.                            │
│                                                                            │
│  Data                                                                      │
│   [Run a check now]  [View history]  [Export diagnostics…]                 │
│   [Open Sentinel folder]  [Reset Sentinel data…]                           │
│                                                                            │
│  Privacy                                                                   │
│   Sentinel never leaves this Mac. Reports contain no book titles,          │
│   notes, file paths, or locations.                                         │
└────────────────────────────────────────────────────────────────────────────┘
```

Settings rules:

- Autonomy is the primary control. The explanation is one line per level.
- "Off" is a real kill switch: stop timer, cancel work, no writes.
- "Pause while reading" is on by default; it prevents repairs during a session and reduces probe cost.
- Per-domain customization is under Advanced, not in the main pane.
- "Reset Sentinel data" archives the current state, then rebuilds; it never touches the library.
- Notification permission is requested only when the user enables notifications, not at launch.

### 10.10 Menu bar

Optional, off by default.

| State | Icon | Tooltip |
|---|---|---|
| Clear | Shield | Sentinel: all clear, checked 9:41 AM |
| Attention | Shield with dot | Sentinel: 2 issues need a decision |
| Critical | Shield with exclamation | Sentinel: 1 critical issue |
| Unknown | Shield with question | Sentinel: check incomplete |
| Paused | Shield with slash | Sentinel: monitoring paused |

Menu:

```text
Sentinel: Attention
2 issues need a decision
──────────────
Open Health Center
Run a check now
──────────────
Pause monitoring
Settings…
```

No issue titles in the menu bar; no reading data in a public screen.

### 10.11 Notifications

Off by default. When enabled:

- Only `critical` and `warning` with impact ≥ medium.
- Only for a **new** issue, a regression, or a failed verification — not for every cycle.
- At most one notification per issue per 7 days.
- Respect quiet hours and Focus.
- Actions: "Review", "Snooze 1 day".
- No notification for informational items, clean cycles, or resolved issues.

Copy:

```text
Sentinel found a backup problem
Your last backup could not be opened. Sentinel has not changed anything.
[Review]  [Snooze]
```

### 10.12 Copy deck

All strings are localization keys with typed placeholders. No user text. Examples:

| Rule | Title | What happened | Why it matters | Action |
|---|---|---|---|---|
| LIB-004 | A book's page position is out of range | The saved page is beyond the end of the book. | The reader may open at a blank page. | Reset to the last valid page |
| LIB-005 | A book points to a missing session | The active-session pointer does not match any session. | New reading could attach to nothing. | Clear the pointer |
| LIB-009 | A collection reference is missing | A book belongs to a collection that no longer exists. | Filters can hide the book. | Remove the missing reference |
| SES-001 | A session ends before it starts | A saved session has an end time earlier than its start. | Reading time can be negative. | Pin the end to the start |
| SES-004 | A reading session has been open for {hours} hours | Asterisma closed while a session was active. | Reading time and streaks can be inflated. | Close at the last page turn |
| SES-006 | A page timing has a negative duration | A page's end time is earlier than its start. | Reading speed can be wrong. | Pin the end to the start |
| SES-015 | Reading timings point to a missing session | Some page timings have no parent session. | They are invisible to analytics and may be lost. | Remove the orphan rows (manual) |
| GOL-001 | A badge was awarded more than once | The same achievement appears multiple times. | Badge counts and toasts can be wrong. | Keep the earliest award |
| FILE-001 | A book file cannot be found | The file moved or is no longer readable. | The book cannot be opened. | Locate the file |
| FILE-004 | A cover image has no book | A cover file is left over from a removed book. | It wastes space. | Move to quarantine |
| BAK-003 | A backup could not be opened | The newest backup failed its integrity check. | Recovery may not be possible from it. | Review backups |
| SQL-001 | The library database did not pass its integrity check | SQLite reported damage. | Some reading history may be unreadable. | Review recovery options |
| WX-003 | Weather coverage is incomplete | Some sessions have no weather snapshot. | Weather insights may be less reliable. | Nothing to fix |
| APP-003 | Notifications are blocked in System Settings | The app has notifications enabled but macOS denies them. | You will not see Sentinel alerts. | Open System Settings |
| SELF-003 | Sentinel's last check took too long | A cycle exceeded its time budget. | Checks may be delayed. | View checks |

Copy rules:

- Title ≤ 60 characters; body ≤ 140.
- No "corrupt" unless the data is truly unreadable; prefer "could not be read".
- No book titles, author names, note text, paths, or locations.
- Every stalled issue says what happens if the user does nothing.
- Every repair says it can be undone and for how long.
- Numbers use the user's locale; plurals use the string catalog.
- No exclamation marks. No "Oops". No blaming the user.

### 10.13 Empty, unknown, and error states

| State | Copy | Action |
|---|---|---|
| Never checked | "Sentinel has not run yet." | Run a check |
| All clear, complete | "Checked {count} things. All clear." | View checks |
| All clear, incomplete | "Checked {ran} of {planned}. {skipped} checks could not run." | View checks |
| Monitoring off | "Sentinel is off. Nothing is being checked." | Turn on |
| Persistence degraded | "Saving is paused to protect your data. Sentinel has not changed anything." | Review recovery |
| Library unreadable | "The library could not be read. Your database has not been overwritten." | Restore options |
| Journal unwritable | "Sentinel could not record its last check." | Open folder / retry |
| Backup unavailable | "A backup could not be made, so automatic fixes are paused." | Free space / review |
| Probe disabled | "This check is off." | Enable |
| Subject gone | "This issue no longer applies." | Archive |

### 10.14 Action matrix

| Issue type | Primary | Secondary | Never |
|---|---|---|---|
| Reversible normalization (R1) | Fix now | Snooze, Acknowledge | Hide without record |
| Missing file (R2) | Locate book… | Snooze | Delete book |
| Backup unreadable (R0/R3) | Review backups | Export diagnostics | Restore without confirmation |
| Low disk (R0) | Open storage settings | Snooze | Delete user files |
| Persistence paused (R0/R3) | Review recovery | Export diagnostics | Clear the database |
| Info (deadline, coverage) | Dismiss | Snooze | Notify |
| Mirage report-only | Open Mirage settings | Dismiss | Edit the stratum |
| Repaired | Undo | View receipt | Re-run blindly |

### 10.15 Accessibility

- Semantic text styles only; no fixed 9-point body text.
- Every status uses icon + text + color, never color alone.
- VoiceOver labels include the issue title, status, and primary action; evidence rows are grouped and read in order.
- Full keyboard navigation: tab order, focus ring, `Return` activates primary, `Escape` closes.
- Reduced motion: no slide animations; use opacity only.
- High contrast: test both light and dark; health colors have text labels.
- Dynamic Type: layouts reflow at the largest macOS text sizes; no clipped buttons.
- No timed auto-dismiss for critical banners.

### 10.16 Localization

- Use a String Catalog; every key has a default English value and a comment for translators.
- No string concatenation; use positional placeholders and plural variations.
- Copy templates live in the domain layer, not in SwiftUI views.
- Dates/times use the user's locale and time zone; durations use a formatter.
- Avoid idioms that do not translate ("all clear" is fine; "good to go" is not).
- RTL layout test for the Health Center.
- Localize severity, status, and action labels; do not localize rule IDs or fingerprints.

### 10.17 First-run and education

Sentinel should not introduce itself with a modal wall. The first time the user opens the Health Center:

```text
Sentinel watches the parts of Asterisma that can quietly go wrong:
your library, sessions, backups, files, and the app's own stores.
It never leaves this Mac. It never changes anything unless you say so.
[Got it]  [Choose what it watches]
```

If the user never opens the Health Center, the first launch card (only when there is something to report) is the introduction. Notifications are requested only when the user enables them.

### 10.18 Visual language

- Use the existing `DesignGrid` spacing and corner radii.
- Health palette: calm green for clear, amber for attention, red only for critical, gray for unknown.
- Typography: semantic body/caption; monospace only in Developer Console and the technical-details disclosure.
- Cards: one issue per card, title, one-line summary, actions; no dense tables in Release.
- Icons: shield family; consistent with the existing Sentinel icon.
- Motion: one subtle transition on state change; no looping animation.
- Privacy: no issue title in the menu bar or notification preview beyond the generic category.

### 10.19 Anti-patterns to reject

- "Something went wrong" without a next step.
- "All clear" when probes were skipped.
- A red badge for an informational deadline.
- The same issue listed five times because it was re-detected.
- A "Fix" button that silently changes user intent.
- An undo hidden behind a filename the user must find.
- A Release copy path that only Debug builds can open.
- A health score that goes up when checks fail to run.
- A notification for every cycle.
- Technical IDs in the primary user surface.

## 11. Scheduling, performance, and capacity

### 11.1 Cadence

| Cycle | Trigger | Probes | Target duration | User-visible |
|---|---|---|---|---|
| **Launch fast pass** | App launch, after DataStore load | T0 + T1 | < 50 ms | Launch card uses this |
| **Fast cycle** | Every 15 min while active | T0 + T1 | < 200 ms | Health Center updates |
| **Normal cycle** | Every 60 min while active | T0–T2 | < 1 s | Issues update |
| **Deep cycle** | Daily at 3:00 AM local, or on demand | T0–T3 | < 10 s | History / checks |
| **Maintenance** | Weekly, idle window | T4 | < 60 s | Backup drill result |
| **On demand** | "Run a check now" | T0–T3 | Budget shown | Progress + result |

Rules:

- The fast pass must never wait for SQLite or file I/O that can exceed 50 ms. T2/T3 results stream in later.
- Deep and maintenance cycles run only when the app is idle, no reader is open, and no session is active.
- "Pause while reading" skips all but T0; it does not queue a backlog.
- A missed cycle is not replayed multiple times. The next tick runs once with a `missedCycles` count.
- On wake, run a fast pass after 10 seconds, then resume cadence. Do not run a deep pass immediately after wake unless it was due.

### 11.2 Budgets

| Resource | Budget | Enforcement |
|---|---|---|
| Main-actor time per launch pass | 50 ms | `ContinuousClock` measurement; overrun issue |
| Main-actor time per fast cycle | 20 ms | Snapshot capture only; probes off-main |
| Probe wall time | 10 ms T0, 50 ms T1, 250 ms T2, 2 s T3 | Per-probe timeout + cancellation |
| Whole cycle | 500 ms fast, 2 s normal, 15 s deep | Cycle deadline; remaining probes skipped |
| CPU average | < 0.5% over 24 h | Instrumented in Debug; release sampling |
| Memory | < 20 MB peak Sentinel-owned | Autorelease pools per probe; no retained rows |
| Journal growth | < 10 MB/month | Segment rotation + retention |
| Issue store | < 5 MB / 5k issues | Resolved pruning |
| Backup drill temp space | < 2× live DB | Preflight free-space check |
| Notification rate | ≤ 1 per issue per 7 days | Policy gate |

Budget overruns are findings (SELF-003), not silent slowness. If a probe repeatedly exceeds its budget, its tier is downgraded automatically and the developer console shows why.

### 11.3 Incremental work

Sentinel must not rescan 138k timings every 15 minutes.

**Library probes:**

- Keyed by `DataStore.libraryGeneration` (promote `analyticsEpoch` or add a dedicated counter).
- If the generation is unchanged and no relevant setting changed, reuse the previous result with a new `checkedAt`.
- A probe declares `invalidatedBy: [.libraryMutation, .fileChange, .settingsChange, .timeBucket]`.

**SQL probes:**

- Use aggregate queries and indexes; never materialize all rows.
- Maintain a high-water mark for `page_times` by rowid/update timestamp when available.
- For full integrity checks (`PRAGMA integrity_check`), run only in T3/T4, not every cycle.
- Cache per-book counts keyed by `books.updated_at`.

**File probes:**

- Enumerate directory metadata once per cycle, not per book.
- Cache bookmark resolution for 24 h unless the file mtime changed or the user opened the book.
- Batch `resourceValues` calls.

**Derived probes:**

- Reuse `AnalyticsCache` for expensive analytics, keyed by generation + day bucket.
- Never call `AnalyticsEngine` whole-library functions per book inside a loop; use the SQL aggregates when available.

**Journal/issue store:**

- Append only changes, not a full snapshot each cycle.
- Issue store writes are debounced and atomic; a cycle with no state change writes only the `cycle` record.

### 11.4 Concurrency and scheduling implementation

- `SentinelRuntime` is an actor with a serial executor. All cycle state lives inside it.
- The scheduler uses a single `Task` loop with `Task.sleep`, not a main-runloop `Timer`, so it survives view lifecycle and does not depend on a visible window.
- The loop checks `Task.isCancelled` at each await point; `stop()` cancels the current cycle and waits for probes to finish or cancel.
- Probes run in a `TaskGroup` with a per-probe timeout child task. One slow probe cannot block the group beyond its timeout.
- Snapshot capture is a short `@MainActor` function; everything else is off-main.
- SQL probes open a read-only GRDB connection or use `pool.read` with a short transaction. They never hold a transaction across awaits that could span a write.
- Journal and issue-store writes are serialized inside the runtime actor; no file handle escapes.
- The UI receives an immutable `SentinelViewState` on the main actor, at most once per cycle plus repair updates.

### 11.5 Sleep, wake, and app state

| Event | Behavior |
|---|---|
| App launch | Fast pass after data load; card from last report + this pass |
| App active | Fast/normal cadence |
| App inactive/background | Fast pass only if the app is still running and the user enabled background checks; otherwise pause |
| System sleep | Scheduler stops; no catch-up storm |
| System wake | Fast pass after 10 s, then cadence |
| Reader open | T0 only; no repairs |
| Active reading session | No repairs; T0 health only |
| Demo install | All probes paused via bridge mutation flag |
| Low power mode | Cadence doubles; deep cycle deferred |
| Disk full | No snapshot/repair; critical issue; T0 only |
| App terminating | Cancel cycle; flush journal; no repair starts |

### 11.6 Capacity model

Reference library: 7 books, 292 sessions, 138,459 page timings, ~48 MB SQLite.

| Scale | Books | Sessions | Timings | Fast pass | Deep pass | Notes |
|---|---:|---:|---:|---:|---:|---|
| Reference | 7 | 292 | 138k | < 50 ms | < 5 s | Current real data |
| 10× | 70 | 2,920 | 1.38M | < 50 ms | < 15 s | SQL aggregates still indexed |
| 100× | 700 | 29,200 | 13.8M | < 50 ms | < 60 s | Deep pass may need sampling; backup drill grows |
| Pathological | 5k | 200k | 100M | < 50 ms | > 2 min | Tiered/sampled checks; report capacity issue |

The fast pass must stay constant because it is snapshot-only. Deep checks scale with data; the plan requires `EXPLAIN QUERY PLAN` tests and a benchmark fixture at 10× before Phase 5 exits.

### 11.7 Watchdog of the watchdog

- A cycle has a hard deadline. If the runtime does not publish a cycle completion within 2× the budget, a `SELF-003 cycle-overrun` issue is created by the next launch.
- The scheduler records a heartbeat. If no heartbeat for 3 expected intervals while the app is active, the Health Center shows "Sentinel has not checked recently."
- A probe that times out three times in a row is disabled for 24 h and reported; the rest of the cycle continues.
- A repair that fails verification twice for the same fingerprint is disabled for that fingerprint; the issue becomes manual-only.
- A journal write failure switches to in-memory buffering and retries; if it persists for 24 h, the Health Center says records are not durable.
- Sentinel never kills the app or blocks quit to finish a check.

---

## 12. Safety, security, and privacy

### 12.1 Threat model

| Threat | Example | Mitigation |
|---|---|---|
| Buggy repair damages data | Closes the wrong session, clamps a valid page | Snapshot, re-read, verification, undo, quiescence |
| Corrupt store misleads engine | Payload decodes to empty or wrong counts | Fail-closed load, generation checks, evidence |
| Malicious book metadata | Title contains path traversal or control characters | Never use user text in paths; canonicalize; escape |
| Symlink attack | `Sentinel/` or covers path points outside root | Resolve symlinks, reject writes outside canonical root |
| Journal injection | Book title includes newline/JSON | Never journal user text; structured encoder |
| Privacy leak in diagnostics | Export includes titles/paths/locations | Redaction allowlist, test scan |
| Disk exhaustion | Quarantine/journal grows unbounded | Budgets, retention, preflight free space |
| Denial of service | Huge library makes probes hang | Tiering, timeouts, sampling, budget |
| Privilege escalation | Repair uses shell or broad file APIs | No shell, no arbitrary paths, audited APIs |
| Mirage boundary violation | Sentinel edits identity map | Report-only, write-scope pin |
| Test leakage | Unit tests write real app-support | Isolated store, checksum test |
| User alarm fatigue | 96 notifications/day | Dedupe, lifecycle, notification policy |

### 12.2 Write confinement

The only writable locations for Sentinel are:

```text
<dataRoot>/Sentinel/
```

Nothing else. Not the data root itself (the v1 `.sentinel-write-test` is removed), not `Backups/` (backups are written by the backup API), not `covers/` (CoverStore owns it), not `mirage/` (Mirage owns it), not the library DB (DataStore/GRDB owns it).

Enforcement:

- `SentinelPaths` is the only type that constructs URLs for writes. It exposes `journalURL`, `stateURL`, `repairURL`, `quarantineURL`, `reportURL`, and nothing else.
- Every write path is canonicalized; if the resolved path is not under `Sentinel/`, the operation fails closed and records a self-issue.
- Symlinks are rejected for any component under `Sentinel/`.
- Tests use a temp data root and a checksum before/after to prove no production file changed.
- The source audit check fails CI if `Sentinel*` sources import `Network`, call `NSAppleScript`, spawn `Process`, or use `FileManager` writes outside `SentinelPaths`.

### 12.3 Snapshot and restore

- `createSafetySnapshot` must verify the snapshot opens. A copied file with a bad header is not a snapshot.
- SQLite snapshots use `pool.writeWithoutTransaction { wal_checkpoint(TRUNCATE) }` then a file copy, as today, plus a read-only open check.
- JSON snapshots use the existing `Backups/` rotation and a decode check.
- Undo snapshots are retained separately from the 10-deep rotation so a repair does not evict the user's oldest backup. The retention policy is explicit.
- Restore is always user-confirmed, always preceded by a snapshot of the current store, and always followed by a full load verification.

### 12.4 Verification matrix

| Repair class | Verification | Pass condition |
|---|---|---|
| Session normalization | Re-run SES rule for fingerprint | Zero findings for subject |
| Timing normalization | Re-run SES-006/SES-007 | Zero findings, SQL count matches |
| Collection dedupe | Re-run COL-002 | No duplicate ids |
| Achievement dedupe | Re-run GOL-001 | One record per kind |
| Missing file relink | FILE-001/002 | File resolves and opens |
| Cover quarantine | FILE-004 | No orphan cover for id |
| Backup restore | BAK-003/004 + load counts | Integrity ok, counts match |
| Orphan row cleanup | SES-015/016 + `foreign_key_check` | Zero orphans, no FK violations |
| Journal compaction | SELF-006 | Size below budget, replay succeeds |
| Undo | Original probe | Original condition restored |

A repair without a row here is not eligible for automatic execution.

### 12.5 Privacy classes

| Class | Examples | Journal | Diagnostics | UI |
|---|---|---|---|---|
| **Safe** | counts, durations, rule IDs, bands, hashed IDs | Yes | Yes | Yes |
| **Identifier** | full UUIDs, record IDs | Yes (hashed in export) | Yes | Technical details only |
| **Debug** | paths, titles, chapter names, query text | No | No (excluded by default) | Debug console only |
| **Secret** | none in Sentinel | Never | Never | Never |

Rules:

- The safe journal never contains Class Debug or Secret.
- Diagnostics export hashes identifiers and excludes debug detail unless the user explicitly checks "Include technical details".
- Notifications and menu bar show category, not title.
- No location, weather coordinates, app names, note text, or highlight text ever leaves the device through Sentinel.
- There is no network code in Sentinel. A source scan enforces it.

### 12.6 Sandbox and entitlements

Sentinel adds no entitlements. It uses the app's existing sandbox and data root. It does not request full disk access, automation, or network. Security-scoped bookmarks are resolved only for books the user already authorized.

### 12.7 Defensive parsing

- Every persisted Sentinel file has a schema version and a tolerant decoder with explicit defaults.
- Unknown keys are preserved where possible, ignored otherwise.
- Oversized lines/records are rejected with a self-issue, not loaded into memory unbounded.
- Journal replay caps lines per segment and total issues; beyond the cap, it stops and reports.
- JSON decoding never trusts counts for allocation; arrays are bounded.
- A corrupt state file is quarantined, not overwritten in place.

### 12.8 Failure modes and user messaging

| Failure | Sentinel does | User sees |
|---|---|---|
| Snapshot fails | No mutation; mark stalled | "Sentinel could not make a backup, so it did not change anything." |
| Verification fails | Roll back; record failed repair | "Sentinel tried to fix this and put it back." |
| Rollback fails | Global repair pause; critical self-issue | "Automatic fixes are paused. Your data needs attention." |
| Store changes mid-repair | Abort; retry next cycle | Nothing (no false alarm) |
| Journal unwritable | Buffer; retry; self-issue | "Sentinel could not record its last check." |
| Issue store corrupt | Quarantine; rebuild; self-issue | "History was rebuilt; some old entries may be missing." |
| Disk full | No repair; critical issue | "There is not enough free space to protect your data." |
| Clock skew | Report; suppress age-based repairs | "The system clock changed; some checks were paused." |

### 12.9 Cold-start and Sentinel-failure runbook

This is the procedure for the day Sentinel itself is the problem: the app opens to an empty library, a repair looks wrong, or the app will not launch at all. It is deliberately short, ordered, and biased toward **preserving bytes** over restoring convenience.

The runbook assumes the layout in §7.6. Paths below are relative to `<dataRoot>`:

```text
Sentinel/state/issues.json
Sentinel/state/config.json
Sentinel/journal/*.jsonl
Sentinel/repairs/*.json
Sentinel/snapshots/*
Sentinel/quarantine/
```

#### 12.9.1 Symptoms and first moves

| Symptom | Likely cause | First move |
|---|---|---|
| Library is empty after a crash or update | fail-closed load latch (`SENT-003`) | **Do not save, import, or erase.** Quit and follow 12.9.2 |
| App will not launch | corrupt issue store, corrupt state file, or a probe crash loop | Safe mode (12.9.3) |
| "Automatic fixes are paused" | a rollback failed; repair pause latch is set | Read the last repair record; follow 12.9.4 |
| Repairs appear to do nothing | verification failing; repair silently rolled back | Open the receipt; the rollback reason is recorded |
| Sentinel pane is empty | autonomy off, or engine never started | Check `autonomy` in `config.json` and the last `cycle` record |
| Journal grows abnormally | a probe is failing every cycle, or a loop | Disable the offending probe; follow 12.9.5 |
| Many issues appeared after an update | rule-version mass reopen (`§7.3a.3`) | Check the `rule-version` record before acting |

#### 12.9.2 First ten minutes

1. **Stop writing.** Quit the app. Do not import a book, run a repair, or press "Erase all data". Every one of those can overwrite the evidence.
2. **Preserve the data root before touching it.** Copy, do not move:

   ```bash
   ditto "<dataRoot>" "$HOME/Desktop/sentinel-incident-$(date +%Y%m%d-%H%M%S)"
   ```

   `ditto` preserves extended attributes and security-scoped metadata that a Finder drag can lose.
3. **Read the latches, do not guess.** In the copy, inspect `Sentinel/state/config.json` for `autonomy` and `probeOverrides`, and the last `cycle` journal record for `loadFailure` and `schemaVersion`. Record the values in the incident note before changing any of them.
4. **Test the issue store in isolation.** A decode failure is cheap to confirm:

   ```bash
   python3 -m json.tool "<copy>/Sentinel/state/issues.json" > /dev/null && echo decodes || echo corrupt
   ```

5. **Disable before diagnosing.** Create the hard-stop flag the runtime checks before probes and before repairs:

   ```bash
   touch "<dataRoot>/Sentinel/disabled"
   ```

   This is inert: it stops scheduling and repair, it does not delete state. Remove it only in step 10.
6. **Reproduce read-only.** Launch with `SENTINEL_SAFE_MODE=1` (Debug) to skip probe execution and confirm whether the app shell itself is healthy. If the app launches in safe mode, the data is likely recoverable; if it does not, the fault is in the issue store or state file.
7. **Choose one repair path, not a sequence of guesses.** Use 12.9.4.
8. **Snapshot again before restoring.** A restore is itself a mutation. Take a fresh verified copy of the current store so the restore can be undone.
9. **Verify after restore.** Counts match, state decodes, `integrity_check` is ok, and one full T0/T1 cycle completes without a new self-issue.
10. **Re-enable deliberately.** Remove `Sentinel/disabled` only after a clean cycle. Watch one complete cycle; if a self-issue appears, stop and return to step 2.

#### 12.9.3 Safe mode

Safe mode is a launch flag, not a repair. It:

- skips probe execution and repair dispatch;
- still loads the app and the library through the normal fail-closed path;
- writes a single `self` journal record with the reason `safe-mode`;
- shows a non-dismissible banner that automatic fixes are off.

Safe mode does **not** bypass the fail-closed load latch. If the library cannot decode, the app must still refuse to save; that is the behavior protecting the data.

#### 12.9.4 Recovery decision tree

```text
Does the app launch in safe mode?
├─ no ──▶ issue store or state file is the fault
│         ├─ issues.json decodes? ──▶ replay journal (REP-034)
│         └─ issues.json corrupt  ──▶ archive it, rebuild from journal (REP-034/035)
│                                     └─ still no launch ──▶ disable Sentinel, launch,
│                                                             file a self-issue, keep the copy
└─ yes ─▶ does the library load?
          ├─ no  ──▶ loadFailure set?
          │         ├─ yes ──▶ restore the newest verified snapshot (REP-026/027)
          │         └─ no  ──▶ repair the specific unreadable payload row (REP-031)
          └─ yes ─▶ are repairs paused or wrong?
                    ├─ paused ──▶ read the last repair record; undo it (REP-036)
                    └─ wrong  ──▶ undo first (REP-036), verify, then investigate
```

Rules for the tree:

- Prefer the **narrowest** repair that addresses the symptom. `REP-031` (one payload row) before `REP-027` (whole-library restore).
- Never run `REP-016` (delete orphan rows) before taking a snapshot; it is R3 for a reason.
- Never restore over the live database while the app is running. Quit, restore to a temp path, verify, then swap.
- If two repairs could both apply, the owner issue's `rootCauseKey` decides which one is primary; the other becomes a follow-up, not a parallel mutation.

#### 12.9.5 Stopping a bad probe

1. Read `Sentinel/journal/` for the last `cycle` record; it names `probe-failed` and `probe-timeout` entries.
2. Disable that probe in `Sentinel/state/config.json` under `probeOverrides` (`"SES-011": { "enabled": false }`), not by deleting code.
3. Leave the probe disabled through one full cycle; confirm the cycle duration returns to budget.
4. File the failure with its descriptor, fixture, and budget so the fix is testable.
5. Re-enable only after the contract tests pass in Debug and Release.

#### 12.9.6 What not to do

- Do not delete `Sentinel/` to make a banner disappear. That discards history and undo handles.
- Do not press "Erase all data" to clear a fail-closed latch. It converts a recoverable state into an unrecoverable one.
- Do not restore a backup while the app is open, or while a second copy of the app is running.
- Do not copy `debug-*.jsonl` into a diagnostics bundle; it is excluded for a reason.
- Do not disable fail-closed loading to "get the library back". A partial library that saves over a good one is the worst outcome in this document.
- Do not run two repairs at once on the same `rootCauseKey`.

#### 12.9.7 Incident record template

```text
Date / app version / build:
Symptom (one sentence):
Latches before: autonomy= repairPause= loadFailure= schemaVersion=
Probes last run / last cycle duration:
Repair records inspected (IDs):
Path chosen (REP-xxx) and why:
Snapshot used (path hash, not path):
Verification result (counts, integrity_check, one clean cycle):
What was preserved for support (hashed paths only):
Follow-up issue / rule ID:
```

#### 12.9.8 Exit criteria

- The app launches normally with Sentinel enabled.
- One full cycle completes inside budget with zero `probe-failed` and zero new self-issues.
- Library counts and library-state decode match the pre-incident record.
- The incident note and the preserved copy exist and are referenced by a self-issue.
- The cause has either a regression pin or a named open defect; "it went away" is not a resolution.

---

## 13. Testing and verification

### 13.1 Test pyramid

```text
                 ┌─────────────────────────────┐
                 │ Manual owner scenarios (10) │
                 ├─────────────────────────────┤
                 │ UI + accessibility tests    │
                 ├─────────────────────────────┤
                 │ Repair integration + chaos  │
                 ├─────────────────────────────┤
                 │ Probe fixtures (positive/neg)│
                 ├─────────────────────────────┤
                 │ Domain unit tests (pure)    │
                 └─────────────────────────────┘
```

Target: 400+ Sentinel-specific tests for the first tranche (four per probe plus domain/repair/security), and 2,000+ at the full 700-probe scale. The domain layer carries at least half of them.

### 13.2 Deterministic harness

```text
SentinelEnvironment
  clock            TestClock (settable, monotonic)
  calendar         injected (Gregorian + non-Gregorian fixture)
  fileSystem       TestFileSystem (in-memory or temp root)
  diskCapacity     settable
  database         TestDatabase (GRDB in-memory or temp file)
  userDefaults     ephemeral suite
  notificationCenter  spy
```

No probe may call `Date()`, `Calendar.current`, `FileManager.default`, or `UserDefaults.standard` directly. A source scan and a review checklist enforce this.

### 13.3 Fixture tiers

| Fixture | Contents | Used for |
|---|---|---|
| Empty | No books, no state | Fresh store, bootstrap, all-clear |
| Minimal | 1 book, 1 session, 2 timings | Fast probes, repairs |
| Reference | 7 books, 292 sessions, 138,459 timings | Realistic SQL/probe budget |
| 10× | 70 books, 2,920 sessions, 1.38M timings | Performance gate |
| Corrupt payload | One book/state row invalid | Fail-closed load, recovery UX |
| Corrupt timings | Negative, orphan, future, out-of-range | SQL probes, repairs |
| Corrupt backup | Truncated SQLite, bad header | Restore drill failure |
| Missing files | Bookmarks resolve nil, files moved | File probes, relink |
| Subsystem rot | Bad weather/audio/behavior/Mirage fixtures | Report-only probes |
| Legacy journal | v1 JSONL with findings/cycles | Migration/replay |
| Demo overdrive | Rapid profile swaps | Bridge/quiescence |

### 13.4 Probe contract tests

Every probe gets four tests:

1. **Positive:** a fixture that violates the invariant produces exactly one finding with the expected fingerprint.
2. **Negative:** a clean fixture produces zero findings.
3. **Boundary:** the threshold edge (24 h − 1 s vs 24 h + 1 s; 200 MB vs 199 MB).
4. **Failure:** a missing/unreadable source produces `skipped`/`failed`, not `clean`.

Plus:

- Determinism: same snapshot + environment → identical findings, twice.
- Cost: probe runs within its tier budget on the reference fixture.
- Privacy: safe evidence contains no forbidden text (scan).
- Fingerprint stability: reordering subjects does not change the fingerprint; count/time changes do not change it.

### 13.5 Repair tests

For every repair:

- **Happy path:** precondition → apply → verify → resolved; state matches expected.
- **Verification failure:** inject a probe that still reports → rollback; state byte-equal to before.
- **Precondition changed:** generation/subject changed → skipped; no mutation.
- **Snapshot failure:** no mutation; stalled.
- **Double apply:** second attempt is idempotent or skipped.
- **Quiescence:** active session/reader blocks the repair.
- **Undo:** restores exact before state; original probe returns pre-repair result.
- **Concurrent mutation:** a save during apply is detected; rollback or retry, never a torn write.
- **Privacy:** repair record contains no user text.

### 13.6 Security pins (named tests)

| Test | Proves |
|---|---|
| `writeScopeIsConfined` | Only `Sentinel/` paths written |
| `writabilityProbeCreatesNoFile` | No v1 `.sentinel-write-test` |
| `killSwitchIsInert` | Off means no timer, probes, journal, or repairs |
| `snapshotRequiredForMutation` | No snapshot → no mutation |
| `verificationFailureRollsBack` | Failed verify restores exact state |
| `undoRestoresByteEqualState` | Undo is exact |
| `journalHasNoUserText` | Titles/notes/paths never journaled |
| `diagnosticsExportIsRedacted` | Export contains no Class Debug |
| `symlinkWriteRejected` | No write through symlink |
| `mirageStratumUntouched` | Bytes identical across Sentinel cycles |
| `testRootNeverProduction` | No production path in test process |
| `releaseAutonomyDefaults` | Release migrates to A2/A1 correctly |
| `journalPartialLineRecovered` | Crash tail does not crash replay |
| `issueStoreCorruptionRebuilds` | State quarantine + replay |

### 13.7 UI and accessibility tests

- Launch card states: fixed, stalled, all-clear, unknown, degraded.
- Review opens the Health Center in Release, not the console.
- Issue detail actions are keyboard-reachable; primary action is default.
- VoiceOver labels include status and action.
- Dynamic Type at largest size: no clipped text/buttons.
- Dark/light/high-contrast appearance.
- No title/path in notification preview.
- "All clear" is never shown when a required probe skipped.
- Menu bar states.

### 13.8 Performance tests

- Reference fixture: fast pass < 50 ms main, normal < 1 s, deep < 10 s.
- 10× fixture: fast pass constant, deep < 15 s.
- SQL probes: `EXPLAIN QUERY PLAN` shows index use; no full scan of `page_times`.
- Journal append: < 5 ms per cycle at 10 MB segment; rotation < 100 ms.
- Memory: < 20 MB peak, no retained page-timing rows.
- No main-thread file I/O: instrument with `Thread.isMainThread` assertions in Debug.

### 13.9 Chaos and fault injection

- Kill the app mid-repair; on relaunch, no partial mutation and a clear recovery state.
- Kill during journal append; partial line ignored.
- Corrupt `issues.json`; rebuild from journal.
- Make the data root read-only; probes degrade, no crash.
- Fill the disk; no snapshot, no repair, critical issue.
- Flip the system clock backward/forward; age-based repairs pause, clock issue.
- Remove the DB while the app runs; probes report unavailable, no crash.
- Replace a backup with garbage; drill fails, issue raised.
- Sleep/wake during a cycle; cycle cancels cleanly.
- Swap demo profiles during a cycle; bridge pauses, no findings.

### 13.10 Test isolation

- All Sentinel tests use an isolated data root (`RuntimeEnvironment.isolatedStoreDirectory` or explicit temp URLs).
- No test writes the real `Application Support/Asterisma/` path.
- `scripts/verify-test-isolation.sh` checksums the real data root before/after the unit census; any change fails.
- The shared `SentinelEngine.shared` is not used in tests; engines are injected.
- `SentinelDataBridge` is reset between suites.

### 13.11 Manual owner scenarios

1. Launch with a healthy library: all-clear card, honest check count.
2. Launch with a corrupt book row: degraded recovery screen; no data overwritten; restore option.
3. Crash mid-session, relaunch after 2 days: orphan issue, fix closes at last page activity, undo restores.
4. Move a book file: missing-file issue, Locate works, progress preserved.
5. Corrupt the newest backup: critical issue, restore drill shows it, older backup selected.
6. Disable Sentinel: no timer, no journal, no probes; enable again: fast pass.
7. Snooze an issue: disappears from needs-decision, returns after snooze.
8. Undo a repair: original issue reappears; history shows both.
9. Run on a 10× synthetic library: UI remains responsive, deep pass completes within budget.
10. Turn on notifications, trigger a critical issue: one notification, quiet hours respected, no repeat.

### 13.12 Regression corpus

Every fixed data bug becomes a permanent fixture:

- crash-window duration (NEW-DE-3);
- duplicate achievements (audit #1);
- SQLite orphan session under-count (SENT-001);
- corrupt library-state row (2026-10-26 hardening);
- duplicate collection membership;
- phantom active id;
- negative timing;
- backup marker mismatch;
- corrupt behavior archive.

The probe suite must catch each fixture; the repair suite must fix it and verify.

---

## 14. Observability and developer experience

### 14.1 What Sentinel records about itself

Per cycle:

- cycle id, start/end, duration, trigger;
- snapshot generation, book/session/timing counts;
- probes planned/ran/skipped/failed/timed out, per-probe duration;
- findings normalized, issues opened/updated/resolved/regressed;
- repairs planned/started/committed/failed/rolled back;
- budget overruns;
- journal bytes written, segment id.

Per repair:

- full plan, snapshot hash, before/after hashes, verification result, rollback result, undo availability.

Per issue:

- lifecycle transitions with actor, timestamp, reason.

### 14.2 Developer Console upgrades

The Debug pane becomes a real Sentinel workbench:

```text
┌────────────────────────────────────────────────────────────────────┐
│ Sentinel Workbench                                                 │
│ [Probes] [Issues] [Repairs] [Journal] [Fixtures] [Performance]      │
│ ────────────────────────────────────────────────────────────────── │
│ Probe matrix                                                       │
│ ID       Tier  Last run  Duration  Result     Findings  Next due   │
│ LIB-001  T1    11:04:01  3 ms      clear      0         11:19      │
│ SES-004  T1    11:04:01  7 ms      1 issue    1         11:19      │
│ BAK-003  T3    yesterday 412 ms    fail       1         tomorrow   │
│ [Run selected] [Dry run] [Disable]                                 │
└────────────────────────────────────────────────────────────────────┘
```

Capabilities:

- Run one probe or one domain on demand.
- Dry-run a repair: plan + preview + verification, no mutation.
- Inject a fixture (corrupt row, missing file, low disk) into a *test* store only.
- Inspect a fingerprint and its evidence.
- View the raw safe journal and the Debug stream.
- See cycle duration, probe timings, and budget status.
- Export a diagnostics bundle.
- Toggle shadow mode and compare v1/v2 findings.

### 14.3 Diagnostics bundle

```text
Sentinel-diagnostics-2026-10-26.zip
  manifest.json            app version, OS, cycle ids, counts, hashes
  health.json              current band, domain bands, coverage
  issues.json              open + recent issues, safe evidence only
  repairs.json             repair receipts, no paths
  journal-safe.jsonl       safe journal tail (last 30 days, redacted)
  checks.json              probe catalog, last run, duration, outcome
  config.json              autonomy/cadence, no personal data
  README.txt               what is included, what is excluded
```

Excluded by default: debug stream, book titles, file paths, note text, locations, application names. The user can opt into "Include technical details" with a warning; the bundle is still local until the user shares it.

### 14.4 Shadow-mode instrumentation

During Phase 1–3:

- v1 and v2 run on the same snapshot.
- Compare: issue sets by normalized rule/fingerprint; counts; repair eligibility.
- Record `v2-only`, `v1-only`, `agree`, `fingerprint-collision`, `severity-diff`.
- Block promotion to actor mode until:
  - v2 covers every v1 rule;
  - no v1-only findings in the reference fixture suite;
  - no false auto-repair in fault injection.

### 14.5 Documentation as part of the system

- Every rule ID has a page in the future Sentinel rules directory with invariant, evidence, repair, verification, copy, and test.
- Every repair ID has a page with preconditions, API, rollback, and test.
- The Health Center "Technical details" links to the local doc anchor where possible (or shows the same content).
- The README's Sentinel section is generated from a small manifest, not hand-maintained.
- A docs-truth test checks that every rule in the registry has copy and docs, and every repair has a verification probe.

## 15. Rollout plan

### 15.1 Program shape

```text
SG0  Truth & guardrails
 │
SG1  Domain foundation (issues, fingerprints, journal v2, clock)
 │
SG2  Runtime + snapshot + probe v2 (port 8, add core coverage)
 │
SG3  Repair engine v2 (plan, verify, undo, rollback)
 │
SG4  Health Center (Release UX, report card, notifications)
 │
SG5  Data-system coverage (SQL, backups, files, subsystems)
 │
SG6  Intelligence (correlation, trends, capacity, coverage)
 │
SG7  Hardening & release (performance, chaos, accessibility, docs)
```

Each phase ends with a gate. The owner replies **APPROVE**, **APPROVE WITH CHANGES**, or **STOP**. No phase starts before the prior gate is accepted.

### 15.2 Phase 0 — Truth and guardrails

**Goal:** make the current Sentinel honest before building the new one.

**Deliverables:**

- Remove the duplicate launch cycle (`start()` + `runCycle()` in `NewContentView`).
- Make the Dev Console probe count derive from the engine, not `8`.
- Fix or remove the dead `#if DEBUG` branch in `isEnabled`.
- Implement the report card's promised Review action or remove the claim.
- Remove `.sentinel-write-test` from the data root; use a memory/temp probe or an explicitly allowed `Sentinel/` file.
- Fix the `markFixed` first-only bug (mark all matching findings).
- Stop writing book titles into the journal; separate safe summary from debug detail.
- Make `lifetime` counters either truly lifetime (persisted totals) or rename them.
- Add test isolation for the Sentinel journal; no real app-support writes.
- Add `SENTINEL-ROADWORK.md` and link it from README/roadmap.
- Add a "current coverage" table to README that matches the code (8 probes, 4 repairs, Debug-only pane).

**Exit gate SG0:**

- Unit census green (target 236+).
- `grep` proves no `.sentinel-write-test` path.
- `verify-test-isolation.sh` passes.
- Probe count matches the engine's actual registry.
- README Sentinel claims match the code.

**Estimate:** 1 session, 4–6 hours.

**Status (2026-10-28): executed.** Census **242/0/9**; 6 SG0 pins added; isolation byte-identical; Release compiles. Evidence: [gates/SG0.md](gates/SG0.md). The next action is owner review of that receipt before SG1 begins.

### 15.3 Phase 1 — Domain foundation

**Goal:** build the durable model before adding coverage.

**Deliverables:**

- `SentinelIssue`, `SentinelEvidence`, `SentinelFingerprint`, `SentinelRuleID`, lifecycle enum.
- `SentinelClock`, `SentinelEnvironment`, `TestClock`.
- `SentinelIssueStore` with atomic writes and journal replay.
- `SentinelJournalV2` with segments, safe/debug split, checksums, migration from v1.
- `SentinelConfiguration` with autonomy levels and migration from the three existing keys.
- `SentinelHealthModel` and `SentinelCoverage`.
- Copy template registry for the existing 12 rule codes.
- Shadow runner that can execute v1 probes and normalize their output into v2 issues without mutating.

**Tests:**

- Fingerprint stability and collision resistance.
- Lifecycle transitions (every legal and illegal edge).
- Journal replay → identical issue set.
- Legacy journal migration.
- Config migration (false→A1, true→A3).
- Copy exists for every rule.
- Issue store crash safety (kill between temp and rename).

**Exit gate SG1:**

- New domain tests ≥ 25, all green.
- Shadow run on the reference fixture: v1 findings map 1:1 to v2 issues (except duplicates, which collapse).
- No production behavior change; v1 still acts.

**Estimate:** 2 sessions, 8–12 hours.

### 15.4 Phase 2 — Runtime, snapshot, and probe v2

**Goal:** replace the main-actor synchronous cycle with a bounded, isolated runtime.

**Deliverables:**

- `SentinelRuntime` actor, cycle lock, heartbeat, budget, cancellation.
- `SentinelScheduler` with launch/fast/normal/deep/maintenance cadence and sleep/wake.
- `SentinelSnapshot` with generation, immutable books/state, SQL handle, file manifest.
- `SentinelDataBridgeV2` with typed source registration; keep the old bridge during shadow.
- Probe protocol v2, descriptor, timeout isolation, skip/failed states.
- Port the 8 v1 probes to v2.
- Add core LIB/SES probes: duplicate ids, phantom active id, page ranges, timings, overlap, future timestamps.
- Coverage report and `SELF-003`/`SELF-004` self-probes.
- Probe matrix in the Debug console.

**Tests:**

- Cycle lock prevents overlap.
- One slow probe times out; the rest complete.
- Snapshot generation change aborts safely.
- Fast pass main time < 50 ms on the reference fixture.
- Every ported probe has positive/negative/boundary/failure tests.
- Sleep/wake scheduling simulation.

**Exit gate SG2:**

- 25+ probes registered in this phase (program target: 700+), 20+ exercised by fixtures.
- Fast pass budget met; no main-thread file I/O.
- Coverage report correct when a probe is skipped.
- Shadow v1/v2 parity for all v1 rules.

**Estimate:** 2–3 sessions, 12–18 hours.

### 15.5 Phase 3 — Repair engine v2

**Goal:** make every mutation planned, verified, reversible, and quiet.

**Deliverables:**

- `SentinelRepairPlan`, `RepairAction`, `RepairRegistry`, `RepairExecutor`.
- Quiescence gate, generation check, re-read, snapshot verification.
- `SentinelVerifier` with per-rule probe mapping.
- `SentinelRepairRecord`, undo handles, repair receipts.
- R1 ports: orphan session (SQL-aware), phantom id, negative timing, dedupe collections, negative session end, page clamps, orphan timings.
- R2: relink book, quarantine orphan cover.
- Dry-run mode and preview payloads.
- Global pause on rollback failure.

**Tests:**

- Happy path, verification failure, rollback, double apply, quiescence, snapshot failure.
- SQLite orphan repair uses real last activity (the SENT-001 regression).
- Undo restores byte-equal affected records.
- No repair without a snapshot.
- Repair receipts contain no user text.

**Exit gate SG3:**

- 12+ repair plans, 8+ R1 verified.
- Fault injection: 0 false auto-fixes; 100% rollback on forced verification failure.
- Undo works for every R1.
- Active reading blocks every repair.

**Estimate:** 2–3 sessions, 12–18 hours.

### 15.6 Phase 4 — Health Center

**Goal:** give Release users a real surface.

**Deliverables:**

- Health Center window: Overview, Issues, History, Checks, Settings.
- Issue detail with what/why/now/what-if, evidence disclosure, actions.
- Launch card states (fixed, needs decision, all clear, unknown, degraded).
- Review opens the Health Center in Release.
- Menu bar extra (opt-in).
- Notification policy + permission flow.
- Settings autonomy levels, cadence, quiet hours, domains, data controls.
- Accessibility pass, localization keys, copy deck for all current rules.
- View model + snapshot updates; no probing from views.

**Tests:**

- Card states, Review routing, all-clear honesty.
- Issue actions (fix, snooze, acknowledge, ignore, undo).
- Release-mode autonomy defaults.
- Dynamic Type, VoiceOver labels, keyboard navigation.
- No user text in notification preview.
- Health Center empty/unknown/degraded states.

**Exit gate SG4:**

- A Release build can: see health, review issues, read an explanation, fix an R1, undo it, and see history.
- No Debug-only path is referenced by Release copy.
- Accessibility checklist complete.
- Owner can complete the five questions in §3.5 in under 30 seconds.

**Estimate:** 2–3 sessions, 12–18 hours.

### 15.7 Phase 5 — Data-system coverage

**Goal:** sentinel the whole app, especially SQLite and backups.

**Deliverables:**

- SQL probes: integrity, foreign keys, payload/row counts, orphan rows, WAL, schema, growth.
- Backup probes: freshness, open check, restore drill, marker consistency, size anomaly.
- File probes: missing files, bookmarks, orphan/corrupt covers, permissions, duplicates.
- Weather, audio, behavior, Mirage, app-state probes.
- Repairs: checkpoint WAL, orphan rows (R3), quarantine behavior archive, prune profiles, relink, covers, rebuild state root.
- `total_pages` decision (migration or bounded payload decode).
- 10× benchmark fixture and performance gate.

**Tests:**

- SQL probes on reference + 10× fixtures; `EXPLAIN QUERY PLAN` assertions.
- Restore drill success and failure fixtures.
- Missing-file and relink flow.
- Orphan row repair with backup/rollback.
- Subsystem probes are report-only and never mutate.
- 10× fast pass constant, deep pass within budget.

**Exit gate SG5:**

- 60+ probes and 25+ repairs in the first coverage wave (program target: 700+ / 350+).
- SENT-001 regression passes: orphan close at real last activity.
- Backup drill passes on a real/reference backup and correctly fails on a truncated one.
- No probe holds a write transaction or writes user data.
- 10× performance gate met.

**Estimate:** 3–4 sessions, 18–26 hours.

### 15.8 Phase 6 — Intelligence

**Goal:** turn a list into a diagnosis.

**Deliverables:**

- Root-cause correlation by subject, subsystem, and time window.
- "What changed since last check" diff.
- Health bands with coverage honesty.
- Trends: first seen, last seen, occurrence, severity trend, regression.
- Capacity projection (disk, library, backups).
- Shadow parity report and false-positive review.
- Rule confidence tuning from fixtures, not guesswork.

**Tests:**

- Correlation fixtures (low disk → backup fail → save degraded).
- Band calculation with critical/unknown/watch.
- Regression/ack/snooze transitions across relaunch.
- Trend math with injected clock.
- No duplicate issues after 100 cycles.

**Exit gate SG6:**

- One persistent condition = one issue after 100 simulated cycles.
- A three-issue cascade groups into one diagnosis with three evidence items.
- Unknown coverage never shows clear.
- Health band matches the fixture matrix.

**Estimate:** 2 sessions, 8–12 hours.

### 15.9 Phase 7 — Hardening and release

**Goal:** make it shippable and keep it honest.

**Deliverables:**

- Chaos suite (kill mid-repair, corrupt state, read-only root, disk full, clock skew).
- Accessibility + localization complete.
- Performance at 10× and pathological fixtures.
- Diagnostics export + redaction.
- Docs generated/checked from the rule/repair registry.
- Remove v1 engine, legacy journal writer, and dead settings keys after migration.
- Default autonomy decision and onboarding copy.
- Release package + README update.

**Tests:**

- Full unit census + new UI tests.
- Isolation checksum.
- Security pins all green.
- 24-hour soak with no leak/growth.
- Manual owner scenarios 1–10.

**Exit gate SG7:**

- All gates SG0–SG6 receipts attached.
- 400+ Sentinel tests for the first tranche (2,000+ at full scale), 0 failures, 0 real-data writes.
- No known P0/P1 Sentinel defect.
- Owner accepts the Health Center and default autonomy.
- README/roadmap/this document match the shipped behavior.

**Estimate:** 2 sessions, 8–12 hours.

### 15.10 Total estimate

| Phase | Sessions | Hours | Risk |
|---|---:|---:|---|
| 0 Truth | 1 | 4–6 | Low |
| 1 Domain | 2 | 8–12 | Medium |
| 2 Runtime | 2–3 | 12–18 | High (concurrency) |
| 3 Repair | 2–3 | 12–18 | High (data safety) |
| 4 UX | 2–3 | 12–18 | Medium |
| 5 Coverage | 3–4 | 18–26 | High (SQLite/backups) |
| 6 Intelligence | 2 | 8–12 | Medium |
| 7 Hardening | 2 | 8–12 | Medium |
| **Spine + first tranche** | **16–20** | **82–122** | |
| **Full target (700+ probes / 120 domains / 350+ repairs)** | **120–180** | **600–900** | Multi-quarter |

The 16–20 sessions deliver the runtime, the Health Center, and the first 138 probes / 36 repairs. Reaching the full **700+ / 120 / 350+** target is a scale-up program of roughly six coverage waves and four repair waves: **120–180 sessions, 600–900 hours**. The architecture is designed so those waves add registry entries, tests, and copy — not new engine code.

### 15.10a Scale-up model for 700+ probes / 120 domains / 350+ repairs

| Unit | Adds | Cumulative (probes / repairs / subdomains) |
|---|---|---|
| First tranche (this plan) | 138 probes, 36 repairs, 15 shipped subdomains | 138 / 36 / 15 |
| W1 — Completeness | 94 probes, 17 subdomains | 232 / 36 / 32 |
| W2 — Consistency | 94 probes, 18 subdomains | 326 / 36 / 50 |
| W3 — Temporal & lifecycle | 94 probes, 16 subdomains | 420 / 36 / 66 |
| W4 — Subsystem depth | 94 probes, 19 subdomains | 514 / 36 / 85 |
| W5 — Degraded & adversarial | 93 probes, 17 subdomains | 607 / 36 / 102 |
| W6 — Scale, recovery & meta | 93 probes, 18 subdomains | 700 / 36 / 120 |
| 4 repair waves | ~80 plans each, every one verified and undoable | 700 / 356 / 120 |
| Test expansion | Four contract tests per probe plus domain, security, and repair tests | 2,000+ Sentinel tests |

The arithmetic is exact, not approximate: **138 + 562 = 700 probes**, **15 + 105 = 120 subdomains**, and **36 + 320 = 356 repair plans**.

The per-wave probe count is a **budget**, not an effort estimate. A wave that cannot meet its budget splits into two gates rather than borrowing from the next wave, and a wave that finishes under budget does not get to invent work to spend it. §8.11 names every subdomain, so "wave 4" can be scoped, staffed, and accepted without renegotiating what it means.

This is a multi-quarter program, not a weekend. Phase 0 and Phase 1 alone deliver a materially more honest Sentinel; Phase 4 delivers the user-visible transformation.

### 15.11 Rollback at every gate

- Each phase is behind a runtime flag; disabling it restores v1 behavior.
- The v2 journal is additive; v1 can ignore it.
- The issue store is rebuildable from the journal; deleting it loses only derived state.
- The repair executor is the only new mutation path; disabling it leaves the current four repairs available through v1.
- No phase changes the library schema until Phase 5, and any schema change is additive + reversible.

---

## 16. Success metrics and gates

### 16.1 Baseline vs target

| Metric | Baseline (2026-10-26) | Target | Measured by |
|---|---:|---:|---|
| Probe definitions | 8 | 700+ | Registry count |
| Domains | 3 | 120 | Registry |
| Rule IDs with copy + evidence | ~12 | 1000+ | Docs/registry check |
| Repair plans | 4 | 350+ | Registry |
| Repairs with verification | 0 | 350+ | Repair records |
| Repairs with undo | 0 | 350+ | Repair records |
| Release surfaces | 2 | 7 | Product review |
| Issue lifecycle states | 3 outcomes | 9 states | Domain tests |
| Duplicate findings per persistent issue/day | ~96 | 1 | 100-cycle simulation |
| Fast-pass main-thread time | unbounded | < 50 ms | Performance test |
| False auto-fixes | unknown | 0 | Fault injection |
| Rollback success on forced failure | n/a | 100% | Fault injection |
| Coverage reporting | none | per probe/cycle | Coverage report |
| Sentinel-specific tests | 8 | 400+ first tranche; 2,000+ full | Census |
| Real-app-support writes in tests | possible | 0 | Isolation checksum |
| Journal user-text leaks | possible | 0 | Privacy scan |
| Notifications per issue | n/a | ≤ 1 / 7 days | Policy test |
| Time to answer the five user questions | undefined | < 30 s | Owner test |

### 16.2 Gate receipts

Every gate produces a receipt file under `docs/plans/sentinel/gates/SG<number>.md` with:

- date, branch, commit;
- census numbers and `.xcresult` path;
- new tests and what they pin;
- performance numbers on the reference fixture;
- known deltas;
- rollback steps;
- owner decision.

### 16.3 Gate criteria (summary)

| Gate | Must be true |
|---|---|
| **SG0** | Current claims match code; no real-data test writes; no duplicate cycle; no `.sentinel-write-test` |
| **SG1** | Domain model, fingerprints, journal v2, config migration; shadow parity for v1 rules |
| **SG2** | Runtime actor, budgets, snapshot generation; 25+ probes delivered in this phase (program target: 700+); fast pass < 50 ms; no main I/O |
| **SG3** | Plan/verify/undo for 12+ repairs; 0 false auto-fixes; 100% rollback in fault injection |
| **SG4** | Release Health Center answers all five questions; no Debug-only Release paths; accessibility pass |
| **SG5** | 60+ probes and 25+ repairs in the Phase 5 slice (program target: 700+ / 350+); SQLite/backup/file coverage; SENT-001 regression; 10× gate |
| **SG6** | Dedupe 100 cycles; root-cause grouping; coverage-honest bands; trends |
| **SG7** | 400+ first-tranche tests (2,000+ at full scale); chaos; localization; diagnostics; v1 removed; owner acceptance |

### 16.4 Guardrail metrics (must never regress)

- **0** silent data overwrites caused by Sentinel.
- **0** mutations without a verified snapshot.
- **0** mutations without a verification probe.
- **0** user-text leaks in journal/diagnostics/notifications.
- **0** writes outside `Sentinel/`.
- **0** test writes to the real data root.
- **0** "all clear" claims with required probes skipped.
- **0** Release paths that require Debug.
- **< 1%** average CPU over 24 h.
- **< 20 MB** Sentinel-owned peak memory.
- **< 10 MB/month** safe journal growth.
- **≤ 1** notification per issue per week.

### 16.5 The 1000× scorecard

Do not collapse Sentinel quality into one number. If a single view is needed, use three independent axes and a hard gate:

```text
Better   = (rule coverage × lifecycle correctness × verification rate) / false-positive rate
Stronger = (domain coverage × repair coverage × rollback proof × privacy)
Easier   = (surfaces × actions × accessibility × time-to-understanding) / alarm fatigue
```

Each axis is reported separately. A high score on one cannot compensate for a zero on another. The target is the owner's current numbers on each axis — 1000+ rule codes, 700+ probes, 120 domains, 350+ repairs — with zero guardrail violations. "1000×" is the floor, not the finish line.

---

## 17. Risks and mitigations

| Risk | Likelihood | Impact | Mitigation | Trigger |
|---|---|---|---|---|
| Scope creep turns Sentinel into a second app | High | High | Gate-driven phases; non-goals; smallest useful probe set per phase | Phase exceeds estimate by 50% |
| Over-automation damages data | Low | Critical | R1-only auto, snapshot, verification, rollback, global pause | Any false auto-fix |
| False confidence ("all clear" when blind) | Medium | High | Coverage model, required probes, unknown band | Skipped probe shown as clear |
| Performance regression | Medium | High | Tiering, budgets, 10× fixture, off-main | Fast pass > 50 ms |
| Alarm fatigue | High | Medium | Dedupe, lifecycle, quiet hours, notification caps | > 1 notification/week |
| Privacy leak via debug detail | Medium | High | Safe/debug split, redaction tests | Any title/path in safe output |
| Swift 6/concurrency bugs | Medium | High | Actor, Sendable snapshots, no main I/O, stress tests | Data race/crash |
| SQLite complexity (payload vs rows) | High | High | Read-only probes, no reconciliation without evidence, backup/rollback | Count mismatch |
| Backup storage growth | Medium | Medium | Retention, undo-window separation, size budgets | Backups > 2× DB |
| Test brittleness | Medium | Medium | Deterministic harness, fixtures, no wall clock | Flaky suite |
| Documentation drift | High | Medium | Generated docs, registry checks, gate receipts | Docs/code mismatch |
| Maintenance burden | Medium | High | Small rule registry, shared probe helpers, one repair executor | New probe requires > 1 day |
| User ignores the Health Center | Medium | Medium | Launch card, menu bar opt-in, notifications opt-in, calm copy | No engagement after 30 days |
| Mirage boundary violation | Low | Critical | Report-only, source scan, byte-identity pin | Any write under `mirage/` |
| Disk-full during repair | Low | Critical | Preflight free space, no snapshot → no repair | Free < 2× DB |

### 17.1 Stop conditions

Pause the program and return to the owner if:

- any false automatic repair is observed;
- any rollback fails;
- any user data is altered without a repair record;
- fast pass exceeds 100 ms on the reference fixture;
- a required probe cannot run on a clean install;
- the Release Health Center cannot explain a critical state;
- the census has a failure that cannot be fixed without weakening a test.

### 17.2 What we will deliberately not do

- No cloud dashboard.
- No AI-generated explanations; copy is deterministic and local.
- No automatic book deletion or file moves.
- No repair of Mirage's stratum.
- No attempt to replace Time Machine.
- No "health score" that hides issues.
- No background daemon outside the app.
- No changing the library schema solely for Sentinel in Phases 0–4.

---

## 18. Open decisions for the owner

| ID | Decision | Options | Recommendation |
|---|---|---|---|
| D-001 | Release default autonomy | Observe / Assist / Auto-safe | **Assist** — suggest, user clicks |
| D-002 | Health Center form | Separate window / sidebar pane / both | **Window** + toolbar entry; pane later if space |
| D-003 | Menu bar default | On / Off | **Off**, opt-in; avoids clutter |
| D-004 | Notifications default | On / Off | **Off**, request on enable |
| D-005 | Health display | Band only / Band + numeric | **Band + reason**; numeric only in Developer Console |
| D-006 | Issue retention | 30 / 90 / 365 days | **90 days resolved**, open forever |
| D-007 | Undo window | 7 / 30 / 90 days | **30 days** |
| D-008 | Quarantine auto-prune | 7 / 30 / never | **30 days**, with manifest |
| D-009 | Diagnostics detail | Safe only / optional technical | **Safe by default**, technical opt-in with warning |
| D-010 | Localization timing | Phase 4 / Phase 7 | **Phase 4 keys, Phase 7 translations** |
| D-011 | `total_pages` column | Add in Phase 5 / keep payload decode | **Add in Phase 5** if migration is additive and reversible |
| D-012 | Auto-safe in Release | Never / opt-in advanced | **Opt-in advanced** after Phase 7 proof |
| D-013 | Sentinel state location | `Sentinel/` / root files | **`Sentinel/`**, migrate legacy journal |
| D-014 | Repair of normalized rows | Never / R3 manual | **R3 manual**, only with backup + audit |
| D-015 | Health Center during reading | Available / suppressed | **Suppressed** while reader open; menu bar optional |

---

## 19. Appendices

### A. Current inventory and line references

As of 2026-10-26 (line numbers will drift; symbols are canonical):

| Symbol | Location | Note |
|---|---|---|
| `SentinelEngine` | `Core/SentinelEngine.swift:90` | `@MainActor` singleton |
| `SentinelFinding` | `Core/SentinelEngine.swift:41` | No fingerprint/lifecycle |
| `runCycle` | `Core/SentinelEngine.swift:196` | Synchronous cycle |
| `repairIsAvailable` | `Core/SentinelEngine.swift:265` | 4 rules |
| `dispatchRepairs` | `Core/SentinelEngine.swift:279` | Multi-book pass |
| `markFixed` | `Core/SentinelEngine.swift:350` | First finding only |
| `appendJournal` | `Core/SentinelEngine.swift:365` | `try?` append |
| `rotateJournalIfLarge` | `Core/SentinelEngine.swift:389` | 500-line rewrite |
| `overnightReport` | `Core/SentinelEngine.swift:416` | "Console" copy |
| `IntegrityProbe` | `Core/SentinelEngine.swift:450` | Discards repaired books |
| `StoreWritabilityProbe` | `Core/SentinelEngine.swift:502` | `.sentinel-write-test` |
| `OrphanedActiveSessionProbe` | `Core/SentinelEngine.swift:528` | Duplicates B-4 |
| `SentinelDataBridge` | `Core/SentinelDataBridge.swift` | Weak store + mutation flag |
| `SentinelPaneView` | `Features/DeveloperConsole/SentinelPaneView.swift` | Debug-only |
| `probeCount` | `SentinelPaneView.swift:119` | Hardcoded 8 |
| `SentinelReportCardView` | `Features/DeveloperConsole/SentinelReportCardView.swift` | Dismiss only |
| `SentinelSettingsPane` | `Features/Goals/SettingsRootView.swift:454` | 3 controls |
| Launch wiring | `App/NewContentView.swift:775` | `start()` + `runCycle()` |
| SQLite load | `Core/DataStore3.swift:701` | Summary + fail-closed latch |
| SQLite schema | `Core/Storage/LibraryDatabase.swift` | GRDB schema |
| Backups | `Core/LibraryArchiveManager.swift:153` | JSON rotation |
| Cover store | `Core/CoverStore.swift` | Files + NSCache |
| Pins | `AsterismaV2.5Tests/Core/SentinelPinsTests.swift` | 6 + 2 |

### B. Traceability to existing documents

| Source | What it says | How this plan uses it |
|---|---|---|
| `README.md` §3.4 | 8 probes, S1–S7, Release monitor + report | Baseline and promise to fulfill |
| `docs/audits/11-completion-and-health-report-2026-10-24.md` | Data-safety stack is strong; Sentinel journal 53 KB; test gaps | Motivation for coverage/UX |
| `docs/audits/08-deep-audit.md` NEW-DE-3/13 | Crash-window inflation; quarantine unused; test hygiene | SENT-001, SENT-010, SENT-045 |
| `docs/registers/03-fix-log.md` P6/P6.5 | Doctrine, pins, two-faced pane | Preserve strengths |
| `docs/plans/bedrock/gates/GATE-G3C.md` | SQLite cutover, 138k timings | The blind spot |
| `docs/plans/bedrock/gates/GATE-G8.md` | Daily backup + pre-repair snapshot | Backup probes |
| `docs/method/07-testing-strategy.md` | Swift Testing, serialized suites, isolation | Test approach |
| `docs/12-owner-test-authority.md` | Owner overrides benchmarks | Gate model |

### C. Glossary

| Term | Meaning |
|---|---|
| **Probe** | A pure read that checks one invariant |
| **Finding** | A raw observation from a probe |
| **Issue** | A durable, deduplicated diagnosis with lifecycle |
| **Fingerprint** | Stable identity for an issue |
| **Evidence** | Typed facts supporting an issue |
| **Confidence** | How sure the detector is |
| **Impact** | What the user loses if the issue is real |
| **Repair plan** | Typed mutation with preconditions, apply, verify, undo |
| **Risk class** | R1/R2/R3 gating for automation |
| **Snapshot** | Verified copy of the active store before mutation |
| **Undo handle** | Data needed to restore affected records |
| **Coverage** | Which required probes ran, skipped, or failed |
| **Shadow mode** | v2 observes beside v1 without acting |
| **Quiescence** | No reader, session, mutation, or demo install in flight |
| **Safe detail** | Evidence/journal content with no user text |
| **Debug detail** | Identifiers/paths for development, never shared |

### D. Per-session execution checklist

Before a Sentinel session:

- [ ] `git status` clean or owned changes only.
- [ ] Unit census green; record the number.
- [ ] Read the current gate and the phase deliverables.
- [ ] Confirm no other agent is editing the same files.

During:

- [ ] One probe/repair at a time; one pin per defect. Use Appendix I; no ad-hoc descriptors.
- [ ] No `Date()`, `FileManager.default`, or `UserDefaults.standard` in probes.
- [ ] No user text in safe output.
- [ ] No writes outside `Sentinel/`.
- [ ] No release copy that points to Debug.

After:

- [ ] Focused tests + full unit census.
- [ ] Gate receipt with numbers and known deltas.
- [ ] Update rule/repair docs and README coverage.
- [ ] Leave the working tree in an explainable state.

### E. Gate receipt template

```text
# Gate SGx — <name>

Date:
Branch / commit:
Owner decision: APPROVE | APPROVE WITH CHANGES | STOP

## Delivered
- ...

## Verification
- Unit census: ___ passed / ___ skipped / ___ failed (___ total)
- Focused suites: ...
- Performance: fast pass ___ ms; deep ___ s; memory ___ MB
- Privacy scan: ...
- Isolation checksum: ...

## Known deltas
- ...

## Rollback
- ...

## Next phase
- ...
```

### F. Copy deck source of truth

The copy deck in §10.12 is illustrative. The shipped source of truth is the rule registry:

```text
SentinelRule
  id
  domain
  titleKey
  whatKey
  whyKey
  actionKey
  verificationProbeID
  repairIDs
  defaultSeverity
  defaultConfidence
  required
```

A docs-truth test asserts that every rule has all keys in the String Catalog and a matching entry in the future Sentinel rules directory.

### G. What to delete or rename in the current code

- Delete `.sentinel-write-test` behavior (SENT-010).
- Remove the dead `#if DEBUG` in `isEnabled` (SENT-025).
- Replace `probeCount = 8` with the registry count (SENT-024).
- Replace `markFixed` first-only semantics (SENT-005).
- Rename `lifetimeAutoFixed` / `lifetimeStalled` to `retainedJournalAutoFixed` / `retainedJournalStalled` until true lifetime totals exist (SENT-008).
- Remove the "Console" copy from Release report headlines (SENT-002).
- Stop journaling `debugDetail` (SENT-011).
- Replace `compactMap`-style "best effort" with explicit skipped/failed states (SENT-047).
- Move the existing journal to `Sentinel/legacy/` after migration.

### H. Final definition of 1000×

Sentinel 1000 is not "700 probes." It is a state where:

- a user trusts the shield because it has never lied about what it checked;
- a developer trusts it because every mutation has a plan, a proof, and an undo;
- a future session can add a probe without touching the engine, and add a repair without touching the UI;
- the app can be abandoned for a month and come back to an honest, actionable health report;
- the watchdog itself is monitored, tested, and quiet.

That is the standard this document sets.

### I. Probe and repair authoring recipe

The catalog says *what* to build; this appendix says *how* to build it so probe 200 looks like probe 10. Use it for every probe and repair after SG2. If a step does not apply, say why in the pull request rather than skipping it silently.

#### I.1 Before writing a line

Record these six decisions in the issue or PR description. They are cheap now and expensive later.

| Decision | Example | Wrong answer looks like |
|---|---|---|
| Invariant, one sentence | "A timing never starts before its session starts." | "Check timings" |
| Subdomain ID | `SES.2` | "sessions stuff" |
| Role and owner | `contributor`, owner `SES-002` | A second probe opening the same issue |
| Sources and privacy class | `SQLite`, `library-metadata` | Reading `UserDefaults` directly |
| Outcome | report-only, or `REP-xxx` | "Maybe fix it later" |
| Fixture tier | `corrupt`, `scale` | Only the happy-path demo library |

#### I.2 Probe recipe

| # | Step | Done when |
|---|---|---|
| 1 | State the invariant as a falsifiable sentence with a subject, predicate, and boundary | A reviewer can name one record that violates it |
| 2 | Assign the subdomain from §8.11 and check ownership | The registry shows no other owner for that invariant |
| 3 | Write the descriptor: `id`, `domain`, `titleKey`, `ruleVersion`, `role`, `ownerProbeID`, `rootCauseKey`, `tier`, `timeout`, `required`, `dependencies` | Registry validates with zero warnings |
| 4 | Pick the tier and measure the budget | p95 on the reference fixture is under half the tier budget |
| 5 | Build the fixture **before** the implementation | Four fixtures exist: violating, clean, boundary pair, unreadable source |
| 6 | Implement read-only against the snapshot and injected environment | No writes, no network, no `Date()`, no `UserDefaults.standard`, no `FileManager.default` |
| 7 | Emit `RawFinding`, never an issue | No `id`, `fingerprint`, `status`, `firstSeen`, or `occurrenceCount` is set |
| 8 | Write the tests: positive, negative, boundary, failure, determinism, cost, fingerprint stability | All seven pass in Debug and Release |
| 9 | Add safe evidence, copy keys, and the docs page | Privacy scan passes; every key exists; the page states false-positive cases |
| 10 | Register and run one full cycle | Coverage report marks the subdomain `checked`; cycle budget is unchanged |

#### I.3 Repair recipe

| # | Step | Done when |
|---|---|---|
| 1 | Name the rule(s) closed and the shared `rootCauseKey` | Every rule listed resolves to this plan; no orphan plan |
| 2 | Declare class and scope (R1/R2/R3; library, artifact, Sentinel) | The executor can enforce the scope from the plan alone |
| 3 | Write preconditions as re-readable predicates | A stale subject aborts before any mutation |
| 4 | Declare the snapshot and prove it opens | Read-only open + integrity check succeeds before apply |
| 5 | Apply only through the owning API | No direct file write, no SQL outside the store, no shell |
| 6 | Name the verification probe and its pass condition | Zero findings for the fingerprint, not "looks fixed" |
| 7 | Define the undo handle precisely | Field list, restore path, expiry, and post-restore verification |
| 8 | Write the receipt | Plan, before/after hashes, verification result, undo reference |
| 9 | Run five fault injections: apply-fail, verify-fail, crash-after-apply, double-apply, stale subject | Every one leaves state byte-equal or fully restored |
| 10 | Write the preview copy for R2/R3 | User can see exactly what changes and what does not |
| 11 | Write the docs page: what changes, what does not, when not to use it | A future session can refuse the repair correctly |
| 12 | Register and update the repair catalog | Registry test passes; catalog row and docs agree |

#### I.4 Definition of done

A probe is done when:

- [ ] Descriptor complete, `ruleVersion` starts at 1, `rootCauseKey` assigned.
- [ ] Exactly one owner; contributors name it; corroborators cannot open issues.
- [ ] Four contract tests, determinism, cost, and fingerprint-stability tests pass.
- [ ] Safe evidence contains no titles, paths, locations, or note text.
- [ ] Copy keys exist in the string catalog; the docs page exists and is linked.
- [ ] The probe is registered, appears in coverage, and stays inside its tier budget.

A repair is done when:

- [ ] Class, scope, preconditions, snapshot, apply API, verification probe, and undo handle are declared.
- [ ] Happy path and verification-failure path pass; rollback is byte-equal.
- [ ] Five fault injections pass, including double-apply and stale subject.
- [ ] Receipt is written and readable in History; undo is reachable from the receipt.
- [ ] Preview copy exists for R2/R3; the docs page exists.
- [ ] The repair is registered and every rule it closes names it.

#### I.5 Review rubric

| Dimension | Pass | Fail (send it back) |
|---|---|---|
| Ownership | One owner, named contributors | Two probes open the same invariant |
| Determinism | Same snapshot → same findings, twice | Uses `Date()`, random, or live network |
| Evidence | Typed, safe, re-readable | A message string assembled from user data |
| Privacy | Passes the scan | Title or path in `safeValue` |
| Budget | Under tier budget with headroom | Runs a full table scan on every cycle |
| Verification | Names a probe and a zero condition | "Verified manually" |
| Undo | Exact fields and a restore path | "Restore from backup" with no handle |
| Truth | Docs and copy match behavior | Copy promises a fix the plan cannot make |

#### I.6 Ten anti-patterns

1. **The counting probe.** Counts rows and calls it an invariant; it cannot name which row is wrong.
2. **The absence probe.** Treats "no evidence" as "healthy" instead of `skipped`.
3. **The twin owner.** A second probe that opens the same issue under a new rule ID.
4. **The screenshot repair.** Fixes the symptom the user sees while leaving the root cause.
5. **The optimistic verify.** Re-reads through a cache that still holds the old value.
6. **The unbounded undo.** "Restore the database" with no record of which rows changed.
7. **The title in the safe field.** Any user text that reaches the journal or diagnostics.
8. **The threshold without a boundary test.** 24 h exactly is where the bugs live.
9. **The direct default read.** `UserDefaults.standard` inside a probe, bypassing the injected environment.
10. **The orphan rule.** Copy and docs ship, but no probe emits it, so it can never fire.

### J. Defect closure matrix

Every SENT defect from §2.7 maps to a closing gate, the probe(s) that must detect it, the repair that fixes it (or `—` where a data probe cannot see it), and the regression pin that proves it stays closed. **Pin names are target suites; none of the new ones exist yet.** A defect is closed only when its pin runs in the census.

Phase → gate: 0 → SG0, 1 → SG1, 2 → SG2, 3 → SG3, 4 → SG4, 5 → SG5, 6 → SG6, 7 → SG7.

| ID | Defect | Closes at | Owner / detecting probe(s) | Repair | Regression pin |
|---|---|---|---|---|---|
| SENT-001 | SQLite summary hides timings | SG5 | SES-015, SES-016, SES-018, SQL-003, SQL-007 | REP-001, REP-005 | `SQLiteSummaryTimingTests` |
| SENT-002 | Release points at Debug console | SG4 | — (surface + copy) | — | `ReleaseSurfaceTests` |
| SENT-003 | No recovery path for load latch | SG3 | SQL-007, SQL-013, LIB-013 | REP-026, REP-027 | `FailClosedRecoveryTests` |
| SENT-004 | No post-repair verification | SG3 | plan's `verificationProbeID` | REP-036 | `RepairVerificationTests` |
| SENT-005 | `markFixed` first finding only | SG1 | SES-004 | REP-001 | `MultiSubjectRepairTests` |
| SENT-006 | Validator repairs discarded | SG2 | LIB-003, LIB-004 | — | `IntegrityProbeTests` |
| SENT-007 | No fingerprint or dedupe | SG1 | — (diagnoser) | — | `FingerprintStabilityTests` |
| SENT-008 | Lifetime counters truncate | SG1 | — (metrics) | — | `CounterRetentionTests` |
| SENT-009 | Journal append not crash-safe | SG1 | SELF-001 | REP-018 | `JournalCrashTests` |
| SENT-010 | Writability probe out of scope | SG1 | SEC-002 | — | `WriteConfinementTests` |
| SENT-011 | Journal contains user text | SG1 | SEC-001, SEC-004 | — | `PrivacyScanTests` |
| SENT-012 | Synchronous main-thread cycle | SG2 | SELF-003 | — | `MainActorBudgetTests` |
| SENT-013 | Two cycles on launch | SG0 | SELF-003 | — | `SingleCycleLaunchTests` |
| SENT-014 | Static timer-only scheduling | SG2 | SELF-003 | — | `SchedulerLifecycleTests` |
| SENT-015 | No persisted issues | SG1 | SELF-002 | REP-034 | `IssueStoreTests` |
| SENT-016 | No user actions | SG4 | — (UI) | — | `HealthCenterActionTests` |
| SENT-017 | No repair record or undo | SG3 | BAK-008, BAK-009 | REP-036 | `RepairReceiptTests` |
| SENT-018 | Backup failures invisible | SG5 | BAK-001, BAK-003 | REP-027 | `BackupFailureTests` |
| SENT-019 | No DB integrity probes | SG5 | SQL-001, SQL-002, SQL-005 | REP-015, REP-017 | `DatabaseIntegrityTests` |
| SENT-020 | No asset or file probes | SG5 | FILE-001 … FILE-012 | REP-012, REP-013, REP-014 | `AssetProbeTests` |
| SENT-021 | No derived-data probes | SG5 | LIB-010, LIB-015, SES-014, SES-018 | REP-022, REP-029 | `DerivedDataTests` |
| SENT-022 | No subsystem probes | SG5 | WX-001…007, AUD-001…005, BHV-001…005, MIR-001…008 | REP-020, REP-021, REP-023 | `SubsystemProbeTests` |
| SENT-023 | No Sentinel self-health | SG6 | SELF-001 … SELF-010 | REP-034, REP-035 | `SentinelSelfHealthTests` |
| SENT-024 | `probeCount` hardcoded | SG0 | SELF-008 | — | `RegistryCountTests` |
| SENT-025 | Release repair gate untested | SG1 | — (release gate) | — | `ReleaseRepairGateTests` |
| SENT-026 | Report card "Review" unimplemented | SG4 | — (UI) | — | `ReportCardRoutingTests` |
| SENT-027 | Settings too thin | SG4 | — (UI) | — | `SettingsCoverageTests` |
| SENT-028 | Plain-English lacks why/action | SG4 | — (copy) | — | `CopyDeckTests` |
| SENT-029 | Accessibility/localization gaps | SG7 | — (UI) | — | `AccessibilitySnapshotTests` |
| SENT-030 | Dev Console lacks history/matrix | SG6 | SELF-008 | — | `DevConsoleHistoryTests` |
| SENT-031 | `Date()` in probes | SG2 | — (determinism) | — | `ProbeDeterminismTests` |
| SENT-032 | Disk threshold is a constant | SG2 | CAP-001 | — | `DiskThresholdTests` |
| SENT-033 | Bookmark probe runs every cycle | SG5 | FILE-002, FILE-007 | REP-012 | `BookmarkCostTests` |
| SENT-034 | Informational findings treated as stalled | SG1 | GOL-007 | — | `SeveritySemanticsTests` |
| SENT-035 | Duplicate orphan findings | SG1 | SES-004, SES-020 | REP-001 | `OverlapArbitrationTests` |
| SENT-036 | Deadline repeats forever | SG2 | GOL-007 | — | `DeadlineLifecycleTests` |
| SENT-037 | Hand-built JSON summary line | SG1 | SELF-001 | — | `JournalEnvelopeTests` |
| SENT-038 | No journal writer lock | SG1 | SELF-001 | — | `JournalLockTests` |
| SENT-039 | Bridge is last-attach-wins | SG2 | — (isolation) | — | `BridgeIsolationTests` |
| SENT-040 | No store generation | SG2 | — (generation) | — | `StoreGenerationTests` |
| SENT-041 | No diagnostics export | SG6 | SEC-004 | — | `DiagnosticsRedactionTests` |
| SENT-042 | README/Settings overstate coverage | SG0 | SELF-008 | — | `CoverageTruthTests` |
| SENT-043 | Journal failure is silent | SG1 | SELF-001 | — | `JournalFailureTests` |
| SENT-044 | No rate limiting or quiet hours | SG2 | — (policy) | — | `NotificationPolicyTests` |
| SENT-045 | Test gaps | SG7 | all of the above | — | `SentinelCensusTests` |
| SENT-046 | `Calendar.current` semantics | SG2 | GOL-007 | — | `CalendarSemanticsTests` |
| SENT-047 | No coverage metric | SG6 | SELF-008 | — | `CoverageReportTests` |
| SENT-048 | No reset or export controls | SG4 | SELF-006 | REP-035 | `ResetStateTests` |

Ten rows have no data probe, deliberately. **SENT-002, SENT-016, SENT-026** are surface and copy defects, caught by Release-mode UI tests. **SENT-007, SENT-008, SENT-031, SENT-039, SENT-040, SENT-044** are diagnoser, determinism, isolation, or policy defects, caught by their named suites. **SENT-025** is a release-gate defect. A launch card that points at a Debug console cannot be detected by a probe, and inventing one to fill the cell would be theater. The pin is the proof.

---

*End of Sentinel Roadwork.*
