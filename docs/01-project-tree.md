# 01 · Project Tree

## What this document is

This is a map of every file and folder in the project, organized so you can find your way around without needing to know how to code.

**Think of it like a building directory:** the top level is the project folder itself; inside are folders for documentation, the actual app code, tests, and the Xcode project settings.

---

## The top level (what you see when you open the project folder)

| Folder / file | What it is |
|---|---|
| `README.md` | The front door — start here |
| `docs/` | All project documentation (registers, roadmap, audit, history, the Mirage integration campaign, etc.) |
| `docs/INDEX.md` | The one-hop lookup: a question maps to the exact file (and line) that owns it |
| `RT_Mirage_Codebase_Merge_Playbook.md` | Owner's kept snapshot of the merge playbook (tracked canon: `docs/integration/` — ignored here by `.gitignore`) |
| `merge-log.md` | Owner's kept snapshot of the campaign log (tracked canon: `docs/integration/merge-log.md` — ignored here by `.gitignore`) |
| `AsterismaV2.0/` | The actual app code — every Swift file that makes the app work |
| `AsterismaV2.0Tests/` | Automated tests that prove the app works correctly |
| `AsterismaV2.0UITests/` | User-interface tests (mostly placeholder stubs) |
| `AsterismaV2.0.xcodeproj/` | The Xcode project file (do not edit by hand) |
| `AsterismaV2.0.entitlements` | Permissions the app asks macOS for (sandbox, user-selected files, location) |
| `AsterismaV2.0-Info.plist` | App settings such as its name, icon, and location description |
| `scripts/` | Census, benchmark, test-isolation, runtime staging, icon, release-package, 3D-graph build (`build-graph-3d.py` + vendored renderer), the cold-retrieval harness (`comprehension-bench.py` + its question bank), the Markdown evidence collector (`audit-markdown.py`), and the stable build-and-launch command (`run-latest.sh`) |
| `dist/` | Generated release packages (gitignored, rebuilt by `scripts/package-release.sh`); the stale local build was removed on 2026-10-28 |
| `.mirage-runtime/` | Local staged Mirage runtime (gitignored; required for a fresh build) |
| `graphify-out/` | Generated knowledge graph, 2D community HTML, offline full-node 3D HTML, and report. The code-refreshed graph has **8,956 nodes / 21,465 edges / 433 communities**; counts, hashes, and the documentation-refresh limitation are in `docs/registers/03-fix-log.md`. `graph-3d-full.html` is the only 3D export — `graph-3d.html` was retired 2026-10-29 |
| `.gitignore` | Tells Git which files to ignore (build junk, user settings, etc.) |
| `.graphifyignore` | Tells graphify to skip `scripts/vendor/` — the minified 3D renderer — so graph counts describe project code and docs |

---

## The `docs/` folder (documentation)

Every documentation file begins with a number so you can read them in order:

