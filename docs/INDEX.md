# Index — where to look first

> The map, not the manual. Use this page when you already know the question.
> Every entry links to the file that owns the answer — and, where a single line
> settles it, to that exact line. `scripts/comprehension-bench.py` re-validates
> every link and anchor and fails when a niche question stops resolving in one
> hop.

## Read in this order

1. `README.md` — what the app is, verified health, open work, commands.
2. `docs/INDEX.md` — this page; skip straight to the row you need.
3. `docs/01-project-tree.md` — where every file lives.
4. `docs/registers/04-handoff.md` — the current state and the next actions.

## The app and its shell

| If you need… | Read first | Then |
|---|---|---|
| Bundle identifier, product name, deployment target | `AsterismaV2.0.xcodeproj/project.pbxproj#L465` | `AsterismaV2.0-Info.plist` |
| App shell: declares the root content view (SwiftUI) | `AsterismaV2.0/App/NewContentView.swift#L1` | `AsterismaV2.0/App/AsterismaApp.swift` |
| Quick Open: pure ranking index, result targets, and the ⌘K overlay | `AsterismaV2.0/App/CommandPalette.swift#L1` | `AsterismaV2.0Tests/App/CommandPaletteTests.swift` |
| Four durable destinations and keyboard shortcuts | `AsterismaV2.0/App/AppSection.swift#L1` | `AsterismaV2.0/App/NewContentView.swift` |
| Home: resume-first launch surface, stats, shelves | `AsterismaV2.0/Features/Home/ReadingDeskView.swift#L1` | `docs/design/UI-UX-OVERHAUL-2026-10-29.md` |
| Library: unified grid/list, filters, selected-book dock | `AsterismaV2.0/Features/Library/LibraryBrowserView.swift#L1` | `docs/design/UI-UX-OVERHAUL-2026-10-29.md` |
| UI/UX models, weighted scores, and two-tranche record | `docs/design/UI-UX-OVERHAUL-2026-10-29.md` | `docs/design/UX-BETA-AUDIT-2026-10-25.md` |
| Reader customization: EPUB themes/fonts/size/brightness/mode, PDF layout/fit/RTL/gap | `docs/design/READER-POLISH-2026-10-25.md` | `AsterismaV2.0/Features/Reader/ReaderAppearance.swift`, `AsterismaV2.0/Features/Reader/PDFReaderSettings.swift` |
| Environment: 10 s palette engine, drifting atmosphere, stars, live weather layer, readability scrim | `AsterismaV2.0/Features/Environment/Engine/EnvironmentEngine2.swift#L1` | `AsterismaV2.0/Features/Environment/Weather/WeatherEffectView.swift`, `docs/design/UI-UX-OVERHAUL-2026-10-29.md` |
| Force any hour or weather kind and inspect the computed environment state | `AsterismaV2.0/Features/DeveloperConsole/EnvironmentStudioView.swift#L1` | `AsterismaV2.0/Features/Environment/Weather/WeatherVisual.swift` |
| App identity: data root directory name, bundle identifier constants | `AsterismaV2.0/Core/AppIdentity.swift#L12` | `AsterismaV2.0/Core/RuntimeEnvironment.swift` |
| Feature folders and the full file map | `docs/01-project-tree.md` | `AsterismaV2.0/Features/` |

## Defaults and feature switches

| If you need… | Read first | Then |
|---|---|---|
| Mirage toggle: switches the feature off, defaults key | `AsterismaV2.0/Features/Mirage/MirageSettings.swift#L21` | `docs/integration/adr/ADR-6-mirage-feature-lifecycle.md` |
| Mirage warm engine, cached library index, and batch queue (ADR-13) | `AsterismaV2.0/Features/Mirage/MirageEngineService.swift#L1` | `docs/integration/adr/ADR-13-mirage-warm-engine-and-library-scale.md` |
| Sentinel defaults keys: kill switch, repairs, interval minutes | `AsterismaV2.0/Core/SentinelEngine.swift#L140-L143` | `AsterismaV2.0/Core/Sentinel/SentinelConfiguration.swift` |
| Sentinel notifications: request defaults key, launch card | `AsterismaV2.0/Core/Sentinel/SentinelNotification.swift#L75` | `docs/plans/sentinel/gates/SG7.md` |

## Health: Sentinel and recovery

