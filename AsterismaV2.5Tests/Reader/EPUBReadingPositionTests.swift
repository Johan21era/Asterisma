//  EPUBReadingPositionTests.swift
//  AsterismaV2.5
//
//  Pin the exact EPUB chapter/page position so reopening a book resumes where
//  the reader left off instead of starting at page 1.

import Foundation
import Testing

@testable import AsterismaV2_5

@Suite("EPUB reading position")
@MainActor
struct EPUBReadingPositionTests {
    @Test("Exact chapter/page survives a SQLite reopen")
    func exactPositionPersists() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let jsonURL = root.appendingPathComponent("library.json")
        let store = DataStore(fileURL: jsonURL, storageEngine: .sqlite)
        let book = Book(
            title: "Position Pin",
            author: "Test",
            fileURL: root.appendingPathComponent("position.epub"),
            fileType: .epub,
            totalPages: 200,
            currentPage: 47,
            epubChapterIndex: 4,
            epubPageInChapter: 17,
            chapters: []
        )
        #expect(store.addBook(book))
        store.saveImmediately()

        let reopened = DataStore(fileURL: jsonURL, storageEngine: .sqlite)
        let restored = try #require(reopened.book(id: book.id))
        #expect(restored.epubChapterIndex == 4)
        #expect(restored.epubPageInChapter == 17)
        #expect(restored.currentPage == 47)
    }
}