| File | Number | What it is | Who should read it |
|---|---|---|---|
| `README.md` | 00 | Project overview and front door | Everyone, first |
| `docs/INDEX.md` | — | One-hop lookup: question → exact file/line | Everyone with a specific question |
| `docs/01-project-tree.md` | 01 | This file — where everything lives | Everyone |
| `docs/registers/02-defect-register.md` | 02 | Everything known to be broken or risky | Anyone who wants to fix bugs |
| `docs/registers/03-fix-log.md` | 03 | Everything that has been fixed, with proof | Anyone who wants to understand the history |
| `docs/registers/04-handoff.md` | 04 | What to do next, in order | Anyone who wants to contribute |
| `docs/registers/05-doc-audit.md` | 05 | Markdown truth-audit ledger: per-file scores, digests, evidence, and skips | Anyone editing documentation |
| `docs/roadmap/05-remediation-roadmap.md` | 05 | The long-term plan, phase by phase | Anyone planning future work |
| `docs/roadmap/06-rsvp-feature-plan.md` | 06 | Plan for the speed-reading feature | Anyone working on that feature |
| `docs/method/07-testing-strategy.md` | 07 | How tests are written and why | Anyone writing tests |
| `docs/audits/08-deep-audit.md` | 08 | The full independent audit from Oct 2026 | Anyone who wants the complete picture |
| `docs/audits/11-completion-and-health-report-2026-10-24.md` | 11 | Bedrock-era completion and health snapshot | Anyone reviewing the release |
| `docs/audits/12-sentinel-v2-tranche-2026-10-28.md` | 12 | Sentinel v2 first-tranche delivery, census, and honest holds | Anyone reviewing Sentinel or the current census |
| `docs/audits/13-reading-analytics-phase-zero-2026-10-29.md` | 13 | Reading analytics Phase Zero baseline, confirmed defects, and next experiments | Anyone starting the analytics rebuild |
| `docs/audits/evidence/reading-analytics-phase-zero-2026-10-29.json` | — | Machine-readable eight-persona Phase Zero trace | Reproducing the report's numbers |
| `docs/plans/sentinel/` | — | Sentinel program plan, 120-subdomain atlas, and SG0–SG7 gate receipts | Anyone extending Sentinel |
| `docs/REBRAND-ASTERISMA.md` | — | Asterisma rename + data-root migration record | Anyone touching names, paths, or the bundle ID |
| `docs/plans/bedrock/` | — | G0–G8 gate record, master plan, baseline, distribution notes | Anyone auditing the release |
| `docs/design/fullscreen-surface-audit.md` | — | Fullscreen surface audit, border inventory, and after capture | Anyone reviewing the UI |
| `docs/design/UX-BETA-AUDIT-2026-10-25.md` | — | Beta UX audit, finding register, and remediation phases | Design, engineering, QA, and product owners |
| `docs/design/READER-POLISH-2026-10-25.md` | — | Apple Books benchmark, Phase 1/2 reader customization, chrome, and library polish record | Design, engineering, and anyone continuing the polish program |
| `docs/design/UI-UX-OVERHAUL-2026-10-29.md` | — | Two weighted UI models, Home/Library shell and Quick Open/adaptive decision records, receipts, and limits | Design, engineering, QA, and the next UI session |
| `docs/reorganization/` | — | AV1-ROR baseline, relocation ledger, exception register, and execution report | Anyone auditing repository structure |
| `docs/12-owner-test-authority.md` | 12 | The owner's personal test results are the absolute source of truth | Everyone — this overrides all other claims |
| `docs/MILESTONES.md` | — | Pinned capability milestones with exact timestamps | Everyone — the wins matter too |
| `docs/owner-test-results/` | — | Personal test sessions, template, and evidence | The owner, then anyone acting on the results |
| `docs/history/09-final-traces.md` | 09 | Diary of the performance upgrade marathon | Anyone interested in performance history |
| `docs/history/10-profiler-fix.md` | 10 | The story of how the big freeze was finally fixed | Anyone interested in the freeze mystery |

**The integration chapter — `docs/integration/`** (added by the Oct 2026 RT–Mirage merge campaign; its own ID space lives inside the folder):

| File | What it is | Who should read it |
|---|---|---|
| `RT_Mirage_Codebase_Merge_Playbook.md` | The playbook that governed — and still governs the §22/TiB era of — the merge | Anyone touching Mirage |
| `merge-log.md` | The campaign log of record (M-014 onward, append-only) | Anyone who wants the full history with receipts |
| `final-acceptance-2026-10-18.md` | The closing acceptance checklist, receipt per row | Reviewers |
| `adr/` | The ADR register: transport, packaged runtime, ledger stratum, identity mapping, feature lifecycle, spoiler-cursor contract, repository strategy, TiB charter | Anyone changing the boundary |
| `evidence/` | The §19 evidence bundle manifest + the operational handoff bundle + receipt artifacts | Reviewers / release owner |
| `phase1/` | Pre-ladder extractions: the 28-action wire protocol, RT touchpoints, normative-doc pins | Anyone on the wire |
| `rehearsals/` | §15 rehearsal log: rollback census, backup-restore re-pin, runtime staging/swap | Ops |
| `tib/` | §22 Titanium Bridge: TiB charter (ADR-12), TB-M0 gate plan + observation ledger | The next sessions |

