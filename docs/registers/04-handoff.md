# 04 · Handoff

## Plain-language answers

This document answers the seven questions every close-out should answer, in plain language. It is written so that anyone — whether or not they have ever written code — can pick up the project and know exactly where things stand.

**Refreshed 2026-10-29: the V1.0 release is merged, reorganized, and CI-green, and it carries the Sentinel v2 first tranche; `AsterismaV2.0` is the current working identity, not a shipped release.** The V2.0 tree now also carries the Home/Library shell overhaul, the reader customization pass, the offline contract pass, the ADR-13 Mirage warm-engine/library-scale overhaul, and the environment/Sentinel/console navigation overhaul (live atmosphere, weather layer, deepened daylight palettes with a readability scrim, Sentinel sidebar, Environment Studio, Subsystem Explorer), all compiled and unit-tested but **not committed and not visually accepted**. The current unit census is **515 tests / 99 suites / 719 runs / 506 passed / 9 skipped / 0 failed** (`./scripts/census.sh --unit-only`, exit 0; 2026-10-31), after the reading-analytics recalibration and the 200-round stress evaluation. The hand-graded real-library pass that followed was **declared void on 2026-10-29** — see the session close at the end of this file and `docs/audits/new-era-testing.md` §31. The app is usable now. The remaining work is owner acceptance of the shell/reader/offline/Mirage changes, distribution hardening, and the Sentinel holds recorded in SG7 (manual acceptance, v1 removal, localization, menu bar, accessibility, 10× benchmark).

---

## What was I doing?

First, the October audit era: verifying the app, fixing the freeze saga, and re-documenting it.

Then the **RT–Mirage merge campaign** (October 2026): integrating a separately owned EPUB analysis engine (“Mirage”) behind a typed, fail-closed boundary.

Then the **Bedrock program** (2026-10-24): fixing the audit-era correctness punch list, moving the live library to SQLite, adding Open-Meteo weather, wiring Behavior Context V3, and producing a signed local release candidate.

Next, the **Asterisma rebrand** (2026-10-24): renaming the product, project, targets, module, source folders, package, and user-facing copy to **AsterismaV1.0**, and moving the data root from `ReadTracker` to `Asterisma` without losing the library.

Then, the **ready close-out** (2026-10-26): the preservation-first repository reorganization, the GitHub CI runner correction, a green 229-test remote census, and a rebuilt signed package.

Then, the **Sentinel v2 first tranche** (2026-10-28): 138 probes across 15 domains, 25 verified repair plans, a Release Health Center, journal v2 with fingerprints and diagnoses, a launch card, opt-in notifications, and a redacted diagnostics export. SG7 is **HOLD** on manual owner acceptance, v1 removal, and localization.

Then, the **SG8 surface layer** (2026-10-28): two generic probes (`SQL-016`, `SELF-011`), a source-generated surface manifest (15 tables, 8 preferences, 5 notification names), and a CI freshness gate. New tables are structurally contract-checked after regeneration without new probe code; the catalog is now **140 probes / 58 required**, and the full unit census is **432 tests / 671 runs / 9 skipped / 0 failed**. Owner acceptance remains SG7's gate.

Then, the **Library Recovery program** (2026-10-28): preservation-first incident handling, verified backup catalog and drill, atomic restore with rollback and crash reconciliation, logical rebuild, orphan row repair with export/undo, and a two-way Sentinel contract — Sentinel nominates only structural damage, pauses completely during recovery, and runs one deep verification pass afterward. Code complete; owner acceptance is the gate.

---

## Why?

1. **Trust first:** the app holds years of reading history. The Bedrock work fixed data-ordering, crash-window, cache, onboarding, and cover bugs before adding anything new.
2. **A capability, not a rewrite:** Mirage analyzes EPUBs as a companion engine. It keeps its own ledger and never writes the app’s store.
3. **Receipts, not assumptions:** every gate closed on a green census, and the release has a package checksum plus a launch receipt.
4. **A real name:** the product is **Asterisma**; this MVP build is **AsterismaV1.0**. The internal sandbox bundle ID stayed `johan.Reading-Tracker` on purpose so the existing container and library were not orphaned.

---

## What did I end up doing?

