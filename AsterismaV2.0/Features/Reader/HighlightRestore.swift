//  HighlightRestore.swift
//  AsterismaV2.0
//
//  WP-1.4: pure anchor-resolution for rendering stored annotations after
//  reflow or relaunch.
//
//  Design rule (brief §4, kept by the WP-1.4 packet): stored fields are
//  lookup keys, not screen geometry. The EPUB `pageInChapter` and the PDF
//  stored `rect` describe where the highlight was at creation time. Neither
//  is ever used as a scroll target, a draw target, or a comparison input
//  here. Visible location is re-derived from content plus `selectedText`:
//
//    EPUB — dense locator offsets against the chapter's own text, then a
//           whitespace-tolerant quote search, then `.notFound`.
//    PDF  — a search of the page's text (the only path; the stored rect is
//           never consulted), then `.notFound` when the page is gone.
//
//  Everything here is pure String/PDF-independent work so tests can pin the
//  contract without WKWebView or PDFKit; the readers supply the text.

import Foundation

// MARK: - HighlightOutcome

/// The result of re-deriving where a stored annotation lives in current
/// content. Ranges are 0-based UTF-16 offsets into the *supplied* text,
/// matching both `EPUBTextSelection`'s offset contract and `NSRange`
/// semantics for `PDFPage.string`.
enum HighlightOutcome: Equatable {
    /// The stored offsets themselves hit text matching the quote. The
    /// expected path; layout-independent by construction.
    case resolved(Range<Int>)
    /// The content shifted and the stored offsets no longer match, but the
    /// quote was re-found by search. The caller draws at this range — it is
    /// a real match, never a fabricated one.
    case candidate(Range<Int>)
    /// The quote is absent (or the anchor's chapter/page is invalid). The
    /// caller shows the chapter/page with NO fabricated highlight.
    case notFound

    /// The UTF-16 range to draw, for any outcome that found the quote.
    var range: Range<Int>? {
        switch self {
        case let .resolved(value), let .candidate(value):
            return value
        case .notFound:
            return nil
        }
    }
}

// MARK: - HighlightRestore

enum HighlightRestore {

    /// Resolves an EPUB note against one chapter's text
    /// (`document.body.textContent` in the live `WKWebView`).
    ///
    /// Resolution order:
    ///  1. Parse the dense `ch:<chapter>:<start>:<end>` locator (stored in
    ///     `cfi`, built by `EPUBTextSelection.init`). If the range is in
    ///     bounds and its text matches the quote (whitespace-normalized),
    ///     that range is `.resolved`. Font-size changes never move
    ///     character offsets, so this is the reflow-proof path.
    ///  2. Quote search over the chapter text. One match → `.candidate`;
    ///     multiple → `.candidate` for the hit nearest the stored start (a
    ///     `nil` hint takes the first match). This is the "content shifted"
    ///     path: the highlight moves with the words, not with pixels.
    ///  3. `.notFound`. `pageInChapter` is never read: it is a scroll hint
    ///     at creation time, and using it for resolution would drift after
    ///     any reflow.
    static func resolveEPUB(
        chapterText: String,
        chapterIndex: Int,
        anchor: BookNoteAnchor?,
        selectedText: String
    ) -> HighlightOutcome {
        guard case let .epub(storedChapter, locator, _) = anchor else {
            return .notFound
        }
        // The reader resolves a note only against the chapter it names;
        // a mismatch is not an error, just no highlight for that chapter.
        guard storedChapter == chapterIndex else { return .notFound }

        guard let parsed = EPUBTextSelection.parse(locator) else {
            // A locator that no longer parses (never produced by this
            // reader, but possible from older or hand-written data) falls
            // through to the quote search rather than failing outright.
            return searchQuote(selectedText, in: chapterText, nearestTo: nil)
        }

        let start = parsed.startOffset
        let end = parsed.endOffset
        let chapterLength = (chapterText as NSString).length
        let locatorIsSane = start >= 0 && end > start && end <= chapterLength
        if locatorIsSane {
            let locatorText = (chapterText as NSString)
                .substring(with: NSRange(location: start, length: end - start))
            if normalized(locatorText) == normalized(selectedText) {
                return .resolved(start ..< end)
            }
        }
        return searchQuote(selectedText, in: chapterText, nearestTo: start)
    }

    /// Resolves a PDF note against one page's text (`PDFPage.string`).
    ///
    /// The stored normalized rect is provenance only: it is never drawn,
    /// never compared, and never used to scroll. A layout change (zoom, fit,
    /// rotation, page gap) cannot drift the mark because every annotation's
    /// bounds come from a fresh search result in the CURRENT layout's
    /// coordinate space.
    ///
    /// Page validity: a `pageIndex` past the document's page count is
    /// `.notFound` — never clamped to the last page, because a clamped page
    /// would be a fabricated location.
    static func resolvePDF(
        pageText: String,
        pageIndex: Int,
        pageCount: Int,
        anchor: BookNoteAnchor?,
        selectedText: String
    ) -> HighlightOutcome {
        guard case let .pdf(storedPage, _) = anchor else { return .notFound }
        guard storedPage == pageIndex else { return .notFound }
        guard storedPage >= 0, storedPage < max(0, pageCount) else {
            return .notFound
        }

        // Exact literal containment is the expected path (`page.string`
        // offsets change with PDFKit's text layout even when the words do
        // not, so the search is what carries the invariant, not a stored
        // offset).
        let trimmed = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty,
           let literal = pageText.range(of: trimmed)
        {
            return .resolved(utf16Offsets(for: literal, in: pageText))
        }
        // Whitespace-insensitive search: PDFKit joins lines with \r\n or
        // \n, so the same words with different line breaks are a real match
        // reported as `.candidate` rather than a failure.
        return searchQuote(selectedText, in: pageText, nearestTo: nil)
    }

