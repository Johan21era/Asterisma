# WP-1.4 — Annotation UI

**Status:** completed (2026-11-07) — see the receipt at the end of this file
**Administrator:** Buffy
**Executor:** `opencode/glm-5.3-flash-free` (session `ses_e4b97d907ffe7MZavRdmhkB9bN`),
completed by Buffy after the free-message cap
**Baseline:** `main` at `54640b1`
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

Existing files that may change:

- `AsterismaV2.5/Features/Reader/EPUBReaderScreen.swift`
- `AsterismaV2.5/Features/Reader/PDFReaderView2.swift`
- `AsterismaV2.5/Features/Library/BookDetailsView.swift`
- `AsterismaV2.5/Core/DataStore3.swift` (only to add the single note mutation
  helper; do not restructure saving)

Files to create in the worktree. None of these exists yet, so they are written
without code spans and must not be read as current paths:

- AsterismaV2.5/Features/Reader/AnnotationCreation.swift
- AsterismaV2.5/Features/Reader/HighlightRestore.swift
- AsterismaV2.5/Features/Reader/HighlightViews.swift
- AsterismaV2.5Tests/Reader/AnnotationCreationTests.swift
- AsterismaV2.5Tests/Reader/HighlightRestoreTests.swift
- .agent-handoff/WP-1.4.md (worktree only, gitignored)

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

## Receipt — 2026-11-07

**Session.** `ses_e4b97d907ffe7MZavRdmhkB9bN`, worktree `kind-planet` at
`54640b1`. GLM wrote `AnnotationCreation.swift`, `HighlightRestore.swift`,
`HighlightViews.swift`, both test suites, the DataStore helpers, and the
`BookDetailsView` extraction, then reported `Error: Free usage limit reached`
mid-edit. It never built or tested its own work, and `PDFReaderView2.swift` was
untouched. Its handoff is therefore not evidence of anything; Buffy inspected
the tree, kept the parts that held up, and finished the packet.

**Completed by Buffy.** One Swift syntax error (`a ..< (b)` parses as a prefix
range operator) was rewritten. The missing `EPUBChapterWebView.Coordinator`
members were added: `marksJSON`, `onBodyText`, `onHighlightTap`, the
`epubHighlight` message branch, and an injected renderer
(`window.__epubApplyHighlights`) built on the CSS Custom Highlight API, keyed by
note id so re-applying a payload cannot duplicate a mark. A click is mapped to a
character offset and, when it lands inside a mark, posts that note id back. CR-1
finding 4's EPUB half is closed: a cleared selection now posts nil and the
screen clears `selectionState`, so the action bar cannot outlive its text.

`PDFReaderView2.swift` gained what the packet required and GLM never wrote:
highlight annotations resolved per page from `PDFPage.string` via
`HighlightRestore.resolvePDF` (the stored rect is provenance only), removed and
re-added by a tagged prefix so re-renders are idempotent, a `mouseDown` hit test
that maps a tapped annotation to its note id, and the same action bar, editor
popover, and DataStore helpers as EPUB.

**Checks.** Debug build exit 0. Focused run over `AnnotationCreationTests`,
`HighlightRestoreTests`, and `ReaderAppearanceTests`: 29 tests in 3 suites
passed, exit 0. Full census exit 0 with 557 tests, 548 passed, 9 skipped, 0
failed (546 Swift Testing tests in 105 suites); result bundle
`rt-census-20261107-002415.xcresult`. `git diff --check` exit 0. Surface and
index gates exit 0. No file outside the allowed paths changed.

**Not verified.** No live `WKWebView` or `PDFView` run: the CSS Custom Highlight
API path, the click-to-offset mapping, and PDF annotation drawing are compiled
and reviewed, not exercised. If a WebKit build lacks the Highlight API, marks
simply do not draw — the model and notes are unaffected. No owner visual pass
and no live-library migration. PDF staleness is expressed by drawing nothing
rather than an inline message, because the screen never opens the document and
so cannot honestly claim a quote is missing.