| # | What | Evidence |
|---|------|----------|
| 1 | **G0 — safety baseline:** worktree, data snapshot, test isolation, benchmark | `docs/plans/bedrock/BASELINE.md` |
| 2 | **G1 — correctness:** fixed and pinned writer ordering, crash-window inflation, stale midnight cache, onboarding import bypass/goal clobber, spatial covers, RSVP cancellation | `gates/GATE-G1.md` |
| 3 | **G2/G2B — distribution + Mirage:** app icon, entitlements, shared scheme, ad-hoc package; 47 MB runtime embedded, signed, manifest-verified, bundle-smoke green | `gates/GATE-G2.md`, `GATE-G2B.md` |
| 4 | **G3A/B/C — SQLite:** GRDB schema, lazy summary store, real-library cutover, JSON retired to `.migrated`; load **5.06 ms** vs 493.7 ms | `gates/GATE-G3A.md`, `GATE-G3B.md`, `GATE-G3C.md` |
| 5 | **G4 — weather:** Open-Meteo provider, live session→snapshot→SQLite pipeline, no WeatherKit entitlement | `gates/GATE-G4.md` |
| 6 | **G5 — library intelligence:** EPUB genre/series/word count, Book Details, notes, tags, collections | `gates/GATE-G5.md` |
| 7 | **G6 — Behavior Context V3:** full report, Advanced Context window, evidence archive, history analysis | `gates/GATE-G6.md` |
| 8 | **G7 — debt:** removed 1,157 lines of dead code; Swift 6 attempted and deferred with an honest 148-error receipt | `gates/GATE-G7.md` |
| 9 | **G8 — release candidate:** full census, package, checksum, launch smoke, owner acceptance | `gates/GATE-G8.md` |
| 10 | **R1 — Asterisma rebrand + data migration:** live library moved in place, counts preserved | `docs/REBRAND-ASTERISMA.md` |
| 11 | **Merge + push:** fast-forwarded `main`, pushed `main` and all tags to GitHub | `main` at `aba8aa4`; tag `asterisma-v1.0-mvp` |
| 12 | **R2 — repository reorganization:** app shell under `App/`, 48 flat tests into eight responsibility groups, 280-file baseline reconciled with zero content changes | `docs/reorganization/AV1-ROR-EXECUTION-2026-10-26.md` |
| 13 | **CI hardening + ready package:** `macos-26` / Xcode 26.6 census, Xcode 26.6 concurrency fix, rebuilt signed package, green remote receipt | GitHub run `40266848038`; `dist/AsterismaV1.0-1.0-arm64.zip` |
| 14 | **Sentinel v2 first tranche + SG8 surface layer:** 140 probes / 15 domains / 25 repairs; 28 source-derived surfaces with generic table contracts; Release Health Center, journal v2, launch card, notifications, diagnostics | `docs/audits/12-sentinel-v2-tranche-2026-10-28.md`; `docs/plans/sentinel/gates/SG8.md` |
| 15 | **Library Recovery (Phases 1–6):** preserve → diagnose → export, backup verify/drill, atomic restore + rollback + reconcile, logical rebuild, orphan row repair with undo, Sentinel gate/suspension/verification, Recovery tab + support summary | `DBappends.md`; `docs/plans/library-recovery/G6.md` |

---

## Overarching goal

An app that can be trusted with years of reading history, with a change process that is receipt-driven end to end. AsterismaV2.0 adds a clean product identity and a faster SQLite-backed store without trading away the user’s existing library.

---

## What needs to happen next? (in order)

| # | Item | Estimate | Details |
|---|------|----------|---------|
| **A** | **Reading analytics Phase Zero → E1/E2** | Multi-session program | The evidence report is `docs/audits/13-reading-analytics-phase-zero-2026-10-29.md`. Next: fix the DEBUG-only synthetic generator (E1), then replace the 60 s timing ceiling with a measured attention policy (E2). Do not tune the genre weight or the 40/25/20/15 blend until both are green. |
| 0 | **Library Recovery owner acceptance (G6)** | One focused session | Run the nine-step acceptance script in `docs/plans/library-recovery/G6.md` on a copied library. The gate is not passed until this is signed off. Performance tuning for 1.38 M timings is a separate follow-up, by owner decision. |
| 1 | **Sentinel owner acceptance + SG7 close** | One focused session | Run the ten roadwork scenarios on a copied library, decide v1 removal, then close or narrow SG7. Localization, menu bar, accessibility, and the 10× benchmark remain separate holds. |
| 2 | **Distribution hardening** | Signing/account setup | Developer ID signing + notarization so first launch is a normal double-click. Today the build is ad-hoc signed and needs right-click → Open. |
| 3 | **Bundle ID migration** | One focused session | The sandbox ID is still `johan.Reading-Tracker`. Moving to an Asterisma ID requires copying the container to the new sandbox; do not change it casually. |
| 4 | **Swift 6 strict concurrency** | Multi-session arc | The attempt produced 148 actor-isolation errors; the project stays in Swift 5 mode until those surfaces are fixed. |
| 5 | **Reader selection highlights/quotes** | 1–2 sessions | Notes, tags, page anchors, and collections work; EPUB/PDF text-selection highlighting is not wired. |
| 6 | **Behavior evidence to SQLite** | 1 session | Evidence currently persists in a JSON archive; the behavior tables exist but are not the live store. |
| 7 | **Collection rename UI** | Small | Create/delete/membership work; rename has no UI. |
| 8 | **Environment/Sentinel/console owner acceptance** | One focused session | Open the app at morning, midday, and afternoon; confirm the background flows, the readability veil is enough, and the Environment Studio can force every weather kind. Then walk the Sentinel sidebar, issue search/filter/Next issue, console sidebar search, and Subsystem Explorer. No screenshot receipt exists; the code and census are the only evidence today. |
| 9 | **Legacy cleanup + remaining dead code** | 1 short session | Repository graphify cache/backup, duplicate playbook, and OS metadata were removed on 2026-10-29; old P5-G `library.sqlite3`/`.migrated` app-support artifacts and zero-caller fragments remain, none live. |
| 9 | **Mirage standing items** | Process, not code | TB-M0 observation cadence, a perf-budget report, and the engine-side backup-surface gap. The packaged app-embed exercise is done. |
| 10 | **Mirage ADR-13 owner acceptance** | One focused session | Exercise the warm engine (start, two analyses without a cold restart, idle stop), a library scan, a batch cancel, and a retry-failed run from Settings ▸ Mirage. Record results in `docs/owner-test-results/`; the stage is not accepted until then. |

