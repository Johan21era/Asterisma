//  AnnotationCreationTests.swift
//  AsterismaV2.0
//
//  WP-1.4: pins for the annotation factory, the single quote formatter,
//  and the pure note-array mutations that back DataStore.upsertNote /
//  deleteNote (the single book.notes mutation path). All pure model tests —
//  no view, no WKWebView/PDFKit, no DataStore instance.

import Foundation
import Testing

@testable import AsterismaV2_0

@Suite("Annotation creation")
struct AnnotationCreationTests {

    private let bookID = UUID()

    // MARK: - Locator round-trip (built and parsed in one place)

    /// The dense locator `ch:<chapter>:<start>:<end>` is built by
    /// EPUBTextSelection.init and parsed by EPUBTextSelection.parse; the
    /// factory stores it verbatim in the anchor and never re-derives it.
    @Test("EPUB factory stores the dense locator and it round-trips")
    func locatorRoundTripThroughFactory() throws {
        let selection = try #require(
            EPUBTextSelection(
                chapterIndex: 7,
                pageInChapter: 2,
                chapterLength: 5_000,
                text: "the measured boundary",
                startOffset: 4_120,
                endOffset: 4_141
            )
        )
        let note = AnnotationCreation.makeNote(from: selection, bookID: bookID)
        guard case let .epub(chapterIndex, cfi, pageInChapter) = note.anchor else {
            Issue.record("Expected .epub anchor, got \(note.anchor)")
            return
        }
        #expect(chapterIndex == 7)
        #expect(pageInChapter == 2)
        #expect(cfi == "ch:7:4120:4141")

