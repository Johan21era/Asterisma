# WP-1.2 — EPUB selection bridge

**Status:** completed — accepted 2026-11-07
**Administrator:** Buffy
**Executor:** `opencode/glm-5.3-flash-free`
**Baseline:** `main` at `b81fc99` (P1.1 schema merged in `6e35429`)
**Mode:** code writer, isolated worktree only

## Objective

Capture the reader's text selection inside the EPUB `WKWebView`, convert it into
a durable locator, and hand it to Swift. This packet ends at the Swift callback:
no persistence, no note editor, no highlight rendering. WP-1.4 owns the UI.

## Inputs (read, do not change)

- `AsterismaV2.5/Features/Reader/EPUBReaderScreen.swift` — `EPUBChapterWebView`,
  its `Coordinator`, the `epubPage` message handler, and `paginationScript`.
- `AsterismaV2.5/Core/Book2.swift` — the frozen `BookNoteAnchor.epub` shape the
  locator must eventually feed.

## Allowed paths

- `AsterismaV2.5/Features/Reader/EPUBReaderScreen.swift`
- `AsterismaV2.5Tests/Reader/EPUBSelectionTests.swift` (new file)
- `.agent-handoff/WP-1.2.md` in the worktree only

## Forbidden

`Book2.swift`, `LibraryDatabase.swift`, `DataStore*`, `project.pbxproj`,
`PDFReaderView2.swift`, `BookDetailsView.swift`, every file under `docs/`, and
any `git commit` or `git push`.

## Requirements

1. Inject a selection script at `.atDocumentEnd`. On a settled selection
   (debounced ~120 ms so a drag posts once), post
   `{chapterIndex, pageInChapter, text, startOffset, endOffset}` through
   `window.webkit.messageHandlers.epubSelection`.
2. Offsets are UTF-16 character offsets into the chapter's
   `document.body.textContent`, clamped to its length. Document that definition
   in a comment; the contract must not drift silently.
3. Register the `epubSelection` handler on the same content controller as
   `epubPage`, and **remove both handlers in `dismantleNSView`** so the web view
   does not retain the coordinator.
4. Reject whitespace-only selections and truncate the quote at 4,000 characters.
5. Add an internal value type in this file, e.g.
   `EPUBTextSelection: Equatable { chapterIndex, pageInChapter, text,
   startOffset, endOffset, locator }`, where
   `locator == "ch:<chapterIndex>:<startOffset>:<endOffset>"`. This string is
   what WP-1.4 stores in `BookNoteAnchor.epub.cfi`; it is a dense locator, not a
   standards-compliant CFI, and the code must say so.
6. Add an internal `EPUBSelectionState` with `record(_:)`, `clear()`, and
   `latest`, so the screen can hold one current selection and page/chapter
   changes clear it. `EPUBReaderScreen` holds it in `@State`, clears it on page
   and chapter changes, and logs the latest value under `#if DEBUG` only.
7. Expose `onSelection` on `EPUBChapterWebView` so WP-1.4 can attach the
   annotation UI. Do not build that UI here.

## Required tests

Create `AsterismaV2.5Tests/Reader/EPUBSelectionTests.swift`:

1. Locator round-trips through `EPUBTextSelection` and its parser.
2. Negative and out-of-range offsets clamp to `0...textLength`.
3. Whitespace-only text is rejected; a 5,000-character quote truncates to 4,000.
4. `EPUBSelectionState.clear()` empties `latest`; a later `record` replaces it.
5. Chapter index and page are preserved unchanged through the locator.

Use pure values; do not instantiate a `WKWebView` in tests.

## Acceptance

- `xcodebuild -project AsterismaV2.5.xcodeproj -scheme AsterismaV2.5 -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build` exits 0.
- `EPUBSelectionTests` and the existing `ReaderAppearanceTests` pass.
- `git diff --check` exits 0.
- No file outside the allowed paths changes.
- Handoff names the model session, changed files, commands, exit statuses, and
  any skipped check. Do not commit or push.

## Stop authority

Buffy may interrupt or terminate this session at any time, deny any request,
revert any change, and discard the worktree. Stop immediately if asked to exceed
the allowed paths, touch a secret, or change the note schema.

## Acceptance receipt — 2026-11-07

**Merged in `3a82d50`.** Buffy reran every acceptance check in the model's
worktree (`calm-lagoon`, detached at `b81fc99`) before merging.

| Check | Result |
|---|---|
| Worktree build | exit 0, `** BUILD SUCCEEDED **` |
| `EPUBSelectionTests` + `ReaderAppearanceTests` | exit 0, **16 tests in 2 suites passed** (7 new, 9 existing) |
| `git diff --check` | exit 0 |
| Scope | only `EPUBReaderScreen.swift` and the new test file; `project.pbxproj` untouched |

The model reported one intermediate test-compile failure (five test functions
missing `throws`), which it fixed before the run above. The JavaScript debounce
and boundary-offset measurement are verified by review and compilation only: the
packet forbade instantiating a `WKWebView` in tests, so no automated test
exercises the injected script. The locator is `ch:<chapter>:<start>:<end>`, not
a standards-compliant CFI, and the code says so.
