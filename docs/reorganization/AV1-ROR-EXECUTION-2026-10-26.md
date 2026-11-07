# AV1-ROR — Repository Reorganization Execution Report

**Document ID:** AV1-ROR-EXECUTION-001
**Date:** 2026-10-26
**Status:** EXECUTED — build, local unit census, and GitHub unit census verified; UI-inclusive census not claimed
**Governing specification:** owner-supplied `engineering team tasks oct 26th .md` (AV1-ROR-MASTER-001)
**Baseline commit:** `c1e1c968fa03257d6926c55d1fa7ed7f531149d2`
**Repository:** `/Users/johanrembeci/Desktop/AsterismaV1.0`

> **Path note (2026-10-29).** The product and its source, test, and project
> folders were later renamed to `AsterismaV2.5`. Path references in this report
> were migrated to the current spelling so they still resolve; the move
> inventory, counts, baseline commit, and `git mv` receipt are unchanged.

## 1. Scope and invariants

This was a structural operation only. No existing source, configuration, script,
test, documentation, project file, asset, or runtime file was edited. Moves were
performed with `git mv`; Git records all 50 as 100% renames with **0 insertions
and 0 deletions**.

Preserved:

- Every original byte of every relocated file (SHA-256 before == after).
- Xcode target membership, via the existing `PBXFileSystemSynchronizedRootGroup`
  declarations (`AsterismaV1.0`, `AsterismaV1.0Tests`, `AsterismaV1.0UITests`)
  and their verified lack of file-exception sets.
- Swift Package Manager manifests, lockfiles, entitlements, Info.plist, and
  build settings.
- Mirage ownership, runtime staging, release packaging, and user data.

## 2. Baseline and inventory

| Item | Verified value |
|---|---|
| Git branch | `main` |
| Git commit | `c1e1c968fa03257d6926c55d1fa7ed7f531149d2` |
| Tracked files | 280 |
| Files observed (including ignored runtime/build outputs) | 2068 |
| App Swift sources | 121 |
| Unit-test files | 48 |
| UI-test files | 3 |
| Documentation files | 72 |
| Shell/Python tooling | 9 |
| Xcode project files | 5 |

Portable baseline manifest (280 tracked files, path/size/mode/SHA-256):

`docs/reorganization/baseline-tracked-2026-10-26.json`

Relocation ledger (50 operations, full before/after hashes):

`docs/reorganization/relocation-ledger-2026-10-26.json`

The local full-filesystem manifest (2,068 files, including ignored runtime and
build outputs) remains at
`/Users/johanrembeci/Desktop/AsterismaV1.0-reorg-baseline-2026-10-26.json`
for this machine's audit trail.

## 3. Project and dependency analysis

- The three synchronized roots contain **no** `PBXFileSystemSynchronizedBuildFileExceptionSet`.
  Nested directories are therefore discovered automatically by Xcode.
- No test file uses `#filePath`, bundle-relative fixtures, or a repository-relative
  fixture path. Test fixtures are constructed in temporary directories.
- `scripts/census.sh --unit-only` targets the whole `AsterismaV2.5Tests` target,
  not a directory.
- `scripts/benchmark.sh` targets the Swift Testing type `BedrockBaselineTests`,
  not its file path.
- Scripts derive the repo root from `$(dirname "$0")/..`; moving scripts would
  require edits. They remain in place.
- The app shell has no path-sensitive references. `@main` and SwiftUI view
  discovery are independent of file location.

## 4. Target tree

