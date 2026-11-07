//  BookFileRelinkTests.swift
//  AsterismaV2.5Tests
//
//  Regression battery for the "Open Book" recovery path. A missing or moved
//  source file must be repairable without deleting and re-importing the book,
//  and a failed repair must leave the existing record byte-for-byte untouched.

import Foundation
import Testing

@testable import AsterismaV2_5

@Suite("Book File Relink — recovery contract")
@MainActor
struct BookFileRelinkTests {

    private func makeStore() -> (store: DataStore, directory: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = DataStore(fileURL: dir.appendingPathComponent("library.json"))
        return (store, dir)
    }

    @discardableResult
    private func writeFile(named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("book bytes".utf8).write(to: url)
        return url
    }

    @Test("relink updates the location, stores a bookmark, and preserves progress")
    func relinkPreservesProgress() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let missingURL = dir.appendingPathComponent("moved.pdf")
        let replacement = try writeFile(named: "replacement.pdf", in: dir)
        let book = Book(
            title: "The Moved Book",
            author: "A. Writer",
            fileURL: missingURL,
            fileType: .pdf,
            totalPages: 120,
            currentPage: 37
        )
        store.addBook(book)

        let updated = try store.relinkBookFile(id: book.id, to: replacement)

        #expect(updated.fileURL == replacement)
        #expect(updated.bookmarkData != nil)
        #expect(updated.currentPage == 37)
        #expect(updated.totalPages == 120)
        #expect(store.book(id: book.id)?.fileURL == replacement)
        #expect(store.book(id: book.id)?.currentPage == 37)
        #expect(store.books.count == 1)
    }

    @Test("availability distinguishes a present source from a moved one")
    func availabilityIsHonest() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let present = try writeFile(named: "present.pdf", in: dir)
        let missing = dir.appendingPathComponent("missing.pdf")
        let available = Book(title: "Present", author: "A", fileURL: present, fileType: .pdf)
        let moved = Book(title: "Moved", author: "A", fileURL: missing, fileType: .pdf)
        store.addBook(available)
        store.addBook(moved)

        #expect(available.isFileAvailable)
        #expect(!moved.isFileAvailable)
    }

    @Test("a mismatched format is refused and the old location survives")
    func formatMismatchLeavesRecordUntouched() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let oldURL = dir.appendingPathComponent("missing.pdf")
        let wrongFile = try writeFile(named: "wrong.epub", in: dir)
        let book = Book(
            title: "PDF Only",
            author: "A",
            fileURL: oldURL,
            fileType: .pdf,
            totalPages: 10
        )
        store.addBook(book)

        do {
            _ = try store.relinkBookFile(id: book.id, to: wrongFile)
            Issue.record("a PDF book must not accept an EPUB replacement")
        } catch let error as BookFileRelinkError {
            guard case let .formatMismatch(expected, actual) = error else {
                Issue.record("expected formatMismatch, got \(error)")
                return
            }
            #expect(expected == .pdf)
            #expect(actual == .epub)
        }

        #expect(store.book(id: book.id)?.fileURL == oldURL)
        #expect(store.book(id: book.id)?.bookmarkData == nil)
    }

    @Test("unknown files and unknown books fail without mutating the library")
    func invalidInputsAreRejected() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let oldURL = dir.appendingPathComponent("missing.pdf")
        let textFile = try writeFile(named: "notes.txt", in: dir)
        let replacement = try writeFile(named: "replacement.pdf", in: dir)
        let book = Book(title: "Guarded", author: "A", fileURL: oldURL, fileType: .pdf)
        store.addBook(book)

        #expect(throws: BookFileRelinkError.self) {
            try store.relinkBookFile(id: book.id, to: textFile)
        }
        #expect(throws: BookFileRelinkError.self) {
            try store.relinkBookFile(id: UUID(), to: replacement)
        }
        #expect(store.book(id: book.id)?.fileURL == oldURL)
        #expect(store.books.count == 1)
    }
}