CI runner alignment is complete (2026-10-26): `census` runs on `macos-26` / Xcode 26.6. The remote `census` is green on the Sentinel v2 tranche (run `40758619365`, `bed710a`); the local census after SG8 is **432 tests / 671 runs / 9 skips / 0 failures**, and CI now runs the surface-freshness gate before the census. SG8 adds auto-extending structural coverage but does not close SG7: owner acceptance (row 1) is still the gate. The audit-era NEW-DE-1…NEW-DE-8 punch list is **fixed and pinned**; the old “open” block in the defect register is historical. Sentinel’s remaining holds are tracked in `docs/plans/sentinel/gates/SG7.md`, not in the old defect register.

---

## What should the next person know to start instantly?

**Baseline:** `main` carries the original release merge at `aba8aa4` plus the owner-accepted reader build, the preservation-first repository reorganization, CI hardening, the Sentinel v2 first tranche (`6099e4e`), and SG8 (`29dd4f6`); ready tag `asterisma-v1.0-ready-2026-10-26`, release tag `asterisma-v1.0-mvp`. At the SG8 boundary the local unit census was **432 tests / 671 runs / 9 skipped / 0 failed**; the reader boundary was **441 tests / 671 runs / 432 passed / 9 skipped / 0 failed** (Stage AA); the offline boundary was **447 tests / 671 runs / 438 passed / 9 skipped / 0 failed** (Stage AB, historical). The ADR-13 boundary was **459 tests / 671 runs / 450 passed / 9 skipped / 0 failed** (Stage AE). The Phase Zero boundary was **469 tests / 671 runs / 460 passed / 9 skipped / 0 failed** (`rt-census-20261029-183222.xcresult`); the current boundary is **515 tests / 99 suites / 719 runs / 506 passed / 9 skipped / 0 failed** (`./scripts/census.sh --unit-only`, exit 0; 2026-10-31), which adds the four Book File Relink tests and the one Phase Zero reading-analytics probe to the Stage AH environment/Sentinel/console boundary of **464 tests / 671 runs / 455 passed / 9 skipped / 0 failed** (Stage AH in `docs/registers/03-fix-log.md`). Release build exit 0 for the earlier boundary; the reader and offline passes have Debug build receipts only. Test isolation was byte-identical at the earlier boundary; it was not re-run after the reader or offline pass. The generated `dist/` package was removed during the 2026-10-28 artifact cleanup; rebuild with `scripts/package-release.sh`. The last documented package SHA-256 is `786832c8049e38ebe03d6220ae0a39b3a0005b010bdce4675e440cea65ef4643`. Canonical census numbers come from `xcrun xcresulttool get test-results summary`; Sentinel evidence is indexed in `docs/plans/sentinel/gates/README.md`. The close-out graph refresh (Stage AI) is **8,156 nodes / 20,371 edges / 389 communities**; the 3D page is 8,579,333 B and all artifact hashes are in the Stage AI receipt. The earlier Stage AG refresh recorded 8,045 / 20,093 / 381; the ADR-13 refresh (Stage AF) recorded 8,037 / 20,085 / 378.

> **History note (2026-10-28):** `main` was rewritten to remove AI co-author trailers from five commits. Trees are byte-identical. Remapped SHAs: `40bc922`→`16d6d16`, `fd524cd`→`5a369e9`, `6aecdc3`→`bed710a`, `2f40a43`→`310b9d3`, `ae4ee36`→`76e8a23`. A local-only `backup/pre-attribution-rewrite` branch may hold the old objects; it is not pushed and is safe to delete.

> **Owner-test authority:** the owner's personal test results are the absolute source of truth and override every benchmark, census, gate receipt, and documentation claim. See `docs/12-owner-test-authority.md`; record sessions in `docs/owner-test-results/`.

**Live data:** `~/Library/Containers/johan.Reading-Tracker/Data/Library/Application Support/Asterisma/` — **1 book / 3 sessions / 77 page timings** after the owner’s deliberate erase/reset and acceptance test. The owner deleted the local backup snapshots on 2026-10-24, so the live library is currently the only copy; rely on Time Machine or an external backup before risky work.

**Docs map:** start at `README.md` → this handoff → `docs/reorganization/` for the final structure audit → `docs/plans/bedrock/` for the release gates → `docs/design/READER-POLISH-2026-10-25.md` for the current reader customization record → `docs/integration/` for anything Mirage.

**Standing constraints:**
- Whole-file rewrites only for `BehaviorContextEngine2` and `BehavioralCategory`.
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — every background path needs explicit `nonisolated`.
- Census green at every boundary; `-derivedDataPath` is forbidden on Desktop/iCloud checkouts (BUG-003).
- **Owner results outrank the census.** A personal test failure is a real failure even if the suite is green; record it and fix it.
- Data root is `Application Support/Asterisma/`; the legacy `ReadTracker/` name is migration-only.
- The bundle ID is intentionally stable for this MVP; changing it needs a container migration.
- **Mirage rules:** never unify the two stores; entries are born only from validated receipts; one warm sidecar serves serialized requests and stops on idle/disable/background (ADR-13); spoiler detail surfaces stay disabled until a verified calibration amendment (ADR-7, fail-closed).
- During a freeze, run `sample <pid>` before reasoning about performance (`10-profiler-fix.md` is the proof).

**Fresh-clone build:** stage the gitignored Mirage runtime first:
`./scripts/stage-mirage-runtime.sh "$PWD/.mirage-runtime"`.