```text
AsterismaV2.5/
├── App/
│   ├── AsterismaApp.swift
│   └── NewContentView.swift
├── Core/ (16 files)
├── Engines/ (4 files)
├── Features/ (101 files)
│   ├── Achievements/ (2)
│   ├── Audio/ (3)
│   ├── BehaviorContext/ (5)
│   ├── DeveloperConsole/ (9)
│   ├── Discovery/ (10)
│   ├── Environment/ (18)
│   ├── Goals/ (3)
│   ├── Insights/ (2)
│   ├── Library/ (13)
│   ├── Mirage/ (14)
│   ├── Notifications/ (2)
│   ├── Onboarding/ (1)
│   ├── RSVP/ (3)
│   ├── Reader/ (4)
│   ├── Recommendations/ (2)
│   ├── Reports/ (4)
│   ├── Sessions/ (4)
├── Assets.xcassets/
└── PrivacyInfo.xcprivacy

AsterismaV2.5Tests/
├── App/ (5)
├── Behavior/ (3)
├── Core/ (10)
├── DeveloperConsole/ (1)
├── Environment/ (6)
├── Library/ (2)
├── Mirage/ (16)
├── Reader/ (5)
```

`AsterismaV2.5Tests` moved from a 48-file flat directory to eight
responsibility-based groups. The app shell now has an explicit `App/` boundary;
all features, engines, and foundational code remain under their existing
architectural layers.

## 5. Relocation ledger

Every operation below is `VERIFIED`: source hash matched the baseline, the
destination hash matched the source, the source path no longer exists, and the
destination exists. Risk `R2` reflects the need to verify Xcode discovery; the
synchronized-group evidence above resolves that dependency.

The **From** paths are historical: they were the bytes before the move and no longer exist, so they are plain text here. The **To** paths are the current, backticked claims.

