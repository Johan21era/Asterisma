//  LibraryMetadataPinsTests.swift
//  Bedrock G5 pins: genre mapping, metadata, notes, collections persistence.

import Foundation
import Testing
@testable import AsterismaV2_5

@Suite("G5 · Genre mapping")
struct GenreMappingTests {
    @Test("OPF subjects map to the app's genre taxonomy")
    func subjectMapping() {
        #expect(ReadingGenre.mapped(from: ["Fantasy fiction"]) == .fantasy)
        #expect(ReadingGenre.mapped(from: ["Science Fiction", "Space Opera"]) == .scienceFiction)
        #expect(ReadingGenre.mapped(from: ["Detective and mystery stories"]) == .mystery)
        #expect(ReadingGenre.mapped(from: ["Biography & Autobiography"]) == .biography)
        #expect(ReadingGenre.mapped(from: ["Juvenile Fiction"]) == .children)
        #expect(ReadingGenre.mapped(from: ["Business & Economics"]) == .business)
        #expect(ReadingGenre.mapped(from: []) == .unknown)
    }
}

@Suite("G5 · Metadata/notes/collections persistence", .serialized)
@MainActor
final class LibraryMetadataPinsTests {

    @Test("Genre, series, favorite, notes, and collections survive SQLite reopen")
    func metadataPersistence() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = dir.appendingPathComponent("library.json")
        let dbURL = dir.appendingPathComponent("library.sqlite3")

        let store = DataStore(
            fileURL: json,
            storageEngine: .sqlite,
            databaseURL: dbURL)
        var book = Book(
            title: "Metadata Book",
            author: "A",
            fileURL: URL(fileURLWithPath: "/tmp/meta.pdf"),
            fileType: .pdf,
            totalPages: 100)
        store.addBook(book)
        book = try #require(store.book(id: book.id))
        book.genre = .science
        book.series = "Frontier"
        book.isFavorite = true
        book.notes = [
            BookNote(bookID: book.id, pageNumber: 4, text: "**Markdown** note", tag: .idea)
        ]
        store.updateBook(book)
        let collection = store.addCollection(name: "Research")
        store.setBook(book.id, membershipIn: collection.id, isMember: true)
        store.saveImmediately()

        let reopened = DataStore(
            fileURL: json,
            storageEngine: .sqlite,
            databaseURL: dbURL)
        let loaded = try #require(reopened.books.first)
        #expect(loaded.genre == .science)
        #expect(loaded.series == "Frontier")
        #expect(loaded.isFavorite)
        #expect(loaded.notes.count == 1)
        #expect(loaded.notes.first?.text == "**Markdown** note")
        #expect(loaded.notes.first?.tag == .idea)
        #expect(reopened.libraryState.collections.first?.name == "Research")
        #expect(loaded.collectionIDs == [collection.id])
    }
}
