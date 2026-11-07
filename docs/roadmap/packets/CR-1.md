# CR-1 — Independent review of the merged annotation tranche

**Status:** completed — 2026-11-07. Three S1 findings fixed; three deferred with
reasons recorded in `docs/audits/2026-11-07-cr1-annotation-review.md`.
**Administrator:** Buffy
**Executor:** `openrouter/stealth/crouton-alpha`
**Baseline:** `main` at `5d1be78`
**Mode:** read-only review. No writes to the repository.

## Objective

Review the three merged packages (`6e35429`, `3a82d50`, `a010a72`) as code, not
as summaries. The question is not "does it compile" — that is already proven —
but "what will break, corrupt, leak, or silently no-op".

## Scope

- `AsterismaV2.5/Core/Book2.swift` — `BookNote`, `AnnotationColor`,
  `BookNoteAnchor`, `NormalizedRect`, `NoteTag.quote`.
- `AsterismaV2.5/Core/Storage/LibraryDatabase.swift` — the `v2` migration, both
  note INSERT paths, `anchorJSON`, `decodeAnchor`.
- `AsterismaV2.5/Features/Reader/EPUBReaderScreen.swift` — the injected selection
  script, `EPUBTextSelection`, `EPUBSelectionState`, handler teardown.
- `AsterismaV2.5/Features/Reader/PDFReaderView2.swift` — `PDFTextSelection`,
  `PDFSelectionGeometry`, the `.PDFViewSelectionChanged` observer.
- The three test files that pin them.

## Required output — write to `/tmp/cr1-review.md` only

1. **Defects**, ranked: for each, the file and line, the precise failure mode, a
   concrete scenario that triggers it, and severity (data loss / silent
   wrongness / crash / cosmetic). A finding without a trigger scenario does not
   count.
2. **G1 gap check**: which of G1's seven boxes the merged code actually satisfies
   today, which are blocked only on UI, and which have a hidden technical gap.
3. **Migration risk**: what happens to a v1 store with existing notes, to a store
   written by this build then opened by an older build, and to the row-repair and
   rebuild paths.
4. **Selection correctness**: offset drift after reflow or chapter reload,
   duplicate posts, retain cycles, and whether the PDF rect is correct under a
   non-zero cropBox, RTL, and continuous scroll.
5. **Concurrency and lifecycle**: `@State` writes from the web-view callback,
   actor isolation, and teardown ordering.
6. **What you would test next**, in priority order, with the reason each test
   would have caught something the current tests miss.

Do not restate the code back. Do not propose a rewrite. No file in the repository
may be modified; do not run `git commit`, `git push`, `git checkout`, `git reset`,
or `git clean`.

## Stop authority

Buffy may terminate this session at any time. Stop immediately if asked to write
to the repository, touch a secret, or exceed the read-only scope.