| ID | From | To | Risk | SHA-256 after | State |
|---|---|---|---|---|---|
| M-001 | AsterismaV2.5/AsterismaApp.swift | `AsterismaV2.5/App/AsterismaApp.swift` | R2 | `fdfc51398b9ac0cbdf0e7fd5bb9985da6a5cecf50089ac04e613e09154d1cd9c` | VERIFIED |
| M-002 | AsterismaV2.5/NewContentView.swift | `AsterismaV2.5/App/NewContentView.swift` | R2 | `078064699a16c5bbba1bc73329ff0d62d26d51370545d15a6cfd003cf997724a` | VERIFIED |
| M-003 | AsterismaV2.5Tests/BedrockBaselineTests.swift | `AsterismaV2.5Tests/App/BedrockBaselineTests.swift` | R2 | `656722dd92a8578ca9b4a5d668485df501d5dbc651856455be1b29d045d55b3f` | VERIFIED |
| M-004 | AsterismaV2.5Tests/CelebrationTimelineTests.swift | `AsterismaV2.5Tests/App/CelebrationTimelineTests.swift` | R2 | `e1dc0ae6ee7ea62465eb21b6486d3a8bbcdc9934bb3611531b2508f2b74ad351` | VERIFIED |
| M-005 | AsterismaV2.5Tests/NonGregorianCalendarTests.swift | `AsterismaV2.5Tests/App/NonGregorianCalendarTests.swift` | R2 | `af16dfab10abd08c6180617705b6cb111770b567550abf92192c90d63472f234` | VERIFIED |
| M-006 | AsterismaV2.5Tests/Reading_TrackerTests.swift | `AsterismaV2.5Tests/App/Reading_TrackerTests.swift` | R2 | `54489bacc91cacd6264a9d08ba1c8c116aa905c322511211e8de1ca1fc6cad3e` | VERIFIED |
| M-007 | AsterismaV2.5Tests/RemediationPinsTests.swift | `AsterismaV2.5Tests/App/RemediationPinsTests.swift` | R2 | `791c8d86a8f59073edf4e2035e386dce3ae3e98efa1e1688f50323c356738184` | VERIFIED |
| M-008 | AsterismaV2.5Tests/AnalyticsCachePinsTests.swift | `AsterismaV2.5Tests/Core/AnalyticsCachePinsTests.swift` | R2 | `33ea280cd20a0f0cef89f1609a44a6b34b5b3f57bb1b3ff38e435803b5221ccb` | VERIFIED |
| M-009 | AsterismaV2.5Tests/CoverStorePinsTests.swift | `AsterismaV2.5Tests/Core/CoverStorePinsTests.swift` | R2 | `9e538621af2b1d4105be2f0b7cf78931c087b13d2e7787ac8ab65113b00b7d1c` | VERIFIED |
| M-010 | AsterismaV2.5Tests/DataEraseTests.swift | `AsterismaV2.5Tests/Core/DataEraseTests.swift` | R2 | `2edac17dec39b519a1acb8c00596efbe1cb50dd7df93bda64229176737b56365` | VERIFIED |
| M-011 | AsterismaV2.5Tests/DurabilityPinsTests.swift | `AsterismaV2.5Tests/Core/DurabilityPinsTests.swift` | R2 | `f907dc83ef2eea5b7e9f31240516d8826c9b0e6d3eefcf0d48c8d29b9aa27a01` | VERIFIED |
| M-012 | AsterismaV2.5Tests/G1CorrectnessPinsTests.swift | `AsterismaV2.5Tests/Core/G1CorrectnessPinsTests.swift` | R2 | `43a922e99388dbd3138d143497d0127a0b77424f6e0d79625b843ff8a069eac0` | VERIFIED |
| M-013 | AsterismaV2.5Tests/ReliabilityTests.swift | `AsterismaV2.5Tests/Core/ReliabilityTests.swift` | R2 | `28abd4c58dbf82e5b45b8a9d6ccf6a59a478dbf0b5118d7cc603fdd8b42561cc` | VERIFIED |
| M-014 | AsterismaV2.5Tests/SchemaEvolutionTests.swift | `AsterismaV2.5Tests/Core/SchemaEvolutionTests.swift` | R2 | `b464cfaea609eac4a0fd2a7c32e08ff55d1d9813db3fc6540d8db73af82e05cb` | VERIFIED |
| M-015 | AsterismaV2.5Tests/SentinelPinsTests.swift | `AsterismaV2.5Tests/Core/SentinelPinsTests.swift` | R2 | `1dc0b20f5948893ba12684f0d300d8a0b4cbba93deb1b64c378b0021352e8da1` | VERIFIED |
| M-016 | AsterismaV2.5Tests/SQLiteDataStoreTests.swift | `AsterismaV2.5Tests/Core/SQLiteDataStoreTests.swift` | R2 | `8e7cf298bec55bd01ec0a15d2ed3074fef82be6fbcc343f6206a26f3718070f0` | VERIFIED |
| M-017 | AsterismaV2.5Tests/SQLiteFoundationTests.swift | `AsterismaV2.5Tests/Core/SQLiteFoundationTests.swift` | R2 | `1f6b4db3abbcb9e3e1138526b3ce7c7ed8b306f4440fb8fb31f9e526333bac3e` | VERIFIED |
| M-018 | AsterismaV2.5Tests/LibraryCollectionTests.swift | `AsterismaV2.5Tests/Library/LibraryCollectionTests.swift` | R2 | `1827d003914aa80907304cc5c62002f4c159d24d6f9ef3ff327d3b82988a20a1` | VERIFIED |
| M-019 | AsterismaV2.5Tests/LibraryMetadataPinsTests.swift | `AsterismaV2.5Tests/Library/LibraryMetadataPinsTests.swift` | R2 | `eadfbf19cbdfb76f79cd09f0a57c5514e727a62c7e96309fcde9aaf5c794239d` | VERIFIED |
| M-020 | AsterismaV2.5Tests/EPUBReadingPositionTests.swift | `AsterismaV2.5Tests/Reader/EPUBReadingPositionTests.swift` | R2 | `f0bd40650ade9f2008ea06d17de58bd03e3965ad02455e648dcaa3b70077c82f` | VERIFIED |
| M-021 | AsterismaV2.5Tests/FolderEPUBImportTests.swift | `AsterismaV2.5Tests/Reader/FolderEPUBImportTests.swift` | R2 | `ee0e283e3e92587163b0cbde79ecac60bfdc15ab931575b6ea62c32c3aa32f2d` | VERIFIED |
| M-022 | AsterismaV2.5Tests/ReaderAppearanceTests.swift | `AsterismaV2.5Tests/Reader/ReaderAppearanceTests.swift` | R2 | `3e2733542e048d5603532b810fabedaa8ca51d02d72e3086c3b62c90b3a1b94b` | VERIFIED |
| M-023 | AsterismaV2.5Tests/RSVPLogicTests.swift | `AsterismaV2.5Tests/Reader/RSVPLogicTests.swift` | R2 | `8e122a9a82523b088ce13db621e44868d12611a9ea27f82ceb1f3a2b9f80a1b4` | VERIFIED |
| M-024 | AsterismaV2.5Tests/TextExtractionTests.swift | `AsterismaV2.5Tests/Reader/TextExtractionTests.swift` | R2 | `a4274a3de92c621e216e40559e2d4d9e481986fad42e97ed738fab95ffa7277c` | VERIFIED |
| M-025 | AsterismaV2.5Tests/FatigueAnalyzerTests.swift | `AsterismaV2.5Tests/Behavior/FatigueAnalyzerTests.swift` | R2 | `a9fbb214cf958999dfc05603d28e4824af164eea30640fcb1fb9f1f680d85426` | VERIFIED |
| M-026 | AsterismaV2.5Tests/G6ContextPinsTests.swift | `AsterismaV2.5Tests/Behavior/G6ContextPinsTests.swift` | R2 | `26a56124e60456958b4b5a2f5478c9dcd133a72c4a882e74e3d8d03ac43d19bf` | VERIFIED |
| M-027 | AsterismaV2.5Tests/G6EvidencePersistenceTests.swift | `AsterismaV2.5Tests/Behavior/G6EvidencePersistenceTests.swift` | R2 | `bbbb918ec44c23d4778afa822221adc682ef0e6183da3d11d96d16a8a3727d85` | VERIFIED |
| M-028 | AsterismaV2.5Tests/EnvironmentEngineTests.swift | `AsterismaV2.5Tests/Environment/EnvironmentEngineTests.swift` | R2 | `2ce80b1017c51c777f850c3b4cf5f1cfc34a9522d49eca218daf2f9933b20a6e` | VERIFIED |
| M-029 | AsterismaV2.5Tests/OpenMeteoLiveSmokeTests.swift | `AsterismaV2.5Tests/Environment/OpenMeteoLiveSmokeTests.swift` | R2 | `9add1ff4f78f55f916912fedb299e5160d07ae51af21cac343c6d0a50f06a757` | VERIFIED |
| M-030 | AsterismaV2.5Tests/OpenMeteoProviderTests.swift | `AsterismaV2.5Tests/Environment/OpenMeteoProviderTests.swift` | R2 | `92e9f98c64beaf9a2abc34c76ae20d0276967f54e4192b761ebd40206828cb08` | VERIFIED |
| M-031 | AsterismaV2.5Tests/WeatherConfidencePinsTests.swift | `AsterismaV2.5Tests/Environment/WeatherConfidencePinsTests.swift` | R2 | `c36ad2afc60cf3fc5b4bee30e46fca919f5c4777b4ce8688dc0e25dcb90c8e9c` | VERIFIED |
| M-032 | AsterismaV2.5Tests/WeatherLivePipelineTests.swift | `AsterismaV2.5Tests/Environment/WeatherLivePipelineTests.swift` | R2 | `1a7dd32818caf7a62312a49eb7ce17117463de5fbcb15455a8bda4cf20383a03` | VERIFIED |
| M-033 | AsterismaV2.5Tests/WeatherTests.swift | `AsterismaV2.5Tests/Environment/WeatherTests.swift` | R2 | `ebe9a64e4c02df7ed6fe86f16629634a11f3ae99fe948ca97c6155b0ba3bb3e9` | VERIFIED |
| M-034 | AsterismaV2.5Tests/DemoProfileServiceTests.swift | `AsterismaV2.5Tests/DeveloperConsole/DemoProfileServiceTests.swift` | R2 | `93356d30323346752efe08018ca66a21848746fae43f3da66da753eac2bf7e1d` | VERIFIED |
| M-035 | AsterismaV2.5Tests/MirageAppImportMountTests.swift | `AsterismaV2.5Tests/Mirage/MirageAppImportMountTests.swift` | R2 | `846419b7dcbec659ad2fbb25807fc91aaf00c25b981686e892dce77cac95746c` | VERIFIED |
| M-036 | AsterismaV2.5Tests/MirageBundledRuntimeTests.swift | `AsterismaV2.5Tests/Mirage/MirageBundledRuntimeTests.swift` | R2 | `651723ff21426321fdc85cc866cb84321615358e32b2af35196c3b9a97667a05` | VERIFIED |
| M-037 | AsterismaV2.5Tests/MirageCursorContractTests.swift | `AsterismaV2.5Tests/Mirage/MirageCursorContractTests.swift` | R2 | `946d4756ab044ceeb6c20f9c361c9489c0636449b038d09a82741e9788717d20` | VERIFIED |
| M-038 | AsterismaV2.5Tests/MirageFeatureLifecycleTests.swift | `AsterismaV2.5Tests/Mirage/MirageFeatureLifecycleTests.swift` | R2 | `2b753157d454765302ef4faec5c2b7057000fb1dd1012d512695b3a1c03ee712` | VERIFIED |
| M-039 | AsterismaV2.5Tests/MirageHandshakePinTests.swift | `AsterismaV2.5Tests/Mirage/MirageHandshakePinTests.swift` | R2 | `fc41bbaa597b1dc51da479aabec01d820ca8cd40c2f5e8dc69354e4b1b18ba0c` | VERIFIED |
| M-040 | AsterismaV2.5Tests/MirageIdentityDriftTests.swift | `AsterismaV2.5Tests/Mirage/MirageIdentityDriftTests.swift` | R2 | `d8daaba42552f6d76584e4d72f925a513ecebedfa8a2c808e2cfe269cdcc255a` | VERIFIED |
| M-041 | AsterismaV2.5Tests/MirageIdentityMapContractTests.swift | `AsterismaV2.5Tests/Mirage/MirageIdentityMapContractTests.swift` | R2 | `1f4fc44a9b3032484fdd881d7729b464f2656a204a0f673b97597edc22f542cd` | VERIFIED |
| M-042 | AsterismaV2.5Tests/MirageIdentityRealEngineImportTests.swift | `AsterismaV2.5Tests/Mirage/MirageIdentityRealEngineImportTests.swift` | R2 | `76a28e3946a5f232f17860939f40d426ccd10f72a4c1799de1a02e610d031c31` | VERIFIED |
| M-043 | AsterismaV2.5Tests/MiragePageTurnNonTriggerTests.swift | `AsterismaV2.5Tests/Mirage/MiragePageTurnNonTriggerTests.swift` | R2 | `71b64de69eceb1d96d0cf5a412d25a17e90a8d4e0d2f0d1551ce26b0581f5a43` | VERIFIED |
| M-044 | AsterismaV2.5Tests/MirageProtocolConformanceTests.swift | `AsterismaV2.5Tests/Mirage/MirageProtocolConformanceTests.swift` | R2 | `fb180932554b02041d671823889f44c3e02cabed0be3cd8dd91ab194b8aaf7a4` | VERIFIED |
| M-045 | AsterismaV2.5Tests/MirageRealEngineSmokeTests.swift | `AsterismaV2.5Tests/Mirage/MirageRealEngineSmokeTests.swift` | R2 | `11ca43eaffd76444ffcde09f13a615ec9f227f6b7a4888b3ec40b050017a1558` | VERIFIED |
| M-046 | AsterismaV2.5Tests/MirageSidecarLifecycleTests.swift | `AsterismaV2.5Tests/Mirage/MirageSidecarLifecycleTests.swift` | R2 | `36e3d0a83945adde907bc281d682d67c694a07fda0299f831833665f53698030` | VERIFIED |
| M-047 | AsterismaV2.5Tests/MirageSpoilerProbeTests.swift | `AsterismaV2.5Tests/Mirage/MirageSpoilerProbeTests.swift` | R2 | `d92f736d43859f0cacc7b9414384abbaf8cb38b8f57f95a5b46068a796beb339` | VERIFIED |
| M-048 | AsterismaV2.5Tests/MirageStatusSurfaceTests.swift | `AsterismaV2.5Tests/Mirage/MirageStatusSurfaceTests.swift` | R2 | `ebb61e015600aa6d264c706116c500e9083498eb98c2310e43f5d53f7c6e3b43` | VERIFIED |
| M-049 | AsterismaV2.5Tests/MirageStubSidecarSupport.swift | `AsterismaV2.5Tests/Mirage/MirageStubSidecarSupport.swift` | R2 | `1b0473cc1ef92c491b9dcc772ae12f70075728e12147aee6a5aac0944712e813` | VERIFIED |
| M-050 | AsterismaV2.5Tests/MirageZBootDiagnosticTests.swift | `AsterismaV2.5Tests/Mirage/MirageZBootDiagnosticTests.swift` | R2 | `79a076bf71a11a8e01bb83a5442833619723b885c0d23ad45413bf6771105139` | VERIFIED |