---

## Related documents

- `docs/registers/02-defect-register.md` — everything known to be broken or risky (the NEW-DE block is historical; F-series items remain the source of truth)
- `docs/registers/03-fix-log.md` — everything fixed, with proof (Stages B/R cover Bedrock/Asterisma and the ready close-out)
- `docs/plans/bedrock/` — G0–G8 gate record, baseline, plan, distribution notes
- `docs/reorganization/` — preservation-first structure audit, baseline manifest, relocation ledger, and execution report
- `docs/design/READER-POLISH-2026-10-25.md` — Apple Books benchmark and Phase 1 reader/library polish record
- `docs/REBRAND-ASTERISMA.md` — rename and data-root migration record
- `docs/integration/RT_Mirage_Codebase_Merge_Playbook.md` — the merge-era constitution (§22 still executes the TiB era)
- `docs/audits/08-deep-audit.md` — the full independent audit (October 2026)

---

## Session close — 2026-10-25

**Delivered:** Apple Books-style reader appearance panel and library polish.
Candidate package `a8ebf2ec…17009` (code `3bff002`, tag
`asterisma-v1.0-polish-1`).

**Verification:** Debug/Release builds green; package signature and bundle
smoke green; `ReaderAppearanceTests` 5/5. Full UI-inclusive census remains
blocked by the macOS UI-test automation bootstrap.

**Cleanup:** removed ~2.9 GB of Xcode DerivedData, 91 temporary test/build
artifacts, all `.DS_Store` files, and two empty legacy project folders. Kept
the signed release zip, the staged Mirage runtime, and graphify deliverables.
`.obsidian/` is now ignored as local vault configuration.

**Next:** owner visual retest of the Appearance panel and book plate. The next
polish batch is in-book search/bookmarks/highlights, vertical scroll, and
per-theme custom settings.

---

## Session close — 2026-10-26

**Delivered:** preservation-first repository reorganization (app shell under
`App/`, 48 flat tests into eight responsibility groups), GitHub CI correction
to `macos-26` / Xcode 26.6, the Xcode 26.6 `nonisolated` subscript fix, and a
rebuilt signed ready package.

**Verification:** Debug build green; repository baseline reconciliation
280/280 with zero content changes; local unit census **220 passed / 0 failed /
9 skipped**; GitHub unit census **229 tests / 10 deliberate skips / 0 failures**
(run `40266848038`); package signature, sandbox entitlements, embedded-Mirage
smoke, and Gatekeeper-rejection expectation re-verified.

**Ready package:** `786832c8049e38ebe03d6220ae0a39b3a0005b010bdce4675e440cea65ef4643`
(app code `1c88ae5`, tag `asterisma-v1.0-ready-2026-10-26`).

**Cleanup:** graphify refreshed at the ready tree; generated `.DS_Store` and
temporary build/test residue removed. The signed zip, staged Mirage runtime,
and historical graphify outputs were preserved.

**Next:** owner visual retest of the Appearance panel and book plate on the
ready package. If accepted, record owner acceptance and promote milestone 004
from candidate to accepted. Then resume the polish backlog: in-book search,
bookmarks/highlights, vertical scroll, per-theme settings, library shelf/grid,
and the accessibility/responsive matrix.

---

## Session close — 2026-10-29 (3D graph views)

**Delivered:** the offline 3D views now open on a double-click in Safari
(the `[hidden]` fallback card was covering the canvas), orbit a full sphere in
both axes, pan with the arrow keys, and render through analytic node impostors
with a cached layout. Implementation is entirely in
`scripts/graph3d-template.html`; details and measurements are in
`docs/registers/03-fix-log.md` Stage T.

**Verification:** `python3 scripts/build-graph-3d.py --check` returns `ok` for
`graph-3d-full.html` (7.71 MiB,
`ab9a19b6407b2a703d80c302701938f71d86a8c74f393f8927619f8265f67971`); the
community 3D view was deleted in the same session, so the generator now emits
one page. The full
view dropped from 5,949,312 to 450,660 triangles and now holds 59.6 fps while
dragging at 2560×1440 / DPR 2 (was 46.5 fps); warm reopen is 256–340 ms versus
2,817 ms cold. Hover, select, isolate, and reset were exercised in Chromium and
WebKit with no console errors and no network requests. The app code was not
touched, so no Xcode build or census was rerun for this stage.

**Next:** owner visual check of `graph-3d-full.html` and `graph.html`; the
work is committed and pushed (`c2c669d`).
`graph-3d-full.html` stays local and must be rebuilt after any graph refresh;
`graph-3d.html` is retired.

---

## Session close — 2026-10-29 (one-hop retrieval)

**Delivered:** `docs/INDEX.md` (question → exact file/line, no duplicated
answers), `scripts/comprehension-bench.py` with a 30-question niche bank and a
12-fact overview bank, and a CI “Comprehension index freshness” step.

**Measured (30 questions + 12 overview facts, 3 reps):** facts naive
**51.2–51.3 ms / 27,264 B** versus indexed **0.1 ms / 5,398 B** —
**344–352×**, accuracy 100%, 0 grep fallbacks; the pre-index 24-question
baseline was 48.7 ms / 26,907 B / 88%. Overview: 246 files / 3.12 MB /
74.6–75.6 ms versus 4 documents / ~63 KB / 0.8 ms — **≈97×**, coverage 100%.