| If you need… | Read first | Then |
|---|---|---|
| Sentinel probe IDs and contracts: manifest tables, required surfaces need a registered owner, catalog | `AsterismaV2.0/Core/Sentinel/SentinelProbesSurface.swift#L45` | `AsterismaV2.0/Core/Sentinel/SentinelProbeCatalog.swift`, `docs/plans/sentinel/gates/README.md` |
| Surface manifest freshness: the script that fails CI when the manifest is stale | `scripts/verify-sentinel-surface.sh` | `AGENTS.md#L117`, `scripts/sentinel-surface.py` |
| Sentinel catalog size and the probe receipt | `docs/registers/04-handoff.md#L25` | `docs/plans/sentinel/gates/README.md` |
| Library recovery: Phase 5 rebuild result, carries skipped rows | `AsterismaV2.0/Core/LibraryRecovery/LibraryLogicalRebuilder.swift#L11` | `docs/plans/library-recovery/G6.md` |
| Recovery gate: enum defines the operational mode that suspends writes | `AsterismaV2.0/Core/LibraryRecovery/LibraryRecoveryGate.swift#L13` | `docs/plans/library-recovery/G6.md` |
| Sentinel Health Center: sidebar destinations, issue search/filter, Next issue, Check now | `AsterismaV2.0/Features/Sentinel/SentinelHealthCenterView.swift#L1` | `AsterismaV2.0/Features/Sentinel/SentinelViewModel.swift` |
| Developer Console: LIVE/PLANNED sidebar search, Environment Studio, Subsystem Explorer | `AsterismaV2.0/Features/DeveloperConsole/DeveloperConsoleRootView.swift#L1` | `AsterismaV2.0/Features/DeveloperConsole/SubsystemExplorerView.swift`, `AsterismaV2.0/Features/DeveloperConsole/EnvironmentStudioView.swift` |

## Data

| If you need… | Read first | Then |
|---|---|---|
| SQLite store: journal mode, GRDB connection that backs the live library, schema, migrations | `AsterismaV2.0/Core/Storage/LibraryDatabase.swift#L34-L45` | `AsterismaV2.0/Core/Storage/LibrarySnapshot.swift` |
| Library snapshot: table counts struct, key paths | `AsterismaV2.0/Core/Storage/LibrarySnapshot.swift#L48` | `AsterismaV2.0/Core/Storage/LibraryDatabase.swift` |
| Reading analytics: Phase Zero baseline, confirmed profile-sensitivity defects, next experiments | `docs/audits/13-reading-analytics-phase-zero-2026-10-29.md` | `docs/audits/evidence/reading-analytics-phase-zero-2026-10-29.json` |
| Synthetic reading-time evaluation: shared books, scenario tests, and limitations | `docs/audits/synthetic-reading-evaluation.md` | `tools/cde/synthetic_eval.py` |
| Fresh stress-run error root causes: reproduced arithmetic for the candidate tail, cold start, and unlearnable scenarios | `docs/audits/fresh-stress-root-cause-2026-10-30.md` | `docs/audits/fresh-reading-stress-100-2026-10-30.md`, `tools/cde/audit_fresh_tail.py` |
| Fresh 200-round stress evaluation: fixed baseline vs retired estimator vs rejected candidate, with holdout and demo | `docs/audits/fresh-reading-stress-200-2026-10-30.md#L1` | `docs/audits/evidence/fresh-stress-evidence-archive-2026-10-31.md`, `tools/cde/write_fresh_200_report.py` |
| Fresh stress evidence archive: manifests, aggregates and compressed summaries for the deleted 100/200-round raw trees | `docs/audits/evidence/fresh-stress-evidence-archive-2026-10-31.md#L1` | `docs/audits/fresh-reading-stress-200-2026-10-30.md`, `tools/cde/archive_fresh_evidence.py` |
| Real-book testing — **VOID 2026-10-29**: every hand-graded verdict declared void; read for the failure record and the surviving byte evidence only, never as accuracy results | `docs/audits/new-era-testing.md#L1456` | `docs/audits/new-era-testing.md#L3` |
| Book difficulty engine: what the shipped model actually computes, its measured defects (X1–X13), and the proposed Cognitive Difficulty Engine architecture | `docs/plans/cde/PHASE-1-AUDIT.md#L1` | `scripts/cde-phase1-audit.py` |

## Build, test, release

| If you need… | Read first | Then |
|---|---|---|
| Run the latest working tree: one stable build-and-launch command | `README.md#L238` | `scripts/run-latest.sh` |
| Build and test commands: Debug build, test, and census summary | `README.md#L254` | `scripts/census.sh`, `AGENTS.md#L117` |
| Last local unit census tests and runs record | `docs/audits/synthetic-reading-evaluation.md` | `scripts/census.sh` |
| Release receipts: git tag, package SHA-256, historical unit census record | `docs/registers/04-handoff.md#L91` | `README.md#L7` |
| CI receipts: last remote census run id, green Sentinel tranche | `docs/registers/04-handoff.md#L87` | `.github/workflows/census.yml` |
| Clean test session: Erase Library & Data… menu action | `README.md#L318` | `docs/registers/04-handoff.md` |
| CI run id verified the Sentinel v2 tranche `40758619365` | `docs/registers/04-handoff.md#L87` | `.github/workflows/census.yml` |
| CI workflow: GitHub Actions census runs on the runner image, Xcode version, test steps | `.github/workflows/census.yml#L10-L13` | `AGENTS.md` |

## Knowledge graph

| If you need… | Read first | Then |
|---|---|---|
| 3D graph view: full nodes and edges, 2D community HTML, generator | `README.md#L293` | `scripts/build-graph-3d.py`, `scripts/graph3d-template.html` |
| 3D graph generator: verify outputs without writing, staleness flag | `scripts/build-graph-3d.py#L232` | `README.md` §6 |
| Retired artifacts: the community 3D graph file removed 2026-10-29 | `AGENTS.md#L230` | `README.md#L308` |
| Graph exclusions: the vendored 3D renderer is kept out of graph counts | `.graphifyignore#L1` | `README.md#L308`, `docs/01-project-tree.md` |
| Graph refresh receipt: counts, excluded vendor nodes, artifact hashes, browser check | `docs/registers/03-fix-log.md` (Stage AS) | `README.md#L308` |

