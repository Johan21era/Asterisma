//  AnnotationCreation.swift
//  AsterismaV2.5
//
//  WP-1.4: the single factory that turns a settled reader selection into a
//  persisted `BookNote`, plus the single quote formatter every surface
//  (rows, popovers, clipboard) shares.
//
//  Frozen-schema discipline: `Book2.swift` is not touched. The factory only
//  fills the WP-1.1 fields that already exist (`selectedText`, `color`,
//  `anchor`); the EPUB anchor's `cfi` payload is the dense
//  `ch:<chapter>:<start>:<end>` locator built by `EPUBTextSelection.init`
//  and parsed by `EPUBTextSelection.parse` — the locator is built and
//  parsed in one place, and the factory consumes it without re-deriving.

import AppKit
import Foundation

// MARK: - AnnotationCreation

/// WP-1.4: selection → `BookNote` factory. Pure and side-effect-free: it
/// never touches DataStore. Readers call this, then hand the note to
/// `DataStore.upsertNote(_:inBook:)` (the single mutation path).
///
/// Frozen-schema rule (owner decision 2026-11-07): the bridge already caps
/// selection text at 4,000 characters (`EPUBTextSelection.maxTextLength`,
/// `PDFSelectionGeometry.maxSelectedTextLength`), and the factory adds no
/// second cap. Buffy dropped the brief's 2,000-character pre-highlight limit.
enum AnnotationCreation {

    /// Builds an anchored, empty-bodied highlight note from an EPUB
    /// selection. `bookID` ties the note to its book; `color` is the user's
    /// current default highlight color. The dense locator journey is:
    /// built by `EPUBTextSelection.init`, stored verbatim here, parsed only
    /// by `EPUBTextSelection.parse` (see `HighlightRestore`).
    static func makeNote(
        from selection: EPUBTextSelection,
        bookID: UUID,
        color: AnnotationColor = .yellow
    ) -> BookNote {
        BookNote(
            bookID: bookID,
            // EPUB `pageInChapter` is chapter-local reflow state, not the
            // book's `pageNumber` analytics page; it lives in the anchor and
            // is only ever a scroll hint. Keep `pageNumber` nil rather than
            // shipping a page number that means nothing globally.
            pageNumber: nil,
            text: "",
            tag: .highlight,
            selectedText: selection.text,
            color: color,
            anchor: .epub(
                chapterIndex: selection.chapterIndex,
                cfi: selection.locator,
                pageInChapter: selection.pageInChapter
            )
        )
    }

    /// Builds an anchored, empty-bodied highlight note from a PDF selection.
    /// `pageNumber` carries the 0-based PDF page index in the legacy
    /// `BookNote.pageNumber` slot (the details UI prints `p. <n+1>`), and the
    /// normalized creation rect is stored inside the anchor as *provenance
    /// only* — `HighlightRestore` never uses it as a draw target.
    static func makeNote(
        from selection: PDFTextSelection,
        bookID: UUID,
        color: AnnotationColor = .yellow
    ) -> BookNote {
        BookNote(
            bookID: bookID,
            pageNumber: selection.pageIndex,
            text: "",
            tag: .highlight,
            selectedText: selection.text,
            color: color,
            anchor: .pdf(pageIndex: selection.pageIndex, rect: selection.rect)
        )
    }

    /// Builds a page-anchored editorial note for a comic page. Comic pages
    /// are images, so there is no selected text or highlight rectangle: the
    /// durable location is the 0-based page index in the comic container.
    static func makePageNote(
        text: String,
        bookID: UUID,
        pageIndex: Int,
        tag: BookNote.NoteTag = .general
    ) -> BookNote {
        BookNote(
            bookID: bookID,
            pageNumber: pageIndex,
            text: text,
            tag: tag,
            anchor: .comic(pageIndex: pageIndex)
        )
    }
}

// MARK: - QuoteFormatter

/// WP-1.4: the ONE formatter for location captions and copy-quote strings.
/// Requirement 6: copy quote yields the selected text plus
/// `— Chapter N` (EPUB) or `— Page N` (PDF). Row captions, popover
/// captions, and the clipboard all call this, so the three surfaces can
/// never disagree; there is deliberately no second caption implementation.
enum QuoteFormatter {

    /// `— Chapter N` for an EPUB-anchored note, `— Page N` for a
    /// PDF-anchored note (1-based, N = stored index + 1). nil for notes
    /// with no anchor — plain editorial notes have no location to caption.
    static func locationCaption(_ note: BookNote) -> String? {
        switch note.anchor {
        case let .epub(chapterIndex, _, _):
            return "— Chapter \(chapterIndex + 1)"
        case let .pdf(pageIndex, _):
            return "— Page \(pageIndex + 1)"
        case let .comic(pageIndex):
            return "— Page \(pageIndex + 1)"
        case nil:
            return nil
        }
    }

    /// The full copy string: selected text (end-whitespace trimmed, interior
    /// whitespace verbatim) + a newline + the location caption. nil when the
    /// note has no quotable text or no anchor, so callers can hide the
    /// Copy action instead of copying a partial string.
    static func copyQuote(_ note: BookNote) -> String? {
        guard let quote = quotedText(of: note),
              let caption = locationCaption(note)
        else { return nil }
        return quote + "\n" + caption
    }

    /// The selected text with its trailing/leading whitespace trimmed
    /// ("verbatim including original whitespace trim only at the ends").
    /// nil for whitespace-only selections and plain editorial notes.
    static func quotedText(of note: BookNote) -> String? {
        guard let selected = note.selectedText else { return nil }
        let trimmed = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - AnnotationClipboard

/// WP-1.4: the one clipboard write used by every annotation surface.
extension AnnotationClipboard {
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

enum AnnotationClipboard {}
