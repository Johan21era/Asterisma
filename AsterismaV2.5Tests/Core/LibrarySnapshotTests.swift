//  LibrarySnapshotTests.swift
//  Library Safety — Phase 0 gate pins.
//
//  G0 is deliberately small: a snapshot must be one consistent file, must open
//  read-only with exact counts, must never overwrite an existing restore point,
//  and the live store must freeze and reopen through one connection.

import Foundation
import Testing
@testable import AsterismaV2_5

@Suite("Library Safety · Phase 0 snapshots", .serialized)
@MainActor
final class LibrarySnapshotTests {

    private func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeBook(_ index: Int) -> Book {
        let id = UUID()
        return Book(
            id: id,
            title: "Snapshot \(index)",
            author: "A",
            fileURL: URL(fileURLWithPath: "/tmp/snapshot-\(id.uuidString).pdf"),
            fileType: .pdf,
            totalPages: 100)
    }

    @Test("Snapshot opens read-only with the live counts and a matching hash")
    func snapshotRoundTrip() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbURL = dir.appendingPathComponent("library.sqlite3")
        let db = try LibraryDatabase(url: dbURL)
        try db.importLibrary(
            books: [makeBook(1), makeBook(2)],
            state: LibraryState())
        try db.close()

        let live = try LibraryDatabase(url: dbURL)
        defer { try? live.close() }
        let snapshotURL = dir.appendingPathComponent("Backups/phase0.sqlite3")
        let manifest = try live.makeConsistentSnapshot(to: snapshotURL)

        #expect(FileManager.default.fileExists(atPath: snapshotURL.path))
        #expect(manifest.sha256 == (try LibraryFileSync.sha256(of: snapshotURL)))
        #expect(manifest.counts.books == 2)
        #expect(manifest.counts.sessions == 0)
        #expect(manifest.quickCheck.lowercased() == "ok")
        #expect(manifest.foreignKeyViolations == 0)
        #expect(!FileManager.default.fileExists(
            atPath: snapshotURL.path + "-wal"))

        let inspection = try LibraryDatabase.inspectSnapshot(
            at: snapshotURL, fullIntegrity: true)
        #expect(inspection.manifest.sha256 == manifest.sha256)
        #expect(inspection.missingTables.isEmpty)
        #expect(inspection.integrityMessages.isEmpty)
        #expect(inspection.unexpectedTables.isEmpty)
    }

    @Test("A snapshot never overwrites an existing restore point")
    func snapshotRefusesDestination() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbURL = dir.appendingPathComponent("library.sqlite3")
        let db = try LibraryDatabase(url: dbURL)
        try db.importLibrary(books: [makeBook(1)], state: LibraryState())
        try db.close()

        let live = try LibraryDatabase(url: dbURL)
        defer { try? live.close() }
        let snapshotURL = dir.appendingPathComponent("existing.sqlite3")
        let sentinel = Data("do not replace".utf8)
        try sentinel.write(to: snapshotURL)

        #expect(throws: LibrarySnapshotError.destinationExists(snapshotURL.path)) {
            _ = try live.makeConsistentSnapshot(to: snapshotURL)
        }
        #expect(try Data(contentsOf: snapshotURL) == sentinel)
    }

    @Test("A committed write is present in the next snapshot")
    func committedWriteIsInSnapshot() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbURL = dir.appendingPathComponent("library.sqlite3")
        let db = try LibraryDatabase(url: dbURL)
        defer { try? db.close() }
        try db.importLibrary(books: [makeBook(1)], state: LibraryState())

        var second = makeBook(2)
        second.title = "Committed after first save"
        try db.saveAll(books: [makeBook(1), second], state: LibraryState())

        let snapshotURL = dir.appendingPathComponent("committed.sqlite3")
        let manifest = try db.makeConsistentSnapshot(to: snapshotURL)
        #expect(manifest.counts.books == 2)

        let inspection = try LibraryDatabase.inspectSnapshot(at: snapshotURL)
        #expect(inspection.manifest.counts.books == 2)
        #expect(inspection.integrityMessages.isEmpty)
    }

    @Test("Checkpoint goes through the live pool and truncates the WAL")
    func checkpointThroughLivePool() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = DataStore(
            fileURL: dir.appendingPathComponent("library.json"),
            storageEngine: .sqlite,
            databaseURL: dir.appendingPathComponent("library.sqlite3"))
        store.addBook(makeBook(1))
        store.saveImmediately()

        #expect(await store.performCheckpoint())
        store.closeStorageForTesting()

        let wal = dir.appendingPathComponent("library.sqlite3-wal")
        let attrs = try? FileManager.default.attributesOfItem(atPath: wal.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        #expect(size == 0)
    }

    @Test("Freeze drains and closes; reopen replaces memory from disk")
    func freezeAndReopen() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = DataStore(
            fileURL: dir.appendingPathComponent("library.json"),
            storageEngine: .sqlite,
            databaseURL: dir.appendingPathComponent("library.sqlite3"))
        store.addBook(makeBook(1))
        store.saveImmediately()
        #expect(store.storageCondition == .healthy(engine: .sqlite))

        let token = try await store.freezeForRecovery(incidentID: "inc-test")
        #expect(store.isFrozenForRecovery)
        #expect(store.storageCondition == .recovering(incidentID: "inc-test"))

        // This mutation must stay in memory only while frozen.
        store.addBook(makeBook(2))
        store.saveImmediately()

        try await store.reopenAfterRecovery(token: token)
        #expect(!store.isFrozenForRecovery)
        #expect(store.storageCondition == .healthy(engine: .sqlite))
        #expect(store.books.count == 1)

        store.addBook(makeBook(3))
        store.saveImmediately()

        let reopened = DataStore(
            fileURL: dir.appendingPathComponent("library.json"),
            storageEngine: .sqlite,
            databaseURL: dir.appendingPathComponent("library.sqlite3"))
        #expect(reopened.books.count == 2)
    }
}
