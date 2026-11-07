# Open-work reconciliation — 2026-11-07

**Baseline:** `dc4afe4`.
**Method:** read-only audit in the isolated worktree `quick-planet`, session
`ses_e4be99068ffeSUBkfahAgpeIy5`, then independent inspection by Buffy.
**Rule:** only the rows below were re-opened or built. The audit's unverified
rows were not copied into this file as facts.

## High-risk inherited items

| Item | Source | Verified receipt | Disposition |
|---|---|---|---|
| NA-3 report-generation race | `docs/roadmap/05-remediation-roadmap.md:46` | `AsterismaV2.5/Features/Reports/AnnualReportArchiveView2.swift:35` and `:151` — `generationToken` is incremented and a stale result is discarded; no focused test found | **VERIFY_AND_CLOSE** — add or relocate a rapid-switch pin in P0.5/G3 |
| NA-4 apple-events entitlement and usage string | `docs/roadmap/05-remediation-roadmap.md:47` | `AsterismaV2.5.entitlements:28`; `AsterismaV2.5-Info.plist:14`; built `Info.plist` contains `NSAppleEventsUsageDescription` and `NSLocationWhenInUseUsageDescription` | **CLOSED** |
| NA-5 privacy manifest | `docs/roadmap/05-remediation-roadmap.md:48` | `AsterismaV2.5/PrivacyInfo.xcprivacy`; the synchronized app group includes it; built `AsterismaV2.5.app/Contents/Resources/PrivacyInfo.xcprivacy` reads back with `plutil` | **CLOSED** |
| F-12 re-bind accumulation | `docs/roadmap/05-remediation-roadmap.md:147` | `AsterismaV2.5/Features/Sessions/SessionEventRouter2.swift:65-67`; `AsterismaV2.5/Features/Goals/ReadingGoalManager2.swift:349-354`; pin at `AsterismaV2.5Tests/App/RemediationPinsTests.swift:229` | **CLOSED**; P0.4 census passed 518 tests / 509 passed / 9 skipped / 0 failed |

The P0.4 baseline build used:

```bash
xcodebuild -project AsterismaV2.5.xcodeproj -scheme AsterismaV2.5 \
  -configuration Debug -derivedDataPath /tmp/asterisma-dd-wp01 \
  CODE_SIGNING_ALLOWED=NO build
```

It exited 0. The built app contains its own privacy manifest and both usage
strings. A signed/notarized artifact is still P8; this build proves packaging,
not release signing.

## Truth defects corrected

| Defect | Source | Evidence | Correction |
|---|---|---|---|
| Dependency count | `README.md:52`; `docs/roadmap/07-master-progression.md:94` | `Package.resolved` has `grdb.swift` 7.11.1 and `zipfoundation` 0.9.20 | Both documents now say two packages |
| Stale analytics next step | `docs/registers/04-handoff.md:72`; `docs/roadmap/07-master-progression.md:115` | `docs/audits/13-reading-analytics-phase-zero-2026-10-29.md:568-578` says E1–E3, E6, E7 executed; E4/E5 not done | Both now point at E4/E5 |
| App size | `README.md:53` | 180 Swift files; 68,367 raw lines; 60,538 non-blank at `dc4afe4` | README now carries the re-derived figures |

## Still open

- LR-G6 owner acceptance, SG7 holds, Developer ID/notarization, bundle-ID
  migration, Swift 6, reader highlights, Mirage standing items, owner visual
  acceptance.
- E4/E5 analytics work; NA-3 focused pin; NA-7's two stale `Session Concept 1.md`
  pointers; F-10 print-only failures; F-13(d) rename-vs-document disposition;
  the W-01 code anchor in the deep audit.
- P0.4 census passed: 518 tests / 509 passed / 9 skipped / 0 failed / 719 runs, exit 0. The audit's census row is now closed.