**Defects fixed:** README claimed 138 checks / 56 required; the SG8 receipt
says 140 / 58 (both README lines corrected, historical prose left alone). The
build-config row now says Xcode 27.1 locally / CI pins 26.6, and the README
open-work table now puts Library Recovery G6 ahead of Sentinel SG7, matching
this handoff.

**Verified:** `python3 scripts/comprehension-bench.py --validate-only` passes
(30 facts, 12 overview facts, all anchors in bounds); `--mode all` exits 0 with
the gate above. Commit `c2c669d` is pushed; GitHub census run `40811182851` is
green in 3m26s, including the new index-freshness step and the full unit census
(432 tests / 671 runs / 9 skips / 0 failures).

**Cold-reader trial:** 3 dispatch attempts, ~85 s (valid brief), ~245 s (invalid
— the worker summarized the session instead of reading), ~48 s (valid brief).
Spawned workers inherit this conversation, which is why run 2 failed; the
repeatable context-free measurement is the fresh-process harness.

**Next:** owner visual checks; refresh graphify and the full 3D view so the new
files appear in the graph; keep `docs/INDEX.md` anchors current and rerun
`--mode all` after any edit above an indexed line.

---

## Session close — 2026-10-29 (graph refresh + truth audit)

**Delivered:** graphify refreshed from the current tree; a root
`.graphifyignore` excludes the minified vendored 3D renderer; the 2D community
export and the full 3D page were regenerated; `AGENTS.md` gained the mandatory
Markdown truth audit (evidence standard, weighted rubric, append-only ledger),
`scripts/audit-markdown.py` collects the mechanical evidence, and the stale
app/test counts in README, the project tree, the testing method, and the
remediation roadmap were corrected against fresh commands and CI logs.

**Graph:** **7,599 nodes / 19,164 edges / 361 communities** (previous receipt
7,510 / 19,023; the difference is +89 doc and tooling nodes after removing
3,371 vendor-renderer nodes). `graph.html` is the aggregated view (361
community nodes / 1,425 cross-community edges); `graph-3d-full.html` is 7.76 MiB
and `--check` returns `ok`.

**Verified:** surface manifest OK (15 tables / 8 defaults keys / 5 notification
names); `comprehension-bench.py --validate-only` OK (30 facts, 12 overview
facts); unit census **432 tests / 671 runs / 423 passed / 9 skipped / 0 failed**,
exit 0; the 3D page rendered in Chromium with WebGL, zero console
errors, and no external requests.

**Remote CI:** run `40813582449` succeeded in 2m25s on commit
`b4b587be9aaead322d42581f0a44a7e35bf939e7`; the surface-freshness,
comprehension-index, and unit-census steps are all green.

**Docs:** the full **83-file Markdown sweep is complete**: 13 current documents
PASS, 68 dated receipts REVIEW with disclosed skips, and the generated graph
report SKIPPED; all 417 path claims resolve. The per-file table, evidence, and
skip register are in `docs/registers/05-doc-audit.md`.

**Next:** owner visual check of `graph-3d-full.html` and `graph.html`; keep the
index anchors current; refresh the graph again after the next batch of doc edits
if the node counts matter for a receipt. A new full sweep belongs with the next
release, not an ordinary edit.

## Session close — 2026-10-29 (AsterismaV2.0 rename)

**Delivered:** the product, Xcode project, app target, scheme, test targets,
Swift module, source/test/UI folders, Info.plist, entitlements, release script,
CI workflow, and current documentation now use **AsterismaV2.0** /
**AsterismaV2_0**. `MARKETING_VERSION` is **2.0** and
`CURRENT_PROJECT_VERSION` is **2**. The bundle identifier
`johan.Reading-Tracker` and the `Application Support/Asterisma/` data root were
deliberately left unchanged so the existing sandbox container and library
survive the rename. The V1.0 package names, tags, and SHAs in dated receipts
were preserved as history.

**Verified locally:** `xcodebuild build` succeeded for both Debug and Release
under `AsterismaV2.0.xcodeproj` / scheme `AsterismaV2.0`; the unit census is
**432 tests / 671 runs / 423 passed / 9 skipped / 0 failed** with
`environmentDescription` `AsterismaV2.0 · Built with macOS 26.6.1`; surface
manifest OK; `comprehension-bench.py --validate-only` OK (30 facts, 12 overview
facts); `audit-markdown.py` OK on all 83 Markdown files; `verify-test-isolation.sh`
reports the real app-support data byte-identical.

**Graph:** `graphify update . --force` rebuilt **7,621 nodes / 19,186 edges /
355 communities** from the working tree on base commit `fced076`. The aggregated 2D page is 355 community nodes / 1,339
cross-community edges (432,802 B); the full 3D page is 7,621 nodes / 19,186
links (8,146,098 B, 7.77 MiB) and `--check` returns `ok`.

**Remote CI:** **not yet run for this rename.** The last green workflow is
`40816019439` (2m37s) on `fced076`, which predates the rename. The rename must
pass the same workflow before it can be called release-ready.

**Next:** commit and push the rename, watch `census.yml` to green, then
visually check `graph.html` and `graph-3d-full.html`. The outer worktree folder
is still `/Users/johanrembeci/Desktop/AsterismaV1.0`; renaming it is a separate
owner action because moving the checkout during a session would invalidate
the recorded paths.

---

## Session close — 2026-10-29 (Home/Library UI shell)

