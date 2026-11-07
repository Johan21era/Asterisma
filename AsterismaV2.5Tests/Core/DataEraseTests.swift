//  DataEraseTests.swift
//  AsterismaV2.5
//
//  Owner-testing reset: erasing must leave no books, sessions, goals, covers,
//  backups, or Mirage stratum behind, and a reopened store must start empty.

import Foundation
import Testing

@testable import AsterismaV2_5

@Suite("Data erase")
@MainActor
struct DataEraseTests {
    @Test("SQLite erase clears the store and reopens empty")
    func sqliteEraseClearsEverything() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let jsonURL = root.appendingPathComponent("library.json")
        let store = DataStore(fileURL: jsonURL, storageEngine: .sqlite)
        let book = Book(
            title: "Erase Me",
            author: "Test",
            fileURL: root.appendingPathComponent("erase-me.pdf"),
            fileType: .pdf,
            totalPages: 10
        )
        #expect(store.addBook(book))
        store.updateGoalSet(ReadingGoalSet(dailyPageTarget: 5))
        store.saveImmediately()
        #expect(store.books.count == 1)

        // Debris the reset must remove: covers, backups, and Mirage stratum.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("covers", isDirectory: true),
            withIntermediateDirectories: true)
        try Data("cover".utf8).write(to: root.appendingPathComponent("covers/test.jpg"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Backups", isDirectory: true),
            withIntermediateDirectories: true)
        try Data("backup".utf8).write(to: root.appendingPathComponent("Backups/test.sqlite3"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("mirage", isDirectory: true),
            withIntermediateDirectories: true)
        try Data("ledger".utf8).write(to: root.appendingPathComponent("mirage/test.db"))

        try store.eraseAllUserData()

        #expect(store.books.isEmpty)
        #expect(store.booksForArchive().isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Backups/test.sqlite3").path))
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("mirage/test.db").path))
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("covers/test.jpg").path))

        let reopened = DataStore(fileURL: jsonURL, storageEngine: .sqlite)
        #expect(reopened.books.isEmpty)
    }

    @Test("JSON erase clears the store and writes an empty library")
    func jsonEraseClearsEverything() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let jsonURL = root.appendingPathComponent("library.json")
        let store = DataStore(fileURL: jsonURL)
        let book = Book(
            title: "Erase Me Too",
            author: "Test",
            fileURL: root.appendingPathComponent("erase-me-too.pdf"),
            fileType: .pdf,
            totalPages: 4
        )
        #expect(store.addBook(book))
        store.saveImmediately()
        #expect(store.books.count == 1)

        try store.eraseAllUserData()

        #expect(store.books.isEmpty)
        let reopened = DataStore(fileURL: jsonURL)
        #expect(reopened.books.isEmpty)
    }
}
