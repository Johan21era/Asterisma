# Comic containers (2.5), reader experience (2.5.1), metadata + Mirage (2.6) — delivery record, 2026-11-07

## Scope

The owner greenlit the 2.5 expansion: manga, manhua, manhwa, webcomics, and
western comics must work across the app and its subsystems.

The design decision is deliberate: **those categories are reading modes over
page-image containers, not separate file formats.** The implementation supports
two containers that the project can actually decode:

- **CBZ** — a ZIP archive of page images, read lazily.
- **Image folder** — a directory of page images, read lazily.

CBR, CB7, and CBT are **not supported**. They require a RAR or 7z decoder, and
the project has no such dependency. The importer rejects them with an explicit
message rather than opening a file it cannot read.

## What changed

| Area | File | Behavior |
|---|---|---|
| Model | `AsterismaV2.5/Core/Book2.swift` | `BookFileType` adds `.cbz` and `.comic`; `Book.comicReadingMode` decodes tolerantly; `resolvedComicReadingMode` supplies the format default; `BookNoteAnchor` adds `.comic(pageIndex:)`. |
| Container engine | `AsterismaV2.5/Features/Reader/ComicArchive.swift` | Natural page order, hidden/`__MACOSX` filtering, chapter grouping by folder, serialized CBZ extraction, explicit empty/unsupported errors. |
| Reader rules | `AsterismaV2.5/Features/Reader/ComicReaderModel.swift` | Direction-aware arrow mapping (LTR, RTL, vertical), clamped pagination, progress labels. |
| Reader UI | `AsterismaV2.5/Features/Reader/ComicReaderScreen.swift` | Native horizontal paging in correct LTR/RTL visual order, continuous vertical webtoon, direct-manipulation scrubber, chapter jumps, page-note sheet, auto-hiding floating chrome, session lifecycle through `SessionCoordinator`. |
| Reader experience | `AsterismaV2.5/Features/Reader/ComicReaderExperience.swift` | Paper palettes, shared brightness, appearance panel, page scrubber, pan/zoom inspection, and the local keyboard monitor. |
| Import | `AsterismaV2.5/Features/Library/BookImporter.swift` | `.cbz` and image-folder imports, first-page cover, chapter ranges, directory-selectable open panel, explicit CBR/CB7/CBT refusal. |
| Dispatch | `AsterismaV2.5/App/NewContentView.swift` | `.cbz`/`.comic` route to `ComicReaderScreen`; EPUB/PDF keep their readers. |
| Library | `AsterismaV2.5/Features/Library/LibraryFilterState.swift`, `LibraryFilterSidebarView.swift` | Format filter with only the formats present in the library. |
| Reports | `AsterismaV2.5/Features/Reports/AnnualReportData2.swift`, `AnnualReportView.swift` | Format breakdown now includes comic counts. |
| Notes | `AsterismaV2.5/Features/Reader/AnnotationCreation.swift` | `makePageNote`; comic captions read `— Page N`. |
| Recovery | `AsterismaV2.5/Core/DataStore3.swift` | Relinking treats an image folder as `.comic` and an unzipped EPUB package as `.epub`. |
| Sentinel | `AsterismaV2.5/Core/Sentinel/SentinelProbesFiles.swift` | FILE-009 skips image-folder comics, whose type is not extension-based. |
| Copy | `AsterismaV2.5/App/CommandPalette.swift`, `ReadingDeskView.swift`, `LibraryBrowserView.swift`, `OnboardingView.swift` | Import and empty-state copy names comics. |
| Tests | `AsterismaV2.5Tests/Reader/ComicArchiveTests.swift`, `ComicImportTests.swift`, `ComicReaderModelTests.swift` | 19 pins for ordering, extraction, import, mode inference, RTL visual order, page-image decode/cache, anchors, legacy decode, filters, and panel selection. |
| 2.6 metadata | `AsterismaV2.5/Features/Reader/ComicMetadata.swift` | ComicInfo.xml parser: title, series, number, volume, writer, penciller, publisher, summary, genre, language, manga direction, declared page count, and the zero-based front-cover page. Malformed or absent files are metadata misses, never import failures. |
| 2.6 import wiring | `AsterismaV2.5/Features/Library/BookImporter.swift` | Comic title/author/series/genre/direction/cover come from ComicInfo.xml when present; a declared cover page is honored, otherwise page one. |
| 2.6 model | `AsterismaV2.5/Core/Book2.swift` | `Book.comicInfo` stores the parsed record with a tolerant decode, so every pre-2.6 library payload still loads. |
| 2.6 inspector | `AsterismaV2.5/Features/Library/BookDetailsView.swift` | Read-only Comic Metadata section: series/issue, publisher, language, reading direction, and summary. |
| 2.6 Mirage bridge | `AsterismaV2.5/Features/Mirage/ComicMirageBridge.swift` | On-device Vision OCR → deterministic EPUB 3 text edition, cached by source digest and derivation version; tall webtoon strips are OCR'd in overlapping native-resolution tiles; RTL modes order same-line balloons right-to-left. |
| 2.6 Mirage flow | `AsterismaV2.5/Features/Mirage/MirageImportFlow.swift`, `MirageEngineService.swift` | `MirageSourceKind` (`.epub`/`.comic`/`.unsupported`), folder-capable source fingerprints, derived-EPUB digest for the receipt check, original container digest for the identity anchor, and the typed `.analysisPreparationFailed` outcome. |
| 2.6 Mirage gates | `MirageAnalysisSheetView.swift`, `MirageBatchAnalyzer.swift`, `MirageAppImportMount.swift`, `SettingsRootView.swift`, `ComicReaderScreen.swift` | Comics are eligible in the sheet, the batch queue, and Settings coverage counts; the comic reader's chrome carries the same Analyze with Mirage entry as the EPUB reader. |
| 2.6 scope | `AsterismaV2.5/Features/Mirage/MirageImportFlow.swift`, `MirageEngineService.swift` | The source fingerprint and the whole comic preparation path start/stop the bookmark's security scope, so hashing and OCR survive an app restart. |
| 2.6 paragraph guard | `AsterismaV2.5/Features/Mirage/ComicMirageBridge.swift` | OCR lines longer than 2,000 characters are split deterministically at word boundaries, below the engine's per-paragraph limit. |
| 2.6 tests | `AsterismaV2.5Tests/Reader/ComicMetadataTests.swift`, `AsterismaV2.5Tests/Mirage/ComicMirageBridgeTests.swift`, `AsterismaV2.5Tests/Mirage/MirageComicImportTests.swift` | 19 new pins: parser/import metadata (7), bridge structure/determinism/cache/failure (6), and comic identity/gates/folder fingerprint (6); the normalization pin also checks long-line splitting. |