**Delivered:** the main window now opens on a resume-first **Home** reading
desk; the sidebar is a four-destination map (Home, Library, Insights, Goals,
⌘1–⌘4); the Library is one adaptive grid/list with search, shelf filters, and a
selected-book dock; Insights and Goals are embedded destinations instead of
sheets; and the duplicate spatial-explorer entry point is gone from the main
window. The reader was deliberately left unchanged. Full design record:
`docs/design/UI-UX-OVERHAUL-2026-10-29.md`.

**Why this shape:** a weighted multi-criteria model (`T/U/L/A/C/V/E/X`) put
shell/navigation, Home, and Library at the top; a ±15% weight sensitivity run
kept those three in the top three in 100% of 20,000 draws. The spatial explorer
scored high on leverage only because deleting it is cheap; its low consistency
score is why it was retired rather than extended.

**Verified locally:** `xcodebuild build` (Debug, scheme `AsterismaV2.0`) →
**BUILD SUCCEEDED**, exit 0. `./scripts/census.sh --unit-only` → **432 tests /
671 runs / 423 passed / 9 skipped / 0 failed**, exit 0. App source is **169
Swift files / 63,448 raw lines / 56,051 non-blank**; the test folder remains 66
Swift files. No new test file was added for the presentation-only tranche.

**Not verified:** owner visual acceptance at 900×640 and 1200×780; VoiceOver,
keyboard-only, and 200% text-size passes; remote CI. The app was launched and
its 1200×742 window observed through `CGWindowListCopyWindowInfo`, but macOS
denied `screencapture` ("could not create image from window/rect"), so there is
no screenshot receipt. The V2.0 rename and this shell are both uncommitted in
the working tree; the last remote run predates both.

**Graph:** refreshed after the new Swift files and docs; the exact counts and
artifact hashes are in the Stage Y receipt in `docs/registers/03-fix-log.md`.

**Next:** owner opens the app, approves or rejects Home/Library/dock at both
window sizes, then the work is committed and pushed and `census.yml` is watched
to green. If the layout is rejected, change the owning view, not the model.

---

## Session close — 2026-10-29 (Quick Open + adaptive shell)

**Delivered:** the second UI/UX tranche. The shell now has a keyboard-first
**Quick Open** palette (⌘K) over destinations, books, discovery, import, and
Settings; Home's hero adapts between cover-beside-copy and stacked shapes;
Today's card reads the active daily goal and opens Goals; a Recently finished
shelf closes the loop after a book is completed; the Library dock clamps to
236–292 pt and stacks its actions when compact; ⌘F focuses Library search.
Full record: `docs/design/UI-UX-OVERHAUL-2026-10-29.md` §7.

**Verified locally:** `xcodebuild build` (Debug, scheme `AsterismaV2.0`) →
**BUILD SUCCEEDED**, exit 0. `./scripts/census.sh --unit-only` → **437 tests /
671 runs / 428 passed / 9 skipped / 0 failed**, exit 0, xcresult
`rt-census-20261029-005620.xcresult`. App source is **170 Swift files / 64,084
raw lines / 56,626 non-blank**; the test folder is **67 Swift files**, including
five new `CommandPaletteTests`.

**Not verified:** owner visual acceptance at 900×640, 900×640 with a 300 pt
sidebar, and 1200×780; VoiceOver, keyboard-only, and 200% text-size passes; the
palette overlay's focus/⌘K behavior (the pure ranking index is tested); remote
CI. The macOS screen-capture permission is still denied, so there is no
screenshot receipt. The V2.0 rename, Stage Y, and Stage Z remain uncommitted in
the working tree; the last remote run predates all of them.

**Graph:** refreshed after the new Swift files, design record, README, project
tree, and Stage Z receipt; exact counts and hashes are in the Stage Z graph row
in `docs/registers/03-fix-log.md`.

**Next:** owner opens the app and validates Home, the adaptive hero, Library,
the dock, Quick Open, and the reader return path at all three window sizes. Then
commit and push, watch `census.yml` to green, and run the keyboard/VoiceOver
pass. If the layout is rejected, change the owning view, not the model.

---

## Session close — 2026-10-29 (reader customization)

**Delivered:** the EPUB Appearance panel now has Paged/Scrolling mode, a
35–100% page-only brightness dimmer, Both Margins Advance, and the existing
six themes, eleven font choices, bold, 80–200% size, line/character/word
spacing, margins, justification, hyphenation, page-turn style, and page-number
toggle. The PDF panel is separate because PDFs keep publisher typography:
single/continuous/facing/facing+scroll layouts, fit page/width/height/actual,
cover-alone, LTR/RTL page order through PDFKit's `displaysRTL`, a 0–80 pt page
gap, system/paper/slate mat colors, and the same dimmer. Full record:
`docs/design/READER-POLISH-2026-10-25.md` Phase 2.

**Verified locally:** Debug build `** BUILD SUCCEEDED **`, exit 0. Focused
`ReaderAppearanceTests` → **9 tests in 1 suite passed**, exit 0, xcresult
`Test-AsterismaV2.0-2026.10.29_01-29-24--0400.xcresult`. Full unit census →
**441 tests / 671 runs / 432 passed / 9 skipped / 0 failed**, exit 0, xcresult
`rt-census-20261029-012648.xcresult`. A Chromium harness at 1280×720 rendered
**23 paged pages**, switched to **21 scrolling viewport-pages**, landed at
`scrollY = 2160` for page 3, and restored page 3 at `scrollLeft = 3840` when
switching back. App source is **171 Swift files / 64,758 raw lines / 57,220
non-blank**; the test folder is **67 Swift files**.

