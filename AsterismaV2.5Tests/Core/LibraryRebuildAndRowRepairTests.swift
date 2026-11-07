//  LibraryRebuildAndRowRepairTests.swift
//  Library Safety — Phase 5 gate pins.

import Foundation
import GRDB
import Testing
@testable import AsterismaV2_5

@Suite("Library Safety · rebuild and row repair", .serialized)
@MainActor
final class LibraryRebuildAndRowRepairTests {

    private func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeBook(_ index: Int) -> Book {
        let id = UUID()
        let start = Date().addingTimeInterval(-1_000)
        var book = Book(
            id: id,
            title: "Rebuild \(index)",
            author: "A",
            fileURL: URL(fileURLWithPath: "/tmp/rebuild-\(id).pdf"),
            fileType: .pdf,
            totalPages: 50)
        book.sessions = [
            ReadingSession(
                bookID: id,
                startTime: start,
                endTime: start.addingTimeInterval(300),
                startPage: 0,
                endPage: 10,
                pageTimes: [
                    PageTiming(
                        pageNumber: 1,
                        startTime: start,
                        endTime: start.addingTimeInterval(30)),
                    PageTiming(
                        pageNumber: 2,
                        startTime: start.addingTimeInterval(30),
                        endTime: start.addingTimeInterval(60)),
                ])
        ]
        return book
    }

    private func makeDatabase(
        at url: URL,
        books: [Book],
        state: LibraryState = LibraryState()
    ) throws {
        let db = try LibraryDatabase(url: url)
        try db.importLibrary(books: books, state: state)
        try db.close()
    }

    @Test("Rebuild carries books, sessions, timings, and state")
    func rebuildHealthyStore() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.sqlite3")
        let destination = dir.appendingPathComponent("rebuilt.sqlite3")
        var state = LibraryState()
        state.collections = [BookCollection(name: "Recovered Shelf")]
        try makeDatabase(at: source, books: [makeBook(1), makeBook(2)], state: state)

        let result = try LibraryLogicalRebuilder.rebuild(
            sourceURL: source, destination: destination)
        #expect(result.rebuiltCounts.books == 2)
        #expect(result.rebuiltCounts.sessions == 2)
        #expect(result.rebuiltCounts.pageTimes == 4)
        #expect(result.stateDecoded)
        #expect(result.skippedBooks == 0)
        #expect(result.lostRows >= 0)

        let snap = try LibraryDatabase.inspectSnapshot(at: destination)
        #expect(snap.manifest.counts == result.rebuiltCounts)
        #expect(snap.manifest.quickCheck.lowercased() == "ok")
    }

    @Test("Rebuild skips an undecodable book and reports it")
    func rebuildSkipsBadPayload() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.sqlite3")
        let destination = dir.appendingPathComponent("rebuilt.sqlite3")
        try makeDatabase(at: source, books: [makeBook(1), makeBook(2)])

        let db = try LibraryDatabase(url: source)
        try db.pool.write { database in
            try database.execute(sql: "UPDATE books SET payload_json = 'not-json' WHERE rowid = 1")
        }
        try db.close()

        let result = try LibraryLogicalRebuilder.rebuild(
            sourceURL: source, destination: destination)
        #expect(result.rebuiltCounts.books == 1)
        #expect(result.skippedBooks == 1)
        #expect(result.notes.contains { $0.hasPrefix("books-skipped:") })
    }

    @Test("Orphan inventory exports, deletes, and undoes exact rows")
    func rowRepairRoundTrip() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let databaseURL = dir.appendingPathComponent("live.sqlite3")
        try makeDatabase(at: databaseURL, books: [makeBook(1)])

        // Deliberately bypass foreign keys to create the orphans the service
        // must find. The app's pool always enforces them, so this fixture uses
        // its own connection with enforcement disabled.
        var config = Configuration()
        config.foreignKeysEnabled = false
        let raw = try DatabaseQueue(path: databaseURL.path, configuration: config)
        try await raw.write { database in
            try database.execute(
                sql: """
                    INSERT INTO sessions
                    (id, book_id, start_time, end_time, start_page, end_page, payload_json)
                    VALUES ('orphan-session', 'missing-book', 0, 1, 0, 1, '{}')
                    """)
            try database.execute(
                sql: """
                    INSERT INTO page_times
                    (id, session_id, idx, page_number, start_time, end_time, payload_json)
                    VALUES ('orphan-timing', 'missing-session', 0, 1, 0, 1, '{}')
                    """)
        }
        try raw.close()

        let service = try LibraryRowRepairService(
            root: dir.appendingPathComponent("LibraryRecovery"))
        let inventory = try await service.inventory(databaseURL: databaseURL)
        #expect(inventory.contains { $0.table == "sessions" && $0.count == 1 })
        #expect(inventory.contains { $0.table == "page_times" && $0.count == 1 })

        let receipt = try await service.deleteOrphans(
            databaseURL: databaseURL, table: "page_times")
        #expect(receipt.deletedRows == 1)
        #expect(FileManager.default.fileExists(atPath: receipt.exportURL.path))

        let afterDelete = try await service.inventory(databaseURL: databaseURL)
        #expect(!afterDelete.contains { $0.table == "page_times" })

        let restored = try await service.undo(exportURL: receipt.exportURL)
        #expect(restored == 1)
        let afterUndo = try await service.inventory(databaseURL: databaseURL)
        #expect(afterUndo.contains { $0.table == "page_times" && $0.count == 1 })
    }
}
