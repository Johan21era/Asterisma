//  HighlightRestoreTests.swift
//  AsterismaV2.5
//
//  WP-1.4: pins for pure anchor resolution — exact and shifted EPUB
//  locators, PDF page search, the notFound honesty rule (no fabricated
//  ranges, no clamping to the last page), reflow invariance, and the
//  idempotent apply (one mark per note id). No WKWebView or PDFKit.

import Foundation
import Testing

@testable import AsterismaV2_5

@Suite("Highlight restore")
struct HighlightRestoreTests {

    private let bookID = UUID()

    /// Builds an EPUB note stored at `start..<end` over `quoteText`.
    private func epubNote(
        chapter: Int = 4,
        start: Int,
        end: Int,
        quoteText: String,
        pageInChapter: Int = 0
    ) -> BookNote {
        BookNote(
            bookID: bookID,
            text: "",
            tag: .highlight,
            selectedText: quoteText,
            anchor: .epub(
                chapterIndex: chapter,
                cfi: "ch:\(chapter):\(start):\(end)",
                pageInChapter: pageInChapter
            )
        )
    }

    // MARK: - EPUB: exact locator match resolves

    @Test("Exact EPUB locator match resolves to the stored range")
    func epubExactMatchResolves() throws {
        let chapterText = "Alpha beta gamma delta epsilon."
        // UTF-16 offsets: "Alpha " = 6, "beta" = 4 → range 6..<10.
        let note = epubNote(start: 6, end: 10, quoteText: "beta")
        let outcome = HighlightRestore.resolveEPUB(
            chapterText: chapterText,
            chapterIndex: 4,
            anchor: note.anchor,
            selectedText: note.selectedText ?? "MISSING"
        )
        #expect(outcome == .resolved(6 ..< 10))

        // The resolved text is really the quote.
        let resolved = try #require(outcome.range)
        let hit = (chapterText as NSString).substring(
            with: NSRange(location: resolved.lowerBound, length: resolved.count)
        )
        #expect(HighlightRestore.normalized(hit) == "beta")
    }

    @Test("EPUB pageInChapter never moves the resolved range")
    func epubPageHintIsNotAResolveInput() {
        let chapterText = "Alpha beta gamma delta epsilon."
        let note0 = epubNote(start: 6, end: 10, quoteText: "beta", pageInChapter: 0)
        let note999 = epubNote(start: 6, end: 10, quoteText: "beta", pageInChapter: 999)
        for note in [note0, note999] {
            let outcome = HighlightRestore.resolveEPUB(
                chapterText: chapterText,
                chapterIndex: 4,
                anchor: note.anchor,
                selectedText: note.selectedText ?? "MISSING"
            )
            #expect(outcome == .resolved(6 ..< 10))
        }
    }

    // MARK: - EPUB: shifted content resolves to a candidate

    @Test("A shifted quote re-resolves to a candidate by content search")
    func epubShiftedQuoteResolvesToCandidate() throws {
        // Note stored over "gamma delta" (11..<22) in the ORIGINAL chapter.
        let note = epubNote(start: 11, end: 22, quoteText: "gamma delta")
        // Reflowed chapter: 10 characters of new front matter push the words
        // along; the stored offsets now point at different text.
        let reflowedText = "0123456789 Alpha beta gamma delta epsilon."
        let outcome = HighlightRestore.resolveEPUB(
            chapterText: reflowedText,
            chapterIndex: 4,
            anchor: note.anchor,
            selectedText: note.selectedText ?? "MISSING"
        )
        guard case let .candidate(range) = outcome else {
            Issue.record("Expected .candidate, got \(outcome)")
            return
        }
        let hit = (reflowedText as NSString).substring(
            with: NSRange(location: range.lowerBound, length: range.count)
        )
        #expect(HighlightRestore.normalized(hit) == "gamma delta")
        #expect(range.lowerBound > 10)
    }

    @Test("Multiple occurrences pick the one nearest the stored start")
    func epubNearestOccurrenceWins() {
        // "gamma" appears twice; stored start (11) is closer to the second.
        let chapterText = "gamma alpha beta gamma alpha beta delta"
        let note = epubNote(start: 11, end: 22, quoteText: "gamma")
        let outcome = HighlightRestore.resolveEPUB(
            chapterText: chapterText,
            chapterIndex: 4,
            anchor: note.anchor,
            selectedText: note.selectedText ?? "MISSING"
        )
        guard case let .candidate(range) = outcome else {
            Issue.record("Expected .candidate, got \(outcome)")
            return
        }
        #expect(range.lowerBound == 17)
    }

    // MARK: - Honesty: notFound, never fabricated

    @Test("A missing quote returns notFound — never a fabricated range")
    func epubMissingQuoteNotFound() {
        let note = epubNote(start: 6, end: 10, quoteText: "nonexistent sentence")
        let outcome = HighlightRestore.resolveEPUB(
            chapterText: "Alpha beta gamma delta epsilon.",
            chapterIndex: 4,
            anchor: note.anchor,
            selectedText: note.selectedText ?? "MISSING"
        )
        #expect(outcome == .notFound)
    }