**Not verified:** owner visual acceptance and a real-book pass; the macOS
screen-capture permission is still denied, so there is no screenshot receipt.
The WKWebView mode switch is covered by a one-off browser harness, not a
standing CI test. No remote CI run for this working tree. The V2.0 rename, the
UI tranches, and this reader pass remain uncommitted.

**Next:** owner opens an EPUB and a PDF and runs the 15-step acceptance
checklist in `docs/design/READER-POLISH-2026-10-25.md`, especially RTL spread
order, cover-alone, Scrolling mode position return, and brightness legibility.
Then commit and push, watch `census.yml` to green, and refresh the graph after
the final docs edits.

---

## Session close — 2026-10-29 (offline contract)

**Delivered:** an offline contract for the local-first app. The source audit
found only four live network surfaces — Open-Meteo weather, Open Library and
Gutendex discovery, and remote discovery cover images — and no network code in
the reader, library, goals, insights, engines, or core groups. Discovery now
uses a bounded ephemeral session (10 s request / 15 s resource, no connectivity
wait), queries both providers concurrently, and cancels both in-flight requests
when the path drops; its offline state says the local surfaces still work.
Weather requests are capped at 10 s and run in an independent task, so an
offline session close cannot delay notifications or local analysis. Exact code
and test receipt: `docs/registers/03-fix-log.md` Stage AB.

**Verified locally:** Debug build `** BUILD SUCCEEDED **`, exit 0. Focused
`DiscoveryOfflineTests` + `OpenMeteoProviderTests` → **11 tests in 2 suites
passed**, 0 failed, 0 skipped, exit 0, xcresult
`Test-AsterismaV2.0-2026.10.29_01-48-57--0400.xcresult`. Unit census → **447
tests / 671 runs / 438 passed / 9 skipped / 0 failed**, exit 0, xcresult
`rt-census-20261029-020548.xcresult`. Full UI-inclusive census → **450 tests /
673 runs / 441 passed / 9 skipped / 0 failed**, exit 0, xcresult
`rt-census-20261029-020643.xcresult`. App source is **172 Swift files / 64,868
raw lines / 57,315 non-blank**; the test folder is **68 Swift files**. The six
new pins cover the bounded session, both providers offline, cross-provider
dedupe, cancellation of both providers, and typed weather failure.

**Not verified — explicit skip:** a whole-suite run with the network denied at
the OS level could not be executed. `sandbox-exec` around `xcodebuild` hung
before the test runner connected (346–352 s), and launching the already
App-Sandboxed app directly under `sandbox-exec` ended with `Trace/BPT trap: 5`.
Xcode's own package resolution also fails under `sandbox-exec`
(`sandbox_apply: Operation not permitted`). This is recorded as `SKIPPED`, not
as an offline pass. Also unverified: owner offline acceptance with Wi-Fi off, a
real-book pass in that state, remote CI, and a commit/push for this working tree.
The graph was refreshed immediately afterward in Stage AC: **7,836 nodes / 19,618 edges / 387 communities**, 3D page **8,298,484 B (7.91 MiB)**, `build-graph-3d.py --check` exit 0, and a loopback Chromium check with WebGL true and no external resource requests.

**Next:** disconnect the network, launch the app, and exercise Home → Library →
an EPUB and a PDF → Goals/Insights; open Discover and confirm the offline state
and that the sheet closes cleanly. Then reconnect, confirm search resumes, and
commit/push with `census.yml` watched to green.

## Session close — 2026-10-29 (real-library hand grading completed)

> **Superseded later the same day:** every figure in this section was declared
> **VOID** by the owner. The section is kept as history. The void, its reasons
> and the surviving byte evidence are in the final session close below and in
> `docs/audits/new-era-testing.md` §31. Do not use the table below as a baseline.

**What was finished.** The owner-directed real-book pass is complete. All 149
EPUB packages in `asterisma new testing suite` were inventoried; 14 were proved
byte-identical duplicates by SHA-256, leaving **135 distinct works**, and **all
135 were read and hand-graded** against the app's own engine output. No script
assigned a verdict; the verdict record is `docs/audits/new-era-grades.tsv`, and
the reasoning, per-batch receipts and corrections are in
`docs/audits/new-era-testing.md`.

**The three results that matter.**

| Axis | Wrong | Direction |
|---|---:|---|
| Reading time | 126 / 129 judgeable (98%) | always **pessimistic**, 1.2×–3.1× |
| Page count | 73 / 135 (54%) | 46 too long, 27 too short |
| Difficulty label | 58 / 135 (43%) | 49 of 53 categorical misses **overstate** |

**The three structural causes** (detailed in §28):

1. The default pace is 120 s per 250-word page = **125 wpm**, about half of
   ordinary reading. Every reader without history is told a book takes ~2× as
   long as it will.
2. Page density is one constant (250 wpp) for a library whose real density runs
   **141–440 wpp**. Accuracy happens only where a book's difficulty multiplier
   accidentally offsets the gap — which is why epic fantasy looks right and
   Dumas, Dumas-length translations and light novels do not.