## Tests

| If you need… | Read first | Then |
|---|---|---|
| Reader appearance tests: nine pins for themes, settings injection, brightness, PDF mapping, gap, and RTL | `AsterismaV2.0Tests/Reader/ReaderAppearanceTests.swift#L1` | `docs/design/READER-POLISH-2026-10-25.md` |
| Offline contract: bounded discovery/weather sessions, cancellation, and network-free pins | `docs/registers/03-fix-log.md` (Stage AB) | `AsterismaV2.0Tests/Discovery/DiscoveryOfflineTests.swift#L1` |
| Mirage ADR-13 pins: warm-session serialization, idle teardown, index reconciliation, batch cancel/retry | `AsterismaV2.0Tests/Mirage/MirageEngineServiceTests.swift#L1` | `AsterismaV2.0Tests/Mirage/MirageLibraryIndexTests.swift`, `AsterismaV2.0Tests/Mirage/MirageBatchAnalyzerTests.swift` |
| Environment pins: condition→visual mapping, override store, forced clock/weather, scrim ordering | `AsterismaV2.0Tests/Environment/EnvironmentWeatherVisualTests.swift#L1` | `AsterismaV2.0/Features/Environment/Weather/WeatherVisual.swift` |

## Difficulty engine (CDE)

| If you need… | Read first | Then |
|---|---|---|
| What the difficulty formula is called, and the three names it is **not** (the engine, the legacy analyzer, the number) | `docs/plans/cde/FORMULA.md#L20` | `tools/cde/cde_model.py#L44` |
| What the new difficulty index computes, exactly: equations, six dimensions, feature definitions, weights | `docs/plans/cde/FORMULA.md#L87` | `tools/cde/cde_model.py#L72` |
| Why the shipped engine was rebuilt: reproduced defects with receipts | `docs/plans/cde/PHASE-1-AUDIT.md#L136` | `docs/plans/cde/FORMULA.md#L454` |
| What would prove the index is any good, and the pre-registered pass/fail gate | `docs/plans/cde/PHASE-3-VALIDATION.md#L190` | `docs/plans/cde/PHASE-3-VALIDATION.md#L51` |
| Measured behaviour: reliability, sampling stability, ablation, weight sensitivity, interval coverage | `docs/plans/cde/FORMULA.md#L370` | `tools/cde/cde_eval.py` |
| Which books the index scores highest and lowest | `docs/audits/evidence/cde-v0.3-scores-2026-10-29.json` | `docs/plans/cde/FORMULA.md#L454` |
| External review objections, answered point by point with measured rebuttals | `docs/plans/cde/REVIEW-RESPONSE.md#L56` | `docs/plans/cde/FORMULA.md#L543` |
| Adversarial measurements: coverage, feature redundancy, aggregation alternatives, split-half | `docs/audits/evidence/cde-critique-2026-10-29.json` | `tools/cde/cde_critique.py` |
| All 149 packages scored, duplicate identity proved, and what 16 blind grades found | `docs/plans/cde/RETEST-2026-10-29.md` | `docs/audits/evidence/adf-149-sheet-2026-10-29.md` |
| How to grade ADF against prose without mistaking judgement for ground truth | `docs/plans/cde/GRADING.md` | `tools/cde/cde_grade.py` |
| Every book's score, band, interval and six dimension percentiles | `docs/audits/evidence/adf-149-scores-2026-10-29.json` | `docs/audits/evidence/adf-149-sheet-2026-10-29.md` |

## Documentation evidence

| If you need… | Read first | Then |
|---|---|---|
| Markdown truth audit: evidence standard, weighted rubric, verdict rules | `AGENTS.md#L12` | `docs/registers/05-doc-audit.md` |
| Markdown evidence collector: digests, paths, anchors, commands | `scripts/audit-markdown.py` | `docs/registers/05-doc-audit.md` |
| Current close-out receipt: environment/weather, Sentinel and console navigation, graph refresh, and truth audit | `docs/registers/04-handoff.md` (2026-10-29 baseline) | `docs/registers/03-fix-log.md` (Stage AI) |
| CDE build record: what was implemented, what voids the earlier grades, and what is still missing | `docs/registers/03-fix-log.md` (Stages AM–AP) | `docs/plans/cde/FORMULA.md` |

## How this page is checked

```bash
python3 scripts/comprehension-bench.py --validate-only   # bank + every anchor
python3 scripts/comprehension-bench.py --mode all        # gate: one-hop accuracy, time, files
```

The bench is a fresh, context-free process each run. It compares a grep-first
reader with an index-first reader on 30 niche facts and 12 overview facts,
then compares a full 250-file scan with the four entry documents above. A stale
anchor, a broken path, or a question that falls back to grep fails the gate.
Fix the index, not the threshold.
