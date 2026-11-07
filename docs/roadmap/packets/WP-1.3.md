# WP-1.3 — PDF selection bridge

**Status:** completed — accepted 2026-11-07, after a correction
**Administrator:** Buffy
**Executor:** `opencode/glm-5.3-flash-free`
**Baseline:** `main` at `b81fc99` (P1.1 schema merged in `6e35429`)
**Mode:** code writer, isolated worktree only

## Objective

Capture the reader's text selection in the PDF view, convert it into a page
index plus a normalized rect, and hand it to Swift. This packet ends at the
Swift callback: no persistence, no note editor, no highlight rendering. WP-1.4
owns the UI.

## Inputs (read, do not change)

- `AsterismaV2.5/Features/Reader/PDFReaderView2.swift` — `ReaderPDFView`,
  `PDFReaderView`, its `Coordinator`, and `PDFReaderScreen`.
- `AsterismaV2.5/Core/Book2.swift` — the frozen
  `BookNoteAnchor.pdf(pageIndex:rect:)` shape and `NormalizedRect`.

## Allowed paths

- `AsterismaV2.5/Features/Reader/PDFReaderView2.swift`
- `AsterismaV2.5Tests/Reader/PDFSelectionTests.swift` (new file)
- `.agent-handoff/WP-1.3.md` in the worktree only

## Forbidden

`Book2.swift`, `LibraryDatabase.swift`, `DataStore*`, `project.pbxproj`,
`EPUBReaderScreen.swift`, `BookDetailsView.swift`, every file under `docs/`, and
any `git commit` or `git push`.

## Requirements

1. Observe `PDFViewSelectionChanged` in `ReaderPDFView` (or override the mouse
   path) and resolve `currentSelection`. Ignore `nil` and whitespace-only
   selections.
2. Build an internal value type in this file, e.g.
   `PDFTextSelection: Equatable { pageIndex, text, rect: NormalizedRect }`,
   where:
   - `pageIndex` is `document.index(for: page)` for the first page the selection
     touches;
   - `rect` is `selection.bounds(for: page)` normalized by
     `page.bounds(for: .cropBox)`, clamped to `0...1`, so it is invariant to
     zoom, fit mode, and window size.
3. Add an internal, pure `PDFSelectionGeometry` (or equivalent) with a function
   that maps a page-space rect plus page bounds to a `NormalizedRect`, and
   another that reports whether a rect is usable (non-empty, inside the page).
   Tests target these functions, not a live `PDFView`.
4. Expose `onSelection` from `PDFReaderView` up to `PDFReaderScreen`, which holds
   the latest selection in `@State` and logs it under `#if DEBUG` only. Clear it
   on page change.
5. Truncate the quote at 4,000 characters and document it.
6. Do not change the appearance panel, layout, fit, or RTL behavior.

## Required tests

Create `AsterismaV2.5Tests/Reader/PDFSelectionTests.swift`:

1. A rect at the page origin with half width/height normalizes to
   `(0, 0, 0.5, 0.5)`.
2. A rect in the page's lower-right quadrant normalizes to values above 0.5 and
   at most 1.
3. A rect that extends past the page clamps into `0...1` instead of exceeding it.
4. A zero-area or empty rect is reported unusable.
5. A multi-line bounding rect contains both line rects and stays within the page.

Use `CGRect` fixtures; do not instantiate a `PDFView`.

## Acceptance

- `xcodebuild -project AsterismaV2.5.xcodeproj -scheme AsterismaV2.5 -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` exits 0.
- `PDFSelectionTests` and the existing `ReaderAppearanceTests` pass.
- `git diff --check` exits 0.
- No file outside the allowed paths changes.
- Handoff names the model session, changed files, commands, exit statuses, and
  any skipped check. Do not commit or push.

## Stop authority

Buffy may interrupt or terminate this session at any time, deny any request,
revert any change, and discard the worktree. Stop immediately if asked to exceed
the allowed paths, touch a secret, or change the note schema.

## Acceptance receipt — 2026-11-07

**Merged in `a010a72`.** Buffy reran every acceptance check in the model's
worktree (`kind-orchid`, detached at `b81fc99`).

| Check | Result |
|---|---|
| Worktree build | exit 0, `** BUILD SUCCEEDED **` |
| `PDFSelectionGeometryTests` + `ReaderAppearanceTests` | exit 0, **14 tests in 2 suites passed** (5 new, 9 existing) |
| `git diff --check` | exit 0 |
| Scope | only `PDFReaderView2.swift` and the new test file |

**Correction Buffy made before merge.** The model implemented the selection
hook as `func pdfViewSelectionChanged(_:)` on the `PDFViewDelegate` Coordinator.
`PDFViewDelegate` declares no selection callback, so that method compiles and is
never called: a silent no-op. Selection changes are delivered only through
`.PDFViewSelectionChanged`. Buffy replaced the method with a
`NotificationCenter` observer registered in `makeNSView` against the view, added
`removeObserver` to `deinit`, corrected the false header comment, and added a
sixth test that posts the notification and requires a usable anchor. That test
would have failed against the model's version. The registration itself is
verified by review of the single call site, not by the test.

A first verification attempt used `-only-testing:AsterismaV2.5Tests/PDFSelectionTests`,
which matched no type (the suite type is `PDFSelectionGeometryTests`); only the
nine appearance tests ran. Buffy caught the false pass and reran with the real
identifier.