## 2.5.1 — the reader feels like a surface

The first 2.5 pass made comics readable. The 2.5.1 pass removes the tells that
made them feel like a slideshow:

- **Native paging, not a swapped image.** Paged modes use a horizontal
  `ScrollView` with paging targets. RTL reverses only the visual order; story
  page indices remain increasing so progress, notes, and resume positions do
  not need a second coordinate system.
- **Pages arrive before the turn.** A five-page prefetch window runs around the
  current page, de-duplicates in-flight work, and decodes through ImageIO off
  the main actor. The cache is bounded at 24 pages / 256 MB.
- **The controls get out of the way.** Floating top and bottom capsules fade
  after three seconds of stillness and return on pointer movement. Paper
  palettes, the shared EPUB/PDF brightness dimmer, full screen, chapter jumps,
  and the scrubber remain one gesture away.
- **A page can be inspected.** Double-clicking a page (or the magnifier) opens
  a pan/zoom surface; Escape returns to the exact reading position.
- **The keyboard is complete.** Arrows follow the selected reading direction,
  Space and Shift-Space move forward/back, Page Up/Down and Home/End work, and
  `F` toggles full screen. A local monitor ignores text editors and sheets.
- **The first opening is less surprising.** Import suggests RTL for a title
  containing manga/manhua/manhwa and vertical for a webtoon; the reader still
  persists any explicit mode choice.

