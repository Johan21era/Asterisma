//  ComicReaderModelTests.swift
//  AsterismaV2.0
//
//  2.5 — reading modes are presentation, not file format. These tests pin the
//  direction mapping, the durable comic anchor, and the tolerant Book decode
//  that keeps pre-2.5 libraries loadable.

import Foundation
import Testing

@testable import AsterismaV2_0

@Suite("Comic reader model")
struct ComicReaderModelTests {
    @Test("Container defaults are sensible and persisted modes override them")
    func defaultModes() {
        #expect(ComicReadingMode.defaultMode(for: .comic) == .vertical)
        #expect(ComicReadingMode.defaultMode(for: .cbz) == .leftToRight)
        #expect(ComicReadingMode.defaultMode(for: .epub) == .leftToRight)
        #expect(ComicReadingMode.defaultMode(for: .pdf) == .leftToRight)

        let folderBook = Book(
            title: "Webtoon",
            author: "Unknown",
            fileURL: URL(fileURLWithPath: "/tmp/webtoon"),
            fileType: .comic,
            totalPages: 3
        )
        #expect(folderBook.comicReadingMode == nil)
        #expect(folderBook.resolvedComicReadingMode == .vertical)

        let manga = Book(
            title: "Manga",
            author: "Unknown",
            fileURL: URL(fileURLWithPath: "/tmp/manga.cbz"),
            fileType: .cbz,
            totalPages: 3,
            comicReadingMode: .rightToLeft
        )
        #expect(manga.resolvedComicReadingMode == .rightToLeft)
    }

    @Test("A title suggests a starting mode without changing the default contract")
    func suggestedModes() {
        #expect(ComicReadingMode.suggested(for: "Manga Volume 1", fileType: .cbz) == .rightToLeft)
        #expect(ComicReadingMode.suggested(for: "Manhwa Collection", fileType: .cbz) == .rightToLeft)
        #expect(ComicReadingMode.suggested(for: "Manhua Anthology", fileType: .cbz) == .rightToLeft)
        #expect(ComicReadingMode.suggested(for: "Tower of God Webtoon", fileType: .cbz) == .vertical)
        #expect(ComicReadingMode.suggested(for: "Batman", fileType: .cbz) == .leftToRight)
        #expect(ComicReadingMode.suggested(for: "Manga Folder", fileType: .comic) == .vertical)
        #expect(ComicReadingMode.suggested(for: "Novel", fileType: .epub) == .leftToRight)
    }

    @Test("Paged visual order mirrors only for right-to-left reading")
    func visualOrder() {
        #expect(ComicPagination.visualOrder(pageCount: 4, mode: .leftToRight) == [0, 1, 2, 3])
        #expect(ComicPagination.visualOrder(pageCount: 4, mode: .rightToLeft) == [3, 2, 1, 0])
        #expect(ComicPagination.visualIndex(forPage: 0, pageCount: 4, mode: .rightToLeft) == 3)
        #expect(ComicPagination.pageIndex(forVisual: 3, pageCount: 4, mode: .rightToLeft) == 0)
        #expect(ComicPagination.visualIndex(forPage: 99, pageCount: 4, mode: .rightToLeft) == 0)
        #expect(ComicPagination.pageIndex(forVisual: 99, pageCount: 4, mode: .leftToRight) == 3)
    }

    @Test("Right-to-left manga advances on the left arrow")
    func arrowDirectionMapping() {
        #expect(ComicReadingMode.leftToRight.isForward(.right))
        #expect(ComicReadingMode.leftToRight.isForward(.down))
        #expect(!ComicReadingMode.leftToRight.isForward(.left))
        #expect(!ComicReadingMode.leftToRight.isForward(.up))

        #expect(ComicReadingMode.rightToLeft.isForward(.left))
        #expect(ComicReadingMode.rightToLeft.isForward(.down))
        #expect(!ComicReadingMode.rightToLeft.isForward(.right))
        #expect(!ComicReadingMode.rightToLeft.isForward(.up))

        #expect(ComicReadingMode.vertical.isForward(.down))
        #expect(!ComicReadingMode.vertical.isForward(.up))
    }