        let parsed = try #require(EPUBTextSelection.parse(cfi))
        #expect(parsed.chapterIndex == 7)
        #expect(parsed.startOffset == 4_120)
        #expect(parsed.endOffset == 4_141)
    }

    // MARK: - Factory field mapping

    @Test("EPUB factory maps anchor, selectedText, color, and empty body")
    func epubFactoryFieldMapping() throws {
        let selection = try #require(
            EPUBTextSelection(
                chapterIndex: 3,
                pageInChapter: 1,
                text: "Hello, world",
                startOffset: 7,
                endOffset: 12
            )
        )
        let note = AnnotationCreation.makeNote(
            from: selection,
            bookID: bookID,
            color: .green
        )
        #expect(note.bookID == bookID)
        #expect(note.selectedText == "Hello, world")
        #expect(note.color == .green)
        #expect(note.text == "")
        #expect(note.tag == .highlight)
        #expect(note.pageNumber == nil)
        guard case let .epub(chapterIndex, cfi, pageInChapter) = note.anchor else {
            Issue.record("Expected .epub anchor")
            return
        }
        #expect(chapterIndex == 3)
        #expect(pageInChapter == 1)
        #expect(cfi == "ch:3:7:12")
    }

    @Test("PDF factory maps page, rect, and selectedText exactly")
    func pdfFactoryFieldMapping() {
        let rect = NormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let selection = PDFTextSelection(
            pageIndex: 11,
            text: "Selected passage",
            rect: rect
        )
        let note = AnnotationCreation.makeNote(
            from: selection,
            bookID: bookID,
            color: .blue
        )
        #expect(note.bookID == bookID)
        #expect(note.selectedText == "Selected passage")
        #expect(note.color == .blue)
        #expect(note.text == "")
        #expect(note.tag == .highlight)
        #expect(note.pageNumber == 11)
        guard case let .pdf(pageIndex, anchorRect) = note.anchor else {
            Issue.record("Expected .pdf anchor")
            return
        }
        #expect(pageIndex == 11)
        #expect(anchorRect == rect)
    }

    // MARK: - Quote copy (requirement 6, one formatter)

    @Test("EPUB copy quote is selected text plus the chapter caption only")
    func epubQuoteCopy() throws {
        let selection = try #require(
            EPUBTextSelection(
                chapterIndex: 3,
                pageInChapter: 0,
                text: "Hello, world",
                startOffset: 0,
                endOffset: 12
            )
        )
        let note = AnnotationCreation.makeNote(from: selection, bookID: bookID)
        #expect(QuoteFormatter.copyQuote(note) == "Hello, world\n— Chapter 4")
    }

    @Test("PDF copy quote is selected text plus the page caption only")
    func pdfQuoteCopy() {
        let selection = PDFTextSelection(
            pageIndex: 11,
            text: "Selected passage",
            rect: NormalizedRect(x: 0, y: 0, width: 0.1, height: 0.1)
        )
        let note = AnnotationCreation.makeNote(from: selection, bookID: bookID)
        #expect(QuoteFormatter.copyQuote(note) == "Selected passage\n— Page 12")
    }

    @Test("Editorial notes have no quote copy, and captions match the copied caption")
    func editorialNotesHaveNoCopy() throws {
        let editorial = BookNote(bookID: bookID, pageNumber: 4, text: "My thought")
        #expect(QuoteFormatter.copyQuote(editorial) == nil)
        #expect(QuoteFormatter.locationCaption(editorial) == nil)

        // Caption formatter is the same one the copy string uses.
        let anchored = try #require(
            EPUBTextSelection(
                chapterIndex: 0,
                pageInChapter: 0,
                text: "quote text",
                startOffset: 0,
                endOffset: 10
            )
        )
        let note = AnnotationCreation.makeNote(from: anchored, bookID: bookID)
        let copy = try #require(QuoteFormatter.copyQuote(note))
        #expect(copy.hasSuffix(QuoteFormatter.locationCaption(note) ?? "MISSING"))
    }

    // MARK: - Delete removes exactly one id (requirement 5)

    @Test("Delete removes exactly the target id from a ten-note array")
    func deleteRemovesExactlyOneID() {
        let ids = (0 ..< 10).map { _ in UUID() }
        let seeded = ids.map { id in
            BookNote(id: id, bookID: bookID, text: "note", tag: .general)
        }
        let removedID = ids[4]
        let updated = noteArrayByDeleting(id: removedID, from: seeded)

        #expect(updated.count == 9)
        #expect(Set(updated.map(\.id)) == Set(ids.filter { $0 != removedID }))
        #expect(!updated.contains { $0.id == removedID })
        // Deleting an id that is not present changes nothing.
        let stranger = noteArrayByDeleting(id: UUID(), from: updated)
        #expect(stranger == updated)
    }

    // MARK: - Upsert idempotence and the 50-cycle check (requirement 2 / box 4)

    @Test("Two upserts of the same id leave one row")
    func doubleUpsertLeavesOneRow() {
        let id = UUID()
        let first = BookNote(
            id: id, bookID: bookID, text: "first body", tag: .general
        )
        var notes = noteArrayByUpserting(first, into: [])
        #expect(notes.count == 1)

        // The editor save path mutates only body/color on the SAME id —
        // never mints a second row.
        var edited = first
        edited.text = "edited body"
        edited.color = .pink
        notes = noteArrayByUpserting(edited, into: notes)

        #expect(notes.count == 1)
        #expect(notes[0].id == id)
        #expect(notes[0].text == "edited body")
        #expect(notes[0].color == .pink)
        // The editor never rewrites anchor or selectedText.
        #expect(notes[0].anchor == nil)
        #expect(notes[0].selectedText == nil)
    }

    @Test("Fifty create/delete cycles leave no orphaned rows")
    func fiftyCreateDeleteCycles() throws {
        let baseline = (0 ..< 5).map { _ in
            BookNote(bookID: bookID, text: "kept", tag: .general)
        }
        var notes = baseline
        let baselineIDs = Set(baseline.map(\.id))

        for index in 0 ..< 50 {
            // Alternate EPUB and PDF anchors exactly as the readers create them.
            let anchored: BookNote
            if index % 2 == 0 {
                let selection = try #require(
                    EPUBTextSelection(
                        chapterIndex: index % 4,
                        pageInChapter: 0,
                        text: "quote \(index)",
                        startOffset: 0,
                        endOffset: 50
                    )
                )
                anchored = AnnotationCreation.makeNote(
                    from: selection, bookID: bookID, color: .green
                )
            } else {
                let selection = PDFTextSelection(
                    pageIndex: index % 7,
                    text: "quote \(index)",
                    rect: NormalizedRect(x: 0, y: 0, width: 0.2, height: 0.2)
                )
                anchored = AnnotationCreation.makeNote(
                    from: selection, bookID: bookID, color: .pink
                )
            }
            notes = noteArrayByUpserting(anchored, into: notes)
            #expect(notes.count == 6) // baseline + the one live cycle note
            notes = noteArrayByDeleting(id: anchored.id, from: notes)
            #expect(notes.count == 5)
        }

        #expect(notes.count == 5)
        #expect(Set(notes.map(\.id)) == baselineIDs)
        // No orphan from any cycle survives.
        #expect(!notes.contains { $0.tag == .highlight })
    }
}