## 2.6 — ComicInfo metadata and Mirage comic analysis

ComicInfo.xml is now the native comic metadata source. The importer reads it
from a CBZ entry or an image folder's root (case-insensitive, shallowest match),
and maps:

- `<Title>`, `<Series>`, `<Number>`, and `<Volume>` into the library title and
  `Book.series`; a missing title composes `Series #Number` instead of "Unknown".
- `<Writer>` (falling back to `<Penciller>`) into `Book.author`.
- `<Genre>` through `ReadingGenre.mapped(from:)`.
- `<Manga>` (`YesAndRightToLeft`, `YesAndLeftToRight`, `No`) into the initial
  reading mode, so a labelled manga opens RTL and an unlabelled file keeps the
  title heuristic.
- `<Summary>`, `<Publisher>`, `<LanguageISO>`, and the zero-based
  `Type="FrontCover"` page into `Book.comicInfo` and the details inspector.

Metadata never gates an import: a malformed ComicInfo.xml is a metadata miss,
and the pages still import with the filename title and Unknown author.
`Book.comicInfo` decodes tolerantly, so existing library JSON is unchanged.

Mirage's engine is still EPUB-only at the wire level. The new
`ComicMirageBridge` closes that gap without touching the engine or inventing a
protocol action:

1. open the comic through `ComicArchive`;
2. recognize each page on-device with Vision (accurate, no language correction,
   automatic language detection; right-to-left line order for RTL modes; tall
   webtoon strips are OCR'd in overlapping native-resolution tiles);
3. write a deterministic EPUB 3 text edition — fixed entry order, fixed
   1980-01-01 ZIP timestamps, fixed permissions, stored `mimetype`, escaped
   XHTML, and one spine document per page that produced text;
4. dispatch the existing `import_epub` action against the derived file.

Two guards keep that path from turning a working comic into a failure. The
fingerprint and the whole preparation path hold the bookmark's security scope
while they read, because a URL resolved after an app restart has no access
until its scope is active. And any OCR line above 2,000 characters is split
at word boundaries, because the engine refuses an entire edition over one
oversized paragraph.

Identity stays anchored to the original container. The flow fingerprints the
comic (a file for CBZ/EPUB, a canonical relative-path-plus-contents digest for
image folders) for the identity map, and fingerprints the derived EPUB for the
engine receipt suffix check. Editing the comic therefore still orphans the link;
rebuilding the same OCR text produces the same EPUB digest and reuses the engine
edition (`reused: true`). The typed `.analysisPreparationFailed` outcome keeps a
preparation fault distinct from an unreadable source.

Comics are eligible in the analyze sheet (with comic-specific copy), the batch
analyzer, and Settings ▸ Mirage coverage counts. The comic reader's chrome now
carries the same "Analyze with Mirage" entry as the EPUB reader.

Mirage's engine boundary is unchanged: no engine source was edited, no protocol
action was invented, and `.mirage-runtime/` remains the pinned staged copy.

## Verification

The Debug app build succeeded:

```bash
xcodebuild -project AsterismaV2.5.xcodeproj -scheme AsterismaV2.5 -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Result: `** BUILD SUCCEEDED **`, exit **0**.

The 2.5.1 close (historical) ran **19 tests in 3 suites** against
`ComicArchiveTests`, `ComicImportTests`, and `ComicReaderModelTests`. The 2.6
focused run adds the metadata, bridge, comic-identity, batch, and fingerprint
suites:

```bash
xcodebuild test -project AsterismaV2.5.xcodeproj -scheme AsterismaV2.5 -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:AsterismaV2.5Tests/ComicMetadataTests -only-testing:AsterismaV2.5Tests/ComicMirageBridgeTests -only-testing:AsterismaV2.5Tests/MirageComicImportTests -only-testing:AsterismaV2.5Tests/MirageBatchAnalyzerTests -only-testing:AsterismaV2.5Tests/MirageFingerprintTests
```

Result: **25 tests in 5 suites passed**, exit **0**.

The full unit census passed:

```bash
./scripts/census.sh --unit-only
```

Result: **590 tests in 113 suites passed** (console), exit **0**. The result
bundle records **591 passed / 10 skipped / 0 failed** across **719 runs**
(`totalTestCount` 601). The 10 skips are the existing opt-in, benchmark, and
live-network pins; none is a comic test. The 2.5.1 close (historical) reported
571 tests in 110 suites / 582 runs, 572 passed.

The two CI-mirror gates passed:

```bash
./scripts/verify-sentinel-surface.sh
python3 scripts/comprehension-bench.py --validate-only
```

Results: surface gate exit **0** (15 tables, 8 defaults keys, 5 notification
names); comprehension link gate exit **0** (30 facts, 12 overview facts).

Whitespace check:

```bash
git diff --check
```

Result: exit **0**.

## Limits

- The app was **not launched**. No screenshot, window interaction, or visual
  inspection was performed. The reader is compile- and logic-tested, not
  visually accepted. No frame-time profile was captured for a real 300-page
  book; prefetch and native paging are verified by code and tests, not by an
  Instruments trace.
- No real comic library was read. The import tests use a generated CBZ and
  synthetic image folders with 1×1 PNG pages; they prove ordering, extraction,
  counts, chapters, and mode defaults, not image scaling or long-strip layout
  on a real 300-page book.
- CBR/CB7/CBT remain unsupported. Supporting them needs a deliberate decoder
  dependency and a separate security review.
- ComicInfo.xml was tested against synthetic archives, not a real publisher
  library. Cover-page selection is proven by the importer's page choice; the
  rendered cover was not visually inspected.
- Vision OCR was **not exercised end-to-end in tests**: the bridge pins inject
  the recognizer to prove EPUB structure, byte determinism, caching, failure
  typing, and long-line splitting. The bookmark-scope path was not exercised in
  a sandboxed relaunch. No real manga/manhua/manhwa/webtoon OCR accuracy or language-detection
  measurement was made, and no tiled-webtoon OCR run was inspected.
- Comic notes are **page-anchored**. There are no text-region highlights or
  in-book search on comic pages, because pages are bitmaps.
- The knowledge graph was **not refreshed** in this session. `graphify-out/`
  therefore does not include the new comic files, and its counts should not be
  read as a post-2.5 graph.
- The app was not committed or pushed. Commit and push are separate owner
  decisions.

## Evidence map

- Model and anchor: `AsterismaV2.5/Core/Book2.swift`.
- Container and chapter rules: `AsterismaV2.5/Features/Reader/ComicArchive.swift`.
- Reader: `AsterismaV2.5/Features/Reader/ComicReaderScreen.swift`,
  `AsterismaV2.5/Features/Reader/ComicReaderModel.swift`,
  `AsterismaV2.5/Features/Reader/ComicReaderExperience.swift`.
- Import: `AsterismaV2.5/Features/Library/BookImporter.swift`.
- Metadata: `AsterismaV2.5/Features/Reader/ComicMetadata.swift`;
  `AsterismaV2.5/Features/Library/BookDetailsView.swift`.
- Mirage bridge: `AsterismaV2.5/Features/Mirage/ComicMirageBridge.swift`.
- Mirage identity and gates: `MirageImportFlow.swift`,
  `MirageEngineService.swift`, `MirageAnalysisSheetView.swift`,
  `MirageBatchAnalyzer.swift`, `MirageAppImportMount.swift`,
  `AsterismaV2.5/Features/Goals/SettingsRootView.swift`.
- Tests: `AsterismaV2.5Tests/Reader/ComicArchiveTests.swift`,
  `ComicImportTests.swift`, `ComicReaderModelTests.swift`,
  `ComicMetadataTests.swift`; `AsterismaV2.5Tests/Mirage/ComicMirageBridgeTests.swift`,
  `MirageComicImportTests.swift`.
- Session close: `docs/registers/04-handoff.md`; fix entries:
  `docs/registers/03-fix-log.md` Stage AU (2.5), Stage AV (2.5.1), and Stage AW (2.6).