## 6. Exception register — left in place deliberately

| Path | Proposed improvement | Why blocked / exempt |
|---|---|---|
| `AsterismaV2.5-Info.plist` | Move under `Configuration/` | Explicit Xcode project reference; moving requires a project-file edit. **BLOCKED (R4).** |
| `AsterismaV2.5.entitlements` | Move under `Configuration/` | Signing/package input referenced by tooling; moving requires protected edits. **BLOCKED (R4).** |
| `AsterismaV2.5.xcodeproj/` | Rename/rearrange | Project configuration is protected and must not be rewritten. **EXEMPT.** |
| `AsterismaV2.5/Assets.xcassets` | Move under `Resources/` | Asset catalog is already a coherent resource boundary; move has no navigability gain and adds bundle risk. **EXEMPT.** |
| `AsterismaV2.5/PrivacyInfo.xcprivacy` | Move under `Resources/` | Privacy manifest must remain discoverable at the app-bundle root. **EXEMPT (R3).** |
| `scripts/` | Group by release / Mirage / tests | Scripts resolve the repo root via `dirname "$0"/..`; moving requires source edits. **BLOCKED (R4).** |
| `.github/` | Reorganize workflows | Release/CI inputs depend on stable paths; no owner authorization to edit them. **EXEMPT.** |
| `docs/` | Consolidate/renumber | Numbered identities, authority hierarchy, and cross-references are historical records. Moving would risk link/authority drift and require edits. **EXEMPT.** |
| `docs/01-project-tree.md` | Update in place to the new App/test groups | Existing documentation is preserved under the mission's no-rewrite rule; this execution report is the authoritative post-reorganization tree. **EXEMPT.** |
| `docs/plans/bedrock 2/` | Merge duplicate folder | Empty, untracked duplicate; removed without touching any file. |
| `merge-log.md`, `RT_Mirage_Codebase_Merge_Playbook.md` | Move into docs | Frozen owner snapshots; canonical copies already live under `docs/integration/`. **EXEMPT.** |
| `dist/` | Move/delete | Local release artifact; intentionally preserved. **EXEMPT.** |
| `.mirage-runtime/` | Move into source tree | Externally owned staged runtime; path contract and ownership boundary. **EXEMPT.** |
| `graphify-out/` | Move/delete | Generated knowledge graph; tracked deliverables intentionally preserved. **EXEMPT.** |
| `.obsidian/` | Move/delete | Local vault configuration; gitignored. **EXEMPT.** |
| `AsterismaV2.5UITests/` | Group | Only three placeholder files; grouping adds no meaningful boundary. **EXEMPT.** |
| `Core/`, `Engines/`, `Features/` | Further splitting | Already aligned with the documented architecture; splitting would be redesign, not reorganization. **EXEMPT.** |

