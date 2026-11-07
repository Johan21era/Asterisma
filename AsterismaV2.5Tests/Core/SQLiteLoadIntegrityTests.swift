//  SQLiteLoadIntegrityTests.swift
//  Regression pins: an undecodable SQLite record must fail the load closed,
//  never be omitted from a "successful" load, and never be overwritten by a
//  later save that only knows about the surviving records.

import Foundation
import GRDB
import Testing
@testable import AsterismaV2_5

@Suite("SQLite load integrity", .serialized)
@MainActor
final class SQLiteLoadIntegrityTests {

    private func tempPaths() throws -> (json: URL, db: URL, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir.appendingPathComponent("library.json"),
                dir.appendingPathComponent("library.sqlite3"), dir)
    }

    private func makeBook(title: String) -> Book {
        Book(
            title: title,
            author: "A",
            fileURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).pdf"),
            fileType: .pdf,
            totalPages: 100)
    }

    private func corruptBookPayload(_ id: UUID, in db: LibraryDatabase) throws {
        try db.pool.write { database in
            try database.execute(
                sql: "UPDATE books SET payload_json = 'not-json' WHERE id = ?",
                arguments: [id.uuidString])
        }
    }

    private func corruptStatePayload(in db: LibraryDatabase) throws {
        try db.pool.write { database in
            try database.execute(
                sql: "UPDATE library_state SET payload_json = 'not-json' WHERE key = 'root'")
        }
    }

    private func bookPayload(_ id: UUID, in db: LibraryDatabase) throws -> String? {
        try db.pool.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT payload_json FROM books WHERE id = ?",
                arguments: [id.uuidString])
        }
    }

    private func statePayload(in db: LibraryDatabase) throws -> String? {
        try db.pool.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT payload_json FROM library_state WHERE key = 'root'")
        }
    }

    private func rowCount(_ table: String, in db: LibraryDatabase) throws -> Int {
        try db.pool.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
    }

    // MARK: - LibraryDatabase

    @Test("An undecodable book fails loadBooks instead of shrinking the library")
    func undecodableBookFailsLoad() throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.dir) }

        let db = try LibraryDatabase(url: paths.db)
        defer { try? db.close() }
        let good = makeBook(title: "Good")
        let bad = makeBook(title: "Corrupt")
        try db.importLibrary(books: [good, bad], state: LibraryState())
        try corruptBookPayload(bad.id, in: db)

        do {
            let books = try db.loadBooks()
            Issue.record("loadBooks returned \(books.count) book(s) instead of throwing")
        } catch let error as LibraryDatabaseError {
            guard case let .undecodableBook(id, _) = error else {
                Issue.record("Unexpected load error: \(error)")
                return
            }
            #expect(id == bad.id.uuidString)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        // The failed read must not have mutated or removed anything.
        #expect(try db.counts().books == 2)
    }

    @Test("An undecodable library-state row throws instead of loading defaults")
    func undecodableStateFailsLoad() throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.dir) }

        let db = try LibraryDatabase(url: paths.db)
        defer { try? db.close() }
        var goals = ReadingGoalSet.empty
        goals.dailyPageTarget = 30
        let state = LibraryState(
            goalSet: goals,
            collections: [BookCollection(name: "Kept Shelf")])
        try db.importLibrary(books: [makeBook(title: "Book")], state: state)
        try corruptStatePayload(in: db)

        do {
            let loaded = try db.loadState()
            Issue.record("loadState returned \(loaded) instead of throwing")
        } catch let error as LibraryDatabaseError {
            guard case .undecodableLibraryState = error else {
                Issue.record("Unexpected load error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(try rowCount("collections", in: db) == 1)
        #expect(try statePayload(in: db) == "not-json")
    }

    @Test("A database with no library-state row still loads an empty default")
    func absentStateIsNotCorruption() throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.dir) }

        let db = try LibraryDatabase(url: paths.db)
        defer { try? db.close() }
        let state = try db.loadState()
        #expect(state.goalSet == .empty)
        #expect(state.collections.isEmpty)
        #expect(state.earnedAchievements.isEmpty)
    }

    // MARK: - DataStore

    @Test("DataStore refuses to delete an undecodable book row")
    func dataStorePreservesUndecodableBook() throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.dir) }

        var goals = ReadingGoalSet.empty
        goals.dailyPageTarget = 25

        let store = DataStore(
            fileURL: paths.json, storageEngine: .sqlite, databaseURL: paths.db)
        let good = makeBook(title: "Good")
        let bad = makeBook(title: "Corrupt")
        store.addBook(good)
        store.addBook(bad)
        store.updateGoalSet(goals)
        store.saveImmediately()
        store.closeStorageForTesting()

        let raw = try LibraryDatabase(url: paths.db)
        try corruptBookPayload(bad.id, in: raw)
        try raw.close()

        let reopened = DataStore(
            fileURL: paths.json, storageEngine: .sqlite, databaseURL: paths.db)
        #expect(reopened.books.isEmpty)
        guard case let .degraded(message) = reopened.persistenceHealth else {
            Issue.record("Expected degraded health, got \(reopened.persistenceHealth)")
            return
        }
        #expect(message.contains("Saves are paused"))
        #expect(message.contains(bad.id.uuidString))

        // A normal mutation plus an explicit flush must not persist the empty
        // in-memory library over the database.
        reopened.addBook(makeBook(title: "New"))
        reopened.saveImmediately()
        guard case let .degraded(afterSave) = reopened.persistenceHealth else {
            Issue.record("Write attempt cleared the degraded state")
            return
        }
        #expect(afterSave.contains("Saves are paused"))
        reopened.closeStorageForTesting()

        let verify = try LibraryDatabase(url: paths.db)
        defer { try? verify.close() }
        #expect(try verify.counts().books == 2)
        #expect(try bookPayload(bad.id, in: verify) == "not-json")
        #expect(try bookPayload(good.id, in: verify) != nil)
    }

    @Test("DataStore refuses to overwrite an undecodable library-state row")
    func dataStorePreservesUndecodableState() throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.dir) }

        var goals = ReadingGoalSet.empty
        goals.dailyPageTarget = 42

        let store = DataStore(
            fileURL: paths.json, storageEngine: .sqlite, databaseURL: paths.db)
        let book = makeBook(title: "State Book")
        store.addBook(book)
        store.updateGoalSet(goals)
        _ = store.addCollection(name: "Kept Shelf")
        store.saveImmediately()
        store.closeStorageForTesting()

        let raw = try LibraryDatabase(url: paths.db)
        try corruptStatePayload(in: raw)
        let collectionsBefore = try rowCount("collections", in: raw)
        try raw.close()
        #expect(collectionsBefore == 1)

        let reopened = DataStore(
            fileURL: paths.json, storageEngine: .sqlite, databaseURL: paths.db)
        #expect(reopened.books.isEmpty)
        #expect(reopened.libraryState.goalSet == .empty)
        #expect(reopened.libraryState.collections.isEmpty)
        guard case let .degraded(message) = reopened.persistenceHealth else {
            Issue.record("Expected degraded health, got \(reopened.persistenceHealth)")
            return
        }
        #expect(message.contains("Saves are paused"))

        var changed = ReadingGoalSet.empty
        changed.dailyPageTarget = 1
        reopened.updateGoalSet(changed)
        reopened.saveImmediately()
        reopened.closeStorageForTesting()

        let verify = try LibraryDatabase(url: paths.db)
        defer { try? verify.close() }
        #expect(try statePayload(in: verify) == "not-json")
        #expect(try rowCount("collections", in: verify) == 1)
        #expect(try rowCount("books", in: verify) == 1)
    }

    @Test("Legacy bootstrap never runs over a database with an unreadable state row")
    func bootstrapDoesNotOverwriteCorruptState() throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.dir) }

        // A legacy JSON library exists, which is the bootstrap trigger.
        let legacy = DataStore(fileURL: paths.json)
        legacy.addBook(makeBook(title: "Legacy Book"))
        legacy.saveImmediately()

        let raw = try LibraryDatabase(url: paths.db)
        try raw.importLibrary(
            books: [],
            state: LibraryState(collections: [BookCollection(name: "Corrupt Shelf")]))
        try corruptStatePayload(in: raw)
        try raw.close()

        // Zero books but a state row means the store is not empty: bootstrap
        // must not delete the row and re-import over it.
        let store = DataStore(
            fileURL: paths.json, storageEngine: .sqlite, databaseURL: paths.db)
        guard case let .degraded(message) = store.persistenceHealth else {
            Issue.record("Expected degraded health, got \(store.persistenceHealth)")
            return
        }
        #expect(message.contains("Saves are paused"))
        store.saveImmediately()
        store.closeStorageForTesting()

        let verify = try LibraryDatabase(url: paths.db)
        defer { try? verify.close() }
        #expect(try statePayload(in: verify) == "not-json")
        #expect(try rowCount("books", in: verify) == 0)
    }

    @Test("An explicit archive restore clears the blocked-save state")
    func explicitRestoreRepairsBlockedStore() throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.dir) }

        let store = DataStore(
            fileURL: paths.json, storageEngine: .sqlite, databaseURL: paths.db)
        let original = makeBook(title: "Original")
        store.addBook(original)
        store.saveImmediately()
        store.closeStorageForTesting()

        let raw = try LibraryDatabase(url: paths.db)
        try corruptStatePayload(in: raw)
        try raw.close()

        let reopened = DataStore(
            fileURL: paths.json, storageEngine: .sqlite, databaseURL: paths.db)
        guard case .degraded = reopened.persistenceHealth else {
            Issue.record("Expected degraded health before the restore")
            return
        }

        let restoredBook = makeBook(title: "Restored")
        var restoredGoals = ReadingGoalSet.empty
        restoredGoals.dailyPageTarget = 10
        reopened.restoreState(
            from: [restoredBook],
            state: LibraryState(goalSet: restoredGoals,
                                collections: [BookCollection(name: "Restored Shelf")]))
        reopened.saveImmediately()
        reopened.closeStorageForTesting()

        let verify = try LibraryDatabase(url: paths.db)
        defer { try? verify.close() }
        let loadedBooks = try verify.loadBooks()
        #expect(loadedBooks.map(\.id) == [restoredBook.id])
        let loadedState = try verify.loadState()
        #expect(loadedState.goalSet.dailyPageTarget == 10)
        #expect(loadedState.collections.map(\.name) == ["Restored Shelf"])
    }
}
