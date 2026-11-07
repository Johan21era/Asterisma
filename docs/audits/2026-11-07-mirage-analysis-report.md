# Mirage analysis report (2.7) — delivery record, 2026-11-07

## Scope

Mirage already stored an analysis for every linked book, but the app exposed
only a link state and two counts after an explicit engine check. This pass makes
the analysis measurable without crossing ADR-7's spoiler boundary.

The rule is unchanged: **no claim text, evidence, entity, projection, or graph
detail is read or rendered until a countersigned chapter→unit calibration
exists.** The report therefore uses only:

- engine-attested inventory facts already present in the read-only `books_list`
  result (`units`, `claims`, edition identity), cached by the existing library
  index; and
- RT's own identity map (active, paused, or absent links).

No engine source was edited. No new wire action was invented.

## What changed

| Area | File | Behavior |
|---|---|---|
| Report model | `AsterismaV2.0/Features/Mirage/MirageAnalysisReport.swift` | Derives coverage, indexed-edition count, unit/claim totals and density, zero-claim editions, paused books, unindexed active links, and scan freshness. |
| Coverage source | same | Coverage counts **active identity-map entries only**, intersected with the analyzable book set. A caller cannot inflate it with a stale or orphaned link. |
| Settings surface | `AsterismaV2.0/Features/Goals/SettingsRootView.swift` | "Analysis report" replaces the bare coverage rows: coverage percent, indexed editions, ledger totals, per-edition density, paused links, unindexed-link warning, zero-claim note, last measured analysis time, scan freshness, and an explicit ADR-7 provenance note. |
| Measured duration | `AsterismaV2.0/Features/Mirage/MirageEngineService.swift` | Records `lastAnalysisSeconds` and `lastAnalysisAt` for the last successful analysis, including a comic's on-device OCR preparation. |
| Tests | `AsterismaV2.0Tests/Mirage/MirageAnalysisReportTests.swift` | Four pins: empty library, analyzable-only coverage/density, scanned-index unindexed/paused accounting, and never-scanned-index semantics. |

## Report semantics

- **Coverage** = active links whose RT book is EPUB or comic, divided by all
  EPUB/comic books. A PDF never enters either side of the fraction.
- **Indexed editions** = rows in the cached engine inventory, not RT books.
  One RT book maps to one active edition by ADR-5.
- **Density** = units and claims per indexed edition, plus claims per unit.
  These are engine counts, not a quality score; the UI says so.
- **Paused links** = distinct analyzable books with an orphaned identity entry
  (`source-changed`, `edition-gone`, or `superseded`).
- **Unindexed links** = active links absent from the last scan. A never-scanned
  index reports zero, because missing evidence is not proof of a missing
  edition. A real scan with a missing row is a reconciliation prompt.
- **Zero-claim editions** = indexed rows with `claims == 0`. This is shown as an
  engine count, never as "bad analysis".

## Verification

```bash
xcodebuild test -project AsterismaV2.0.xcodeproj -scheme AsterismaV2.0 -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:AsterismaV2.0Tests/MirageAnalysisReportTests -only-testing:AsterismaV2.0Tests/MirageEngineServiceTests -only-testing:AsterismaV2.0Tests/MirageStatusSurfaceTests -only-testing:AsterismaV2.0Tests/MirageBatchAnalyzerTests
```

Result: **24 tests in 4 suites passed**, exit **0**.

```bash
./scripts/census.sh --unit-only
```

Result: console **594 tests in 114 suites passed**, exit **0**; the result bundle
records **595 passed / 10 skipped / 0 failed** across **719 runs**
(`totalTestCount` 605). The 10 skips are the existing opt-in, benchmark, and
live-network pins; none is a 2.7 test.

The documentation gates:

```bash
./scripts/verify-sentinel-surface.sh
python3 scripts/comprehension-bench.py --validate-only
python3 scripts/audit-markdown.py <edited .md files>
git diff --check
```

Results: surface gate exit **0** (15 tables, 8 defaults keys, 5 notification
names); comprehension link gate exit **0** (30 facts, 12 overview facts);
Markdown audit exit **0**; whitespace check exit **0**.

## Limits

- The app was **not launched**. Settings ▸ Mirage's new report was not visually
  inspected; it is compile- and logic-verified only.
- No real library scan and no real Mirage analysis were run for this pass. The
  report tests use synthetic identity maps and cached indexes.
- The report measures coverage and engine-attested counts. It does **not**
  measure extraction accuracy, recall, reading quality, or book strength; those
  remain engine-side questions.
- ADR-7 analysis detail remains **disabled**. Nothing here renders or reads
  claim text, evidence, entities, projection, or graph detail.
- Analysis duration is wall-clock on this machine and includes OCR preparation
  for comics. It is one sample, not a benchmark distribution.
- The knowledge graph was not refreshed and is stale for the 2.7 file.

## Evidence map

- `AsterismaV2.0/Features/Mirage/MirageAnalysisReport.swift`.
- `AsterismaV2.0/Features/Mirage/MirageEngineService.swift`.
- `AsterismaV2.0/Features/Goals/SettingsRootView.swift`.
- `AsterismaV2.0Tests/Mirage/MirageAnalysisReportTests.swift`.
- `docs/integration/adr/ADR-7-spoiler-cursor-contract.md` (the boundary this
  pass respects).
- Session close: `docs/registers/04-handoff.md`; fix entry:
  `docs/registers/03-fix-log.md` Stage AX.