Also in `docs/history/`:
- `freeze.txt` — a raw 5-second forensic sample of the app while it was frozen (technical, not meant to be read cover to cover)
- `diagnostics-2026-08-26.txt` — raw build output from August 26 (technical)
- `LAST_DEFEAT_demo_profiles.txt` — the complete story of the freeze hunt, written to be read by anyone

---

## The app code (`AsterismaV2.0/`)

This folder contains every Swift file that makes the app run. They are grouped by what they do:

| Group | Contains |
|---|---|
| `App/` | App composition: the `@main` entry point, the four-destination shell (`AppSection`), Quick Open (`CommandPalette`), and the main window (`NewContentView`) |
| `Core/` | The heart of the app: the data store, book models, validators, persistence, and `Sentinel/` (v2 domain, runtime, journal, probe catalog, repairs; `SentinelEngine` is the legacy Debug-console engine) |
| `Engines/` | The "accountants": analytics, estimation, data maturity, insights |
| `Features/` | Everything the user sees and touches: `Home/` (resume-first reading desk), `Library/` (unified browser, filters, selected-book dock), books, reader, goals, `Environment/` (10 s palette engine, continuous atmosphere, stars, shooting stars, live weather layer), weather, audio, achievements, onboarding, reports, RSVP speed-reading, `Sentinel/` (sidebar Health Center, launch card, view model), `DeveloperConsole/` (sidebar search, Environment Studio, Subsystem Explorer, dashboard, Sentinel pane, Demo Profile Lab) — and `Mirage/` (17 typed files: the RT-side of the Mirage integration — wire types, client, sidecar supervisor, runtime locator, cursor gate, status surface, settings, identity map, import flow, sheet, mount, transport, child-process, protocol constants, plus the ADR-13 warm service `MirageEngineService.swift`, cached `MirageLibraryIndex.swift`, and `MirageBatchAnalyzer.swift`) |
| `Assets.xcassets` | Pictures, colors, and icons used in the app |

---

## The tests (`AsterismaV2.0Tests/` and `AsterismaV2.0UITests/`)

These are automated checks that run without you having to click anything. Each test is named after the specific bug or behavior it guards. If a test ever starts failing, that is an early warning that something broke.

As of 2026-11-07: **83 Swift files** in the unit-test folder and **518 tests in 100 suites**. The post-E8 local unit census (`./scripts/census.sh --unit-only`, exit 0) records **518 tests / 719 runs / 509 passed / 9 skipped / 0 failed** under `AsterismaV2.0`, including the 12 ADR-13 pins in `MirageEngineServiceTests`, `MirageLibraryIndexTests`, and `MirageBatchAnalyzerTests`, the five environment pins in `EnvironmentWeatherVisualTests`, the four Book File Relink recovery tests, the one Phase Zero reading-analytics probe, and the new `Engines` group (page-duration policy, estimation provenance, page-estimation model, estimate facade) plus the four reading-difficulty calibration pins, the two E8 facade pins, the G6 SQLite behavior pin, and the 200-round stress-evaluation work. The older UI-inclusive count (450 tests / 673 runs / 441 passed / 9 skipped / 0 failed) is historical and was not re-run for this working tree. The target remains grouped by responsibility (`App`, `Behavior`, `Core`, `DeveloperConsole`, `Engines`, `Environment`, `Library`, `Mirage`, `Reader`, plus Sentinel domain/runtime/catalog/persistence suites). UI tests remain placeholder launch stubs and are not part of the deterministic merge receipt. See `docs/method/07-testing-strategy.md` for how to engage them.

---

## How to use this map

- **If you want to fix a bug:** Start with `02-defect-register.md`, find the item you want to work on, then use this map to locate the relevant source file.
- **If you want to understand how a feature works:** Find the feature group in `Features/` and open the file with the same name.
- **If you are lost:** Come back to this file, or start over at `README.md`.
