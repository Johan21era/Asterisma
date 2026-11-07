//  LibraryPreservationTests.swift
//  Library Safety — Phase 2 gate pins.

import Foundation
import Testing
@testable import AsterismaV2_5

@Suite("Library Safety · Phase 2 preservation", .serialized)
@MainActor
final class LibraryPreservationTests {

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
            title: "Preserved \(index)",
            author: "A",
            fileURL: URL(fileURLWithPath: "/tmp/preserved-\(id).pdf"),
            fileType: .pdf,
            totalPages: 10)
    }

    private func makeDatabase(in dir: URL, books: [Book]) throws -> URL {
        let url = dir.appendingPathComponent("library.sqlite3")
        let db = try LibraryDatabase(url: url)
        try db.importLibrary(books: books, state: LibraryState())
        try db.close()
        return url
    }

    @Test("Preserve, verify, diagnose, and export a healthy store")
    func healthyPreservation() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbURL = try makeDatabase(in: dir, books: [makeBook(1), makeBook(2)])
        let service = try LibraryRecoveryService(
            root: dir.appendingPathComponent("LibraryRecovery"))
        let memory = Data("{\"memory\":true}".utf8)

        let preserved = try await service.preserve(
            incidentID: "inc_healthy",
            storeURL: dbURL,
            memorySnapshot: memory)
        #expect(preserved.files.contains { $0.role == .main })
        #expect(preserved.files.contains { $0.role == .memorySnapshot })
        #expect(preserved.combinedSHA256.count == 64)
        let reloaded = try await service.reloadPreserved(incidentID: "inc_healthy")
        #expect(reloaded.combinedSHA256 == preserved.combinedSHA256)

        let diagnosis = try await service.diagnose(incidentID: "inc_healthy")
        #expect(diagnosis.canOpenReadOnly)
        #expect(diagnosis.tableCounts?.books == 2)
        #expect(diagnosis.undecodableBooks == 0)
        #expect(diagnosis.canRebuildFromPayloads)
        #expect(diagnosis.canRecoverPageTimings)

        let export = dir.appendingPathComponent("export.sqlite3")
        try await service.export(incidentID: "inc_healthy", to: export)
        let inspection = try LibraryDatabase.inspectSnapshot(at: export)
        #expect(inspection.manifest.counts.books == 2)
        #expect(inspection.integrityMessages.isEmpty)

        let preservedMain = dir.appendingPathComponent(
            "LibraryRecovery/incidents/inc_healthy/preserved/library.sqlite3")
        let attrs = try FileManager.default.attributesOfItem(atPath: preservedMain.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("A destroyed store is preserved byte-for-byte and exported")
    func destroyedStoreIsEvidence() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbURL = try makeDatabase(in: dir, books: [makeBook(1)])
        let broken = Data([0x00, 0x01, 0x02, 0x03])
        try broken.write(to: dbURL)

        let service = try LibraryRecoveryService(
            root: dir.appendingPathComponent("LibraryRecovery"))
        let preserved = try await service.preserve(
            incidentID: "inc_broken",
            storeURL: dbURL,
            memorySnapshot: nil)
        #expect(preserved.files.first { $0.role == .main }?.bytes == 4)

        let diagnosis = try await service.diagnose(incidentID: "inc_broken")
        #expect(!diagnosis.canOpenReadOnly)
        #expect(!diagnosis.canRebuildFromPayloads)
        #expect(diagnosis.notes.contains("unreadable"))

        let export = dir.appendingPathComponent("broken-export.sqlite3")
        try await service.export(incidentID: "inc_broken", to: export)
        #expect(try Data(contentsOf: export) == broken)
    }

    @Test("An existing preserved copy is never overwritten")
    func preservationIsImmutable() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbURL = try makeDatabase(in: dir, books: [makeBook(1)])
        let recoveryRoot = dir.appendingPathComponent("LibraryRecovery")
        let service = try LibraryRecoveryService(root: recoveryRoot)
        let first = try await service.preserve(
            incidentID: "inc_once",
            storeURL: dbURL,
            memorySnapshot: nil)

        let db = try LibraryDatabase(url: dbURL)
        try db.saveAll(books: [makeBook(1), makeBook(2)], state: LibraryState())
        try db.close()

        let second = try await service.preserve(
            incidentID: "inc_once",
            storeURL: dbURL,
            memorySnapshot: nil)
        #expect(first.combinedSHA256 == second.combinedSHA256)

        let main = try LibraryStorePreserver.mainFileURL(
            root: recoveryRoot,
            incidentID: "inc_once",
            preserved: first)
        try Data("tamper".utf8).write(to: main)
        #expect(throws: LibraryPreservationError.self) {
            _ = try LibraryStorePreserver.loadAndVerify(
                root: recoveryRoot, incidentID: "inc_once")
        }
    }

    @Test("Export refuses to replace an existing file")
    func exportRefusesExisting() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbURL = try makeDatabase(in: dir, books: [makeBook(1)])
        let service = try LibraryRecoveryService(
            root: dir.appendingPathComponent("LibraryRecovery"))
        _ = try await service.preserve(
            incidentID: "inc_export",
            storeURL: dbURL,
            memorySnapshot: nil)

        let export = dir.appendingPathComponent("existing.sqlite3")
        try Data("existing".utf8).write(to: export)
        await #expect(throws: LibraryRecoveryServiceError.exportDestinationExists(export.path)) {
            _ = try await service.export(incidentID: "inc_export", to: export)
        }
        #expect(try Data(contentsOf: export) == Data("existing".utf8))
    }
}