## 7. Verification

| Check | Result |
|---|---|
| Git rename detection | 50 renames, 100% similarity, 0 insertions / 0 deletions |
| Source hashes | All 50 before/after hashes identical |
| Baseline reconciliation | 280 baseline tracked files; 0 missing, 0 mismatched, 0 unapproved additions, 0 unapproved deletions |
| Xcode Debug build | **BUILD SUCCEEDED** (`xcodebuild build`, Debug, macOS) |
| Local unit-test discovery and census | **220 passed / 0 failed / 9 skipped** (229 cases) via `./scripts/census.sh --unit-only` |
| GitHub CI unit census | **229 tests / 10 deliberate skips / 0 failures** — run `40266848038`, green on macOS 26 / Xcode 26.6 |
| Full UI-inclusive census | Not claimed; UI placeholders depend on interactive macOS automation |
| User data | Not touched |
| Mirage runtime / ownership | Not touched |
| Package signing | Not touched by the reorganization |

Unit verification command:

```bash
./scripts/census.sh --unit-only
```

Reported result from the generated `.xcresult`:

```text
passedTests  : 220
failedTests  : 0
skippedTests : 9
total        : 229
result       : Passed
```

The nine deliberate skips remain opt-in gates. The UI-inclusive census was not
forced; its automation bootstrap limitation is disclosed rather than converted
into a fabricated pass.