    // MARK: - Matching

    /// Quote search shared by both formats. Returns `.candidate` for the
    /// best match, or `.notFound` when the quote is absent. `nearestTo` is
    /// a UTF-16 offset hint (the stored start) used to break ties between
    /// multiple occurrences; a `nil` hint takes the first match.
    private static func searchQuote(
        _ selectedText: String,
        in text: String,
        nearestTo hint: Int?
    ) -> HighlightOutcome {
        let hits = matches(of: selectedText, in: text)
        guard !hits.isEmpty else { return .notFound }
        if let hint {
            if let enclosing = hits.first(where: { $0.contains(hint) || $0.lowerBound == hint }) {
                return .candidate(enclosing)
            }
            let nearest = hits.min { abs($0.lowerBound - hint) < abs($1.lowerBound - hint) }
            return .candidate(nearest ?? hits[0])
        }
        return .candidate(hits[0])
    }

    /// All UTF-16 ranges in `text` whose content equals `needle` with every
    /// whitespace run on either side collapsed to any single whitespace
    /// run. Whitespace-only quotes never match. Implemented with a
    /// whitespace-flexible regex over the raw text so multi-line book text
    /// matches a quote joined with plain spaces.
    static func matches(of needle: String, in text: String) -> [Range<Int>] {
        let trimmed = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !text.isEmpty else { return [] }

        var pattern = ""
        var pendingWhitespace = false
        for character in trimmed {
            if character.isWhitespace {
                pendingWhitespace = true
            } else {
                if pendingWhitespace {
                    pattern += "[\\s\\u00A0\\u2028\\u2029]+"
                    pendingWhitespace = false
                }
                pattern += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        guard !pattern.isEmpty, let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        // UTF-16 offset of each Character (plus an end sentinel), computed
        // once so quote/offset space matches the locators' UTF-16 contract.
        var offsets: [Int] = []
        offsets.reserveCapacity(text.count + 1)
        var runningOffset = 0
        for character in text {
            offsets.append(runningOffset)
            runningOffset += character.utf16.count
        }
        offsets.append(runningOffset)

        let wholeRange = NSRange(text.startIndex ..< text.endIndex, in: text)
        var ranges: [Range<Int>] = []
        for match in regex.matches(in: text, range: wholeRange) {
            guard let matchRange = Range(match.range, in: text) else { continue }
            let firstIndex = text.distance(from: text.startIndex, to: matchRange.lowerBound)
            let lastIndex = text.distance(from: text.startIndex, to: matchRange.upperBound)
            ranges.append(offsets[firstIndex] ..< offsets[lastIndex])
        }
        return ranges
    }

    /// Whitespace normalization used for locator verification: collapses
    /// every whitespace run to one space and trims both ends.
    static func normalized(_ text: String) -> String {
        text.split(
            whereSeparator: { $0.isWhitespace || $0 == "\u{00A0}" || $0 == "\u{2028}" || $0 == "\u{2029}" }
        )
        .joined(separator: " ")
    }

    /// Converts a `String` range to UTF-16 offsets (the space both
    /// `EPUBTextSelection` and `NSRange` operate in).
    static func utf16Offsets(for range: Range<String.Index>, in text: String) -> Range<Int> {
        let nsLocation = NSRange(range, in: text)
        let end = nsLocation.location + nsLocation.length
        return nsLocation.location..<end
    }
}

// MARK: - HighlightMarkSet

/// WP-1.4: the model of the marks drawn for one chapter/page, keyed by note
/// id. This is the pure mirror of the apply steps both real renderers take
/// (the EPUB script removes every `data-asterisma-note` span before
/// wrapping the payload; the PDF page drops every Asterisma annotation
/// before adding fresh ones), so tests can pin idempotence: applying the
/// same note twice — or re-rendering after a data refresh — leaves exactly
/// one mark per note.
struct HighlightMarkSet: Equatable {
    private(set) var noteIDs: [UUID] = []

    /// Adds (or re-adds) a note's mark. Idempotent by note id: a second
    /// apply of the same id cannot grow the set.
    mutating func apply(noteID: UUID) {
        if !noteIDs.contains(noteID) {
            noteIDs.append(noteID)
        }
    }

    /// Removes exactly one note's mark; other notes' marks are untouched.
    mutating func remove(noteID: UUID) {
        noteIDs.removeAll { $0 == noteID }
    }
}
