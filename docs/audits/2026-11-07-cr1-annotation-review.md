# CR-1 annotation review — dispositions

**Date:** 2026-11-07
**Reviewer:** Crouton Alpha, session `ses_e4bad8f47ffemS5k67Um9XkLyR`
**Baseline reviewed:** `main` at `5d1be78`
**Fix commit:** `98aaaf3`
**Administrator:** Buffy. Every finding below was re-verified against the code
before any change; a model's claim is not evidence.

## Why this document exists

The CR-1 packet asked Crouton to review the merged annotation tranche as code.
It returned three S1 findings, three S2 findings, and three follow-ups. Three S1
findings were real and are fixed. This file records what was verified, what
changed, and what was deliberately deferred, so a later reader does not have to
trust a chat log.

The raw review is not committed: it is model output, not a receipt. It can be
regenerated with `opencode session export ses_e4bad8f47ffemS5k67Um9XkLyR`.

## Dispositions

| # | Finding (as returned) | Buffy's verification | Disposition |
|---|---|---|---|
| 1 | EPUB locators are collapsed by clamping | Confirmed at `EPUBReaderScreen.swift:1148-1150` before the fix: both offsets were clamped to `clipped.utf16.count`, the quote's own length, while the JavaScript posts chapter-absolute offsets. Any selection starting past the quote length stored a zero-width locator at the wrong text. The existing test passed only because it used offsets that fit inside the quote. | **Fixed.** The initializer takes the chapter length, the script posts `textLength` from `document.body.textContent.length`, offsets clamp to `0...chapterLength`, and the range is capped at the stored quote length so quote and anchor describe the same text. New test: `chapterAbsoluteOffsetsPreserved` keeps `4120...4141` in a 5,000-character chapter. |
| 2 | Multi-page PDF selections anchor text from page N+1 to page N | Confirmed at `PDFReaderView2.swift:507` before the fix: `selection.string` covered every touched page while the rect came from `selection.pages.first`. | **Fixed.** A multi-page selection now takes the first page's own text via `page.selection(for: selection.bounds(for: page))?.string`. |
| 3 | A downgrade can make the library unreadable | Confirmed by code path: `NoteTag` decoded only known raw values, and `loadBooks` fails closed on any undecodable book payload. One note tagged `Quote` written by this build would make an older build unable to load the library at all. | **Fixed.** `NoteTag` and `AnnotationColor` decode unknown values to `.general` and `.yellow`. The remaining downgrade risk — an older build silently dropping `selectedText`, `color`, and `anchor` on its next save — is inherent to schema evolution without a migration fence and is recorded in `docs/registers/02-defect-register.md` practice, not solved here. |
| 4 | A deselection leaves the previous selection standing | Confirmed: the early-return guards published nothing, so the screen kept the last anchor. | **Fixed for PDF.** `onSelection` now carries `nil` on a cleared or whitespace-only selection, the screen stores the optional, and the callback hops to the main thread defensively. **Still open for EPUB:** its `EPUBSelectionState` clears on page and chapter change but not on deselect. Assigned to WP-1.4. |
| 5 | The PDF observer is torn down only in `deinit` | Confirmed: `dismantleNSView` stopped the timer and the security scope but not the selection observer. | **Fixed.** `stopSelectionObservation()` runs from `dismantleNSView`; `deinit` keeps its `removeObserver` as a backstop. |
| 6 | A duplicate note id aborts `saveAll` on the primary key | Not reproduced. Ids are minted per note and no path reuses one; a synthetic collision would need a corrupted payload. | **Deferred to WP-1.5**, which owns export, import, and orphan recovery and is the right place to make a duplicate id a defined, tested outcome rather than an abort. |
| 7 | `pageNumber` and `anchor` can diverge in the existing editor | True by construction today: the old editor writes `pageNumber` only, and no reader writes an anchor yet. | **Assigned to WP-1.4.** The single `upsertNote` helper must write both from one selection so they cannot disagree. |
| 8 | Point-vs-normalized tolerance can drop edge selections | Plausible but not reproduced: it needs a live PDF selection whose bounds touch the crop box edge by less than the 0.001 tolerance. | **Deferred with a named test.** WP-1.4's restore suite must include a selection flush to the page edge; if it reproduces, widen the tolerance or clamp before the usability check. |

## Verification of the fixes

| Check | Result |
|---|---|
| Debug build | exit 0, `** BUILD SUCCEEDED **` |
| Focused suites: `EPUBSelectionTests`, `PDFSelectionGeometryTests`, `AnnotationSchemaTests`, `SchemaEvolutionTests`, `ReaderAppearanceTests` | exit 0, **32 tests in 5 suites passed** |
| `./scripts/census.sh --unit-only` | exit 0, **537 tests / 528 passed / 9 skipped / 0 failed / 719 runs** |

The census moved from 536 to 537 because the fix added one EPUB regression test.
No test was weakened or deleted to make this pass: the one test that changed
(`offsetsClamp`) previously asserted the buggy contract and now passes the
chapter length explicitly.

## Limits

The EPUB JavaScript is still verified by review and compilation only; no test
instantiates a `WKWebView`. The PDF notification path is pinned by a test, but
the observer's registration in `makeNSView` is verified by review. No live
library was migrated, and no owner visual pass exists for any of this work.