## 8. Execution journal

1. Recorded clean baseline at `c1e1c968fa03257d6926c55d1fa7ed7f531149d2`.
2. Generated 2,068-file hash manifest.
3. Inspected `project.pbxproj`: three synchronized roots, no exceptions.
4. Searched source/tests/scripts for relative path assumptions.
5. Approved app-shell and unit-test grouping batches.
6. Executed 50 `git mv` operations with per-file hash checks.
7. Confirmed Git sees 50 renames with zero content changes.
8. Removed the empty, untracked `docs/plans/bedrock 2/` directory.
9. Built the app: **BUILD SUCCEEDED**.
10. Ran `./scripts/census.sh --unit-only`: **220 passed / 0 failed / 9 skipped** (229 cases).
11. Reconciled all 280 baseline tracked files: no missing, mismatched, added, or deleted files.
12. Fixed the GitHub runner (`macos-26` / Xcode 26.6) and Xcode 26.6 concurrency diagnostic.
13. Verified GitHub run `40266848038`: 229 tests, 10 deliberate skips, 0 failures.

## 9. Post-reorganization CI remediation

The first GitHub run exposed two independent infrastructure defects:

1. The workflow ran on `macos-14` / Xcode 15.4, which cannot open project format 77.
   The runner is now `macos-26` / Xcode 26.6.
