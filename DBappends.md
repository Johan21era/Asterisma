# Library Safety

**Database Recovery + Sentinel Integration — Technical Implementation Plan**

| Field | Value |
|---|---|
| **Status** | Implemented (code + tests); owner acceptance pending |
| **Owner** | Engineering |
| **Date** | 2026-10-28 |
| **Baseline commit** | `29dd4f6` |
| **Baseline tests** | 432 tests · 671 runs · 9 skipped · 0 failed |
| **Baseline Sentinel** | 140 probes · 15 domains · 25 repairs · 162 `@Test` functions in Sentinel-named test files |
| **Scope** | macOS app, SQLite library, existing Sentinel v2, new Library Recovery subsystem |
| **Out of scope** | Automatic structural repair, automatic data deletion, privacy-leak detection, cloud backup, iOS |

> **Reading rule.** This document separates *observed baseline facts*, *design decisions*, and *work to be done*. If a statement is not backed by the current tree or by a test described here, it is a proposal, not a claim.

---

## Table of contents

- [0. Decision summary](#0-decision-summary)
- [1. Why this exists](#1-why-this-exists)
- [2. Current-state audit](#2-current-state-audit)
- [3. Invariants and permanent refusals](#3-invariants-and-permanent-refusals)
- [4. Architecture](#4-architecture)
- [5. Domain model](#5-domain-model)
- [6. Contracts and interfaces](#6-contracts-and-interfaces)
- [7. File and module layout](#7-file-and-module-layout)
- [8. Storage layout and schemas](#8-storage-layout-and-schemas)
- [9. Backup subsystem](#9-backup-subsystem)
- [10. Incident detection and freeze](#10-incident-detection-and-freeze)
- [11. Recovery options](#11-recovery-options)
- [12. Restore and swap algorithm](#12-restore-and-swap-algorithm)
- [13. Salvage and rebuild](#13-salvage-and-rebuild)
- [14. Row-level repairs](#14-row-level-repairs)
- [15. Sentinel integration](#15-sentinel-integration)
- [16. Health Center UX](#16-health-center-ux)
- [17. Configuration and autonomy](#17-configuration-and-autonomy)
- [18. Concurrency, durability, and crash safety](#18-concurrency-durability-and-crash-safety)
- [19. Security and privacy](#19-security-and-privacy)
- [20. Testing strategy](#20-testing-strategy)
- [21. Rollout plan](#21-rollout-plan)
- [22. Documentation and operations](#22-documentation-and-operations)
- [23. Risks](#23-risks)
- [24. Open decisions](#24-open-decisions)
- [25. Appendices](#25-appendices)

---

## 0. Decision summary

### 0.1 The one-sentence plan

**Build a local, copy-first Library Recovery subsystem that preserves the damaged store, diagnoses a copy, offers explicit recovery options with data-loss accounting, executes only after user confirmation, verifies independently, and lets Sentinel detect, freeze, explain, and verify — but never perform structural surgery itself.**

### 0.2 What is built

1. **Library Safety coordinator** — an app-level state machine that owns incident sequencing between `DataStore`, Sentinel, and Library Recovery.
2. **Library Recovery subsystem** — file preservation, consistent snapshots, backup manifests, backup verification, read-only diagnosis, export, restore, conservative salvage, logical rebuild, receipts, and crash recovery.
3. **Sentinel integration** — promotion of specific findings into incidents, suspension of probes and repairs while the store is frozen, post-recovery verification, journal entries, diagnostics, and a Recovery surface in the Health Center.
4. **Row-level repair path** — orphan-row inventory, export, deletion, and undo through Library Recovery; Sentinel proposes, Recovery executes.
5. **Safety corrections to the existing code** — a truly consistent backup, one SQLite writer, no second connection from the repair bridge, and a published storage condition.
6. **Deferred, gated work** — file-level undo, automatic maintenance, row-level orphan repair, and an explicit opt-in last-resort policy. Each is scoped, but not allowed to ship before its gate.

### 0.3 What is explicitly not built

These are permanent design refusals, not backlog items:

- No automatic restore that chooses a backup and overwrites newer data.
- No automatic rebuild after a failed integrity check.
- No automatic deletion of unreadable rows, orphan rows, or “orphan” files.
- No structural file swap inside `SentinelRepairExecutor` or `SentinelRepairAction`.
- No claim that a file swap is undoable when only row payloads are versioned.
- No Sentinel mutation of a suspect store while an incident is open.
- No “privacy leak repair” in the database subsystem.
- No automatic merge of duplicate books.
- No in-place `VACUUM` of the live database as a background repair.

Section 3 records the rationale and the replacements for each refused idea. Section 21 places the deferred work behind gates.

### 0.4 What is staged but committed

These are not rejected. They are real capabilities that must be built later, after the safety substrate exists:

| Capability | Earliest phase | Gate |
|---|---|---|
| Consistent backup + manifest + verification | Phase 0 / 3 | G0, G3 |
| Read-only incident mode + export | Phase 2 | G2 |
| Assisted restore from a verified backup | Phase 4 | G4 |
| Conservative salvage and logical rebuild | Phase 5 | G5 |
| Row-level orphan inventory + repair | Phase 5 | G5 |
| Sentinel suspension + post-recovery verification | Phase 6 | G6 |
| File-level undo with versioned stores | Phase 7 | G7 |
| Automatic maintenance (checkpoint, rotation) | Phase 7 | G7 |
| Explicit opt-in last-resort restore policy | Phase 7 (decision required) | G7 + owner sign-off |
| 10× SQLite benchmark and accessibility pass | Phase 7 | G7 |

### 0.5 Definition of done

The plan is complete only when all of the following are true:

- A corrupt store can be detected, frozen, preserved, diagnosed, exported, and restored from a verified backup without mutating the original before confirmation.
- A failed restore rolls back to the exact pre-recovery file, or enters a clearly reported critical state without pretending success.
- Every recovery option reports what will be recovered and what will be lost before execution.
- Every executed recovery produces a receipt with before/after hashes, row counts, integrity results, and an outcome.
- Sentinel stops all probes, repairs, and auto-safe actions while an incident is open, and verifies the reopened store before closing the incident.
- The original store is never deleted automatically.
- The real App Support tree is byte-identical after the test suite.
- The owner acceptance scenarios in Appendix G pass on a copy of the real library.
- The 10× fixture and accessibility checks pass, or the limitation is recorded explicitly.

---

## 1. Why this exists

### 1.1 The failure being solved

The app’s library is a SQLite database plus external files:

```text
library.grdb.sqlite3
library.grdb.sqlite3-wal
library.grdb.sqlite3-shm
Backups/library-*.sqlite3
covers/
Sentinel/
Mirage runtime state
```

The database stores books, sessions, page timings, library state, collections, notes, achievements, weather, audio profiles, behavior events, application sessions, inactivity records, device state, and metadata. The `books.payload_json` column is the app’s parity source of truth for a book summary; `sessions.payload_json` and `page_times.payload_json` carry the normalized row payloads.

A damaged file can present in several distinct ways:

1. **The file cannot be opened.** SQLite header, page size, or locking failure.
2. **The file opens but fails structural checks.** `PRAGMA integrity_check` reports b-tree, index, or page errors.
3. **The file is structurally valid but semantically broken.** Orphan foreign keys, duplicate IDs, count mismatches, undecodable JSON.
4. **The file is valid but the app cannot load a row.** `DataStore` fails closed on an undecodable book or state row.
5. **The file is valid but unbackupable.** Disk full, permissions, or a stale WAL.
6. **A repair or migration is interrupted.** A swap, restore, or schema migration leaves a partial state.

These are not one problem. They need different tools, different evidence, and different consent.

### 1.2 Why Sentinel alone cannot solve it

Sentinel is a diagnostic and row-level repair system. Its safety contract assumes:

- the database can be opened;
- a snapshot can be made;
- the exact subject can be re-read;
- the detecting probe can be re-run after the change;
- the change can be represented as a typed action with a previous value;
- undo can restore that previous value.

Structural damage breaks every assumption. If the file is unreadable, there is no snapshot to take through the normal path, no subject to re-read, and no probe to re-run. If the file is swapped, the undo payload for a book row cannot restore the file.

Sentinel should remain excellent at what it does. It should not become a page-level database tool.

### 1.3 Why automatic database repair is the wrong product

A database does not heal. There are only three real outcomes when the container is damaged:

1. **Restore from a trusted copy.**
2. **Salvage readable rows into a new file.**
3. **Rewrite the file in place** — the riskiest option and the one most likely to destroy evidence.

“Automatic self-repair” is a slogan that hides the choice of which data survives. A background timer must not decide whether the user’s last three months of reading matter more than the rows that happen to be readable. A human must see the tradeoff.

The correct product is not a self-repairing database. It is a **self-protecting database with assisted recovery**.

### 1.4 Design principles

1. **Preserve before diagnosis.** Copy the store and sidecars before touching anything.
2. **Diagnose on a copy.** The original is read-only during diagnosis.
3. **Never mutate the only copy.** Every option works from a preserved source.
4. **No silent data loss.** Every option reports recovered and lost rows.
5. **Independent verification.** The oracle is not the probe that failed.
6. **Human authority over irreversible choices.** Automatic actions may choose no data; they may not choose which data survives.
7. **One writer.** One owner of the SQLite pool at a time.
8. **Crash consistency by construction.** Intent file, fsync, atomic rename, deterministic recovery on next launch.
9. **Local only.** No network, no cloud, no telemetry.
10. **One timeline.** Sentinel and Recovery write into one user-visible history, with separate receipts.

---

## 2. Current-state audit

This section records what exists at `29dd4f6`. It is intentionally blunt; the plan depends on the real seams, not the intended ones.

### 2.1 The data path today

| Layer | Current behavior | Consequence |
|---|---|---|
| `DataStore` | `@MainActor`, owns `books` and `libraryState`, writes through `dbWriteQueue` | Serializes app writes, but only for paths that use it |
| `LibraryDatabase` | GRDB `DatabasePool`, WAL, `foreign_keys = ON`, `synchronous = NORMAL` | Multiple connections are possible; WAL sidecars matter |
| Schema | `books`, `sessions`, `page_times`, `library_state`, `collections`, `book_collections`, `notes`, `achievements`, `weather_snapshots`, `audio_profiles`, `behavior_events`, `application_sessions`, `inactivity_records`, `device_state_events`, `meta` | Recovery must preserve tables the app models do not cover |
| `loadBooks()` | Throws `LibraryDatabaseError.undecodableBook` on any bad book payload | Fail-closed; the library is not silently shortened |
| `loadState()` | Throws `LibraryDatabaseError.undecodableLibraryState` on a bad root row | Fail-closed; defaults are not substituted |
| `DataStore.loadFromDatabase` | On failure: empty books/state, `sqliteLoadFailure`, `persistenceHealth = .degraded`, saves paused | Correct safety behavior, but no recovery workflow |
| `DataStore.createSafetySnapshot` | Calls `database.backup(to:)` on `dbWriteQueue.sync` | Serialized against DataStore writes, but see the backup hazard below |
| `LibraryDatabase.backup(to:)` | `PRAGMA wal_checkpoint(TRUNCATE)` in `writeWithoutTransaction`, then `FileManager.copyItem` of the main file | No exclusive lock across checkpoint + copy; no sidecars; no manifest |
| `LiveSentinelRepairBridge.checkpointDatabase` | Opens a separate `DatabaseQueue` to the same file and runs `PRAGMA wal_checkpoint(TRUNCATE)` | A second connection outside `dbWriteQueue`; violates one-writer discipline |
| `DataStore.persistenceHealth` | `.healthy` / `.degraded(String)` | Visible banner, but not a durable incident |
| JSON fallback | If SQLite bootstrap fails, app uses `library.json` / `library-state.json` and `LibraryArchiveManager` | Recovery plan must not confuse JSON mode with SQLite recovery |

### 2.2 The payload model matters for recovery

`LibraryDatabase.importLibrary` encodes a **summary** of each book:

```swift
private static func summary(of book: Book) -> Book {
    var copy = book
    if copy.cachedSecondsPerPage == nil {
        copy.cachedSecondsPerPage = AnalyticsEngine.readingSpeed(for: book)
    }
    copy.sessions = book.sessions.map { summary(of: $0) }
    return copy
}

private static func summary(of session: ReadingSession) -> ReadingSession {
    var copy = session
    if copy.cachedAverageSecondsPerPage == nil {
        copy.cachedAverageSecondsPerPage = copy.averageSecondsPerPage
    }
    copy.pageTimes = []
    return copy
}
```

Consequences:

- A book payload can reconstruct book metadata, session summaries, notes, collections, and library state.
- A book payload **cannot** reconstruct per-page timings; `pageTimes` are stripped before storage.
- `page_times.payload_json` is the only per-timing source of truth on disk.
- If `page_times` is corrupted but `books` is intact, page timings are only recoverable from a backup.
- If `books.payload_json` is corrupted but `page_times` is intact, the book identity/progress may be unrecoverable even though timings exist.

This is the single most important constraint on what a “rebuild” can honestly promise.

### 2.3 Sentinel today

| Area | Current state |
|---|---|
| Registry | 140 probes, 15 domains, 58 required / 82 optional |
| Risk mix | 109 read-only, 26 R1, 5 R2, 0 R3 one-click |
| Repairs | 25 implemented plans; 31 rules wired |
| Runtime | `SentinelRuntime` actor, serialized cycles, recovery gate/suspension implemented |
| Journal | Segmented, checksummed JSONL; 12 event cases; recovery boundary + unknown-event tolerance |
| Health Center | Five tabs (Overview, Issues, History, Checks, Settings), Release surface |
| Diagnostics | Safe bundle, schema v2, no paths/titles |
| Autonomy | Off / Observe / Assist / Auto-fix safe; Release default Assist |
| SG7 | HOLD: v1 engine retained, English only, no menu bar, no a11y automation, no 10× benchmark, no owner acceptance |

### 2.4 Current hazards

| ID | Hazard | Evidence | Impact |
|---|---|---|---|
| **H-1** | Backup is “checkpoint then copy,” not a single consistent snapshot operation | `LibraryDatabase.backup(to:)` | A concurrent write after checkpoint can leave committed pages in WAL that are absent from the copied main file |
| **H-2** | The repair bridge opens a second SQLite connection | `LiveSentinelRepairBridge.checkpointDatabase` creates `DatabaseQueue(path:)` | Two writers; lock contention; backup/checkpoint races |
| **H-3** | No file-level undo | `SentinelRepairRecord` stores payload hashes and plans, not whole-file versions | A restore or swap cannot be undone by the existing repair undo |
| **H-4** | No restore path | There is no code that swaps a backup into place | A verified backup exists but cannot be used from the app |
| **H-5** | No manifest or independent verification of backups | Backup files are copied; BAK-003/004 open them, but no hash/count manifest | A file may open while missing rows or belonging to a different generation |
| **H-6** | No durable incident record | `persistenceHealth` is in-memory | A crash loses the explanation and the recovery state |
| **H-7** | The app has no read-only incident mode | Saves pause via `sqliteLoadFailure`, but the UI still presents an empty library | The user cannot tell whether data is gone or merely unavailable |
| **H-8** | JSON fallback is a different recovery universe | `DataStore` can fall back to JSON | A SQLite recovery plan can accidentally operate on the wrong store |
| **H-9** | `VACUUM INTO` / backup API not used | Current backup is a file copy | No compact, transactionally consistent snapshot |
| **H-10** | No orphan-row inventory | SQL-002 reports a count only | A repair cannot target exact rows without a new inventory |

H-1 and H-2 must be fixed before any recovery feature is built. A restore built on an inconsistent backup is worse than no restore.

### 2.5 What is genuinely strong and must be preserved

- Fail-closed load is correct. Do not replace it with “skip bad rows.”
- The row-level repair contract is strong: authority, quiescence, generation, exact-subject re-read, snapshot, apply, verify, rollback, undo.
- The journal is append-only, segmented, checksummed, and privacy-safe by construction.
- The Health Center is a Release surface and already has coverage honesty.
- The test suite has real corrupt-row, repair, journal, privacy, and isolation pins.
- The data root is centralized in `AppIdentity`; there is one place to preserve.

---

## 3. Invariants and permanent refusals

### 3.1 The data-loss authority rule

This is the constitution of the subsystem:

> **A background process may perform an action only if the action chooses no data. If the action chooses which data survives, a human must approve it with the expected loss in front of them.**

That single rule decides almost every design question in this document.

### 3.2 Invariants

| ID | Invariant | Enforcement |
|---|---|---|
| **I-01** | The original store is never mutated during diagnosis | Diagnosis runs on a preserved copy |
| **I-02** | No recovery executes without a verified preserved copy | `LibraryStorePreserver` returns a hash-verified `PreservedStore`; executor requires it |
| **I-03** | No recovery commits without explicit confirmation | `RecoveryConfirmation` token bound to option ID + incident ID + plan hash |
| **I-04** | No automatic structural restore or rebuild | `RecoveryAutonomy` has no automatic commit case |
| **I-05** | No Sentinel probe, repair, or undo runs while the store is frozen | `SentinelRecoveryGate` + `SentinelRuntime` suspension |
| **I-06** | One SQLite writer at a time | `DataStore.dbWriteQueue` ownership; no second `DatabaseQueue` |
| **I-07** | Every successful recovery is verified independently | New-file integrity check + row manifest + decode sample; not the failed probe |
| **I-08** | Every executed option produces a receipt | `RecoveryReceipt` written before state becomes `.resolved` |
| **I-09** | The original is never deleted automatically | Preserved copy retained until user deletion or documented retention |
| **I-10** | No user text reaches journal, diagnostics, notifications, or incident JSON | Safe evidence types; privacy tests with secret fixtures |
| **I-11** | Recovery works without Sentinel; Sentinel works without Recovery | Dependency direction: Sentinel → `LibraryRecoveryContracts`; Recovery has no Sentinel import |
| **I-12** | No network access in either subsystem | No `URLSession`; code review + grep gate |
| **I-13** | Crash at any swap step is recoverable or clearly reported | `swap.intent` + hashes + startup reconciliation |
| **I-14** | JSON mode is never treated as SQLite recovery | `StorageCondition.storageEngine` branch |
| **I-15** | A recovery option cannot silently reduce row counts | `RecoveryEstimate` requires `lostRows` or `unknown`; confirmation shows it |

### 3.3 Permanent refusals — do not resurrect

These are removed from scope. They are not “Phase 8.” Reintroducing one requires a new ADR, owner sign-off, and a new safety contract.

| Refused design | Why it is permanently wrong | What replaces it |
|---|---|---|
| **Automatic restore of the newest backup** | Chooses older data over newer data without consent; can restore the corruption; destroys the incident evidence | Assisted restore with a verified backup, data-loss estimate, and preserved original |
| **Automatic rebuild after `integrity_check` failure** | Integrity failure is ambiguous; rebuild destroys recoverable rows and forensic evidence | Read-only diagnosis, export, conservative salvage as an explicit option |
| **Automatic deletion of unreadable rows** | A row that cannot decode may still be the only copy of a book’s progress; deletion is irreversible | Quarantine the raw row, export it, require explicit deletion |
| **Automatic deletion of orphan rows** | “Orphan” may mean an external drive is unmounted or a migration is mid-flight | Inventory, export, grace period, explicit repair |
| **Structural file swap inside `SentinelRepairAction` / `SentinelRepairExecutor`** | The executor assumes a readable DB and row-level undo; a file swap violates both | `LibraryRecoveryExecutor` with its own contract and receipt |
| **Calling a file swap “undoable” when only row payloads are versioned** | The claim is false; the user may lose the ability to return | File-level versioning first; do not use the word undo until it exists |
| **Sentinel probes or repairs while an incident is open** | Writes to a suspect DB can worsen corruption and invalidate evidence | Freeze, suspend, verify after reopen |
| **“Privacy leak repair” in the database subsystem** | A database tool cannot see exfiltration, logging, crash reports, or network egress | Separate security audit; storage leaks are maintenance, not privacy |
| **Automatic merge of duplicate books** | Merging progress, sessions, notes, and collections is a data-reconciliation decision | Assisted merge UI later, with preview and export; not in this plan |
| **In-place `VACUUM` of the live database as background repair** | Requires free space equal to the DB, locks the file, and can fail mid-rewrite | `VACUUM INTO` a new file, verify, then assisted swap |
| **Silent fallback to an empty library on load failure** | Destroys trust and can overwrite recoverable data | Fail closed, read-only incident mode, explicit options |

### 3.4 Deferred, not refused

| Deferred idea | Why later | Required predecessor |
|---|---|---|
| Assisted restore | Needs a consistent backup and a verified drill | G0, G3 |
| Conservative salvage | Needs corrupt fixtures and a data-loss ledger | G2, G4 |
| Logical rebuild from payloads | Needs schema preservation and page-timing honesty | G5 |
| Row-level orphan repair | Needs exact-row inventory and an undo path | G5 |
| File-level undo | Needs versioned stores, atomic swap, and crash recovery | G4 |
| Automatic maintenance | Needs proof that checkpoint/vacuum/rotation are idempotent and non-destructive | G3, G7 |
| Pre-authorized last-resort restore | Needs a verified drill, explicit consent, and preserved original | G4, G7 + owner decision |
| 10× benchmark and accessibility | Needs the subsystem to exist first | G7 |

### 3.5 How to tell whether a new idea is permanent or later

Ask these in order:

1. Does it choose which data survives? → permanent human-approval boundary.
2. Does it mutate the only copy? → permanent no.
3. Is the undo real at the same granularity as the change? → if not, do not call it undo.
4. Can it be verified independently of the failure? → if not, do not ship it.
5. Is the trigger unambiguous? → if not, diagnose, do not act.
6. Is the blast radius bounded to rows? → if not, it belongs in Recovery, not Sentinel.

If a proposal fails 1 or 2, it is permanently refused. If it fails 3, 4, or 5, it is “later, with a gate.”

---

## 4. Architecture

### 4.1 Three subsystems and one coordinator

```text
┌─────────────────────────────────────────────────────────────────────┐
│                         Asterisma App                               │
│                                                                     │
│  ┌──────────────────────┐        ┌──────────────────────────────┐  │
│  │      DataStore       │        │   LibraryHealthCoordinator   │  │
│  │  books / state       │◄──────►│  incident state machine      │  │
│  │  dbWriteQueue        │        │  freeze / reopen / sequence  │  │
│  │  freeze / reopen     │        │  single user-visible record  │  │
│  └──────────┬───────────┘        └───────┬──────────────┬───────┘  │
│             │                            │              │          │
│             │                    ┌───────▼──────┐  ┌────▼───────┐  │
│             │                    │   Sentinel   │  │  Library   │  │
│             │                    │  detection   │  │  Recovery  │  │
│             │                    │  explanation │  │  surgery   │  │
│             │                    │  verification│  │  receipts  │  │
│             │                    └───────┬──────┘  └────┬───────┘  │
│             │                            │              │          │
│             │                    ┌───────▼──────────────▼───────┐  │
│             └───────────────────►│      Health Center UI        │  │
│                                  │  Sentinel | Recovery         │  │
│                                  └──────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

| Component | Owns | Never owns |
|---|---|---|
| **DataStore** | live models, save scheduling, write queue, freeze/reopen | file surgery, incident policy |
| **Sentinel** | probes, issue lifecycle, explanations, journal, verification | structural DB writes, backup restore, row deletion |
| **Library Recovery** | preservation, snapshots, manifests, diagnosis, restore, salvage, row repair, receipts | user-facing issue list, autonomy policy for row repairs |
| **Coordinator** | state machine, ordering, mutual exclusion, single incident record | SQL, file format parsing, probe logic |

### 4.2 Dependency rule

```text
AsterismaApp
   └── LibraryHealthCoordinator
         ├── DataStore
         ├── SentinelRuntime
         └── LibraryRecoveryService
               └── LibraryRecoveryContracts

SentinelRuntime ──────────────► LibraryRecoveryContracts   (gate + summary only)
LibraryRecoveryService ──────► no Sentinel import
DataStore ───────────────────► LibraryRecoveryContracts   (freeze/reopen types only)
```

Forbidden:

- `LibraryRecoveryService` importing `SentinelRuntime`.
- `SentinelRepairExecutor` calling file swap.
- `DataStore` owning backup policy.
- The Health Center executing recovery directly.

Allowed:

- Coordinator calls all three.
- Sentinel reads a `SentinelRecoverySummary` projection.
- Recovery calls a `LibraryRecoveryHost` protocol implemented by `DataStore`.
- Both write through a shared `LibraryHealthJournal` protocol.

### 4.3 Runtime sequence — healthy launch

```text
1. AsterismaApp.init
   DataStore(storageEngine: .sqlite)
   LibraryHealthCoordinator(store:)
   SentinelAppIntegration.start(dataStore:coordinator:)

2. DataStore load
   loadBooks() + loadState()
   success -> StorageCondition.healthy
   failure -> StorageCondition.failed(code)

3. Coordinator
   healthy -> no incident
   failed  -> openIncident(.loadFailed)
             freeze writes
             preserve + diagnose asynchronously
             suspend Sentinel

4. Sentinel
   normal: launch fast pass (tier <= t1)
   suspended: no probes, no repairs, no journal writes except suspension event

5. UI
   healthy: normal library; launch card if Sentinel has something to say
   incident: recovery banner/window; library read-only or empty
```

### 4.4 Runtime sequence — incident

```text
Trigger (load/write/probe/backup)
        │
        ▼
Coordinator.openIncident
        │  creates incident.json (state .detected)
        ▼
Coordinator.freeze
        │  DataStore drain + save attempt + freeze token
        │  Sentinel.setOperationalMode(.suspended)
        ▼
Recovery.preserve
        │  clone/copy DB + WAL + SHM + memory snapshot
        │  hash + verify copy
        ▼
Recovery.diagnose (on copy, read-only)
        │  quick_check / integrity_check / FK / counts / decode sample
        │  build options + estimates
        ▼
Coordinator.awaitingDecision
        │  UI shows incident, evidence, options, loss estimates
        ▼
User chooses option + confirmation
        │
        ▼
Recovery.execute
        │  export | restore | salvage | rebuild | quarantine | do nothing
        │  swap.intent / fsync / atomic rename / verify / rollback
        ▼
Coordinator.verifying
        │  DataStore.reopen
        │  Sentinel.runCycle(.deep) — independent verification
        ▼
Resolved / Failed / Abandoned
        │  receipt + journal + UI
```

### 4.5 Failure-domain boundaries

| Failure | Owner | Sentinel behavior | DataStore behavior | UI |
|---|---|---|---|---|
| Book payload undecodable | Recovery | Suspended; may re-check after | Frozen; saves paused | Recovery incident |
| `integrity_check` fails | Recovery | Suspended | Frozen | Recovery incident |
| Foreign-key orphans only | Sentinel + Recovery | Active; proposes row repair | Healthy; no freeze until repair | Issue + optional row repair |
| WAL large | Sentinel | Active | Healthy | Maintenance suggestion |
| Backup verification fails | Recovery | Active unless no verified backup remains | Healthy | Backup issue / incident if all fail |
| Disk full | Recovery | Suspended if writes fail | Saves fail closed | Recovery incident |
| Schema newer than app | Recovery | Suspended | Refuses load | Incident with “update app” option |
| JSON fallback active | Coordinator | Active (Sentinel reads JSON snapshot) | JSON path | Banner, not SQLite recovery |

### 4.6 Why not merge Sentinel and Recovery

| Dimension | Sentinel | Recovery |
|---|---|---|
| Assumes readable DB | Yes | No |
| Mutation granularity | Row/payload | File/table/row |
| Undo granularity | Payload hash | Whole-file version |
| Verification oracle | Re-run probe | Independent integrity + manifest |
| Default autonomy | Assist / auto-safe | Assisted only |
| Blast radius | One book or state | Entire library |
| Failure recovery | Rollback actions | Preserve, swap, rollback, critical state |
| Test fixtures | In-memory snapshots | Corrupt files, crash injection |

Merging them would give Sentinel a file-level mutation it cannot undo and give Recovery a probe-based verification it cannot trust. The coordinator is the correct seam.

---

## 5. Domain model

All new persisted types are `Codable`, `Sendable`, and versioned. They live in `LibraryRecoveryContracts.swift` and `LibraryIncident.swift`. None of them import SwiftUI, AppKit, GRDB, or Sentinel.

### 5.1 Type map

| Type | Purpose | Persisted |
|---|---|---|
| `LibraryIncident` | Durable incident record and state | Yes |
| `LibraryIncidentKind` | What happened | Yes, enum string |
| `LibraryIncidentState` | Where the workflow is | Yes, enum string |
| `LibraryTrigger` | What opened the incident | Yes |
| `LibraryEvidence` | Safe counts/codes only | Yes |
| `LibraryStoreFingerprint` | Identity of the store at detection | Yes |
| `PreservedStore` | Hash-verified copy of the original | Yes |
| `PreservedFile` | One preserved file | Yes |
| `LibraryDiagnosis` | Read-only findings from the copy | Yes |
| `LibraryTableCounts` | Row counts by table | Yes |
| `RecoveryOption` | One user-selectable action | Derived, persisted for audit |
| `RecoveryEstimate` | Recovered/lost/unknown rows | Yes |
| `RecoveryConfirmation` | Proof of user consent | In-memory token + receipt hash |
| `RecoveryReceipt` | Before/after proof of execution | Yes |
| `RecoveryError` | Stable code + safe message | Yes |
| `RecoverySettings` | Retention, backup count, policy | UserDefaults + safe JSON |
| `LibraryOperationalMode` | Normal or suspended | In-memory + journal |
| `SentinelRecoverySummary` | Projection for Sentinel/UI | In-memory only |

### 5.2 Incident

```swift
nonisolated struct LibraryIncident: Codable, Hashable, Identifiable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var id: String                    // "inc_" + UUID
    var kind: LibraryIncidentKind
    var state: LibraryIncidentState
    var trigger: LibraryTrigger
    var detectedAt: Date
    var updatedAt: Date
    var resolvedAt: Date?

    var evidence: [LibraryEvidence]
    var fingerprint: LibraryStoreFingerprint?
    var preserved: PreservedStore?
    var diagnosis: LibraryDiagnosis?
    var options: [RecoveryOption]
    var chosenOptionID: String?
    var receipts: [String]            // rec_ IDs
    var lastError: RecoveryError?
    var userSummaryKey: String        // localization key, not text
    var readOnly: Bool
}

nonisolated enum LibraryIncidentKind: String, Codable, CaseIterable, Sendable {
    case loadFailed
    case writeFailed
    case integrityCheckFailed
    case databaseUnreadable
    case schemaMismatch
    case recordDecodeFailed
    case backupVerificationFailed
    case diskSpaceCritical
    case recoveryInterrupted
}

nonisolated enum LibraryIncidentState: String, Codable, CaseIterable, Sendable {
    case detected
    case freezing
    case frozen
    case diagnosing
    case awaitingDecision
    case executing
    case verifying
    case resolved
    case failed
    case abandoned
}

nonisolated enum LibraryTrigger: Codable, Hashable, Sendable {
    case loadFailure(code: String)
    case writeFailure(code: String)
    case probeFinding(ruleID: String, fingerprint: String)
    case backupVerification(backupID: String)
    case launchInterruptedSwap(incidentID: String)
    case userRequested
}
```

Design notes:

- `id` is incidental. The durable identity for correlation is the incident ID plus the preserved-store hash.
- `userSummaryKey` is a localization key. The UI supplies the text.
- `readOnly` is true from `freezing` until `resolved`/`abandoned`; the UI must not offer editing.
- `receipts` are append-only IDs. Receipt files are immutable.
- `lastError` is the last failure, not a history. The receipt carries history.

### 5.3 State machine

| From | Event | Guard | To | Side effects |
|---|---|---|---|---|
| `detected` | `beginFreeze` | incident has a trigger | `freezing` | persist; suspend Sentinel; cancel save timer |
| `freezing` | `frozen` | DataStore drained, store closed, freeze token held | `frozen` | persist; preserve starts |
| `freezing` | `freezeFailed` | close/drain failed | `failed` | receipt `LR-006`; critical banner |
| `frozen` | `beginDiagnosis` | preserved copy verified | `diagnosing` | persist; no UI actions |
| `diagnosing` | `optionsReady` | diagnosis complete | `awaitingDecision` | persist; publish options |
| `diagnosing` | `diagnosisFailed` | copy unreadable or IO error | `failed` | receipt `LR-002`; offer export if possible |
| `awaitingDecision` | `execute` | confirmation bound to option + plan hash | `executing` | persist; write intent |
| `awaitingDecision` | `abandon` | user chooses read-only | `abandoned` | persist; keep read-only; no reopen |
| `executing` | `verify` | new store exists and passes quick check | `verifying` | persist; reopen DataStore |
| `executing` | `executeFailed` | operation failed before commit | `awaitingDecision` | rollback if needed; receipt |
| `verifying` | `resolved` | independent checks + Sentinel cycle pass | `resolved` | receipt; thaw; close incident |
| `verifying` | `verifyFailed` | new store fails independent checks | `failed` | rollback; receipt; critical if rollback fails |
| `failed` | `retry` | preserved copy intact | `awaitingDecision` | new options; keep old receipts |
| `failed` | `abandon` | user chooses read-only | `abandoned` | preserve; no writes |
| `any` | `interrupted` | app relaunched mid-state | `failed` | startup reconciliation; receipt |

Rules:

1. `resolved` is terminal. A new incident gets a new ID.
2. `abandoned` is not resolved. The app remains read-only; the preserved copy remains.
3. No transition from `executing` directly to `resolved`; verification is mandatory.
4. No transition that deletes the preserved copy.
5. Every transition writes `incident.json` atomically before publishing UI state.

### 5.4 Evidence and privacy

`LibraryEvidence` may contain only:

```swift
nonisolated struct LibraryEvidence: Codable, Hashable, Sendable {
    var code: String              // "sql.integrity", "file.missing", "row.decode"
    var count: Int?
    var bytes: Int64?
    var hash: String?             // SHA-256 prefix, never a path
    var table: String?            // known schema table name
    var enumValue: String?        // severity/state, not user text
}
```

Forbidden fields: book title, author, note text, file path, bookmark data, raw payload, SQL statement containing user values, exception message that may embed a path.

Exception messages from SQLite can contain a file path. Before persisting, reduce to a stable code:

```text
SQLITE_CORRUPT -> LR-101
SQLITE_NOTADB -> LR-102
SQLITE_IOERR -> LR-103
SQLITE_FULL -> LR-104
SQLITE_READONLY -> LR-105
SQLITE_BUSY -> LR-106
unknown -> LR-199
```

### 5.5 Store fingerprint

```swift
nonisolated struct LibraryStoreFingerprint: Codable, Hashable, Sendable {
    var mainSHA256: String
    var mainBytes: Int64
    var walBytes: Int64?
    var shmBytes: Int64?
    var pageCount: Int?
    var freelistCount: Int?
    var pageSize: Int?
    var journalMode: String?
    var schemaVersion: Int?
    var sqliteVersion: String?
    var tableCounts: LibraryTableCounts?
    var capturedAt: Date
}
```

The fingerprint is computed before any recovery. It is the identity used in receipts and in the swap intent.

### 5.6 Preserved store

```swift
nonisolated struct PreservedStore: Codable, Hashable, Sendable {
    var directoryName: String       // relative to the incident directory
    var files: [PreservedFile]
    var combinedSHA256: String     // hash of the ordered file hashes
    var createdAt: Date
    var method: PreservationMethod // .apfsClone, .copy, .hardLink? (no hard link)
}

nonisolated struct PreservedFile: Codable, Hashable, Sendable {
    var role: PreservedFileRole     // .main, .wal, .shm, .memorySnapshot, .manifest
    var name: String                // relative file name
    var bytes: Int64
    var sha256: String
}

nonisolated enum PreservationMethod: String, Codable, Sendable {
    case apfsClone
    case byteCopy
}
```

No hard links. A hard link would let a later write mutate the “preserved” file. APFS clone is copy-on-write and safe; if unavailable, use a byte copy.

### 5.7 Diagnosis

```swift
nonisolated struct LibraryDiagnosis: Codable, Hashable, Sendable {
    var canOpenReadOnly: Bool
    var quickCheck: String?
    var integrityCheck: [String]
    var foreignKeyViolations: [String: Int]   // table -> count
    var tableCounts: LibraryTableCounts?
    var missingTables: [String]
    var unexpectedTables: [String]
    var undecodableBooks: Int
    var undecodableState: Bool
    var pageCount: Int?
    var freelistCount: Int?
    var pageSize: Int?
    var canVacuum: Bool
    var canRebuildFromPayloads: Bool
    var canRecoverPageTimings: Bool
    var notes: [String]                       // stable codes only
    var diagnosedAt: Date
}

nonisolated struct LibraryTableCounts: Codable, Hashable, Sendable {
    var books: Int
    var sessions: Int
    var pageTimes: Int
    var collections: Int
    var notes: Int
    var achievements: Int
    var weatherSnapshots: Int
    var audioProfiles: Int
    var behaviorEvents: Int
    var applicationSessions: Int
    var inactivityRecords: Int
    var deviceStateEvents: Int
    var meta: Int
}
```

The diagnosis does not assert what the app “should” contain. It records what the copy contains and what can be read.

### 5.8 Recovery options and estimates

```swift
nonisolated struct RecoveryOption: Codable, Hashable, Identifiable, Sendable {
    var id: String                    // "export", "restore:<backupID>", "salvage", ...
    var kind: RecoveryOptionKind
    var risk: RecoveryRisk
    var titleKey: String
    var detailKey: String
    var estimate: RecoveryEstimate
    var preconditions: [RecoveryPrecondition]
    var confirmation: RecoveryConfirmationLevel
    var isEnabled: Bool
    var disabledReasonKey: String?
    var backupID: String?
}

nonisolated enum RecoveryOptionKind: String, Codable, Sendable {
    case exportCopy
    case restoreBackup
    case salvageReadableRows
    case rebuildNormalizedTables
    case quarantineRecord
    case doNothing
}

nonisolated enum RecoveryRisk: String, Codable, Sendable {
    case readOnly          // r1: no mutation
    case rowLevel          // r2: reversible at row level
    case fileLevel         // r3: replaces or rewrites the store
}

nonisolated struct RecoveryEstimate: Codable, Hashable, Sendable {
    var recoveredRows: Int?
    var lostRows: Int?
    var unknownRows: Bool
    var lostTimeWindow: TimeInterval?
    var confidence: Double            // 0...1, an estimate, never a promise
}

nonisolated enum RecoveryConfirmationLevel: String, Codable, Sendable {
    case singleButton
    case doubleConfirm
    case typePhrase                  // e.g. type RESTORE
}

nonisolated struct RecoveryConfirmation: Sendable {
    var incidentID: String
    var optionID: String
    var planHash: String
    var confirmedAt: Date
    var typedPhrase: String?
}
```

`RecoveryEstimate` is never omitted. If the system cannot compute a number, it sets `unknownRows = true` and the UI says so. A blank estimate is a bug.

### 5.9 Receipts

```swift
nonisolated struct RecoveryReceipt: Codable, Hashable, Identifiable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var id: String                    // "rec_" + UUID
    var incidentID: String
    var optionID: String
    var kind: RecoveryOptionKind
    var startedAt: Date
    var finishedAt: Date
    var outcome: RecoveryOutcome
    var before: LibraryStoreFingerprint?
    var after: LibraryStoreFingerprint?
    var recoveredRows: Int?
    var lostRows: Int?
    var quarantinedRows: Int?
    var verification: RecoveryVerification
    var error: RecoveryError?
    var preservedOriginal: String?    // relative directory name
    var notes: [String]               // stable codes
}

nonisolated enum RecoveryOutcome: String, Codable, Sendable {
    case exported
    case restored
    case salvaged
    case rebuilt
    case quarantined
    case abandoned
    case failed
    case rolledBack
    case critical
}

nonisolated struct RecoveryVerification: Codable, Hashable, Sendable {
    var integrityOK: Bool
    var foreignKeysOK: Bool
    var countsMatchManifest: Bool
    var sampledPayloadsDecoded: Int
    var sampledPayloadFailures: Int
    var sentinelCycleComplete: Bool?
    var sentinelCriticalFindings: Int?
    var verifiedAt: Date
}
```

`outcome == .critical` is reserved for “rollback also failed; both stores are preserved and the user must act.” It must never be reported as success.

### 5.10 Error taxonomy

| Code | Meaning | Recovery behavior |
|---|---|---|
| `LR-001` | Preserve failed | incident `failed`; no mutation |
| `LR-002` | Diagnosis failed | offer export if possible |
| `LR-003` | No verified backup | restore option disabled |
| `LR-004` | Backup schema newer than app | restore disabled; update app |
| `LR-005` | Insufficient disk space | option disabled; export only |
| `LR-006` | Store close/drain failed | incident `failed`; no swap |
| `LR-007` | Swap failed before commit | rollback; incident `awaitingDecision` |
| `LR-008` | Independent verification failed | rollback; incident `failed` |
| `LR-009` | Rollback failed | incident `critical`; preserve both |
| `LR-010` | User cancelled | incident `awaitingDecision`; no mutation |
| `LR-011` | Lock held by another instance | no mutation; show message |
| `LR-012` | Preservation copy hash mismatch | no mutation; delete bad copy |
| `LR-013` | Backup manifest missing | option disabled until verified |
| `LR-014` | Backup hash mismatch | option disabled; quarantine backup |
| `LR-015` | Row repair verification failed | rollback transaction; issue persists |
| `LR-101..106` | SQLite open/IO codes | mapped from the actual error; no raw path |
| `LR-199` | Unknown SQLite error | safe code; diagnosis continues if possible |

### 5.11 Counters

Local-only counters for the Recovery settings/status view:

```text
incidentsDetected
incidentsResolved
incidentsAbandoned
restoresAttempted
restoresSucceeded
restoresRolledBack
salvagesAttempted
rowsRecovered
rowsLost
verificationFailures
backupVerificationsRun
backupVerificationsFailed
```

Stored in `LibraryRecovery/counters.json`, atomic writes, no user text. Never uploaded.

---

## 6. Contracts and interfaces

### 6.1 `LibraryRecoveryService`

An actor. All file work is serialized.

```swift
actor LibraryRecoveryService {
    init(
        root: URL,
        host: any LibraryRecoveryHost,
        io: any LibraryRecoveryIO,
        clock: any LibraryRecoveryClock
    )

    func recoverInterruptedWork() async -> [LibraryIncident]
    func openIncident(_ request: LibraryIncidentRequest) async throws -> LibraryIncident
    func preserveAndDiagnose(incidentID: String) async throws -> LibraryIncident
    func options(for incidentID: String) async -> [RecoveryOption]
    func execute(
        incidentID: String,
        optionID: String,
        confirmation: RecoveryConfirmation
    ) async throws -> RecoveryReceipt
    func abandon(incidentID: String) async throws
    func incident(id: String) async -> LibraryIncident?
    func incidents() async -> [LibraryIncident]
}
```

Rules:

- `openIncident` only writes the incident record. It does not touch the store.
- `preserveAndDiagnose` requires the host to be frozen. It never opens the live store for writing.
- `execute` requires a `RecoveryConfirmation` whose `planHash` matches the current option plan. A stale confirmation is rejected.
- `abandon` keeps the preserved copy and leaves the app read-only until the next successful open.

### 6.2 `LibraryRecoveryHost`

Implemented by `DataStore` on the main actor.

```swift
@MainActor
protocol LibraryRecoveryHost: AnyObject {
    var liveStoreURL: URL { get }
    var storageEngine: StorageEngine { get }
    var storageCondition: StorageCondition { get }

    func freezeForRecovery(_ reason: LibraryFreezeReason) async -> LibraryFreezeToken?
    func drainAndCloseForRecovery() async throws
    func reopenAfterRecovery() async throws -> LibraryOpenResult
    func releaseFreeze(_ token: LibraryFreezeToken) async
    func currentFingerprint() async throws -> LibraryStoreFingerprint
    func currentRowCounts() async throws -> LibraryTableCounts
    func exportMemorySnapshot() async -> Data?
}
```

`LibraryFreezeToken` is opaque and single-use:

```swift
nonisolated struct LibraryFreezeToken: Sendable {
    let id: UUID
    let reason: LibraryFreezeReason
    let createdAt: Date
}

nonisolated enum LibraryFreezeReason: String, Codable, Sendable {
    case loadFailure
    case writeFailure
    case integrityFailure
    case userRecovery
    case backupVerification
}
```

DataStore behavior:

- `freezeForRecovery` cancels the save timer, drains `dbWriteQueue`, sets `recoveryFreeze`, and returns a token once no write is in flight.
- `drainAndCloseForRecovery` attempts one final `saveImmediately()` if the store is writable, captures a memory snapshot, then closes the pool on `dbWriteQueue.sync`.
- `reopenAfterRecovery` constructs a new `LibraryDatabase`, runs `loadFromDatabase`, clears the freeze, and returns the result.
- Any save while frozen returns immediately and sets `persistenceHealth = .recovery`.
- No other component may close or reopen the pool.

### 6.3 `LibraryRecoveryIO`

A narrow file-system protocol so crash and failure injection are testable.

```swift
protocol LibraryRecoveryIO: Sendable {
    func createDirectory(at url: URL) throws
    func fileExists(at url: URL) -> Bool
    func attributes(at url: URL) throws -> FileAttributes
    func cloneItem(at source: URL, to destination: URL) throws
    func copyItem(at source: URL, to destination: URL) throws
    func moveItem(at source: URL, to destination: URL) throws
    func removeItem(at url: URL) throws
    func sha256(at url: URL) throws -> String
    func fsyncFile(at url: URL) throws
    func fsyncDirectory(at url: URL) throws
    func freeSpace(at url: URL) throws -> Int64
    func readData(at url: URL) throws -> Data
    func writeData(_ data: Data, to url: URL, atomic: Bool) throws
}
```

Production implementation uses `FileManager`, `CryptoKit`, and `fcntl(F_FULLFSYNC)` on macOS. Test implementation wraps a fault schedule.

### 6.4 `SentinelRecoveryGate`

Defined in the contracts module. Sentinel depends on this, not on Recovery.

```swift
protocol SentinelRecoveryGate: Sendable {
    func operationalMode() async -> LibraryOperationalMode
}

nonisolated enum LibraryOperationalMode: Sendable, Equatable {
    case normal
    case suspended(LibrarySuspensionReason)
}

nonisolated enum LibrarySuspensionReason: String, Codable, Sendable {
    case incidentOpen
    case storeFrozen
    case recoveryExecuting
    case recoveryVerifying
}
```

`SentinelRuntime` checks the gate:

- at the top of `runCycle`;
- before each automatic repair;
- before `repair`, `undoRepair`, and `previewRepair` return a plan;
- before the scheduler sleeps and after it wakes.

A suspended cycle returns a `SentinelCycleReport` with `error = "Sentinel is paused while the library is in recovery."` and no probe results. It does not write a normal cycle journal entry.

### 6.5 Coordinator API

```swift
@MainActor
final class LibraryHealthCoordinator: ObservableObject {
    @Published private(set) var incident: LibraryIncident?
    @Published private(set) var recoveryState: LibraryRecoveryUIState

    func start() async
    func handleStorageCondition(_ condition: StorageCondition) async
    func handleSentinelCandidate(_ candidate: LibraryIncidentCandidate) async
    func choose(optionID: String) async
    func confirm(optionID: String, phrase: String?) async
    func abandon() async
    func retry() async
    func refresh() async
}
```

`LibraryIncidentCandidate` is the only type Sentinel needs to emit:

```swift
nonisolated struct LibraryIncidentCandidate: Sendable {
    var kind: LibraryIncidentKind
    var ruleID: String?
    var fingerprint: String?
    var severity: SentinelSeverity
    var evidence: [LibraryEvidence]
    var detectedAt: Date
}
```

It contains no paths and no user text.

### 6.6 Notifications

```swift
nonisolated extension Notification.Name {
    static let libraryIncidentDidChange = Notification.Name("library.incident.didChange")
    static let libraryRecoveryDidChange = Notification.Name("library.recovery.didChange")
}
```

Published on the main queue after the incident file is durably written, not before.

### 6.7 Threading rules

| Actor/context | May do | Must not do |
|---|---|---|
| `LibraryHealthCoordinator` (@MainActor) | sequence, publish UI, call host | file I/O, SQL |
| `LibraryRecoveryService` (actor) | file I/O, diagnosis, restore, receipts | touch SwiftUI/DataStore models |
| `DataStore` (@MainActor) | live models, freeze/reopen, save queue | long file copies, SQL diagnosis |
| `SentinelRuntime` (actor) | probes, issues, journal | structural DB writes, restore |
| `LibraryRecoveryHost` (@MainActor) | translate coordinator calls to DataStore | expose pool to Recovery |

Every cross-actor call is explicit `await`. No `Task.detached` inside Recovery without a structured parent and cancellation.

---

## 7. File and module layout

### 7.1 New files

| File | Responsibility |
|---|---|
| `AsterismaV2.5/Core/Storage/LibraryRecoveryContracts.swift` | protocols, enums, safe types shared with Sentinel |
| `.../LibraryIncident.swift` | `LibraryIncident`, triggers, evidence, state |
| `.../LibraryIncidentStore.swift` | atomic incident JSON read/write, scan, index |
| `.../LibraryStoreFingerprint.swift` | hashing, table counts, metadata |
| `.../LibraryStoreManifest.swift` | manifest encode/decode/hash validation |
| `.../LibraryRecoveryIO.swift` | production file IO + `F_FULLFSYNC` |
| `.../LibraryStorePreserver.swift` | clone/copy main + WAL + SHM + memory snapshot |
| `.../LibraryDatabaseDoctor.swift` | read-only diagnosis on a copy |
| `.../LibraryBackupCatalog.swift` | scan backups, manifests, generations |
| `.../LibraryBackupVerifier.swift` | open, integrity, counts, hash, drill |
| `.../LibraryRecoveryPlanner.swift` | options and estimates from diagnosis |
| `.../LibraryRecoveryExecutor.swift` | export, restore, salvage, rebuild, quarantine |
| `.../LibrarySwapCoordinator.swift` | intent, close, move, rename, fsync, rollback |
| `.../LibraryRecoveryVerifier.swift` | independent post-recovery checks |
| `.../LibraryRowRepairService.swift` | orphan inventory, export, delete, undo |
| `.../LibraryRecoverySettings.swift` | retention, backup count, policy |
| `.../LibraryRecoveryDiagnostics.swift` | safe recovery report for support |
| `AsterismaV2.5/App/LibraryHealthCoordinator.swift` | app-level state machine |
| `AsterismaV2.5/Features/LibraryRecovery/LibraryRecoveryView.swift` | incident detail + options |
| `.../LibraryIncidentBanner.swift` | launch banner / card |
| `.../LibraryRecoveryProgressView.swift` | phase progress |
| `.../LibraryBackupListView.swift` | backup catalog + verify/drill |

### 7.2 Modified files

| File | Change |
|---|---|
| `AsterismaV2.5/Core/Storage/LibraryDatabase.swift` | add `makeConsistentSnapshot(to:)`, `readOnlyCopyInfo`, `tableCounts`, `schemaVersion`, `openReadOnly`; replace `backup(to:)` |
| `AsterismaV2.5/Core/DataStore3.swift` | add `StorageCondition`, `freezeForRecovery`, `drainAndCloseForRecovery`, `reopenAfterRecovery`, `performCheckpoint`, `exportMemorySnapshot`; make `sqliteLoadFailure` visible safely |
| `AsterismaV2.5/Core/Sentinel/SentinelDataBridgeV2.swift` | remove second `DatabaseQueue`; call `DataStore.performCheckpoint`; attach recovery gate |
| `AsterismaV2.5/Core/Sentinel/SentinelRuntime.swift` | operational mode, suspension, verification cycle, published recovery summary |
| `AsterismaV2.5/Core/Sentinel/SentinelDomain.swift` | no structural change; add `SentinelRecoverySummary` only |
| `AsterismaV2.5/Core/Sentinel/SentinelJournal.swift` | add incident/recovery events + `unknown` forward-compatible decode |
| `AsterismaV2.5/Core/Sentinel/SentinelDiagnostics.swift` | schema v2, recovery rows, safe redaction tests |
| `AsterismaV2.5/Core/Sentinel/SentinelConfiguration.swift` | no change to autonomy; recovery has separate settings |
| `AsterismaV2.5/App/AsterismaApp.swift` | own coordinator, inject environment object, window/menu entry |
| `AsterismaV2.5/App/NewContentView.swift` | start coordinator, incident banner, read-only state |
| `AsterismaV2.5/Features/Sentinel/SentinelHealthCenterView.swift` | header rename, Recovery tab, incident detail |
| `AsterismaV2.5/Features/Sentinel/SentinelViewModel.swift` | recovery projection + actions |
| `AsterismaV2.5/Features/Goals/SettingsRootView.swift` | Backups & Recovery pane |
| `.github/workflows/census.yml` | no structural change; new tests run automatically |

No `project.pbxproj` edit is needed: the project uses `PBXFileSystemSynchronizedRootGroup`, so new files under the existing folders are included automatically. Verify this after adding the first file; if the group is ever changed, add explicit references.

### 7.3 New test files

| File | Focus |
|---|---|
| `AsterismaV2.5Tests/Core/LibraryRecoveryGateTests.swift`, `AsterismaV2.5Tests/Core/LibraryRecoveryFlowTests.swift` | transitions, guards, terminal states |
| `.../LibraryIncidentStoreTests.swift` | atomic write, tolerant decode, interrupted scan |
| `.../LibraryStorePreserverTests.swift` | clone/copy, hash, sidecars, failure |
| `.../LibraryDatabaseDoctorTests.swift` | corrupt fixtures, read-only, diagnosis |
| `.../LibraryBackupCatalogTests.swift` | manifests, generations, legacy backups |
| `.../LibraryBackupVerifierTests.swift` | hash, integrity, counts, drill |
| `.../LibraryRecoveryPlannerTests.swift` | option gating, estimates |
| `.../LibrarySwapCoordinatorTests.swift` | crash points, rollback, critical |
| `.../LibraryRecoveryVerifierTests.swift` | independent oracle, counts, decode sample |
| `.../LibraryRowRepairTests.swift` | orphan inventory, export, delete, undo |
| `.../LibraryRecoveryPrivacyTests.swift` | no titles/paths in persisted files |
| `.../LibraryRecoveryPerformanceTests.swift` | 70-book and 1.38M-timing budgets |

### 7.4 Naming rules

- Types: `Library*` for Recovery, `Sentinel*` for Sentinel, `Recovery*` for a workflow phase.
- Persisted IDs: `inc_`, `rec_`, `bak_`, `ver_` prefixes.
- Error codes: `LR-###`.
- Localization keys: `recovery.<area>.<name>`; no English literals in persisted JSON.
- Journal event strings: lower camel case, additive only.

---

## 8. Storage layout and schemas

### 8.1 Directory tree

```text
<Application Support>/Asterisma/
├── library.grdb.sqlite3
├── library.grdb.sqlite3-wal
├── library.grdb.sqlite3-shm
├── Backups/
│   ├── library-2026-10-28_120000.sqlite3
│   ├── library-2026-10-28_120000.sqlite3.manifest.json
│   ├── library-2026-10-27_120000.sqlite3
│   ├── library-2026-10-27_120000.sqlite3.manifest.json
│   └── quarantine/
│       └── failed-library-2026-10-26_120000.sqlite3
└── LibraryRecovery/
    ├── recovery.lock
    ├── counters.json
    ├── index.json
    ├── incidents/
    │   └── inc_<uuid>/
    │       ├── incident.json
    │       ├── diagnosis.json
    │       ├── preserved/
    │       │   ├── library.grdb.sqlite3
    │       │   ├── library.grdb.sqlite3-wal
    │       │   ├── library.grdb.sqlite3-shm
    │       │   ├── memory-snapshot.json
    │       │   └── preservation.json
    │       ├── receipts/
    │       │   └── rec_<uuid>.json
    │       ├── swap.intent
    │       └── recovery.log.jsonl
    ├── versions/
    │   └── ver_<uuid>/
    │       ├── library.grdb.sqlite3
    │       ├── library.grdb.sqlite3.manifest.json
    │       └── version.json
    └── quarantine/
        ├── rows/
        │   └── inc_<uuid>-orphans.json
        └── files/
```

`Backups/` remains where the existing app expects it. `LibraryRecovery/` is new and owned by Recovery. Sentinel’s `Sentinel/` folder is unchanged.

### 8.2 `incident.json`

```json
{
  "schemaVersion": 1,
  "id": "inc_8C4E...",
  "kind": "integrityCheckFailed",
  "state": "awaitingDecision",
  "trigger": { "probeFinding": { "ruleID": "SQL-001", "fingerprint": "a1b2c3d4e5f60708" } },
  "detectedAt": "2026-10-28T18:00:00.000Z",
  "updatedAt": "2026-10-28T18:00:12.000Z",
  "resolvedAt": null,
  "evidence": [
    { "code": "sql.integrity", "count": 3, "table": null },
    { "code": "store.bytes", "bytes": 52428800 }
  ],
  "fingerprint": {
    "mainSHA256": "9f2c...",
    "mainBytes": 52428800,
    "walBytes": 1048576,
    "pageCount": 12800,
    "freelistCount": 12,
    "pageSize": 4096,
    "journalMode": "wal",
    "schemaVersion": 1,
    "sqliteVersion": "3.45.0"
  },
  "preserved": {
    "directoryName": "preserved",
    "files": [
      { "role": "main", "name": "library.grdb.sqlite3", "bytes": 52428800, "sha256": "9f2c..." },
      { "role": "wal", "name": "library.grdb.sqlite3-wal", "bytes": 1048576, "sha256": "77aa..." }
    ],
    "combinedSHA256": "c0ffee...",
    "createdAt": "2026-10-28T18:00:04.000Z",
    "method": "apfsClone"
  },
  "diagnosis": { "canOpenReadOnly": true, "quickCheck": "ok", "integrityCheck": ["*** in database main *** Page 42: broken"] },
  "options": [
    { "id": "export", "kind": "exportCopy", "risk": "readOnly", "titleKey": "recovery.option.export.title", "detailKey": "recovery.option.export.detail", "estimate": { "recoveredRows": null, "lostRows": 0, "unknownRows": false, "confidence": 1.0 }, "preconditions": [], "confirmation": "singleButton", "isEnabled": true }
  ],
  "chosenOptionID": null,
  "receipts": [],
  "lastError": null,
  "userSummaryKey": "recovery.summary.integrity",
  "readOnly": true
}
```

Encoding rules:

- ISO-8601 with fractional seconds, UTC.
- Sorted keys.
- Atomic write to `.tmp`, `F_FULLFSYNC`, rename, fsync directory.
- No absolute paths in JSON. Relative names only.
- Decoding is tolerant: missing optional fields get defaults; unknown enum raw values map to `.unknown` or throw a typed `LR-002` depending on safety.

### 8.3 Backup manifest

File: `library-YYYY-MM-DD_HHMMSS.sqlite3.manifest.json`

```json
{
  "schemaVersion": 1,
  "backupID": "bak_20261028_120000",
  "createdAt": "2026-10-28T16:00:00.000Z",
  "reason": "daily",
  "source": {
    "appVersion": "1.0 (build 42)",
    "sentinelVersion": "2.0",
    "sqliteVersion": "3.45.0",
    "schemaVersion": 1
  },
  "file": {
    "name": "library-2026-10-28_120000.sqlite3",
    "bytes": 48234496,
    "sha256": "4d1e..."
  },
  "store": {
    "pageCount": 11776,
    "pageSize": 4096,
    "freelistCount": 8,
    "journalMode": "delete",
    "tableCounts": { "books": 12, "sessions": 74, "pageTimes": 1380000 }
  },
  "verification": {
    "state": "verified",
    "quickCheck": "ok",
    "integrityCheck": "ok",
    "foreignKeyViolations": 0,
    "sampledPayloadFailures": 0,
    "verifiedAt": "2026-10-28T16:00:03.000Z",
    "drill": "open+counts+sample"
  }
}
```

Manifest rules:

- `sha256` is over the exact bytes of the backup file.
- `schemaVersion` is the app’s recovery manifest schema, not the SQLite schema.
- `store.schemaVersion` is the SQLite `PRAGMA user_version` or the app migration version.
- A manifest is written only after the backup file is durable.
- A manifest is never edited to change a result. A re-verification writes a new `verification` object with `verifiedAt` and keeps history in `LibraryBackupCatalog` if needed.

### 8.4 Receipt

```json
{
  "schemaVersion": 1,
  "id": "rec_1A2B...",
  "incidentID": "inc_8C4E...",
  "optionID": "restore:bak_20261028_120000",
  "kind": "restoreBackup",
  "startedAt": "2026-10-28T18:03:00.000Z",
  "finishedAt": "2026-10-28T18:03:09.000Z",
  "outcome": "restored",
  "before": { "mainSHA256": "9f2c...", "mainBytes": 52428800 },
  "after": { "mainSHA256": "4d1e...", "mainBytes": 48234496 },
  "recoveredRows": 1380074,
  "lostRows": 0,
  "quarantinedRows": 0,
  "verification": {
    "integrityOK": true,
    "foreignKeysOK": true,
    "countsMatchManifest": true,
    "sampledPayloadsDecoded": 120,
    "sampledPayloadFailures": 0,
    "sentinelCycleComplete": true,
    "sentinelCriticalFindings": 0,
    "verifiedAt": "2026-10-28T18:03:08.000Z"
  },
  "error": null,
  "preservedOriginal": "inc_8C4E.../preserved",
  "notes": ["restore.backupVerified", "swap.intentCleared"]
}
```

### 8.5 `swap.intent`

```json
{
  "schemaVersion": 1,
  "incidentID": "inc_8C4E...",
  "createdAt": "2026-10-28T18:03:01.000Z",
  "operation": "restore",
  "livePath": "library.grdb.sqlite3",
  "preservedOriginal": "inc_8C4E.../pre-restore.sqlite3",
  "incomingBackup": "Backups/library-2026-10-28_120000.sqlite3",
  "expectedBeforeSHA256": "9f2c...",
  "expectedAfterSHA256": "4d1e...",
  "stage": "intentWritten"
}
```

Stages: `intentWritten` → `originalMoved` → `incomingCopied` → `renamed` → `verified` → `complete`.

On launch, if `swap.intent` exists:

- If live file hash equals `expectedAfterSHA256`, continue verification and complete.
- If live file hash equals `expectedBeforeSHA256`, roll back/clean up and return to `failed`.
- If neither, preserve both files, enter `critical`, and show the incident. Never guess.

### 8.6 Lock

`LibraryRecovery/recovery.lock` with `flock(LOCK_EX | LOCK_NB)`. The lock is held for the duration of preserve/diagnose/execute. If it cannot be acquired, `LR-011`; no mutation. The lock file is not deleted on crash; `flock` releases when the process exits.

### 8.7 Retention

| Artifact | Default | Rule |
|---|---|---|
| Verified backups | 10 | Never delete the only verified backup |
| Failed backups | 2 | Keep in `Backups/quarantine/` for diagnosis |
| Incident copies | 30 days or 5 incidents | Never delete an unresolved incident |
| Receipts | Life of incident + 1 year | Append-only; safe to keep |
| File versions | 14 days | Only after Phase 7 file-level undo |
| Quarantined rows | 30 days | Never delete without user action |
| Recovery journal | 4 segments × 1,000 entries | Same policy as Sentinel journal |

Retention runs only when no incident is unresolved and no recovery is executing. It reports what it will delete before deleting; the first implementation should require a user action for any deletion of incident copies.

### 8.8 Permissions

- `LibraryRecovery/` and subdirectories: `0700`.
- Files: `0600`.
- Exported copies: user-selected destination; default file name only, no path leakage in logs.
- No quarantine file is world-readable.
- The app sandbox remains the outer boundary.

---

## 9. Backup subsystem

### 9.1 Goals

A backup is useful only if it is:

1. **Consistent** — it contains a transactionally coherent snapshot, including committed WAL pages.
2. **Identifiable** — it has a manifest with a hash, timestamp, app/schema version, and row counts.
3. **Verifiable** — it can be opened, checked, and counted without touching the live store.
4. **Restorable** — a drill proves it can become a working store.
5. **Retained** — the only verified copy is never deleted by rotation.

### 9.2 Current backup path and why it changes

The current `LibraryDatabase.backup(to:)` is:

```swift
func backup(to destination: URL) throws {
    try pool.writeWithoutTransaction { db in
        try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
    }
    try? FileManager.default.removeItem(at: destination)
    try FileManager.default.copyItem(at: dbURL, to: destination)
}
```

It is not a single snapshot operation. The checkpoint is completed before the copy begins; a write that starts after the checkpoint can commit pages to WAL that are absent from the copied main file. The copy also omits `-wal` and `-shm`. Under the app’s normal single-writer queue this may be rare, but “rare” is not a safety property for the only restore point.

The replacement is a **consistent snapshot into a new file**, followed by a manifest and verification. The old method stays only as a migration fallback for JSON mode.

### 9.3 Consistent snapshot algorithm

Use SQLite’s `VACUUM INTO` as the primary mechanism. It creates a new database containing the current committed content, works with WAL, and does not require rewriting the live file.

```swift
func makeConsistentSnapshot(to destination: URL) throws {
    let temporary = destination
        .deletingLastPathComponent()
        .appendingPathComponent(".snapshot-\(UUID().uuidString).sqlite3")

    try pool.writeWithoutTransaction { db in
        try db.execute(sql: "VACUUM INTO ?", arguments: [temporary.path])
    }

    try Self.fsyncFile(temporary)
    try FileManager.default.moveItem(at: temporary, to: destination)
    try Self.fsyncDirectory(destination.deletingLastPathComponent())
}
```

Notes:

- `VACUUM INTO` must not run inside a transaction. `writeWithoutTransaction` is deliberate.
- If the SQLite build rejects a bound parameter in `VACUUM INTO`, execute a quoted literal produced by SQLite’s `%q` semantics. Do not concatenate an unescaped path.
- The destination must not exist. Remove only the temporary file, never the final path, before the rename.
- The destination is in the same directory as the live store, so the final rename is atomic on the same volume.
- `F_FULLFSYNC` is used instead of `fsync` on macOS. `fsync` alone does not guarantee the platter on all hardware.
- If `VACUUM INTO` is unavailable in the linked SQLite, fall back to the SQLite Online Backup API (`sqlite3_backup_init` / `sqlite3_backup_step` / `sqlite3_backup_finish`) through a small C wrapper. Do not fall back to a raw file copy.

Free-space precondition:

```text
freeSpace >= (databaseBytes × 2) + 64 MiB
```

The factor of two covers the new snapshot while the live file remains. A `VACUUM INTO` also needs temporary space for the new database. If the precondition fails, the backup is not attempted; the caller records `LR-005` and offers export instead.

### 9.4 Manifest generation

After the snapshot is durable, build the manifest **against the snapshot**, not against the live store.

1. Open the snapshot read-only.
2. Read `PRAGMA page_count`, `page_size`, `freelist_count`, `journal_mode`.
3. Read `PRAGMA user_version` and `sqlite_master` table names.
4. Run `PRAGMA quick_check`.
5. Run `PRAGMA foreign_key_check` and count by table.
6. Count rows in all known tables.
7. Decode all `books.payload_json` and the `library_state` root payload. A book payload is small enough to decode per row; this is the app’s parity source.
8. Sample `page_times.payload_json` (1% or 1,000 rows, whichever is larger, capped at 10,000). Decoding every timing is reserved for a full drill.
9. Hash the snapshot file with streaming SHA-256.
10. Write the manifest atomically next to the snapshot.

Manifest verification states:

| State | Checks | Use |
|---|---|---|
| `recorded` | hash only | never offered for restore |
| `quickVerified` | open + quick_check + counts | diagnostics only |
| `fullyVerified` | quick + integrity + FK + all books + state + timing sample | eligible for restore |
| `drilled` | fully verified + restore into a temp store + reopen + counts | preferred for restore |

The daily backup should reach `fullyVerified`. A drill runs weekly or on demand, not on every launch.

### 9.5 Rotation and catalog

The current `scheduleSQLiteBackupIfNeeded` prunes every `.sqlite3` in `Backups/` to the newest 10. That includes `sentinel-pre-repair-*.sqlite3` safety snapshots. Deleting the only pre-repair copy because ten daily backups exist is not acceptable.

New layout:

```text
Backups/
├── daily/
│   ├── library-2026-10-28_120000.sqlite3
│   └── library-2026-10-28_120000.sqlite3.manifest.json
├── safety/
│   ├── sentinel-pre-repair-2026-10-28_153000.sqlite3
│   └── sentinel-pre-repair-2026-10-28_153000.sqlite3.manifest.json
└── quarantine/
    └── failed-library-2026-10-27_120000.sqlite3
```

Rules:

- Daily retention: 10 verified snapshots.
- Safety retention: `max(undoWindowDays + 1, 3)` snapshots, never fewer than 3.
- Failed verification: move to `quarantine/`, keep 2, never delete the newest failed backup until a newer one is fully verified.
- The only `fullyVerified` or `drilled` backup is never deleted, regardless of count.
- Rotation runs before a new backup, not after, so a failed backup cannot evict a good one.
- The catalog is rebuilt by scanning the directories; there is no separate authoritative index that can drift.
- Legacy backups in `Backups/*.sqlite3` are migrated on first scan: verify, write a manifest, move to `daily/` or `safety/` based on the filename prefix. If a legacy backup fails verification, leave it in place and mark it `quarantined` in the catalog.

Probe changes:

- `StorageProbeFiles.backups(in:)` must scan `Backups/daily`, `Backups/safety`, and legacy root files.
- `BAK-007` counts daily + safety separately; >10 daily is a finding, >3 safety is normal.
- `BAK-010` fallback artifacts remains unchanged.

### 9.6 Restore drill

A drill proves the backup is usable without touching the live store.

1. Create `LibraryRecovery/drills/<drillID>/`.
2. Copy the backup there (or clone).
3. Open read-only with `SQLITE_OPEN_READONLY` and `PRAGMA query_only=ON`.
4. Run `quick_check`, `integrity_check(100)`, `foreign_key_check`.
5. Count all known tables; compare to the manifest.
6. Decode all books and state; sample timings.
7. Optionally open a `DatabaseQueue` read-only and run representative queries used by the app: `SELECT payload_json FROM books ORDER BY date_added`, `SELECT payload_json FROM library_state WHERE key='root'`, count sessions/page_times.
8. Write a `DrillReceipt` with timing, checks, counts, and `drilledAt`.
9. Delete the drill copy only after the receipt is durable. Never delete the source backup.

A drill is not a restore. It must never swap a file.

### 9.7 Failure handling

| Failure | Action |
|---|---|
| `VACUUM INTO` fails due to disk full | delete temp; `LR-005`; do not touch existing backups |
| Snapshot hash mismatches after copy | delete temp; `LR-012`; keep old backups |
| Manifest write fails | keep snapshot but mark `recorded`; do not offer restore |
| `quick_check` fails | move to quarantine; `LR-008`; keep previous verified |
| `foreign_key_check` fails | record counts; not automatically a backup failure (source may have orphans) |
| Decode failure on a book | backup is not fully verified; quarantine if this is a daily backup; do not overwrite a good backup |
| Rotation would delete the only verified backup | skip rotation; record `LR-003` style warning |
| App terminates mid-backup | temp file remains; next scan deletes `.snapshot-*` older than 24h; final path never partial |

### 9.8 Performance targets

Initial targets on a 1.0 GB database, Apple silicon:

| Operation | Target | Measurement |
|---|---|---|
| `VACUUM INTO` | < 15 s | wall clock, background utility |
| Hash | < 2 s | streaming SHA-256 |
| `quick_check` | < 2 s | SQLite |
| `integrity_check` | < 10 s | SQLite |
| Full manifest | < 20 s | including decode |
| Drill | < 30 s | copy + checks |

If a target is missed, record it; do not remove the check. Backups run off-main at utility priority. A backup in progress must not block reading, but it does take a read snapshot; if it causes UI stalls, measure and cap the page step.

### 9.9 Migration from current backups

On first launch of the new build:

1. Scan `Backups/*.sqlite3`.
2. For each file without a manifest, create a manifest with `verification.state = recorded`.
3. Verify the newest 3; if they pass, mark `fullyVerified`.
4. Move daily-looking files to `daily/`; move `sentinel-pre-repair-*` to `safety/`.
5. Do not delete anything during migration.
6. If a file fails to open, leave it in place and add a catalog warning. Do not quarantine automatically; the user may still want the raw file.
7. Record the migration in the recovery journal and in the receipt.

---

## 10. Incident detection and freeze

### 10.1 Triggers

| Trigger | Source | Incident kind | Notes |
|---|---|---|---|
| Load throws `undecodableBook` | `DataStore.loadFromDatabase` | `recordDecodeFailed` | Store may be structurally healthy; one row is bad |
| Load throws `undecodableLibraryState` | `DataStore.loadFromDatabase` | `recordDecodeFailed` | State payload is bad |
| Load throws open/IO error | `LibraryDatabase.init` / `loadBooks` | `databaseUnreadable` or `loadFailed` | Map SQLite code, no raw path |
| Saving fails | `DataStore.save` / `saveImmediately` | `writeFailed` | Risk of divergence; freeze immediately |
| `SQL-001` returns non-ok | Sentinel probe | `integrityCheckFailed` | Only if not already known; severity critical |
| `SQL-002` count above threshold | Sentinel probe | `databaseUnreadable`? No — issue first | Promotion rule below |
| Backup verification fails on all candidates | Recovery catalog | `backupVerificationFailed` | No restore point |
| Disk free below threshold | DataStore / probe | `diskSpaceCritical` | No safe writes |
| Schema newer than app | `LibraryDatabase` migration check | `schemaMismatch` | Refuse to open; update app |
| `swap.intent` found at launch | Recovery startup scan | `recoveryInterrupted` | Reconcile before UI |

### 10.2 Promotion matrix — issue vs incident

Not every critical finding is an incident. Freezing the app for a repairable row is harmful. The coordinator receives candidates and applies this matrix.

| Finding | Default | Promotion condition |
|---|---|---|
| `SQL-001` integrity_check not ok | **incident** | Always; structural integrity is unknown |
| `SQL-002` foreign_key_check > 0 | issue | Promote if load fails or count > 1,000 or > 5% of rows |
| `SQL-003` count parity mismatch | issue | Promote if the store cannot be read or books are missing |
| `SQL-004` duplicate IDs | issue | Promote if duplicates prevent a primary-key operation or load |
| `SQL-005` WAL large | maintenance | Never promote; checkpoint is the action |
| `SQL-007` unreadable rows | issue | Promote if `loadBooks` fails or the count is > 0 and the app cannot open |
| `SQL-013` JSON parse failures | issue | Promote if the failing row is required to load |
| `BAK-003` newest backup does not open | issue | Promote if no other verified backup exists |
| `BAK-004` restore drill fails | issue | Promote if no other verified backup exists |
| `FILE-001` book file missing | issue | Never promote; this is a missing external file, not DB corruption |
| Disk free < 500 MB | **incident** | Always; writes cannot be trusted |
| Schema mismatch | **incident** | Always; app cannot interpret the store |

A promotion decision is recorded in `incident.json` with the rule ID and count. It is not a silent escalation.

### 10.3 Incident creation

```swift
func openIncident(_ request: LibraryIncidentRequest) async throws -> LibraryIncident {
    let incident = LibraryIncident(
        id: "inc_" + UUID().uuidString,
        kind: request.kind,
        state: .detected,
        trigger: request.trigger,
        detectedAt: clock.now,
        updatedAt: clock.now,
        evidence: request.evidence,
        fingerprint: nil,
        preserved: nil,
        diagnosis: nil,
        options: [],
        chosenOptionID: nil,
        receipts: [],
        lastError: nil,
        userSummaryKey: request.userSummaryKey,
        readOnly: false)
    try store.write(incident)
    return incident
}
```

One unresolved incident at a time. If a second candidate arrives, it is merged as evidence into the existing incident when the kind matches, or recorded as a secondary finding. It does not create a second recovery workflow.

### 10.4 Freeze protocol

Freezing is a three-party operation. The coordinator must not proceed until all three are true:

1. Sentinel is suspended and no cycle is in flight.
2. DataStore has drained its write queue and will reject new writes.
3. The SQLite pool is closed.

```text
Coordinator                    DataStore                     Sentinel
    │                             │                             │
    ├─ acquire recovery lock ────►│                             │
    ├─ setOperationalMode(.suspended) ───────────────────────►│
    │                             │◄── wait for cycle ─────────┤
    ├─ freezeForRecovery(reason) ►│                             │
    │                             ├─ cancel save timer          │
    │                             ├─ drain dbWriteQueue        │
    │                             ├─ attempt saveImmediately   │
    │                             ├─ export memory snapshot    │
    │                             ├─ close pool                │
    │◄── freeze token ────────────┤                             │
    ├─ persist incident .frozen ─►│                             │
```

Implementation details:

- `freezeForRecovery` is idempotent. A second call returns the existing token if the reason matches; otherwise it throws `LR-006`.
- The save timer is invalidated before the drain. A timer that fires after the freeze would otherwise enqueue a write behind the barrier.
- `saveImmediately` is attempted once while the store is still writable. If it fails, the error is recorded but the freeze proceeds; the memory snapshot may still preserve the current session.
- `exportMemorySnapshot` encodes `books` and `libraryState` with the app’s normal JSON encoder, writes `memory-snapshot.json` in the incident directory, and returns the data hash. It must not include debug-only fields.
- `close` runs on `dbWriteQueue.sync` so all prior writes are complete. If close throws, the incident becomes `failed` with `LR-006`; no file is moved.
- The freeze token is held by the coordinator; no other component can release it.

Sentinel quiescence:

```swift
func quiesce(timeout: Duration = .seconds(5)) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while isCycleRunning {
        if ContinuousClock.now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return true
}
```

If quiescence times out, the coordinator still freezes DataStore but marks the incident `.failed` with a note that a Sentinel cycle may have been in flight. It does not proceed to preserve until the cycle is known to be done or the process is restarted.

### 10.5 Preserve protocol

Preconditions:

- recovery lock held;
- store frozen and closed;
- free space >= (main + WAL + SHM) × 2 + 64 MiB;
- incident directory created with `0700`.

Algorithm:

1. Compute the original fingerprint from the live files (hash + metadata).
2. Copy `library.grdb.sqlite3` to `preserved/library.grdb.sqlite3` using `clonefile`/`COPYFILE_CLONE` when available, else `copyItem`.
3. Copy `-wal` if present, then `-shm` if present. Copy order is main, WAL, SHM so a hypothetical concurrent write is at least visible in the manifest hash; there should be no writer at this point.
4. Hash every preserved file; compare to the source hash.
5. Write `preservation.json` with file roles, bytes, hashes, method, timestamp.
6. Write `memory-snapshot.json` if `exportMemorySnapshot` returns data; hash it.
7. Write the combined hash: SHA-256 of `role:name:sha256` lines in sorted order.
8. Update `incident.preserved` and `incident.state = .frozen` atomically.

If any copy or hash fails:

- delete the partial preserved directory;
- record `LR-001`/`LR-012`;
- leave the original untouched;
- incident `.failed`;
- offer export only if a separate copy can be made later.

Do not proceed with a “best effort” preserved copy. A partial copy is not a restore point.

### 10.6 Diagnosis protocol

Diagnosis runs on the preserved copy, never on the live file.

1. Open the preserved main file with `SQLITE_OPEN_READONLY` and `PRAGMA query_only = ON`.
2. If opening fails, record `canOpenReadOnly = false` and the mapped SQLite code. Do not attempt `PRAGMA` writes.
3. `PRAGMA quick_check` — fast structural check.
4. If quick_check is not `ok`, `PRAGMA integrity_check(100)` — collect messages, coarsen them to stable codes or table/page hints; never store raw user text.
5. `PRAGMA foreign_key_check` — group by `table` and count. Use the table-valued pragma if available; otherwise fall back to a `LEFT JOIN` inventory.
6. `PRAGMA page_count`, `page_size`, `freelist_count`, `journal_mode`, `user_version`.
7. List `sqlite_master` tables; compare against the expected table set. Missing tables are a serious finding; unexpected tables are preserved but noted.
8. Count every known table.
9. Decode every `books.payload_json` and the `library_state` root payload. Count failures; do not store payloads.
10. Sample `page_times.payload_json`; count failures. A full decode is a separate, explicit scan.
11. Test `VACUUM INTO` on a second copy of the preserved database (or a temp copy) to determine `canVacuum`. Do not run it on the preserved file itself; it writes a new file.
12. Determine `canRebuildFromPayloads`: books table readable, all book payloads decode, and the schema has the known tables. Page timings may still be unrecoverable.
13. Determine `canRecoverPageTimings`: page_times table readable and count > 0.
14. Write `diagnosis.json` atomically; update the incident.

Diagnosis never writes to the preserved copy. If SQLite creates a `-shm` while opening read-only, that is acceptable only in the preserved directory; it is recorded and excluded from the preserved hash set.

### 10.7 Read-only mode

While an incident is open:

- `DataStore` rejects saves and imports.
- The library UI may display the last in-memory books, but marks them “Read-only — recovery in progress.”
- Opening the reader is allowed only in a read-only presentation that does not start a session. In the first implementation, disable opening the reader; display a banner instead. This avoids losing a session that cannot be saved.
- Export is allowed.
- Settings changes unrelated to recovery are allowed but must not touch the library.
- Sentinel is suspended; no probes, no repairs, no notifications beyond the incident notice.

### 10.8 Exit criteria

An incident can become `resolved` only when:

1. A recovery option completed and its receipt is durable.
2. `DataStore.reopenAfterRecovery` succeeded and loaded books + state.
3. Independent verification passed (Section 12.5).
4. Sentinel completed a deep verification cycle with complete required coverage and zero critical database findings.
5. The preserved original still exists.

If any condition fails, the incident stays `failed` or `awaitingDecision`. It does not become `resolved` because the app happens to open.

---

## 11. Recovery options

### 11.1 Option A — Export a copy (read-only)

**Purpose:** get the bytes out without changing anything.

**Preconditions:** preserved store exists.

**Algorithm:**

1. Ask for a destination folder with `NSSavePanel` (directory selection).
2. Create `Asterisma-recovery-<timestamp>/`.
3. Copy the preserved main file, WAL, SHM, `preservation.json`, `diagnosis.json`, `incident.json` (safe projection), and a README.
4. Hash the exported main file; compare to the preserved hash.
5. Write a receipt with `outcome = .exported`.
6. Leave the incident in `awaitingDecision`; export is not a resolution.

**Estimate:** `recoveredRows = nil`, `lostRows = 0`, `unknownRows = false`. This option does not claim recovery.

**Confirmation:** single button.

**Verification:** hash comparison only; no DB mutation.

**Failure:** if the destination is unavailable or the hash mismatches, receipt `failed`, original untouched.

### 11.2 Option B — Restore a verified backup

**Purpose:** return to a known-good store.

**Preconditions:**

- at least one backup with `fullyVerified` or `drilled`;
- backup schema version <= app schema version;
- free space for the incoming file + preserved original;
- recovery lock held;
- store frozen and closed.

**Algorithm:** Section 12.

**Estimate:**

```text
lostRows = max(0, currentCounts - backupCounts) per table
lostTimeWindow = now - backup.createdAt
unknownRows = current store cannot be read
```

If the current store cannot be read, the UI says “We cannot tell how many newer rows will be lost; the backup is from <date>.” That is acceptable, but the confirmation is stronger.

**Confirmation:**

- backup newer than 24h and current store readable → double confirm;
- older than 24h, or current store unreadable, or any lost rows → type `RESTORE`.

**Verification:** independent checks in Section 12.5, plus a Sentinel deep cycle.

**Failure:** rollback to the exact pre-restore file; if rollback fails, `.critical`, preserve both, no deletion.

### 11.3 Option C — Salvage readable rows

**Purpose:** create a new working store from a corrupt original, accepting that some rows are lost.

**Preconditions:**

- preserved copy exists;
- `canOpenReadOnly` is true;
- at least one readable table;
- free space for a new store.

**Algorithm:** Section 13.1.

**Estimate:** based on diagnosis counts. If a table cannot be read, `unknownRows = true`; do not pretend it is zero.

**Confirmation:** type `SALVAGE`.

**Verification:** new store opens, quick_check/integrity_check, counts vs recovered manifest, books/state decode, optional page-timing sample.

**Failure:** delete the temporary new store; original preserved; incident stays `awaitingDecision`.

### 11.4 Option D — Rebuild normalized tables from payloads

**Purpose:** recover a structurally valid database whose normalized tables are damaged, using `books.payload_json` and `library_state.payload_json` as the source.

**Preconditions:**

- all book payloads decode;
- library state decodes;
- the app schema is known;
- page-timing loss is explicitly disclosed if `page_times` is unreadable.

**Algorithm:** Section 13.2.

**What it can recover:** books, session summaries, notes, collections, achievements, goals, deadlines, and other state in the payloads.

**What it cannot recover:** per-page timings that exist only in a damaged `page_times` table; weather/audio/behavior rows that are not in the payload and cannot be read.

**Confirmation:** type `REBUILD`; the UI must name the page-timing loss if applicable.

**Verification:** independent checks; counts; all books/state decode; Sentinel deep cycle.

### 11.5 Option E — Quarantine one undecodable record

**Purpose:** unblock a fail-closed load when exactly one row is undecodable and the rest of the store is healthy.

**Preconditions:**

- diagnosis identifies a specific row;
- the row’s raw bytes can be exported;
- a safety snapshot exists;
- the store is otherwise structurally valid.

**Algorithm:**

1. Copy the raw row (`id`, `payload_json`, table) to `quarantine/rows/inc_<id>-row.json`.
2. Hash the raw payload.
3. Begin a SQLite transaction.
4. Delete the row by primary key.
5. Verify `changes() == 1`.
6. Commit.
7. Reload the store; if load fails, roll back by re-inserting the raw row from quarantine.
8. Verify the row count decreased by exactly one.

**Estimate:** `lostRows = 1`, `unknownRows = false`; the raw row is preserved and restorable.

**Confirmation:** type `QUARANTINE`; the UI shows the row ID and a hash, not the payload.

**Undo:** re-insert the raw row in a transaction; verify the load fails again (which is expected) or that the row is back. Undo is available while the quarantine file exists.

**Risk:** this is a data-loss choice even though the row is preserved. It is R3 and manual. It must never be automatic.

### 11.6 Option F — Do nothing / remain read-only

**Purpose:** stop, preserve, and let the user think or get help.

**Preconditions:** none beyond a preserved store.

**Algorithm:** set incident `.abandoned`; keep frozen/read-only; no file mutation.

**Estimate:** no change.

**Confirmation:** single button with copy that explains the app stays read-only.

**Verification:** none; no success claim.

### 11.7 Option comparison

| Option | Risk | Mutates live store | Recoverable | Requires verified backup | Confirmation |
|---|---|---|---|---|---|
| Export | read-only | no | n/a | no | single |
| Restore | file-level | yes (replace) | yes, pre-restore copy | yes | type `RESTORE` when loss |
| Salvage | file-level | yes (new file) | original preserved | no | type `SALVAGE` |
| Rebuild | file-level | yes (new file) | original preserved | no | type `REBUILD` |
| Quarantine row | row-level | yes (delete one row) | yes, raw row | safety snapshot | type `QUARANTINE` |
| Do nothing | none | no | n/a | no | single |

### 11.8 Data-loss accounting

Every option produces an estimate before execution and an actual after.

```text
For restore:
  beforeCounts = current store counts (or unknown)
  afterCounts  = backup manifest counts
  lost         = max(0, before - after) per table

For salvage:
  recovered    = rows actually inserted into the new store
  lost         = max(0, sourceCounts - recovered) when source count is readable
  unknown      = true when a table cannot be counted

For rebuild:
  recovered    = books + sessions + notes + collections + state rows
  lost         = pageTimes if page_times unreadable
  unknown      = true for auxiliary tables that cannot be read

For quarantine:
  recovered    = 0 (the row is removed from the live store)
  lost         = 1
  preserved    = 1 raw row
```

The receipt records `recoveredRows`, `lostRows`, `quarantinedRows`, and the verification object. The UI shows the actual numbers after execution, even when they are worse than the estimate.

---

## 12. Restore and swap algorithm

### 12.1 Preconditions

A restore is allowed only when all are true:

- incident is `awaitingDecision`;
- recovery lock is held;
- preserved store exists and hash-verifies;
- selected backup has a manifest with `fullyVerified` or `drilled`;
- backup hash matches the manifest;
- backup schema version <= app schema version;
- free space >= backup bytes + current bytes + 64 MiB;
- store is frozen and closed;
- no Sentinel cycle is running;
- confirmation token matches the option and plan hash.

If any precondition fails, the option is disabled with a reason code. The executor re-checks all preconditions; UI state is not trusted.

### 12.2 Step-by-step

```text
 1. Acquire lock (already held).
 2. Re-verify backup manifest + hash.
 3. Write swap.intent (stage intentWritten); fsync file; fsync directory.
 4. DataStore.drainAndCloseForRecovery() — idempotent; ensure closed.
 5. Move live main file to incident/pre-restore.sqlite3.
    - If the move fails, write receipt LR-007, leave intent, stop.
 6. Move live -wal and -shm to incident/pre-restore.* if they exist.
 7. Copy backup to live-directory/.incoming-<uuid>.sqlite3.
 8. Hash the incoming copy; compare to manifest.sha256.
 9. fsync incoming; fsync directory.
10. Rename incoming to library.grdb.sqlite3 (same directory, atomic).
11. fsync directory; update intent stage renamed.
12. DataStore.reopenAfterRecovery().
13. Verify: quick_check, integrity_check, FK, counts vs manifest, decode books/state.
14. Sentinel.runCycle(.deep); require complete required coverage and zero critical DB findings.
15. Write receipt; incident resolved; clear swap.intent.
```

Important orderings:

- The intent is written **before** the store is closed. If the app crashes after the intent but before the close, the live file is still the original and startup can clean up.
- The original is moved, not deleted. It remains the rollback source.
- The incoming copy is made in the live directory so the final rename is same-volume atomic. A cross-volume `moveItem` is not atomic.
- `-wal`/`-shm` are removed/moved only after the pool is closed. Otherwise SQLite can recreate them or apply an old WAL to the new main file.
- Verification runs after reopen, not before. A file that passes `integrity_check` can still fail the app’s decode.

### 12.3 Crash consistency

`swap.intent` is the source of truth. It is written atomically and fsynced before any irreversible step.

| Crash point | Disk state | Startup action |
|---|---|---|
| After intent, before close | original live, intent | live hash = before → delete intent, return to `awaitingDecision` |
| After original moved, before incoming copied | live missing, pre-restore exists, intent | restore pre-restore to live, delete intent, incident `failed` |
| After incoming copied, before rename | live missing, incoming exists, pre-restore exists | verify incoming; if good, complete rename; else restore original |
| After rename, before reopen | live = new, pre-restore exists, intent | verify live hash = after; reopen/verify; if fail, rollback |
| After reopen, before receipt | live = new, pre-restore exists | verify; write receipt; resolve |
| After receipt, before clearing intent | both exist | verify receipt + hashes; clear intent |
| During rollback | pre-restore exists, live may be partial | restore pre-restore; if hash mismatch, `critical` |
| During salvage temp write | temp exists | delete temp older than 24h; original untouched |
| During row repair transaction | SQLite journal/WAL | SQLite rolls back; verify counts |

Startup reconciliation algorithm:

```text
if no swap.intent: continue normal launch
read intent
if live exists and sha256(live) == intent.expectedAfter:
    verify live; if ok -> complete; else -> rollback
else if live exists and sha256(live) == intent.expectedBefore:
    clear intent; return incident to awaitingDecision
else if pre-restore exists:
    verify pre-restore; restore it; incident failed
else:
    incident critical; preserve both; show recovery needed
```

Never delete a file whose hash is unknown. Never “assume” a rename succeeded.

### 12.4 Rollback

Rollback is a first-class operation, not an error path afterthought.

1. Close the new pool if open.
2. Remove `library.grdb.sqlite3` only if its hash matches the new file; if not, move it to `incident/failed-new.sqlite3` and keep it.
3. Remove `-wal`/`-shm` created by the new store.
4. Move `pre-restore.sqlite3` back to the live path.
5. Restore `pre-restore.sqlite3-wal`/`-shm` if they were moved, or leave them absent if the original had none.
6. fsync file and directory.
7. Reopen and verify.
8. Write receipt `outcome = .rolledBack` with reason.

If any step fails, do not retry blindly. Enter `.critical`:

- both `pre-restore` and failed new file preserved;
- no further writes;
- UI says “Recovery could not be completed safely. Your original copy is preserved.”
- support can inspect the receipt and hashes.

### 12.5 Independent post-recovery verification

Verification must not use the probe that failed.

| Check | Method | Pass condition |
|---|---|---|
| File opens | read-only open | `PRAGMA schema_version` returns |
| Structural | `PRAGMA quick_check` | `ok` |
| Structural deep | `PRAGMA integrity_check(100)` | `ok` |
| Foreign keys | `PRAGMA foreign_key_check` | count 0 or documented exceptions |
| Tables | `sqlite_master` | expected tables present |
| Counts | SQL counts vs manifest | exact for books/state; exact for sessions/page_times if claimed |
| Payloads | decode all books + state | 0 failures |
| Timing sample | decode 1% / 1,000 rows | 0 failures or documented |
| App load | `DataStore.reopenAfterRecovery` | books/state loaded, no `sqliteLoadFailure` |
| Sentinel | deep cycle | required coverage complete, no critical DB findings |

If any check fails, the restore is rolled back and the incident is `failed`. The receipt records which check failed.

### 12.6 Failure modes

| Failure | Handling |
|---|---|
| Backup hash mismatch | refuse restore; `LR-014`; leave incident |
| Backup schema newer | refuse; `LR-004`; tell user to update app |
| Disk full during incoming copy | delete incoming; restore original if moved; `LR-005` |
| Rename fails | keep both files; restore original; `LR-007` |
| Reopen fails | close; rollback; `LR-008` |
| Verification fails | rollback; `LR-008` |
| Rollback fails | `.critical`; preserve both; no further writes |
| App crashes mid-swap | startup reconciliation table above |
| User force-quits during progress | treat as crash; startup reconciliation |
| Backup has orphan FKs | verify reports them; restore may still proceed if user accepts, but `foreignKeysOK` false and receipt notes it |

---

## 13. Salvage and rebuild

### 13.1 What “salvage” means here

This plan does **not** implement a custom SQLite b-tree page-repair engine. That is a specialist storage-engine project with a large correctness surface. The app should use SQLite’s own primitives conservatively:

1. `VACUUM INTO` a new file (the preferred path).
2. If that fails, read tables row by row and copy readable rows into a fresh schema.
3. If a page range is unreadable, record the range and continue where possible.
4. Never use `PRAGMA writable_schema` to “fix” the schema.
5. Never write to the preserved original.

A salvage that cannot read a table must say so. “Recovered 0 rows” is not the same as “the table was empty.”

### 13.2 Conservative salvage algorithm

```text
Input: preserved store copy P, expected schema S
Output: new store N, recovered-row manifest, receipt

1. Create N from the current schema (no data).
2. Try VACUUM INTO N from P.
   - If it succeeds and N passes quick_check, use N as the salvage candidate.
   - If it fails, continue with row extraction.
3. For each known table T in S:
   a. Check T exists in P.
   b. Read P's row count for T if possible.
   c. Iterate rows in rowid ranges (e.g. 10,000 at a time).
   d. For each row, decode only what is needed to insert into N.
   e. Insert into N inside a transaction per range.
   f. On a read error, record the range as unreadable and continue to the next range.
   g. Never skip an error silently; count it in the manifest.
4. For books:
   - Prefer books.payload_json as the canonical row.
   - Decode Book; insert book summary, notes, collections, sessions from the payload.
   - pageTimes are empty in the payload; do not invent them.
5. For sessions:
   - If sessions table is readable, use it; otherwise reconstruct session summaries from books.payload_json.
6. For page_times:
   - Only page_times rows can restore per-page timings.
   - If the table is unreadable, record page-timing loss explicitly.
7. For library_state:
   - Copy the root payload if it decodes; otherwise mark state lost and do not substitute defaults silently.
8. For auxiliary tables (weather, audio, behavior, application_sessions, inactivity, device_state_events, meta):
   - Copy readable rows; record per-table counts.
9. Verify N: quick_check, integrity_check, foreign_key_check, counts, decode sample.
10. Write receipt with recovered/lost/unknown per table.
```

### 13.3 Book reconstruction from payload

`books.payload_json` is a `Book` summary. It includes notes, collection IDs, session summaries, and cached analytics. It excludes per-page timings.

Reconstruction order:

1. `library_state` first: collections must exist before `book_collections`.
2. Books: insert `books` row and `book_collections` links for valid collection IDs.
3. Notes: insert from the book payload; preserve IDs and timestamps.
4. Sessions: insert session summaries from the book payload; pageTimings empty.
5. Achievements: insert from `library_state.earnedAchievements`.
6. Page timings: insert only from readable `page_times` rows; match by session ID.

If a book payload fails to decode:

- do not drop it silently;
- export the raw row to `quarantine/rows/`;
- count it as `lostBooks` in the receipt;
- leave a placeholder? No. A placeholder would be a fabricated book. Do not create one.

### 13.4 Logical rebuild from payloads

A logical rebuild is appropriate when the SQLite file is structurally valid but normalized tables are wrong, and the payloads are intact.

```text
1. Create N with the current schema.
2. Read all books.payload_json from P.
3. Decode every Book. If any fails, disable the rebuild option.
4. Insert library_state from the root payload.
5. Insert collections and achievements from state.
6. Insert books, notes, collection links, session summaries.
7. Copy page_times rows from P if the table is readable.
8. Copy auxiliary tables from P if readable.
9. Record every table that could not be copied.
10. Verify N independently.
```

The rebuild must not delete auxiliary tables merely because the app models do not represent them. Weather, audio, behavior, application sessions, inactivity, and device state are user data too.

### 13.5 Index-only corruption

`integrity_check` can report errors such as “wrong # of entries in index” while tables are intact. On a copy, `REINDEX` can rebuild indexes. This is a possible salvage shortcut, but it is not the default.

Rules:

- Run `REINDEX` only on a copy, never on the live store.
- Run it only when the diagnosis classifier says the errors are index-only.
- After `REINDEX`, run `integrity_check` again. If it becomes `ok`, the copy is a candidate; still verify row counts and decode.
- If errors remain, fall back to table extraction or restore.
- Record `reindexAttempted` and `reindexResult` in the receipt.

### 13.6 What cannot be recovered

| Lost data | Why | Only recovery |
|---|---|---|
| Per-page timings when `page_times` is unreadable | Not present in book payloads | Verified backup |
| Book metadata when `books.payload_json` is unreadable | No other source for that book | Verified backup; raw payload quarantine for forensics |
| Library state when the root payload is unreadable | No alternate state file in SQLite mode | Verified backup |
| Weather/audio/behavior rows in an unreadable table | Not represented in book payloads | Verified backup |
| A deleted external book file | Not in the database | Re-import by the user |

This table belongs in the UI. A salvage that cannot recover page timings must say so before the user confirms.

### 13.7 Verification

| Check | Required |
|---|---|
| New store opens read-only | yes |
| `quick_check` | yes |
| `integrity_check(100)` | yes |
| `foreign_key_check` | yes; count recorded |
| Books decode | all rows; 0 failures |
| State decodes | yes |
| Counts vs recovered manifest | exact |
| Page-timing sample | 1% or 1,000 rows |
| App load via DataStore | yes |
| Sentinel deep cycle | yes |

### 13.8 Performance

Salvage is the slowest operation. Targets for a 1.0 GB store:

| Operation | Target |
|---|---|
| `VACUUM INTO` salvage | < 30 s |
| Row extraction fallback | < 5 min |
| Verification | < 30 s |
| Full rebuild from payloads | < 60 s |

If a target is exceeded, show progress and allow cancellation before the commit step. Cancellation after the new store is built but before the swap simply deletes the temp file; the original is untouched.

---

## 14. Row-level repairs

### 14.1 Why this is separate from file recovery

Deleting an orphan timing row is a SQLite write, but it is not structural file repair. It belongs in a row-level service that can:

- identify exact rows;
- export them before deletion;
- delete in one transaction;
- verify counts;
- re-insert for undo;
- run while the store is open, without a file swap.

Sentinel proposes the repair. Recovery executes it. DataStore reloads afterward.

### 14.2 Orphan inventory

New read-only probe `SQL-015` (tier `.t3`, optional):

```sql
-- Orphan sessions
SELECT s.id
FROM sessions s
LEFT JOIN books b ON b.id = s.book_id
WHERE b.id IS NULL;

-- Orphan page timings
SELECT p.id
FROM page_times p
LEFT JOIN sessions s ON s.id = p.session_id
WHERE s.id IS NULL;

-- Orphan book_collections
SELECT bc.book_id, bc.collection_id
FROM book_collections bc
LEFT JOIN books b ON b.id = bc.book_id
LEFT JOIN collections c ON c.id = bc.collection_id
WHERE b.id IS NULL OR c.id IS NULL;

-- Orphan notes
SELECT n.id
FROM notes n
LEFT JOIN books b ON b.id = n.book_id
WHERE b.id IS NULL;

-- Orphan weather / audio
SELECT w.id FROM weather_snapshots w
LEFT JOIN sessions s ON s.id = w.session_id
WHERE w.session_id IS NOT NULL AND s.id IS NULL;
```

`SQL-015` returns counts by table, not IDs, in safe evidence. It is a signal. The exact IDs are fetched by `LibraryRowRepairService` only when the user opens the repair flow, and they are never written to the journal or diagnostics.

### 14.3 Row repair plan

```swift
nonisolated struct RowRepairPlan: Codable, Sendable {
    var id: String                 // "row_" + UUID
    var table: String
    var ruleID: String             // SQL-002 / SQL-015
    var issueFingerprint: String
    var rows: [RowRepairRow]       // id + table + raw payload hash
    var expectedCount: Int
    var exportURL: URL?            // internal, not persisted in safe journal
    var risk: RecoveryRisk         // .rowLevel or .fileLevel
}

nonisolated struct RowRepairRow: Codable, Sendable {
    var primaryKey: String
    var secondaryKey: String?
    var rawJSON: String            // quarantined, never journaled
    var sha256: String
}
```

Execution:

1. Freeze saves / pause the app mutation path (not a full file freeze; a row-level lock is enough).
2. Create a safety snapshot via `DataStore.createSafetySnapshot()`.
3. Export rows to `LibraryRecovery/quarantine/rows/<planID>.json`; fsync.
4. Begin `IMMEDIATE` transaction.
5. `DELETE FROM <table> WHERE <pk> IN (...)` in batches.
6. Verify `changes()` equals `expectedCount`.
7. Commit.
8. Reload `DataStore` from the database.
9. Re-run `SQL-015` and the affected rule; require zero.
10. Write receipt; if verification fails, re-insert from the quarantine export and reload.

Undo:

- Read the quarantine export.
- Re-insert rows with `INSERT OR IGNORE` in one transaction.
- Verify the row count increased by the expected amount.
- Reload the store.
- Mark the receipt undone.

Undo is available while the quarantine file exists (default 30 days). It is not available after the file is deleted.

### 14.4 Risk and consent

| Orphan class | Default risk | Consent |
|---|---|---|
| `page_times.session_id` orphan | row-level | preview count + type `REMOVE` |
| `sessions.book_id` orphan | row-level | preview count + type `REMOVE` |
| `book_collections` orphan | row-level | preview count |
| `notes.book_id` orphan | row-level | preview count + export |
| `weather_snapshots.session_id` orphan | row-level | preview count |
| Large batch (> 1,000 rows) | file-level caution | double confirm + backup |

No orphan repair is automatic. It is not part of Sentinel auto-safe even when the autonomy is `autoSafe`.

### 14.5 What row repair must not do

- Do not delete a book because its file is missing.
- Do not delete a session because it has no page timings.
- Do not delete a note because its book payload could not decode.
- Do not merge duplicate books.
- Do not touch rows whose parent is only temporarily unavailable.
- Do not run while an incident is open; the file may be suspect.

---

## 15. Sentinel integration

### 15.1 Roles

| Sentinel responsibility | Recovery responsibility |
|---|---|
| Detect and explain a candidate | Decide whether it is an incident |
| Provide rule ID, fingerprint, evidence | Preserve, diagnose, offer options |
| Pause during recovery | Execute file-level surgery |
| Verify after reopen | Produce the receipt |
| Journal the story | Own the recovery log |
| Show the issue in Health Center | Show the recovery incident |

Sentinel does not execute recovery. Recovery does not write Sentinel issues.

### 15.2 Runtime changes

```swift
actor SentinelRuntime {
    private var recoveryGate: (any SentinelRecoveryGate)?
    private var operationalMode: LibraryOperationalMode = .normal

    func setRecoveryGate(_ gate: any SentinelRecoveryGate) {
        self.recoveryGate = gate
    }

    func setOperationalMode(_ mode: LibraryOperationalMode) {
        operationalMode = mode
        postUpdate()
    }

    func runCycle(trigger: SentinelCycleTrigger, scope: SentinelCycleScope = .normal) async -> SentinelCycleReport {
        guard case .normal = await currentOperationalMode() else {
            return SentinelCycleReport.suspended(reason: "recovery")
        }
        // existing cycle
    }

    func repair(fingerprint: String) async -> SentinelRepairOutcome {
        guard case .normal = await currentOperationalMode() else {
            return .blocked("recovery", "Recovery is in progress; Sentinel is paused.")
        }
        // existing path
    }
}
```

`currentOperationalMode` combines the local `operationalMode` with the gate (defense in depth). If either says suspended, the cycle is refused.

### 15.3 Promotion adapter

```swift
@MainActor
final class SentinelIncidentPromoter {
    func candidate(from report: SentinelCycleReport) -> LibraryIncidentCandidate? {
        // Only the rules in the promotion matrix can produce a candidate.
        // The caller (coordinator) decides whether to open an incident.
    }
}
```

Rules:

- One candidate per cycle, highest severity first.
- A candidate does not mutate anything.
- A candidate is ignored if an incident is already open; its evidence is merged.
- A candidate from a non-required optional probe cannot freeze the app unless the matrix says so.
- The promoter never reads user text; it uses rule IDs, counts, and fingerprint.

### 15.4 Verification cycle

After a recovery reopens the store:

1. Coordinator sets `operationalMode = .normal` for verification only (or uses a dedicated `verify` mode that allows probes but not repairs).
2. Sentinel runs `runCycle(trigger: .repair, scope: .deep)`.
3. Require:
   - required coverage complete (`requiredRan == requiredTotal`);
   - no critical database findings (`SQL-001`, `SQL-002` above threshold, schema mismatch);
   - no new undecodable rows;
   - the original issue fingerprint is gone or marked resolved.
4. If pass, close the incident. If fail, keep it `failed` and offer retry/restore.

During this cycle, Sentinel repairs are disabled even if the mode is normal. Add a `verificationOnly` flag or a gate reason `.recoveryVerifying` that allows probes but blocks mutations.

### 15.5 Journal events

Add additive cases:

```swift
nonisolated enum SentinelJournalEvent: String, Codable, CaseIterable, Sendable {
    // existing cases...
    case incidentOpened
    case incidentFrozen
    case incidentDiagnosed
    case recoveryOffered
    case recoveryStarted
    case recoveryVerified
    case recoveryFailed
    case recoveryAbandoned
    case recoverySuspended
    case recoveryResumed
    case unknown
}
```

Forward compatibility:

- Custom `init(from:)` maps any unknown raw string to `.unknown`.
- `readAll` counts `.unknown` as `forwardCompatible`, not `corrupt`.
- New entry fields: `incidentID`, `recoveryID`, `optionKind`, `counts`. No paths, titles, or payloads.
- Old app reading a new journal sees `.unknown` and skips it without calling the file corrupt. This is a deliberate downgrade behavior; document it.

### 15.6 Diagnostics

`SentinelDiagnostics` schema bumps to 2:

```swift
struct RecoveryRow: Codable {
    var incidentID: String
    var kind: String
    var state: String
    var option: String?
    var outcome: String?
    var recoveredRows: Int?
    var lostRows: Int?
    var durationMilliseconds: Int?
    var errorCode: String?
}

struct Document: Codable {
    // existing fields...
    var recovery: [RecoveryRow]
}
```

Rules:

- No absolute paths.
- No book titles, authors, note text, or payloads.
- Incident IDs are opaque; recovery IDs are opaque.
- `containsDebugDetail` remains a guardrail; add `containsSecretFixture` in tests.
- Schema v2 is additive; export only, no reader compatibility burden.

### 15.7 Notifications

- Only if `SentinelConfiguration.notificationsEnabled` is true.
- Title: “Library needs attention.”
- Body: “Open Asterisma to review recovery options. Your original file has been preserved.”
- Never include a book title, path, or count that identifies content.
- One notification per incident; no repeated hourly alerts.
- Notification permission is already requested at launch; recovery must not trigger a second prompt.

### 15.8 Launch card and banner

`SentinelReportCardView` stays for ordinary Sentinel summaries. Add a separate `LibraryIncidentCardView`:

| State | Card |
|---|---|
| `detected` / `freezing` | “Checking your library…” spinner; no actions |
| `diagnosing` | “Diagnosing a copy of your library…” |
| `awaitingDecision` | “Your library needs attention. A copy has been preserved.” [Review] |
| `executing` | “Recovering…” progress; no dismiss |
| `failed` | “Recovery could not finish. Your original copy is preserved.” [Review] |
| `critical` | “Recovery needs your attention. Both copies are preserved.” [Review] |
| `resolved` | no card; optional one-time “Recovery verified” note |

The card is not dismissible while `executing` or `critical`. It can be dismissed while `awaitingDecision`, but a persistent banner remains in the library until the incident is resolved or abandoned.

---

## 16. Health Center UX

### 16.1 Surface model

Rename the window header from “Sentinel Health” to **Library Health**. Keep the existing window ID `sentinel-health-center` for state restoration and menu compatibility.

Tabs:

| Tab | Content |
|---|---|
| Overview | Health band, coverage, active incident banner, last check |
| Issues | Sentinel issues, filters, detail, row repairs |
| History | Sentinel journal + recovery receipts, one timeline |
| Checks | Probe results, durations, coverage disclosure |
| Recovery | Present only when an incident exists or recovery history exists |
| Settings | Sentinel autonomy/cadence + Backups & Recovery pane |

The Recovery tab is inserted before Settings when an incident is open. If no incident exists, Settings shows backup status and the last drill.

### 16.2 Recovery tab layout

```text
┌─────────────────────────────────────────────────────────────┐
│  Library needs attention                    [critical badge]│
│  Your library file has structural damage.                   │
│  A copy was preserved at 18:00. The original is untouched.  │
├─────────────────────────────────────────────────────────────┤
│  What we found                                              │
│  • The database fails its integrity check (SQL-001)         │
│  • 3 pages are damaged; 12 books, 74 sessions are readable  │
│  • The newest verified backup is from 2026-10-27 12:00      │
├─────────────────────────────────────────────────────────────┤
│  What you can do                                            │
│  ○ Export a copy (read-only)                                │
│  ○ Restore the verified backup — loses up to 1 day          │
│  ○ Salvage readable rows — page timings may be lost         │
│  ○ Do nothing (stay read-only)                              │
├─────────────────────────────────────────────────────────────┤
│  [Review and continue]                                      │
└─────────────────────────────────────────────────────────────┘
```

### 16.3 Incident detail

Sections:

1. **What happened** — plain-language summary, no SQL.
2. **What is safe** — “A full copy of the original is preserved. We will not change it.”
3. **What we found** — diagnosis cards: opens, integrity, foreign keys, row counts, decode failures.
4. **Your options** — cards with risk, estimate, time, availability, disabled reason.
5. **What happens next** — the exact steps for the selected option.
6. **Technical details** — disclosure with hashes, file sizes, codes; copyable for support.

### 16.4 Confirmation sheet

For any mutating option:

- Title: “Restore this backup?” / “Salvage readable rows?” / “Remove this row?”
- Show before/after counts and the loss window.
- Show a checkbox: “I understand newer reading data may be lost.”
- For file-level options, require typing `RESTORE`, `SALVAGE`, `REBUILD`, or `QUARANTINE`.
- Show the preserved original location as “Preserved copy” (not a raw absolute path in the main copy; a Reveal button is acceptable).
- Primary button is destructive-styled; Cancel is default.
- No “Don’t ask again” for file-level options.

### 16.5 Progress

Phase list:

```text
1. Preserving your original      ✓
2. Diagnosing a copy             ✓
3. Verifying the backup          ✓
4. Replacing the library         ●
5. Checking the result           ○
6. Reopening the library         ○
```

- Cancel is allowed during `preserving`, `diagnosing`, and `verifying`.
- Cancel is not allowed between “original moved” and “verified”; the sheet explains why.
- A force-quit during the swap is handled on next launch; the UI should say “If you quit now, Asterisma will finish or undo the swap on next launch.”

### 16.6 Copy rules

Use:

- “library file” or “library database,” not “SQLite b-tree.”
- “preserved copy,” not “snapshot artifact.”
- “restore a backup,” not “roll back the database.”
- “read-only,” not “frozen writes.”
- “rows” only in technical details; in the main flow, use “books,” “sessions,” “page timings,” “goals.”

Never:

- claim “recovered everything” unless verification proves all expected rows;
- claim “fixed” when the option only exported;
- claim “undo” for a file swap before file-level versioning exists;
- show a raw SQLite error as the primary message.

### 16.7 Accessibility

- Every phase has a text label, not just color.
- Progress uses `ProgressView` with an accessibility value and phase name.
- Confirmation fields have labels and error text; typing requirement is announced.
- Focus moves to the primary heading on tab change.
- Reduced motion: no animated phase transitions beyond a fade.
- Largest Dynamic Type: option cards wrap; no fixed heights.
- VoiceOver: “Preserved copy” and “Original untouched” are read before the destructive button.

### 16.8 Empty and healthy states

Recovery tab absent when no incident. Settings shows:

```text
Backups
  Last verified backup: 2026-10-27 12:00 (fully verified)
  Backups kept: 7 of 10
  Last drill: 2026-10-20 (passed)
  [Verify backups] [Run restore drill] [Show recovery folder]
```

No scary language when healthy. No “database” in the default copy.

---

## 17. Configuration and autonomy

### 17.1 Separate settings

`LibraryRecoverySettings` is separate from `SentinelConfiguration`:

```swift
nonisolated struct LibraryRecoverySettings: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var dailyBackupRetention: Int       // default 10
    var safetyBackupRetention: Int      // default max(undoWindowDays + 1, 3)
    var verifyNewBackups: Bool          // default true
    var drillCadenceDays: Int           // default 7
    var incidentRetentionDays: Int      // default 30
    var quarantineRetentionDays: Int    // default 30
    var allowOptInLastResortRestore: Bool // default false; Phase 7 decision
    var lastDrillAt: Date?
}
```

Defaults:

```text
dailyBackupRetention = 10
safetyBackupRetention = 3 (or undoWindowDays + 1)
verifyNewBackups = true
drillCadenceDays = 7
incidentRetentionDays = 30
quarantineRetentionDays = 30
allowOptInLastResortRestore = false
```

### 17.2 Recovery autonomy

There is no `autoRestore` case. The only recovery authority is user confirmation.

| Setting | Effect |
|---|---|
| `verifyNewBackups` | automatic verification after a backup; no mutation |
| `drillCadenceDays` | automatic drill on a copy; no live mutation |
| `allowOptInLastResortRestore` | deferred; explicit policy, not default |

### 17.3 Interaction with Sentinel autonomy

| Sentinel autonomy | Recovery behavior |
|---|---|
| Off | Recovery still works if an incident is opened by a load failure; user-initiated only |
| Observe | Same; Sentinel does not propose row repairs |
| Assist | Sentinel may propose row repairs; Recovery executes only after confirmation |
| Auto-fix safe | Sentinel may auto-fix R1 row issues; never recovery, never row deletion |

Turning Sentinel off must not disable recovery. A corrupt library is a data emergency, not a Sentinel preference.

### 17.4 Opt-in last-resort restore — deferred design

This is the only “automatic restore” that could ever exist. It is not part of the default product and requires an explicit owner decision in Phase 7.

Policy shape:

```text
If the library cannot open at launch,
and the user previously enabled “Restore the last verified backup if the library cannot open,”
and at least one backup is drilled,
and the original can be preserved,
then:
  1. preserve the original,
  2. restore the drilled backup,
  3. reopen and verify,
  4. notify the user,
  5. keep the original until the user deletes it.
```

It still does not:

- delete the original;
- choose between multiple backups silently (it uses the newest drilled);
- run if the backup schema is newer;
- run if preservation fails;
- run if the user did not opt in.

This is a **pre-authorized policy**, not autonomous repair. It must be labeled that way in the UI. If the owner does not want it, delete the setting and keep the manual flow.

---

## 18. Concurrency, durability, and crash safety

### 18.1 One writer

The current app has one `DataStore` but potentially two SQLite connections:

- `DataStore` owns `LibraryDatabase.pool`.
- `LiveSentinelRepairBridge.checkpointDatabase` opens a separate `DatabaseQueue`.

That second connection must be removed. Checkpointing is a database operation, not a Sentinel file operation. The bridge should call:

```swift
func performCheckpoint() async -> Bool {
    guard recoveryFreeze == nil else { return false }
    return dbWriteQueue.sync {
        do {
            try database?.pool.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            }
            return true
        } catch { return false }
    }
}
```

Rules:

- All writes, checkpoints, backups, and closes go through `dbWriteQueue`.
- No component receives a `DatabasePool` or `DatabaseQueue` except `LibraryDatabase` and `DataStore`.
- Recovery never opens the live path; it receives a preserved copy path.
- Read-only diagnosis opens a copy, not the live pool.
- If a second connection is ever needed, it must be read-only and opened on a preserved copy.

### 18.2 Locking layers

| Layer | Mechanism | Scope |
|---|---|---|
| Process | `flock` on `LibraryRecovery/recovery.lock` | one recovery operation per app instance |
| Coordinator | `@MainActor` serialization | incident state transitions |
| Recovery | `actor` | file operations |
| DataStore | `dbWriteQueue` | all SQLite writes |
| SQLite | `DatabasePool` + WAL | page-level consistency |
| UI | disabled controls + progress | user cannot double-submit |

The process lock is advisory. It prevents two app instances from recovering the same store. It does not replace SQLite locking.

### 18.3 Freeze and close sequence

The exact order matters:

```text
1. Coordinator acquires process lock.
2. Sentinel.setOperationalMode(.suspended)
3. Sentinel.quiesce(timeout: 5s)
4. DataStore.freezeForRecovery
   a. invalidate save timer
   b. drain dbWriteQueue
   c. attempt saveImmediately
   d. capture memory snapshot
   e. set recoveryFreeze
5. DataStore.drainAndCloseForRecovery
   a. barrier on dbWriteQueue
   b. database.close()
   c. database = nil
6. Coordinator persists .frozen.
```

Why this order:

- Suspending Sentinel before closing prevents a probe from reading a closed pool.
- Draining the save queue before closing prevents a write from being lost after the freeze token.
- Capturing the memory snapshot before close preserves an in-flight reading session if the DB is unwritable.
- Closing last ensures no in-flight write is interrupted.

### 18.4 Reopen sequence

```text
1. DataStore.reopenAfterRecovery
   a. create LibraryDatabase(url: live)
   b. run migrations
   c. loadBooks + loadState
   d. publish models
   e. clear recoveryFreeze
   f. persistenceHealth = .healthy (or degraded)
2. Coordinator releases the lock only after verification.
3. Sentinel.setOperationalMode(.normal)
4. Sentinel.runCycle(.deep) for verification; repairs blocked.
5. If verification passes, incident .resolved.
6. If verification fails, incident .failed; keep the original.
```

If `reopenAfterRecovery` fails:

- do not release the lock;
- do not delete the new file;
- attempt rollback to the pre-restore copy;
- if rollback succeeds, incident `failed` with `LR-008`;
- if rollback fails, incident `critical` with `LR-009`.

### 18.5 Durability primitives

| Primitive | Use |
|---|---|
| `FileHandle.synchronize()` | portable flush; not sufficient alone on macOS |
| `fcntl(fd, F_FULLFSYNC)` | platter flush for backup, manifest, intent, receipt |
| `fsync(directoryFD)` | directory entry durability after rename |
| `rename(2)` | same-volume atomic replacement |
| `clonefile(2)` / `COPYFILE_CLONE` | APFS copy-on-write preservation |
| `flock(2)` | process-level recovery lock |

Every persisted control file follows:

```text
write .tmp
F_FULLFSYNC(.tmp)
rename(.tmp, final)
fsync(directory)
```

Never write a control file in place. Never trust a rename without a directory fsync.

### 18.6 SQLite durability settings

The app currently uses:

```sql
PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
```

For recovery-created stores:

- Keep WAL and foreign keys.
- Keep `synchronous = NORMAL` for normal app use; the app’s own writes already accept this tradeoff.
- For the final restored file, run `PRAGMA wal_checkpoint(TRUNCATE)` after reopen if the backup was in WAL mode, then verify. Do not leave a stale WAL from the backup.
- A backup created by `VACUUM INTO` is a single file with no WAL; that is preferred.

### 18.7 Sidecar handling

SQLite WAL mode uses:

```text
library.grdb.sqlite3
library.grdb.sqlite3-wal
library.grdb.sqlite3-shm
```

Rules:

- Preserve all three when they exist.
- A backup made by `VACUUM INTO` has no sidecars; do not copy sidecars into the backup.
- Before restoring a single-file backup, remove the live `-wal` and `-shm` after closing the pool. A stale WAL can be applied to the new main file and corrupt it.
- If the original had a WAL with committed data, the preserved copy includes it. Diagnosis opens the copy with the WAL present so committed data is visible.
- Never copy only the main file and call it a backup.

### 18.8 Crash matrix (extended)

| Crash point | Invariant | Recovery on launch |
|---|---|---|
| Before incident.json write | no incident | normal launch |
| During incident.json temp write | temp only | delete temp; normal launch |
| After incident.json write, before freeze | original live, incident detected | resume freeze |
| During freeze | save timer canceled, maybe pool open | resume freeze; attempt save/close |
| During preserve | partial preserved dir | delete partial; re-preserve |
| During diagnosis | diagnosis temp | delete temp; re-diagnose |
| After diagnosis, before decision | incident awaiting | show options |
| After intent, before close | original live, intent | live hash = before → clear intent |
| After close, before original move | original live, intent | live hash = before → clear intent |
| After original move, before incoming copy | live missing, pre-restore exists | restore original |
| After incoming copy, before rename | incoming + pre-restore | verify incoming; complete or restore |
| After rename, before reopen | live = new, pre-restore | verify and reopen, or rollback |
| After reopen, before receipt | live = new | verify; write receipt |
| After receipt, before intent clear | both | clear intent after hash check |
| During rollback | mixed | restore pre-restore; if hash mismatch, critical |
| During row repair transaction | SQLite journal | SQLite rollback; reload |
| During export | partial export | delete partial; original untouched |
| During drill | temp drill | delete temp; backup untouched |

### 18.9 Multi-instance behavior

- `flock` is acquired before incident creation and held until resolved/abandoned.
- If another instance holds the lock, `LR-011`: show “Another Asterisma window is recovering the library. Close it and try again.”
- Do not use `NSDistributedLock` alone; `flock` is process-scoped and releases on crash.
- Do not delete the lock file; it is a stable inode.

### 18.10 Cancellation

- Cancellation before the intent is written: delete temp files, keep original, incident `awaitingDecision`.
- Cancellation after the intent but before the original move: clear intent, keep original.
- Cancellation after the original move: do not stop; complete or roll back. The UI disables Cancel.
- Cancellation during diagnosis: stop the read-only work; no mutation.
- Cancellation during salvage: delete temp; original untouched.

The rule: **cancel is free until the first irreversible step; after that, it is a recovery operation.**

---

## 19. Security and privacy

### 19.1 Threat model

| Threat | Example | Mitigation |
|---|---|---|
| Local data exposure | Another user reads `LibraryRecovery/` | 0700/0600, app sandbox, no world-readable |
| Malicious backup | A crafted SQLite file triggers a schema/function exploit | Open read-only, `trusted_schema=OFF`, no extensions, current SQLite |
| Path traversal | A manifest name contains `../../` | Reject absolute paths and `..`; resolve inside root |
| Symlink attack | A preserved file is a symlink to a user file | Reject symlinks; use `lstat`; copy real files |
| Manifest tampering | A backup hash is edited | Hash is recomputed; manifest is not trusted alone |
| Denial of service | Huge file causes memory spike | Streaming hash, page ranges, memory budget |
| Accidental export | User exports to a shared folder | Save panel warning; default app-container folder; no auto-export |
| Log leakage | Error includes a book title/path | Stable error codes; redaction tests |
| Recovery of the wrong file | JSON mode vs SQLite mode | `StorageCondition` branch; refuse SQLite recovery in JSON mode |

### 19.2 Local-only guarantee

- No `URLSession`, no `Network.framework`, no analytics SDK.
- No crash report upload from Recovery.
- No cloud backup.
- Exported files leave only through an explicit user save panel.
- The app’s sandbox remains the outer boundary; Recovery does not request new entitlements.

### 19.3 Redaction rules

Persisted recovery data may contain:

- rule IDs, table names, counts, hashes, enum values, timestamps;
- relative file names (`library.grdb.sqlite3`), not absolute paths;
- opaque incident/receipt IDs.

May not contain:

- book titles, authors, series, note text;
- file URLs, security-scoped bookmarks, home directory paths;
- raw payloads, except the quarantine row file, which is explicitly sensitive and stored under `quarantine/rows/` with 0600;
- SQL statements containing user values;
- exception messages with embedded paths.

### 19.4 Quarantine row sensitivity

`quarantine/rows/*.json` contains raw payloads and therefore user text. It is:

- stored only inside the app container;
- 0600;
- excluded from diagnostics and journal;
- deleted only by explicit user action or quarantine retention after resolution;
- never exported automatically.

If the user exports a recovery bundle, the quarantine rows are **not** included by default. A separate “Include quarantined rows” checkbox is required, with a warning.

### 19.5 Backup files are untrusted input

When opening any backup or preserved copy:

```sql
PRAGMA trusted_schema = OFF;
PRAGMA query_only = ON;
```

If the SQLite build supports `SQLITE_DBCONFIG_DEFENSIVE`, enable it before opening. Do not load extensions. Do not `ATTACH` arbitrary paths. Do not execute schema SQL from the backup.

A backup is data, not code. Treat its schema as untrusted until validated against the known table set.

### 19.6 Logging

- `os_log` messages use stable codes and counts.
- No book title, author, note, path, or payload.
- The recovery journal is safe by construction; it has no field for user text.
- Debug builds may print more, but never payloads; the debug console is not a support artifact.
- A `containsSecret` test uses a fixture title/note/path and asserts none appear in incident JSON, journal, diagnostics, or notifications.

### 19.7 File permissions

```text
LibraryRecovery/                 0700
incidents/                       0700
incidents/*/                     0700
preserved/                       0700
preserved/*.sqlite3              0600
quarantine/rows/*.json           0600
receipts/*.json                  0600
Backups/                         0700
Backups/daily/*.sqlite3          0600
```

Check after creation; if permissions cannot be set, record a warning but do not make files world-readable. On macOS, the app container default may already be restrictive; verify.

### 19.8 Export

- `NSSavePanel` with directory selection.
- Default name: `Asterisma Recovery <date>`.
- No automatic export.
- After export, show the path in Finder only on request.
- The export receipt records the exported file hash, not the destination path in the safe journal (the user-facing receipt may show the path; the journal does not).

---

## 20. Testing strategy

### 20.1 Test pyramid

| Layer | Count target | Examples |
|---|---|---|
| Unit | 60–80 | state machine, manifest encode/decode, option gating, error mapping |
| Integration | 40–60 | freeze/reopen, backup, diagnose, restore, row repair |
| Fixture/corrupt | 25–40 | zero-byte, truncated, bad page, missing table, bad JSON |
| Crash/reconciliation | 15–25 | intent stages, rollback, critical |
| Property | 5–10 | idempotence, hash invariants, no silent loss |
| Performance | 4–6 | backup, diagnosis, restore, 10× |
| Privacy | 4–6 | secret fixture across artifacts |
| Isolation | 1–2 | real App Support byte-identical |

### 20.2 Corrupt fixtures

Build every fixture from a real `LibraryDatabase` in a temp directory, then mutate it.

| Fixture | Construction | Expected diagnosis |
|---|---|---|
| Zero-byte | truncate file to 0 | cannot open; export/restore only |
| Header truncated | write first 100 bytes | cannot open; `LR-102` |
| Bad page | overwrite page 2 with `0xFF` | integrity fail; salvage/restore |
| Missing table | drop `page_times` on a copy | schema mismatch; rebuild/restore |
| Bad book JSON | `UPDATE books SET payload_json='not-json'` | decode failure; quarantine/restore |
| Bad state JSON | update root payload | state decode failure; restore |
| Orphan session | insert with `foreign_keys=OFF` | SQL-002/SQL-015 count |
| Orphan timing | insert with `foreign_keys=OFF` | SQL-015 count |
| Duplicate row | create a table without PK in a fixture schema | SQL-004 count |
| Read-only file | `chmod 0444` | open read-only works; write fails `LR-105` |
| Schema newer | `PRAGMA user_version=999` | refuse open/restore `LR-004` |
| Missing WAL | remove WAL after a committed write | data loss; restore |
| Corrupt WAL | overwrite WAL header | integrity/IO error |
| Huge WAL | write many pages, no checkpoint | SQL-005; maintenance |
| Missing backup manifest | delete manifest | unverified; no restore |
| Wrong backup hash | edit manifest | `LR-014` |
| Backup newer schema | set `user_version=999` in backup | `LR-004` |

### 20.3 Crash injection

Unit-level:

```swift
struct FaultInjectingRecoveryIO: LibraryRecoveryIO {
    var failAt: RecoveryIOOperation
    var failAfterCount: Int
    var error: Error
    // count calls; throw at the scheduled point
}
```

Test every stage of Section 12.2:

- after intent write;
- after close;
- after original move;
- after incoming copy;
- after rename;
- after reopen;
- after receipt;
- during rollback.

For process-level crash, add a Debug-only environment variable:

```text
ASTERISMA_RECOVERY_CRASH_AT=afterRename
```

A manual script runs the app (or a test host) and sends `SIGKILL` at the stage; next launch must reconcile. Do not ship the crash hook in Release. Guard with `#if DEBUG` and an explicit build flag.

### 20.4 Property tests

| Property | Assertion |
|---|---|
| Original immutable | Hash of preserved original equals pre-recovery hash after every option except commit |
| Preserve fidelity | Every preserved file hash equals its source at freeze time |
| No silent loss | A successful receipt either has `lostRows == 0` or a non-empty lost table list |
| Idempotent reconciliation | Running startup reconciliation twice yields the same state |
| Option gating | A disabled option cannot execute even if called directly |
| Confirmation binding | A confirmation for option A cannot execute option B |
| Receipt round-trip | Encode/decode preserves all fields |
| State machine | No path from `executing` to `resolved` without `verifying` |
| Privacy | Secret fixture never appears in persisted safe files |

### 20.5 Performance tests

Fixtures:

- **Small:** 70 books, 300 pages, 10 sessions, 3,000 timings.
- **Large:** 1.38 M timings, representative library; generated once in a temp root; not committed.

Measure with `ContinuousClock`. Budgets:

| Operation | Small | Large |
|---|---|---|
| Freeze | < 50 ms | < 200 ms |
| Preserve (clone) | < 100 ms | < 1 s |
| Preserve (copy fallback) | < 1 s | < 20 s |
| Diagnose | < 500 ms | < 10 s |
| Backup (`VACUUM INTO`) | < 2 s | < 30 s |
| Restore | < 3 s | < 30 s |
| Verify | < 3 s | < 30 s |
| Healthy launch overhead | < 5 ms | < 5 ms |

Record actual numbers in the receipt or test log. Do not mark a test passed if it skipped the large fixture; mark it skipped with a reason.

### 20.6 Isolation

- Every test uses `SentinelTempRoot` or an equivalent temp directory.
- `verify-test-isolation.sh` must continue to prove the real App Support tree is byte-identical after the suite.
- Add a check that no `LibraryRecovery/` directory is created under the real App Support root during tests.
- UI tests that need a real-looking library use a temp copy; never the owner’s library.

### 20.7 Privacy tests

Use a fixture with unmistakable secrets:

```text
PRIVATE-BOOK-TITLE-<uuid>
PRIVATE-NOTE-TEXT-<uuid>
/Users/private/path/<uuid>.epub
```

Scan:

- `incident.json`;
- `diagnosis.json`;
- `preservation.json`;
- receipts;
- journal;
- `SentinelDiagnostics` export;
- notification body;
- recovery log.

Assert zero occurrences. The quarantine row file is exempt, and a separate test asserts it is 0600 and excluded from the default export.

### 20.8 Owner acceptance

Ten scenarios in Appendix G. They require a human, a copied real library, and permission to corrupt the copy. They are a gate, not a substitute for automated tests.

### 20.9 CI

- `./scripts/census.sh --unit-only` runs the full unit suite, including new Recovery tests.
- Add `./scripts/verify-recovery-fixtures.sh` to generate corrupt fixtures and run only the Recovery suites; it is faster than the full census and catches fixture drift.
- The GitHub `census` workflow already runs `AsterismaV2.5Tests`; no new job is required, but the test count and duration will grow. Keep the 45-minute timeout under review.
- Do not add UI automation for recovery in the first tranche; the state machine and views are testable without a window, and the owner acceptance covers the human path.

### 20.10 Existing suites to extend

| Suite | Change |
|---|---|
| `SQLiteLoadIntegrityTests` | add backup/restore fixtures; keep fail-closed pins |
| `SentinelPinsTests` | assert no Sentinel output while suspended |
| `SentinelRuntimeTests` | suspension, gate, verification-only mode |
| `SentinelPersistenceTests` | journal unknown events, incident entries |
| `SentinelLaunchAndRepairTests` | repair blocked during incident |
| `DurabilityPinsTests` | backup rotation, manifest, safety retention |
| `SentinelTestSupport` | fixture bridge gains freeze/reopen; new `LibraryRecoveryHarness` |

---

## 21. Rollout plan

### 21.1 Phase 0 — Safety corrections (mandatory)

**Goal:** make the existing backup and checkpoint paths trustworthy enough to build on.

| Task | Deliverable |
|---|---|
| P0-1 | Replace `LibraryDatabase.backup(to:)` with `makeConsistentSnapshot(to:)` using `VACUUM INTO` / backup API |
| P0-2 | Remove the second `DatabaseQueue` from `LiveSentinelRepairBridge`; add `DataStore.performCheckpoint()` |
| P0-3 | Add `StorageCondition`, `LibraryFreezeToken`, `freezeForRecovery`, `reopenAfterRecovery` skeleton |
| P0-4 | Add backup manifest type + hash + `F_FULLFSYNC` utility |
| P0-5 | Tests: concurrent write during backup, backup opens, no stale WAL, single connection |
| P0-6 | Update docs: backup path, retention, known hazard removal |

**Gate G0:**

- A backup taken while a write is in flight contains the committed write or is provably not claimed as consistent.
- No second SQLite connection exists outside `LibraryDatabase`.
- The backup opens read-only and passes `quick_check` + counts.
- Existing safety snapshots still gate repairs.
- Census green.

**If G0 fails, stop.** Do not build recovery on an inconsistent backup.

### 21.2 Phase 1 — Contracts and state machine

**Goal:** the durable incident model, with no UI and no file surgery.

| Task | Deliverable |
|---|---|
|---|---|
| P1-1 | `LibraryIncident`, enums, evidence, fingerprint, receipt types |
| P1-2 | `LibraryIncidentStore` atomic read/write/scan |
| P1-3 | `LibraryHealthCoordinator` skeleton + state transitions |
| P1-4 | Startup reconciliation for incident JSON only |
| P1-5 | Tests: transitions, guards, tolerant decode, interrupted scan |

**Gate G1:** state machine tests pass; no transition reaches `resolved` without `verifying`; incident writes are atomic and survive a crash.

### 21.3 Phase 2 — Preserve, diagnose, export

**Goal:** the first useful incident flow: freeze, preserve, diagnose a copy, export.

| Task | Deliverable |
|---|---|
|---|---|
| P2-1 | `LibraryStorePreserver` clone/copy + hash + sidecars |
| P2-2 | `LibraryDatabaseDoctor` read-only diagnosis |
| P2-3 | `LibraryRecoveryPlanner` with export + do nothing only |
| P2-4 | Read-only mode in `DataStore` and UI banner |
| P2-5 | `LibraryRecoveryView` with diagnosis and export |
| P2-6 | Corrupt fixture suite |

**Gate G2:** on every corrupt fixture, the original hash is unchanged, the preserved copy hash matches, diagnosis is accurate, export opens, and the app is read-only.

### 21.4 Phase 3 — Backup catalog, verification, drill

**Goal:** trustworthy restore points.

| Task | Deliverable |
|---|---|
|---|---|
| P3-1 | `LibraryBackupCatalog` scan + manifests + legacy migration |
| P3-2 | `LibraryBackupVerifier` quick/full/drill |
| P3-3 | Rotation: daily 10, safety N, quarantine failed |
| P3-4 | Update BAK probes for the new layout |
| P3-5 | Settings: Backups & Recovery pane |
| P3-6 | Drill tests + real-copy drill |

**Gate G3:** 10 verified backups rotate correctly; a corrupted backup is rejected; the only verified backup is never deleted; a drill passes on a copy of the real library.

### 21.5 Phase 4 — Assisted restore

**Goal:** the first file-level recovery, with crash safety and rollback.

| Task | Deliverable |
|---|---|
|---|---|
| P4-1 | `LibraryRecoveryPlanner` restore option + estimate |
| P4-2 | `LibrarySwapCoordinator` intent/close/move/copy/rename/fsync |
| P4-3 | `LibraryRecoveryVerifier` independent checks |
| P4-4 | Confirmation sheet with typed phrase |
| P4-5 | Startup reconciliation for `swap.intent` |
| P4-6 | Crash injection tests at every stage |
| P4-7 | Receipts + History projection |

**Gate G4:** restore succeeds on a real copy; a failed verification rolls back; a crash at every stage reconciles without ambiguity; the original is preserved; the receipt accounts for lost rows.

### 21.6 Phase 5 — Salvage, rebuild, row repair

**Goal:** recover what can be recovered when no backup is good.

| Task | Deliverable |
|---|---|
|---|---|
| P5-1 | `SQL-015` orphan inventory probe |
| P5-2 | `LibraryRowRepairService` export/delete/undo |
| P5-3 | Conservative salvage (`VACUUM INTO` + row extraction) |
| P5-4 | Logical rebuild from payloads |
| P5-5 | Page-timing loss disclosure |
| P5-6 | Fixtures for missing tables, bad pages, bad payloads |

**Gate G5:** salvage and rebuild recover what they claim and report what they lose; row repair is reversible from quarantine; no silent row-count reduction; page-timing loss is disclosed before confirmation.

### 21.7 Phase 6 — Sentinel and UX integration

**Goal:** one coherent Library Health surface.

| Task | Deliverable |
|---|---|
|---|---|
| P6-1 | `SentinelRuntime` operational mode + recovery gate |
| P6-2 | Promotion matrix + incident candidates |
| P6-3 | Verification-only deep cycle |
| P6-4 | Journal events + forward-compatible decoding |
| P6-5 | Diagnostics schema v2 + redaction tests |
| P6-6 | Health Center header/tabs/Recovery view |
| P6-7 | Launch card/banner + notification |
| P6-8 | Settings pane + copy |

**Gate G6:** Sentinel performs no probes or repairs during an incident; after recovery it runs a complete verification cycle; the journal tells one story; no user text leaks; the owner can complete the flow without reading SQL.

### 21.8 Phase 7 — Deferred hardening

**Goal:** the later ideas, each behind a gate.

| Task | Deliverable |
|---|---|
|---|---|
| P7-1 | File-level undo with versioned stores (14 days) |
| P7-2 | Automatic maintenance: checkpoint, rotation, optional compaction |
| P7-3 | Opt-in last-resort restore policy — decision + implementation if approved |
| P7-4 | 10× benchmark (1.38 M timings) and memory measurement |
| P7-5 | Accessibility pass (VoiceOver, largest Dynamic Type, reduced motion) |
| P7-6 | Localization keys for all recovery copy |
| P7-7 | Owner acceptance scenarios |

**Gate G7:** all ten owner scenarios pass; 10× benchmark recorded; accessibility checks pass; localization keys are extracted; the opt-in policy is either explicitly approved or deleted.

### 21.9 Effort estimate

| Phase | Sessions (approx.) |
|---|---|
| 0 — Safety corrections | 2 |
| 1 — Contracts/state machine | 2 |
| 2 — Preserve/diagnose/export | 3 |
| 3 — Backup catalog/drill | 2 |
| 4 — Restore | 3 |
| 5 — Salvage/rebuild/row repair | 4 |
| 6 — Sentinel/UX | 3 |
| 7 — Hardening/acceptance | 3 |
| **Total** | **22 sessions (18–26 range)** |

This is an estimate, not a commitment. It assumes one engineer familiar with the codebase and a working Mac test environment. A second engineer can parallelize fixtures and UI, but not the swap/restore path.

### 21.10 Rollback plan

| Phase | Rollback |
|---|---|
| 0 | Revert backup API; old backups remain; no new data files are required |
| 1 | Delete incident store; no live mutation occurred |
| 2 | Delete `LibraryRecovery/`; original untouched; app remains fail-closed |
| 3 | Ignore new catalog; old backups remain in `Backups/` |
| 4 | Revert swap code; preserved originals remain; no automatic migration |
| 5 | Revert salvage/rebuild; no live mutation without explicit option |
| 6 | Revert Sentinel gate/UI; Recovery remains usable from its own view |
| 7 | Revert each feature independently; file versions are additive |

No phase requires a schema migration of the library tables. The recovery data is additive. That is deliberate: a rollback should not strand the user’s library.

---

## 22. Documentation and operations

### 22.1 Documents to update when this ships

| Document | Change |
|---|---|
| `README.md` | Add Library Recovery to the product surface; state the no-auto-repair rule |
| `docs/01-project-tree.md` | Add `Core/LibraryRecovery/`, `Features/LibraryRecovery/`, `App/LibraryHealthCoordinator.swift` |
| `docs/method/07-testing-strategy.md` | Add corrupt fixtures, crash injection, property tests, isolation |
| `docs/registers/04-handoff.md` | Record the new subsystem, gates, and open decisions |
| `docs/plans/sentinel/gates/README.md` | Add Library Recovery gates; clarify Sentinel gate status is unchanged |
| `docs/plans/sentinel/SENTINEL-ROADWORK.md` | Add a cross-reference, not a rewrite; Recovery is a separate program |
| an ADR for library recovery (not written; documentation gap) | Permanent refusals and the coordinator boundary |
| `docs/registers/02-defect-register.md` | Add H-1…H-10 with status |
| `docs/audits/` | Add a recovery audit after G4 and G6 |

### 22.2 Versioning

| Artifact | Version field | Migration rule |
|---|---|---|
| `incident.json` | `schemaVersion` | tolerant decode; unknown optional fields ignored |
| `manifest.json` | `schemaVersion` | re-verify; old manifest without field is `recorded` |
| `receipt.json` | `schemaVersion` | append-only; never edit an old receipt |
| `preservation.json` | implicit in incident | tolerate missing optional fields |
| Journal events | raw string | unknown → `.unknown`, not corrupt |
| Diagnostics | `schemaVersion` | additive; export only |

Rules:

- Never change the meaning of an existing field. Add a new field.
- Never reuse an error code for a different failure.
- Never delete a receipt to “clean up.”
- A new app version must read old incidents. An old app version should read a new incident as `unsupported` and refuse recovery, not crash.

### 22.3 Operational runbook

**Symptom: “Library needs attention” on launch.**

1. Do not erase the library. Do not run “Erase Library & Data.”
2. Open Library Health → Recovery.
3. Check “Preserved copy” exists and the original is untouched.
4. Export a copy before trying anything else.
5. If a verified backup exists, review the data-loss estimate; restore only with confirmation.
6. If no backup exists, choose salvage or export and contact support with the receipt ID.

**Symptom: app opens empty after a failed load.**

- This is expected fail-closed behavior. The books are not necessarily gone.
- Check Recovery for an incident; if absent, check `persistenceHealth` and the JSON fallback.
- Do not import or save; saving is blocked, but importing could overwrite.

**Symptom: recovery failed.**

- Read the receipt outcome: `failed`, `rolledBack`, or `critical`.
- `failed`/`rolledBack`: the original should still be at the live path or the preserved copy.
- `critical`: do not delete either file. Export both. Contact support with the incident ID and receipt ID.

**Support bundle:**

- `SentinelDiagnostics` export (safe).
- `incident.json` safe projection (no paths).
- Receipts (no paths; hashes/counts).
- Never request the library file unless the user explicitly chooses to export it.

### 22.4 Support questions

Ask:

- What did the banner say?
- What is the incident ID and receipt ID?
- Does the preserved copy exist?
- Which option was chosen, and did the confirmation phrase appear?
- What is the free disk space?

Do not ask:

- “Can you send me your library?” before export consent.
- “Did you try deleting the database?”
- “Did you force quit during the swap?” without checking the receipt first.

### 22.5 Release notes template

```text
Library Safety (Recovery)
- Adds a recovery workflow when the library database cannot be read.
- Preserves a full copy of the original before any diagnosis.
- Adds verified backups and a restore drill.
- Does not automatically restore, rebuild, or delete any data.
- Known limitation: per-page timings cannot be rebuilt from book payloads;
  a verified backup is required to recover them if the timing table is damaged.
```

---

## 23. Risks

| Risk | Probability | Impact | Mitigation | Early warning |
|---|---|---|---|---|
| Backup is not truly consistent | Medium | Critical | Phase 0 uses `VACUUM INTO`/backup API; concurrent-write test | Backup opens but counts differ from live |
| Swap loses the only copy | Low | Critical | Preserve before intent; move, never delete; rollback; crash tests | `critical` receipt |
| False incident freezes a healthy app | Medium | High | Promotion matrix; only structural/load failures auto-promote | Users see incidents on healthy fixtures |
| Scope creep into auto-repair | High | High | Permanent refusals; gate reviews; ADR | New “auto” setting appears |
| Recovery is too slow on 1.38 M timings | Medium | Medium | Budgets, background, page ranges, cancellation before commit | Drill exceeds 30 s |
| User cannot understand the options | High | Medium | Plain language, one primary action, data-loss estimate | Support questions repeat |
| Test fixtures drift from real schema | Medium | High | Generate from `LibraryDatabase`; schema assertions; CI | Fixture tables missing after a migration |
| APFS clone unavailable | Low | Low | Fallback byte copy; measure | Preserve falls back often |
| Sandbox blocks a needed path | Low | High | All files under app container; save panel for export | IO error `LR-103` |
| Second SQLite connection returns | Medium | High | Single-writer test; grep gate; code review | `DatabaseQueue(path:)` outside Storage |
| Journal downgrade shows corrupt lines | Medium | Medium | `.unknown` case; forward-compatible read | Old build reports corruption |
| Localization debt | High | Medium | Keys from day one; no literals in JSON | English strings in views |
| Owner acceptance unavailable | Medium | High | Copy the real library; do not use production | G7 blocked |
| Disk full during backup | Medium | High | Free-space precondition; temp cleanup; no partial final | `LR-005` |
| Malicious backup file | Low | High | Read-only, `trusted_schema=OFF`, no extensions | Unusual schema/triggers |
| Retention deletes the only good copy | Low | Critical | Never delete the only verified/drilled; separate safety retention | Catalog warning |
| Recovery conflicts with an active session | Medium | Medium | Freeze saves; memory snapshot; read-only UI | Session not saved |
| App relaunch during swap | Medium | Critical | Intent + hash reconciliation; crash matrix | Startup `critical` |
| Two app instances recover at once | Low | High | `flock` | `LR-011` |

---

## 24. Open decisions

| # | Decision | Recommendation | Owner |
|---|---|---|---|
| D-01 | Product name: “Sentinel Health” vs “Library Health” | **Library Health**; Sentinel is one tab | Product |
| D-02 | Recovery as a tab vs a separate window | Tab + launch banner; avoid a second window | Product |
| D-03 | Daily backup count | 10 | Engineering |
| D-04 | Safety snapshot count | `max(undoWindowDays + 1, 3)` | Engineering |
| D-05 | Incident copy retention | 30 days or 5 incidents; never delete unresolved | Product/Engineering |
| D-06 | Allow row quarantine deletion | Yes, with export + type `QUARANTINE` + undo | Owner |
| D-07 | Allow orphan-row deletion | Yes, Phase 5, with export + type `REMOVE` | Owner |
| D-08 | Opt-in last-resort restore | Defer; off by default; decide after G4 drill | Owner |
| D-09 | File-level undo retention | 14 days, matching current undo window | Product |
| D-10 | JSON-mode recovery scope | Detect and explain only; no SQLite recovery | Engineering |
| D-11 | Add `SQL-015` (changes 138 → 139 probes) | Yes; update docs/tests | Engineering |
| D-12 | Keep `SentinelHealthCenterWindowID` name | Yes, for state restoration; change label only | Engineering |
| D-13 | `VACUUM INTO` vs backup API primary | `VACUUM INTO`; backup API fallback | Engineering |
| D-14 | Encrypt backups | No custom encryption; rely on FileVault/app container | Security |
| D-15 | “Reveal preserved copy” button | Yes, in technical details only, with a warning | Product |
| D-16 | Show raw SQLite error codes to users | No; show a plain message + code in technical details | Product |
| D-17 | Include quarantine rows in export | No by default; explicit checkbox | Security |
| D-18 | Automatic maintenance in Phase 7 | Checkpoint + rotation only; compaction on demand | Engineering |

---

## 25. Appendices

### Appendix A — Type glossary

| Type | Meaning |
|---|---|
| `LibraryHealthCoordinator` | App-level state machine and mediator |
| `LibraryRecoveryService` | Actor that performs preservation, diagnosis, and recovery |
| `LibraryRecoveryHost` | DataStore-side freeze/close/reopen contract |
| `LibraryRecoveryIO` | File-system abstraction for crash/failure injection |
| `LibraryIncident` | Durable record of one recovery episode |
| `LibraryIncidentState` | detected → freezing → frozen → diagnosing → awaitingDecision → executing → verifying → resolved/failed/abandoned |
| `PreservedStore` | Hash-verified copy of the original + sidecars |
| `LibraryStoreFingerprint` | File hashes + SQLite metadata + table counts |
| `LibraryDiagnosis` | Read-only findings from the preserved copy |
| `RecoveryOption` | One user-selectable action |
| `RecoveryEstimate` | Recovered/lost/unknown rows before execution |
| `RecoveryReceipt` | Before/after proof of execution |
| `RecoveryVerification` | Independent post-recovery checks |
| `SentinelRecoverySummary` | Safe projection shown in Sentinel/Health Center |
| `SentinelRecoveryGate` | Suspension contract consumed by Sentinel |
| `swap.intent` | Crash-consistency record for a file replacement |

### Appendix B — File-by-file change map

#### New core files

| File | Key types/functions | Tests |
|---|---|---|
| `LibraryRecoveryContracts.swift` | `LibraryRecoveryHost`, `LibraryRecoveryIO`, `SentinelRecoveryGate`, `LibraryOperationalMode` | contract tests |
| `LibraryIncident.swift` | `LibraryIncident`, `LibraryIncidentKind`, `LibraryIncidentState`, `LibraryTrigger` | state machine |
| `LibraryIncidentStore.swift` | `write`, `read`, `scan`, `reconcile` | incident store |
| `LibraryStoreFingerprint.swift` | `capture`, `sha256`, `tableCounts` | preserve/doctor |
| `LibraryStoreManifest.swift` | `Manifest`, `read`, `write`, `verifyHash` | backup |
| `LibraryRecoveryIO.swift` | `ProductionRecoveryIO`, `F_FULLFSYNC` | swap/crash |
| `LibraryStorePreserver.swift` | `preserve`, `cloneOrCopy`, `verify` | preserve |
| `LibraryDatabaseDoctor.swift` | `diagnose`, `classifyIntegrity`, `readOnlyOpen` | doctor |
| `LibraryBackupCatalog.swift` | `scan`, `migrateLegacy`, `rotate` | catalog |
| `LibraryBackupVerifier.swift` | `verify`, `drill` | verifier |
| `LibraryRecoveryPlanner.swift` | `options`, `estimate` | planner |
| `LibraryRecoveryExecutor.swift` | `executeExport/Restore/Salvage/Rebuild/Quarantine` | executor |
| `LibrarySwapCoordinator.swift` | `writeIntent`, `swap`, `rollback`, `reconcile` | swap |
| `LibraryRecoveryVerifier.swift` | `verifyReopened`, `compareManifest` | verifier |
| `LibraryRowRepairService.swift` | `inventory`, `export`, `delete`, `undo` | row repair |
| `LibraryRecoverySettings.swift` | settings + defaults | settings |
| `LibraryRecoveryDiagnostics.swift` | safe support report | privacy |

#### New app/UI files

| File | Responsibility |
|---|---|
| `App/LibraryHealthCoordinator.swift` | observe storage condition, open incident, freeze, call service, publish state |
| `Features/LibraryRecovery/LibraryRecoveryView.swift` | incident detail and option cards |
| `Features/LibraryRecovery/LibraryIncidentBanner.swift` | banner/card |
| `Features/LibraryRecovery/LibraryRecoveryProgressView.swift` | phase progress |
| `Features/LibraryRecovery/LibraryBackupListView.swift` | backup catalog/drill |

#### Modified files — exact change

| File | Change | Risk |
|---|---|---|
| `Core/Storage/LibraryDatabase.swift` | `makeConsistentSnapshot`, `openReadOnly`, `tableCounts`, `schemaVersion`, `pageMetadata`; replace `backup` | Medium |
| `Core/DataStore3.swift` | `StorageCondition`, freeze/reopen, `performCheckpoint`, memory snapshot, visible load failure | High |
| `Core/Sentinel/SentinelDataBridgeV2.swift` | remove second `DatabaseQueue`; call `DataStore.performCheckpoint` | High |
| `Core/Sentinel/SentinelRuntime.swift` | operational mode, gate, suspension, verification-only, published summary | Medium |
| `Core/Sentinel/SentinelJournal.swift` | new events + `.unknown` decode | Low |
| `Core/Sentinel/SentinelDiagnostics.swift` | schema v2 + recovery rows | Low |
| `Features/Sentinel/SentinelHealthCenterView.swift` | header, tabs, recovery view | Medium |
| `Features/Sentinel/SentinelViewModel.swift` | recovery projection/actions | Medium |
| `App/AsterismaApp.swift` | coordinator ownership/injection, menu/window | Low |
| `App/NewContentView.swift` | start coordinator, banner, read-only | Medium |
| `Features/Goals/SettingsRootView.swift` | Backups & Recovery pane | Low |
| `Tests/Core/SentinelTestSupport.swift` | freeze/reopen fixtures, recovery harness | Low |

### Appendix C — State transition detail

| ID | From | Event | Guard | To | Side effect |
|---|---|---|---|---|---|
| T-01 | detected | beginFreeze | trigger non-nil | freezing | acquire lock, suspend Sentinel |
| T-02 | freezing | frozen | drain/close/token | frozen | persist, start preserve |
| T-03 | freezing | freezeFailed | close/drain error | failed | `LR-006`, critical banner |
| T-04 | frozen | beginDiagnosis | preserved hash valid | diagnosing | read-only doctor |
| T-05 | diagnosing | optionsReady | diagnosis complete | awaitingDecision | publish options |
| T-06 | diagnosing | diagnosisFailed | IO/open error | failed | `LR-002`, export if possible |
| T-07 | awaitingDecision | execute | confirmation valid | executing | write intent, run option |
| T-08 | awaitingDecision | abandon | user confirms | abandoned | keep read-only |
| T-09 | executing | verify | new store exists | verifying | reopen DataStore |
| T-10 | executing | executeFailed | safe failure | awaitingDecision | rollback if needed |
| T-11 | verifying | resolved | all checks pass | resolved | receipt, thaw |
| T-12 | verifying | verifyFailed | check fails | failed | rollback, `LR-008` |
| T-13 | failed | retry | preserved valid | awaitingDecision | new options |
| T-14 | failed | abandon | user confirms | abandoned | keep read-only |
| T-15 | any | interrupted | launch scan | failed | reconcile, receipt |
| T-16 | any | critical | rollback fails | failed | `LR-009`, `critical` receipt |

### Appendix D — Recovery option detail

| Option | Preconditions | Data loss | Duration | Reversible |
|---|---|---|---|---|
| Export | preserved store | none | seconds | n/a |
| Restore | verified backup, schema <= app, free space | newer rows/time window | seconds–minutes | yes, pre-restore copy |
| Salvage | copy opens, one readable table | unreadable rows/table loss | minutes | original preserved |
| Rebuild | all books/state decode | page timings if unreadable | minutes | original preserved |
| Quarantine row | one bad row, snapshot | exactly one row (preserved raw) | seconds | yes, re-insert |
| Do nothing | preserved store | none | none | n/a |

### Appendix E — Test matrix

| Test area | Fixtures | Assertions | Gate |
|---|---|---|---|
| State machine | synthetic | no invalid transitions; terminal states | G1 |
| Incident store | crash/temp | atomic; tolerant; scan | G1 |
| Preserve | valid/corrupt DB + sidecars | hash match; original unchanged | G2 |
| Doctor | zero/truncated/bad page/missing table | accurate classification; no mutation | G2 |
| Backup | live + concurrent write | snapshot contains committed write; opens | G0/G3 |
| Catalog | legacy/new/failed | correct classification; no deletion of only verified | G3 |
| Drill | real copy | opens, counts, sample decode | G3 |
| Restore | verified backup | swap, reopen, verify | G4 |
| Crash | injected at each stage | reconcile or rollback | G4 |
| Salvage | bad pages/missing tables | recovered/lost counts; no silent loss | G5 |
| Rebuild | bad normalized tables | books/state recovered; timings disclosed | G5 |
| Row repair | orphan rows | delete/undo; counts | G5 |
| Sentinel gate | incident | no probes/repairs; resume | G6 |
| Journal | unknown event | forward-compatible, not corrupt | G6 |
| Privacy | secret fixture | no titles/paths in safe artifacts | G6 |
| Isolation | full suite | real App Support byte-identical | G6 |
| Performance | 70 / 1.38M | budgets recorded | G7 |
| Accessibility | UI | labels/focus/Dynamic Type | G7 |

### Appendix F — Manual commands

These are for a copied library, never the production store.

```bash
# Identify
db="$HOME/Library/Application Support/Asterisma/library.grdb.sqlite3"
ls -l "$db" "$db-wal" "$db-shm" 2>/dev/null

# Structural checks (read-only)
sqlite3 "file:$db?mode=ro" 'PRAGMA quick_check;'
sqlite3 "file:$db?mode=ro" 'PRAGMA integrity_check(100);'
sqlite3 "file:$db?mode=ro" 'PRAGMA foreign_key_check;'
sqlite3 "file:$db?mode=ro" "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;"

# Counts
sqlite3 "file:$db?mode=ro" "SELECT 'books', COUNT(*) FROM books UNION ALL SELECT 'sessions', COUNT(*) FROM sessions UNION ALL SELECT 'page_times', COUNT(*) FROM page_times;"

# Hash
shasum -a 256 "$db"

# Consistent copy for investigation (never overwrite the original)
sqlite3 "$db" "VACUUM INTO '/tmp/library-investigation.sqlite3';"

# Restore drill (copy only)
cp "$db" /tmp/drill.sqlite3
sqlite3 'file:/tmp/drill.sqlite3?mode=ro' 'PRAGMA quick_check;'
```

Crash injection (Debug only):

```bash
ASTERISMA_RECOVERY_CRASH_AT=afterRename open -a AsterismaV2.5
# relaunch; Recovery must reconcile, never show a half-swapped success
```

### Appendix G — Owner acceptance scenarios

Run on a copy of the real library. Record the date, build, and result.

| # | Scenario | Pass criteria |
|---|---|---|
| 1 | Healthy launch | No incident; backup verified; drill passes |
| 2 | Bad page in a copy | Incident opens; original hash unchanged; export opens |
| 3 | One bad book payload | Quarantine flow; load succeeds; undo restores the row |
| 4 | Restore older verified backup | Loss estimate shown; restore verifies; original preserved |
| 5 | Restore fails verification | Rollback; no data loss; receipt `failed`/`rolledBack` |
| 6 | Kill during swap | Next launch reconciles; no ambiguous state |
| 7 | All backups corrupt | Restore disabled; export/salvage offered |
| 8 | Disk nearly full | Backup refused; clear `LR-005`; no partial final file |
| 9 | Incident while Sentinel active | Sentinel paused; no probes/repairs; resumes after verification |
| 10 | Privacy scan | No title, note, or path in incident/journal/diagnostics/notification |

### Appendix H — References

| Reference | Why |
|---|---|
| `AsterismaV2.5/Core/Storage/LibraryDatabase.swift` | Schema, WAL, foreign keys, current backup |
| `AsterismaV2.5/Core/DataStore3.swift` | Load fail-closed, save queue, safety snapshot, backup schedule |
| `AsterismaV2.5/Core/Sentinel/SentinelRepair.swift` | Row-level contract and executor boundary |
| `AsterismaV2.5/Core/Sentinel/SentinelDataBridgeV2.swift` | Current bridge + second connection hazard |
| `AsterismaV2.5/Core/Sentinel/SentinelRuntime.swift` | Cycle, published state, repair entry points |
| `AsterismaV2.5/Core/Sentinel/SentinelJournal.swift` | Journal schema and checksum model |
| `AsterismaV2.5/Core/Sentinel/SentinelProbesStorage.swift` | SQL/backup probes and their limits |
| `AsterismaV2.5/Features/Sentinel/SentinelHealthCenterView.swift` | Current tab surface |
| `docs/plans/sentinel/gates/SG7.md` | Open holds; do not claim them closed |
| `docs/plans/sentinel/SENTINEL-ROADWORK.md` | Program targets and phase vocabulary |

### Appendix I — First implementation checklist

Before writing any recovery UI:

- [ ] G0 backup consistency test passes under a concurrent write.
- [ ] `LibraryDatabase` has one snapshot API and one read-only open API.
- [ ] `LiveSentinelRepairBridge` no longer creates a `DatabaseQueue`.
- [ ] `DataStore` has a freeze token and a drain/close barrier.
- [ ] `StorageCondition` is published on load/save failure.
- [ ] Incident JSON writes are atomic and fsynced.
- [ ] A corrupt fixture exists for every row in Appendix E.
- [ ] The owner has approved the permanent refusals in Section 3.3.
- [ ] D-01 through D-06 are decided; the rest can wait.

Do not start Phase 2 until G0 and G1 pass. A recovery feature built on an inconsistent backup is worse than no recovery feature.

---

## Closing statement

This plan builds a safety net, not a self-healing fantasy. The database will not repair itself. The app will preserve what exists, explain what is wrong, show the cost of each option, execute only after a human chooses, verify independently, and keep the original until the user says otherwise.

Sentinel stays the immune system: it detects, explains, pauses, and verifies. Library Recovery is the surgeon: it works on a copy, keeps the original, and never chooses which data survives. The coordinator is the operating room rule: one patient, one surgeon, one decision at a time.

The permanent refusals are the point. If the team later asks for automatic restore, automatic rebuild, or automatic deletion, the answer is already written down: no. The deferred capabilities — assisted restore, salvage, rebuild, row repair, file-level undo, the opt-in policy — are real work, but each sits behind a gate. That is how a data-recovery system earns trust: not by claiming it cannot fail, but by making failure visible, bounded, and reversible.

---

## 25. Execution record — 2026-10-28

Status: **Phases 1–6 implemented and pinned. Phase 7 stays deferred. Owner acceptance (G6) is the only open gate.**

| Phase | State | Evidence |
|---|---|---|
| 1 — Contracts/state machine | Done | `Core/Storage/LibraryRecoveryContracts.swift`, `Core/LibraryRecovery/LibraryIncident.swift`, `LibraryIncidentStore` |
| 2 — Preserve/diagnose/export | Done | `LibraryStorePreserver`, `LibraryDatabaseDoctor`, `LibraryRecoveryService`; preservation + snapshot tests |
| 3 — Backup catalog/drill | Done | `LibraryBackupCatalog`, `LibraryBackupVerifier`, manifest verification and drill pins |
| 4 — Assist restore | Done | `LibrarySwapCoordinator`, `LibraryRecoveryVerifier`, `LibraryRecoveryIO`; restore, rollback, crash-reconcile tests |
| 5 — Salvage/rebuild/row repair | Done | `LibraryLogicalRebuilder`, `LibraryRowRepairService`; rebuild + export/delete/undo round trip |
| 6 — Sentinel/UX | Done | `LibraryRecoveryGate`, gate checks in `SentinelRuntime`, recovery journal events, schema-2 diagnostics, Recovery tab, suspension banner, support summary |
| 7 — Hardening/acceptance | Deferred | File versions, maintenance automation, 10× benchmark, accessibility, localization, acceptance scenarios |

Verification: Debug and Release builds exit 0; unit census **432 tests / 671 runs / 9 skipped / 0 failures** (after SG8); G6 gate pins **11/11**. The UI-test target cannot initialize automation mode on the current host and is reported as a limitation, not a pass.

Defects the tests exposed and this pass fixed:

1. Row repair opened a nested transaction (`db.inTransaction` inside `queue.write`), so the export/delete path could never commit. It now uses `writeWithoutTransaction` plus one explicit transaction.
2. `PRAGMA foreign_keys` was issued inside a transaction, where SQLite ignores it; undo could not restore orphan rows. The pragma now runs outside the transaction and is restored with `defer`.
3. Read-only inspection of a WAL database without its `-shm` fails. Inspection now falls back to a disposable private copy, keeping the original untouched.

Explicit holds carried forward: performance on 1.38 M timings is below target (owner decision to tune separately); orphan repair is implemented and tested but not yet driven from the Recovery tab; salvage-readable-rows remains a planner option without its own UI.

The permanent refusals in §3.3 are unchanged. Nothing in this pass added automatic restore, automatic rebuild, or automatic deletion.

---

*End of DBappends.md.*

