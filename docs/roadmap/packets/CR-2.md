# CR-2 — WP-1.4 annotation UI design

**Status:** completed — 2026-11-07. Brief delivered and folded into
`docs/roadmap/packets/WP-1.4.md`.
**Administrator:** Buffy
**Executor:** `openrouter/stealth/crouton-alpha`
**Baseline:** `main` at `5d1be78`
**Mode:** design only. No code, no repository writes.

## Objective

Design the smallest annotation UI that closes G1's first four boxes without
inventing a new store, and write it as an implementation brief GLM can execute.

## Fixed inputs (already merged, not open for redesign)

- `BookNote` carries optional `selectedText`, `color`, `anchor`.
- `BookNoteAnchor` is `.epub(chapterIndex:cfi:pageInChapter:)` or
  `.pdf(pageIndex:rect:)`; the EPUB bridge produces a `ch:<chapter>:<start>:<end>`
  locator in the `cfi` field, not a standards-compliant CFI.
- `EPUBChapterWebView.onSelection` delivers `EPUBTextSelection`.
- `PDFReaderView.onSelection` delivers `PDFTextSelection`.
- Persistence is `DataStore` mutating `book.notes`; `LibraryDatabase` mirrors it.
- `BookDetailsView` already owns the note list, tag picker, and note editor.

## Required output — write to `/tmp/cr2-design.md` only

1. **Interaction spec** for: create a highlight from a selection, attach a note
   to it, edit, delete, and jump back to the anchor. Include the menu/popover
   states and the empty/error states.
2. **File plan**: new files, and every existing file that must change, with the
   reason. Respect that `Book2.swift` and `LibraryDatabase.swift` are frozen for
   this phase and `project.pbxproj` is Buffy-only.
3. **Reuse over invention**: which existing `BookDetailsView` code should be
   extracted rather than duplicated, and the smallest extraction that works.
4. **Restore semantics**: how a stored anchor maps back to a visible location in
   EPUB (chapter + offset, after reflow) and PDF (page + rect, under any layout),
   and what to do when the target moved or the quote no longer matches.
5. **Test list** GLM must write, with the invariant each test pins. Prefer pure
   model tests over UI tests.
6. **Risks**: the three most likely ways this UI ships broken, and the guard for
   each.

No code, no diffs, no repository writes.

## Stop authority

Buffy may terminate this session at any time. Stop immediately if asked to write
code or exceed the design scope.