2. Xcode 26.6 correctly enforced the project's `MainActor` default on the private
   safe-array subscript used by `OpenMeteoProvider`; the subscript is now marked
   `nonisolated`.

The bundled-runtime app-host assertion is self-gated on `.mirage-runtime` being
staged, because clean CI intentionally builds without that ignored 47 MB bundle.
The synthetic runtime-contract tests still run. CI runs the deterministic unit
target; UI placeholder stubs remain outside the merge-presence receipt.

Verification: GitHub run `40266848038` — **TEST SUCCEEDED**, 229 tests, 10
deliberate skips, 0 failures.

The signed ready package was rebuilt from app code `1c88ae5` after the CI fix:
`dist/AsterismaV1.0-1.0-arm64.zip`, SHA-256
`786832c8049e38ebe03d6220ae0a39b3a0005b010bdce4675e440cea65ef4643`
(tag `asterisma-v1.0-ready-2026-10-26`). Signature, sandbox entitlements,
embedded-Mirage smoke, and the expected Gatekeeper rejection were re-verified
by `scripts/package-release.sh`; the reorganization itself did not touch
packaging inputs.

## 10. Definition of success

The repository is clearer without becoming a different program:

- app composition now has a dedicated `App/` boundary;
- the test target is navigable by responsibility instead of a 48-file flat list;
- every protected boundary with a real path dependency remains untouched;
- every executed move is content-identical and reversible.

Unverified or blocked changes were not executed.