    @Test("A PDF page past the document returns notFound without clamping")
    func pdfOutOfRangePageNotFound() {
        let anchor = BookNoteAnchor.pdf(
            pageIndex: 9,
            rect: NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        )
        // The quote IS on the word-supplied text, and the page count is only
        // 5 — the resolver must still refuse rather than clamp to page 4.
        let outcome = HighlightRestore.resolvePDF(
            pageText: "passage text",
            pageIndex: 9,
            pageCount: 5,
            anchor: anchor,
            selectedText: "passage text"
        )
        #expect(outcome == .notFound)
    }

    // MARK: - PDF: search-not-rect, reflow/layout invariance

    @Test("PDF layout change still resolves; the stored rect is never in the output")
    func pdfReflowResolvesAndRectNeverUsed() throws {
        func note(rect: NormalizedRect) -> BookNote {
            BookNote(
                bookID: bookID,
                text: "",
                tag: .highlight,
                selectedText: "passage text",
                anchor: .pdf(pageIndex: 3, rect: rect)
            )
        }
        // Same page text, two different stored rects (creation layout vs.
        // post-layout-change provenance). Resolution must be identical.
        let before = note(rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.4, height: 0.2))
        let after = note(rect: NormalizedRect(x: 0.9, y: 0.8, width: 0.05, height: 0.01))
        let pageText = "intro passage text outro"
        let outcomeBefore = HighlightRestore.resolvePDF(
            pageText: pageText,
            pageIndex: 3,
            pageCount: 10,
            anchor: before.anchor,
            selectedText: before.selectedText ?? "MISSING"
        )
        let outcomeAfter = HighlightRestore.resolvePDF(
            pageText: pageText,
            pageIndex: 3,
            pageCount: 10,
            anchor: after.anchor,
            selectedText: after.selectedText ?? "MISSING"
        )
        #expect(outcomeBefore == outcomeAfter)
        guard case .resolved = outcomeBefore else {
            Issue.record("Expected .resolved, got \(outcomeBefore)")
            return
        }
        // Output carries only offsets into the CURRENT text — a rect can
        // never appear in a HighlightOutcome, by the enum's own shape.
        let range = try #require(outcomeBefore.range)
        let hit = (pageText as NSString).substring(
            with: NSRange(location: range.lowerBound, length: range.count)
        )
        #expect(hit == "passage text")
    }

    @Test("PDF same words with different line breaks resolve as candidate")
    func pdfWhitespaceFlexibility() {
        let anchor = BookNoteAnchor.pdf(
            pageIndex: 2,
            rect: NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5)
        )
        // Quote stored with spaces; PDFKit lays the page out with a newline.
        let outcome = HighlightRestore.resolvePDF(
            pageText: "alpha passage\nbetween beta gamma",
            pageIndex: 2,
            pageCount: 4,
            anchor: anchor,
            selectedText: "passage between beta"
        )
        guard case let .candidate(range) = outcome else {
            Issue.record("Expected .candidate from whitespace-flexible search, got \(outcome)")
            return
        }
        #expect(range.lowerBound == 6)
        #expect(range.upperBound == 26)
    }

    @Test("PDF a missing quote returns notFound")
    func pdfMissingQuoteNotFound() {
        let anchor = BookNoteAnchor.pdf(
            pageIndex: 2,
            rect: NormalizedRect(x: 0, y: 0, width: 0.5, height: 0.5)
        )
        let outcome = HighlightRestore.resolvePDF(
            pageText: "unrelated words entirely",
            pageIndex: 2,
            pageCount: 4,
            anchor: anchor,
            selectedText: "passage text"
        )
        #expect(outcome == .notFound)
    }

    @Test("A note whose chapter does not match resolves notFound")
    func epubWrongChapterNotFound() {
        let note = epubNote(chapter: 4, start: 0, end: 5, quoteText: "Alpha")
        let outcome = HighlightRestore.resolveEPUB(
            chapterText: "Alpha text",
            chapterIndex: 6,
            anchor: note.anchor,
            selectedText: "Alpha"
        )
        #expect(outcome == .notFound)
    }

    // MARK: - Idempotent apply (box 2: no duplicates)

    @Test("Applying the same note twice yields one mark")
    func applyTwiceYieldsOneMark() {
        let noteID = UUID()
        var marks = HighlightMarkSet()
        marks.apply(noteID: noteID)
        #expect(marks.noteIDs == [noteID])

        // Re-render / data refresh / double render — same id, one mark.
        marks.apply(noteID: noteID)
        #expect(marks.noteIDs.count == 1)
        #expect(marks.noteIDs == [noteID])

        // A second, different note adds exactly one more.
        let secondID = UUID()
        marks.apply(noteID: secondID)
        #expect(marks.noteIDs.count == 2)

        // Delete removes exactly that id (requirement 5, no rows left).
        marks.remove(noteID: noteID)
        #expect(marks.noteIDs == [secondID])
        marks.remove(noteID: noteID)
        #expect(marks.noteIDs == [secondID])
    }
}
