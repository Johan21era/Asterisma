//  LibraryRecoveryFlowTests.swift
//  Library Safety — Phase 4 end-to-end flow.

import Foundation
import Testing
@testable import AsterismaV2_5

@Suite("Library Safety · recovery flow", .serialized)
@MainActor
final class LibraryRecoveryFlowTests {

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
            title: "Flow \(index)",
            author: "A",
            fileURL: URL(fileURLWithPath: "/tmp/flow-\(id).pdf"),
            fileType: .pdf,
            totalPages: 10)
    }

    private func makeBackup(
        dataRoot: URL,
        title: String,
        books: Int
    ) throws -> URL {
        let backupDir = dataRoot.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        let sourceURL = dataRoot.appendingPathComponent("backup-source.sqlite3")
        let db = try LibraryDatabase(url: sourceURL)
        try db.importLibrary(
            books: (0..<books).map { index in
                var book = makeBook(index)
                book.title = "\(title) \(index)"
                return book
            },
            state: LibraryState())
        let destination = backupDir.appendingPathComponent("library-flow.sqlite3")
        let manifest = try db.makeConsistentSnapshot(to: destination)
        try db.close()
        try LibraryBackupManifestStore.write(manifest, for: destination)
        return destination
    }

    @Test("Read-only condition freezes, preserves, diagnoses, and offers options")
    func preservationFlow() async throws {
        let root = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = DataStore(
            fileURL: root.appendingPathComponent("library.json"),
            storageEngine: .sqlite,
            databaseURL: root.appendingPathComponent("library.sqlite3"))
        store.addBook(makeBook(0))
        store.saveImmediately()

        let recoveryRoot = root.appendingPathComponent("LibraryRecovery")
        let incidentStore = try LibraryIncidentStore(root: recoveryRoot)
        let service = try LibraryRecoveryService(root: recoveryRoot)
        let coordinator = LibraryHealthCoordinator(
            store: incidentStore,
            host: store,
            service: service,
            dataRoot: root,
            swap: try LibrarySwapCoordinator(root: recoveryRoot))

        await coordinator.handleStorageCondition(
            .readOnly(engine: .sqlite, code: "LR-002", message: "test"))

        #expect(coordinator.incident?.state == .awaitingDecision)
        #expect(coordinator.incident?.preserved != nil)
        #expect(coordinator.incident?.diagnosis?.canOpenReadOnly == true)
        #expect(coordinator.incident?.options.contains { $0.kind == .exportCopy } == true)
        #expect(store.isFrozenForRecovery)
    }

    @Test("Assisted restore resolves only after verification")
    func assistedRestore() async throws {
        let root = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = DataStore(
            fileURL: root.appendingPathComponent("library.json"),
            storageEngine: .sqlite,
            databaseURL: root.appendingPathComponent("library.sqlite3"))
        store.addBook(makeBook(0))
        store.saveImmediately()
        _ = try makeBackup(dataRoot: root, title: "Replacement", books: 2)

        let recoveryRoot = root.appendingPathComponent("LibraryRecovery")
        let incidentStore = try LibraryIncidentStore(root: recoveryRoot)
        let service = try LibraryRecoveryService(root: recoveryRoot)
        let coordinator = LibraryHealthCoordinator(
            store: incidentStore,
            host: store,
            service: service,
            dataRoot: root,
            swap: try LibrarySwapCoordinator(root: recoveryRoot))

        await coordinator.handleStorageCondition(
            .readOnly(engine: .sqlite, code: "LR-002", message: "test"))
        let backup = try #require(coordinator.backups.first { $0.isVerified })

        await coordinator.restore(backupID: backup.id, confirmation: "RESTORE")

        #expect(coordinator.incident?.state == .resolved)
        #expect(coordinator.incident?.readOnly == false)
        #expect(coordinator.lastReceipt?.outcome == .succeeded)
        #expect(store.storageCondition == .healthy(engine: .sqlite))
        #expect(store.books.count == 2)
        #expect(store.books.allSatisfy { $0.title.hasPrefix("Replacement") })
    }

    @Test("A wrong confirmation never starts a restore")
    func confirmationMismatch() async throws {
        let root = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = DataStore(
            fileURL: root.appendingPathComponent("library.json"),
            storageEngine: .sqlite,
            databaseURL: root.appendingPathComponent("library.sqlite3"))
        store.addBook(makeBook(0))
        store.saveImmediately()
        _ = try makeBackup(dataRoot: root, title: "Replacement", books: 2)

        let recoveryRoot = root.appendingPathComponent("LibraryRecovery")
        let incidentStore = try LibraryIncidentStore(root: recoveryRoot)
        let service = try LibraryRecoveryService(root: recoveryRoot)
        let coordinator = LibraryHealthCoordinator(
            store: incidentStore,
            host: store,
            service: service,
            dataRoot: root,
            swap: try LibrarySwapCoordinator(root: recoveryRoot))
        await coordinator.handleStorageCondition(
            .readOnly(engine: .sqlite, code: "LR-002", message: "test"))
        let backup = try #require(coordinator.backups.first { $0.isVerified })

        await coordinator.restore(backupID: backup.id, confirmation: "restore")
        #expect(coordinator.incident?.state == .awaitingDecision)
        #expect(coordinator.lastReceipt == nil)
        #expect(store.books.count == 1)
    }
}
