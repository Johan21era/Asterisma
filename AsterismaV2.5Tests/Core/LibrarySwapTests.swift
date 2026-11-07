//  LibrarySwapTests.swift
//  Library Safety — Phase 4 gate pins.
//
//  These tests operate below DataStore: the store is already closed when the
//  swap begins. The important property is that both a crash and a failed
//  verification leave a recoverable original behind.

import Foundation
import Testing
@testable import AsterismaV2_5

@Suite("Library Safety · Phase 4 swap", .serialized)
@MainActor
final class LibrarySwapTests {

    private func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeDatabase(
        at url: URL,
        title: String,
        books: Int = 1
    ) throws {
        let db = try LibraryDatabase(url: url)
        let records = (0..<books).map { index in
            let id = UUID()
            return Book(
                id: id,
                title: "\(title) \(index)",
                author: "A",
                fileURL: URL(fileURLWithPath: "/tmp/\(title)-\(id).pdf"),
                fileType: .pdf,
                totalPages: 10)
        }
        try db.importLibrary(books: records, state: LibraryState())
        try db.close()
    }

    private func counts(of url: URL) throws -> LibraryTableCounts {
        try LibraryDatabase.inspectSnapshot(at: url).manifest.counts
    }

    @Test("Restore verifies the new store and preserves the original")
    func successfulRestore() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let live = dir.appendingPathComponent("live.sqlite3")
        let backup = dir.appendingPathComponent("backup.sqlite3")
        try makeDatabase(at: live, title: "Old", books: 1)
        try makeDatabase(at: backup, title: "New", books: 3)

        let before = try LibraryFileSync.sha256(of: live)
        let after = try LibraryFileSync.sha256(of: backup)
        let coordinator = try LibrarySwapCoordinator(
            root: dir.appendingPathComponent("LibraryRecovery"))

        let result = try await coordinator.restore(
            incidentID: "inc_swap",
            backupID: "bak_swap",
            backupURL: backup,
            liveURL: live,
            expectedBeforeSHA256: before,
            expectedAfterSHA256: after)

        #expect(result.intent.stage == .renamed)
        #expect(try LibraryFileSync.sha256(of: live) == after)
        #expect(try counts(of: live).books == 3)
        #expect(FileManager.default.fileExists(atPath: result.preRestoreURL.path))
        #expect(try counts(of: result.preRestoreURL).books == 1)

        let verification = LibraryRecoveryVerifier.verify(
            liveURL: live,
            expectedCounts: try counts(of: backup))
        #expect(LibraryRecoveryVerifier.isPassed(verification))
    }

    @Test("Rollback restores the original after a failed verification")
    func rollbackAfterFailedVerification() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let live = dir.appendingPathComponent("live.sqlite3")
        let backup = dir.appendingPathComponent("backup.sqlite3")
        try makeDatabase(at: live, title: "Original", books: 1)
        try makeDatabase(at: backup, title: "Replacement", books: 2)

        let before = try LibraryFileSync.sha256(of: live)
        let after = try LibraryFileSync.sha256(of: backup)
        let coordinator = try LibrarySwapCoordinator(
            root: dir.appendingPathComponent("LibraryRecovery"))
        _ = try await coordinator.restore(
            incidentID: "inc_rollback",
            backupID: "bak_rollback",
            backupURL: backup,
            liveURL: live,
            expectedBeforeSHA256: before,
            expectedAfterSHA256: after)

        _ = try await coordinator.rollback(liveURL: live)
        #expect(try LibraryFileSync.sha256(of: live) == before)
        #expect(try counts(of: live).books == 1)
        let intent = try #require(await coordinator.currentIntent())
        #expect(intent.stage == .rolledBack)
    }

    @Test("A missing live store and a preserved original reconcile to rolled back")
    func reconcileRollsBack() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let live = dir.appendingPathComponent("live.sqlite3")
        let backup = dir.appendingPathComponent("backup.sqlite3")
        let recoveryRoot = dir.appendingPathComponent("LibraryRecovery")
        try makeDatabase(at: live, title: "Original", books: 1)
        try makeDatabase(at: backup, title: "Replacement", books: 2)

        let before = try LibraryFileSync.sha256(of: live)
        let after = try LibraryFileSync.sha256(of: backup)
        let coordinator = try LibrarySwapCoordinator(root: recoveryRoot)
        let result = try await coordinator.restore(
            incidentID: "inc_reconcile",
            backupID: "bak_reconcile",
            backupURL: backup,
            liveURL: live,
            expectedBeforeSHA256: before,
            expectedAfterSHA256: after)

        // Simulate a crash after the rename: the new live file is present and
        // the pre-restore original is still on disk.
        let outcome = await coordinator.reconcile()
        guard case .completed = outcome else {
            Issue.record("expected completed, got \(outcome)")
            return
        }

        // Now simulate a crash with an unknown live file but an intact original.
        try FileManager.default.removeItem(at: live)
        try Data("unknown live bytes".utf8).write(to: live)
        let rolledBack = await coordinator.reconcile()
        guard case .rolledBack = rolledBack else {
            Issue.record("expected rolledBack, got \(rolledBack)")
            return
        }
        #expect(try LibraryFileSync.sha256(of: live) == before)
        #expect(FileManager.default.fileExists(atPath: result.preRestoreURL.path) == false)
    }

    @Test("A hash mismatch refuses to touch the live store")
    func hashMismatchRefuses() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let live = dir.appendingPathComponent("live.sqlite3")
        let backup = dir.appendingPathComponent("backup.sqlite3")
        try makeDatabase(at: live, title: "Original", books: 1)
        try makeDatabase(at: backup, title: "Replacement", books: 2)
        let before = try LibraryFileSync.sha256(of: live)
        let coordinator = try LibrarySwapCoordinator(
            root: dir.appendingPathComponent("LibraryRecovery"))

        await #expect(throws: LibrarySwapError.self) {
            _ = try await coordinator.restore(
                incidentID: "inc_bad_hash",
                backupID: "bak_bad_hash",
                backupURL: backup,
                liveURL: live,
                expectedBeforeSHA256: String(repeating: "0", count: 64),
                expectedAfterSHA256: String(repeating: "0", count: 64))
        }
        let intent = await coordinator.currentIntent()
        #expect(try LibraryFileSync.sha256(of: live) == before)
        #expect(intent == nil)
    }
}
