# Gate SG0 — Truth and guardrails

> **Historical receipt (2026-10-28).** The probe/repair counts below describe the SG0
> snapshot (8 probes, 4 rules). The current tranche is 138 probes / 15 domains / 25
> repairs; see [SG7.md](SG7.md) and the [gate index](README.md). The guardrail work
> recorded here still stands.

**Date:** 2026-10-28
**Branch:** `main`
**Base commit:** `6099e4e`
**Tree state:** committed in `16d6d16`; GitHub `census` green at `bed710a`

**Decision:** awaiting owner review. This receipt records evidence, not approval.

---

## Delivered

| SG0 deliverable | State | Where |
|---|---|---|
| Remove the duplicate launch cycle | Done | `NewContentView.onAppear` calls `start()` only; `start()` schedules one immediate cycle |
| Derive the probe count from the engine | Done | `SentinelEngine.probeCount`; pane reads `engine.probeCount` |
| Remove the dead `#if DEBUG` in `isEnabled` | Done | `isEnabled` is one expression; repair policy remains in `allowsRepair` |
| Implement the report card's Review action | Done | Review opens the Debug console and dismisses the card; Release passes `nil`, so no dead button |
| Remove the dotfile write probe from the data root | Done | Writability probe writes in a system replacement directory and removes it |
| Fix `markFixed` first-only | Done | Every matching finding is marked; in-place mutation keeps ids and dates |
| Stop journaling user text / debug detail | Done | Journal encodes `SentinelJournalRecord`, which omits `debugDetail`; engine details use book ids, not titles |
| Rename retained-journal counters | Done | `journalAutoFixed` / `journalStalled`; UI labels say “JOURNAL …” |
| Sentinel test isolation | Verified | `verify-test-isolation.sh` passed |
| Link the roadwork | Done | README §3.4 and the remediation roadmap |
| Current-coverage table in README | Done | README §3.4 lists 8 probes, 4 repair rules, surfaces, limits |

---

## Verification

| Gate criterion | Command | Result |
|---|---|---|
| Unit census green, target 236+ | `./scripts/census.sh --unit-only` | **242 tests, 233 passed, 9 skipped, 0 failed**; `TEST SUCCEEDED` |
| SG0 pins | `xcodebuild test … -only-testing:AsterismaV2.5Tests/SentinelSG0Tests` | **6/6 passed** |
| Existing Sentinel pins | `xcodebuild test … -only-testing:AsterismaV2.5Tests/SentinelPinsTests` | **6/6 passed** |
| No write-probe path in source | `rg 'sentinel-write-test' AsterismaV2.5 AsterismaV2.5Tests` | no matches |
| Test isolation | `./scripts/verify-test-isolation.sh` | `TEST ISOLATION OK — real app-support data is byte-identical.` |
| Probe count matches registry | `probeCount` test + pane grep | engine reports 8; pane has no literal |
| README claims match code | manual table audit | 8 probes, 4 rules, Debug-only pane, 500-line rotation, retained counters |
| Release compiles | `xcodebuild build … -configuration Release CODE_SIGNING_ALLOWED=NO` | `BUILD SUCCEEDED` |

Census receipt: [census-2026-10-28.md](census-2026-10-28.md). The historical `.xcresult` bundle from this gate's earlier run was in temporary storage and was not retained.

---

## New pins

`AsterismaV2.5Tests/Core/SentinelSG0Tests.swift`

1. Probe count is `probes.count`, not `8`.
2. `start()` runs exactly one launch cycle, and no second cycle arrives.
3. Every matching finding is marked fixed; both books are actually repaired.
4. The writability probe leaves the data root byte-identical and creates no dotfile artifact.
5. The journal contains the rule and no title or `debugDetail`; the in-memory finding still has its debug detail.
6. A chapter title present in `debugDetail` never reaches the journal, proving the safe projection rather than relying on scrubbed details.

---

## Known deltas

- **Counters are renamed, not persisted.** They remain totals over the retained journal and still shrink when 500-line rotation drops history. True lifetime totals belong to the v2 issue store.
- **The writability probe proves volume writability, not the data root's exact ACL.** It deliberately writes in a system replacement directory to honor S1. A future `Sentinel/` scope will test the real target directory.
- **The journal still has one hand-built cycle summary line.** SG0 fixes user-text leakage; canonical encoding is SG1 work.
- **`Review` exists only in Debug.** Release has no console window, so the button is absent by design.
- **No undo, fingerprint, issue store, or SQLite timing coverage.** Those are SG1–SG5.
- **The roadwork and this receipt are untracked files.** They are linked from README, so they must be committed together before distribution.

---

## Rollback

Source-only; no data migration, schema change, or journal rewrite was performed.

- Revert `AsterismaV2.5/Core/SentinelEngine.swift`, `NewContentView.swift`, `SentinelPaneView.swift`, `SentinelReportCardView.swift`.
- Revert `README.md` and `docs/roadmap/05-remediation-roadmap.md`.
- Delete `AsterismaV2.5Tests/Core/SentinelSG0Tests.swift` and this gate directory.
- The pre-SG0 journal remains readable: old lines still decode with `JSONSerialization`; new lines simply omit `debugDetail`.

---

## Next phase

**SG1 — Domain foundation:** issue model, fingerprints, journal v2, injected clock, and the removal of the remaining `Date()` calls from probes. SG0 is the honesty precondition; SG1 is the first structural build.