3. `difficultyMultiplier` is sensitive to *where* you sample. Five authors
   reproduce it: Tana French 1.95×, TurtleMe 1.47×, Hardy Boys 1.55×, Gwynne
   1.21×, Itachi's Story 1.17× — same authors, same prose, different badges.
   The same effect moved **7 of my own 20 verdicts (35%)** when I re-read those
   books from the middle instead of the front.

**Next actions, in order.**

- **A.** Fix F1 (pace) and re-grade the estimate column. The re-grade is not
  optional: three books currently read `plausible` only because the page error
  cancels the pace error, and fixing pace alone will falsify them.
- **B.** Run the three-window sampling experiment (F3). It is the cheapest test
  that can falsify this file's central claim; the hypothesis is stated in §22.2.
- **C.** Introduce a format-aware density band (F2) with a ≥70%-within-±15%
  acceptance test over the same 135 books.
- **D.** Detect compilations (F4) and exclude nav/TOC/footnote documents (F5)
  from both word count and the analysis sample.

**Not done, and not implied:** no real reading session exists, so the reader
side of the model is still synthetic (§29.1); the PDF path was not graded; there
is one grader and no inter-rater statistic; nothing was committed or pushed.

**Checks at close:** `verify-sentinel-surface.sh` exit 0;
`comprehension-bench.py --validate-only` exit 0; `census.sh --unit-only` exit 0
with **493 tests / 99 suites / 719 runs / 485 passed / 9 skipped / 0 failed**
(`rt-census-20261029-194024.xcresult`).

## Session close — 2026-10-29 (real-library results declared VOID)

**Declaration.** The owner voided every result of the real-library hand-graded
pass. The 135 verdicts, the per-batch tallies, the three accuracy figures,
findings F1–F6 and the cross-examination are withdrawn as evidence. Testing
restarts from scratch once a formulaic difficulty rubric exists. Full reasons and
a status per surviving item: `docs/audits/new-era-testing.md` §31.

**Why it was voided.** Three defects, in ascending order of severity. The
difficulty grade was one reader's judgement — §4 fixed the axes and the legal
values but not the arithmetic, so a second person cannot reproduce a verdict.
There is no second grader and no agreement statistic, while my own re-read moved
**7 of 20** verdicts (§25.1). And the page axis scored books against print
editions even though **128 of 149 packages carry no page markers and none
declares a page count**
(`python3 scripts/real-book-pagination.py "asterisma new testing suite"`, exit 0).

**What still stands.** 149 packages, 14 byte-identical duplicates, 135 distinct
works; the engine's own output as engine behaviour; and the pagination counts.
The verdict file `docs/audits/new-era-grades.tsv` is retained unchanged and
carries no authority; it was not opened for writing.

**Next.** Do not retest, do not tune the estimator, and do not cite the void file
as a baseline. The next action is authoring the difficulty formula the owner
requires. Nothing is committed or pushed.

## Session close — 2026-10-31 (200-round stress evaluation)

**State.** The 200-round run finished: 40 batches, 200/200 main rounds graded,
1,982,800 main predictions and 3,200 demo predictions. The driver was
interrupted after batch 175 and resumed at batch 176. `analyze_fresh_200.py`
exited 0 and verified every row; the demo verifier found no errors. The report
is `docs/audits/fresh-reading-stress-200-2026-10-30.md`
(SHA-256 `76ba1ba0bc050566bcfef62219c7c218d1edcac1850193bd8222ef806f58e582`,
356 lines). `docs/INDEX.md`, the root-cause audit's status section, the fix log
and this handoff were updated. The raw 100- and 200-round trees were then
archived in `docs/audits/evidence/fresh-stress-evidence-archive-2026-10-31.md`
(SHA-256 `aba62346888056aff88a40c6686d7a8cc05e22b038e9305acfd5899d8db2e875`)
and deleted; `du -sk .` fell from 6,885,764 KiB to 257,504 KiB at deletion.
`graphify-out/` was not touched.

**Result.** The fixed baseline beats the saved legacy comparator overall:
median 18.98% against 21.42%, mean 35.45% against 38.21%, spikes 170,404
against 185,341. That comparator is a hybrid: it equals the baseline on
`same_book` (5.48%/7.64%/158 for both) and uses the current per-book policy
there, so it isolates the pooling change on no-personal-speed cases, not the
ceiling change on personal-speed books. The exception is `corpus-evaluation`
(median 16.51% against 15.62%; mean unchanged at 21.13%). The candidate loses at the fitted 0.979
weight (median 23.09%, mean 41.35%, 220,164 spikes) and at the pre-registered
0.5 weight (26.70%, 43.35%, 223,724 spikes). The holdout repeats development
almost exactly, so this is not a failed weight transfer. The report records the
sparse-prior, last-eight and guard-inversion mechanisms; the candidate is
rejected.

**Checks.** Python tests exit 0 (28 tests, `OK`); Sentinel surface exit 0;
index validation exit 0 (`bank ok: 30 facts, 12 overview facts`); unit census
exit 0 (515 total, 506 passed, 0 failed, 9 skipped, 719 runs). The nine skips are
not passes. No independent hand grading or real-reader validation exists.

**Next.** Keep the two production changes. Do not promote the candidate. If the
owner wants another experiment, fall back to the fixed baseline when `recent` is
missing or rejected, shrink recent toward the target's full history, pre-register
the rule, and calibrate on the cases where it changes the answer. That experiment
has not been run. Graph refresh, commit and push remain separately owner-gated
and were not done; the cleanup and evidence archival are recorded above.
