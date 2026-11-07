# WP-1.4 — Annotation UI

**Status:** active
**Administrator:** Buffy
**Executor:** `opencode/glm-5.3-flash-free`
**Baseline:** `main` after the CR-1 fix commit
**Mode:** code writer, isolated worktree only

## Objective

Turn the two selection hooks into the smallest annotation surface that closes
G1 boxes 1–4: create, edit, and delete a highlight in EPUB and PDF; survive
relaunch; restore after font-size or PDF layout change without drift or
duplicate; save a note and copy a quote with its location; and survive 50
create/delete cycles with no orphaned rows.

## Design input

Crouton's design brief (session `ses_e4bad8ec1ffdlUh6HdHcTxrXHl`, written to
`/tmp/cr2-design.md`; re-exportable from the session, not committed) is the
starting point, not scripture. Its load-bearing decisions:

- One shared `BookNoteEditorView` and `BookNoteRowView` extracted from
  `BookDetailsView`, not three editors.
- One DataStore helper is the only path that mutates `book.notes`.
- Stored anchors are lookup keys, not screen geometry: re-derive visible
  location from content plus `selectedText` on every render, keyed by note id.
- Restore is idempotent: remove any mark with the same id before applying one.
- No soft delete, no new store, no schema change.

Buffy dropped two parts of the brief: the 2,000-character pre-highlight limit
(the bridge already caps at 4,000) and the custom selection-menu item (AppKit's
`WKWebView` and `PDFView` selection menus are not reliably extensible from this
code; WP-1.4 ships an in-reader action bar instead).

## Allowed paths

- `AsterismaV2.0/Features/Reader/EPUBReaderScreen.swift`
- `AsterismaV2.0/Features/Reader/PDFReaderView2.swift`
- `AsterismaV2.0/Features/Library/BookDetailsView.swift`
- `AsterismaV2.0/Features/Reader/AnnotationCreation.swift` (new)
- `AsterismaV2.0/Features/Reader/HighlightRestore.swift` (new)
- `AsterismaV2.0/Features/Reader/HighlightViews.swift` (new)
- `AsterismaV2.0/Core/Storage/DataStore3.swift` (only to add the single note
  mutation helper; do not restructure saving)
- `AsterismaV2.0Tests/Reader/AnnotationCreationTests.swift` (new)
- `AsterismaV2.0Tests/Reader/HighlightRestoreTests.swift` (new)
- `.agent-handoff/WP-1.4.md` in the worktree only

## Forbidden

`Book2.swift`, `LibraryDatabase.swift`, `project.pbxproj`, `AGENTS.md`,
`README.md`, every file under `docs/`, any new persistence store, any schema
migration, any `git commit` or `git push`.

## Requirements

1. **Factory.** `AnnotationCreation.makeNote(from: EPUBTextSelection)` and
   `makeNote(from: PDFTextSelection)` produce a `BookNote` with the correct
   anchor, `selectedText`, `color`, and empty body. The dense locator
   `ch:<chapter>:<start>:<end>` is built and parsed in one place.
2. **One mutation path.** Add `upsertNote(_:in:)` and `deleteNote(id:in:)` (or
   equivalent) to the DataStore file; readers and `BookDetailsView` call only
   these. Nothing appends to `book.notes` directly.
3. **Editor reuse.** Extract `BookNoteEditorView` and `BookNoteRowView`; EPUB,
   PDF, and `BookDetailsView` all use them. `BookDetailsView` must no longer
   define its own editor.
4. **Restore.** `HighlightRestore` resolves `(anchor, selectedText)` against
   chapter text (EPUB) or page text (PDF) into `.resolved`, `.candidate`, or
   `.notFound`, and never uses the stored rect as a draw target. Applying marks
   is idempotent by note id.
5. **Delete** removes exactly that note id and leaves no row behind.
6. **Copy quote** yields `selectedText` plus `— Chapter N` or `— Page N`, from
   one formatter used by the row and the popover.
7. No modal error alerts; errors are inline.

## Required tests

`AnnotationCreationTests`: locator round-trip; EPUB and PDF factory field
mapping; quote-copy string for both formats; delete removes exactly one id from
a ten-note array; two upserts of the same id leave one row (50-cycle check).

`HighlightRestoreTests`: exact match resolves; a shifted quote resolves to a
candidate; a missing quote returns `.notFound`; reflow (different page breaks,
same text) still resolves; applying the same note twice yields one mark.

## Acceptance

- Debug build exits 0.
- Both new suites and `ReaderAppearanceTests` pass.
- Full census green.
- `git diff --check` exits 0.
- No file outside the allowed paths changes.
- Handoff names the session, files, commands, exit statuses, and skipped checks.
  Do not commit or push.

## Stop authority

Buffy may interrupt or terminate this session at any time, deny any request,
revert any change, and discard the worktree. Stop immediately if asked to change
the schema, the save model, or a forbidden path.