    @Test("Pagination never steps outside the page range")
    func paginationBounds() {
        #expect(ComicPagination.next(after: 0, pageCount: 3) == 1)
        #expect(ComicPagination.next(after: 2, pageCount: 3) == nil)
        #expect(ComicPagination.previous(before: 2, pageCount: 3) == 1)
        #expect(ComicPagination.previous(before: 0, pageCount: 3) == nil)
        #expect(ComicPagination.next(after: 0, pageCount: 0) == nil)
        #expect(ComicPagination.label(index: 0, pageCount: 5) == "Page 1 of 5")
        #expect(ComicPagination.progress(index: 4, pageCount: 5) == 1.0)
    }

    @Test("A pre-2.5 Book payload decodes with a comic mode default, not a failure")
    func legacyBookDecoding() throws {
        let book = Book(
            title: "Legacy",
            author: "Author",
            fileURL: URL(fileURLWithPath: "/tmp/legacy.cbz"),
            fileType: .cbz,
            totalPages: 12,
            comicReadingMode: .rightToLeft
        )

        let encoded = try JSONEncoder().encode(book)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "comicReadingMode")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(Book.self, from: legacyData)
        #expect(decoded.comicReadingMode == nil)
        #expect(decoded.resolvedComicReadingMode == .leftToRight)
        #expect(decoded.fileType == .cbz)
        #expect(decoded.totalPages == 12)
    }

    @Test("A comic reading mode survives a Book encode/decode round-trip")
    func comicModeRoundTrip() throws {
        let book = Book(
            title: "Manga",
            author: "Author",
            fileURL: URL(fileURLWithPath: "/tmp/manga.cbz"),
            fileType: .cbz,
            totalPages: 20,
            comicReadingMode: .rightToLeft
        )
        let decoded = try JSONDecoder().decode(Book.self, from: JSONEncoder().encode(book))
        #expect(decoded.comicReadingMode == .rightToLeft)
        #expect(decoded.resolvedComicReadingMode == .rightToLeft)
    }

    @Test("Comic page notes round-trip and caption the page")
    func comicAnchor() throws {
        let bookID = UUID()
        let note = AnnotationCreation.makePageNote(text: "Great spread", bookID: bookID, pageIndex: 4)

        #expect(note.pageNumber == 4)
        #expect(note.anchor == .comic(pageIndex: 4))
        #expect(QuoteFormatter.locationCaption(note) == "— Page 5")

        let decoded = try JSONDecoder().decode(BookNote.self, from: JSONEncoder().encode(note))
        #expect(decoded.anchor == .comic(pageIndex: 4))
        #expect(QuoteFormatter.locationCaption(decoded) == "— Page 5")
    }

    @Test("Format filtering separates comics from prose")
    func formatFilter() {
        let books = [
            Book(title: "Prose", author: "A", fileURL: URL(fileURLWithPath: "/tmp/a.epub"), fileType: .epub),
            Book(title: "Paper", author: "B", fileURL: URL(fileURLWithPath: "/tmp/b.pdf"), fileType: .pdf),
            Book(title: "Archive", author: "C", fileURL: URL(fileURLWithPath: "/tmp/c.cbz"), fileType: .cbz),
            Book(title: "Folder", author: "D", fileURL: URL(fileURLWithPath: "/tmp/d"), fileType: .comic),
        ]

        var state = LibraryFilterState.none
        state.selectedFormat = .cbz
        #expect(state.isActive)
        #expect(state.apply(to: books).map(\.title) == ["Archive"])

        state.selectedFormat = .comic
        #expect(state.apply(to: books).map(\.title) == ["Folder"])

        state.clearSelections()
        #expect(state.apply(to: books).count == 4)
    }
}
