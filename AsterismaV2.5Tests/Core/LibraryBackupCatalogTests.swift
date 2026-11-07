//  LibraryBackupCatalogTests.swift
//  Library Safety — Phase 3 gate pins.

import Foundation
import Testing
@testable import AsterismaV2_5

@Suite("Library Safety · Phase 3 backups", .serialized)
@MainActor
final class LibraryBackupCatalogTests {

    private func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeLibrary(in dir: URL, books: Int = 2) throws -> URL {
        let url = dir.appendingPathComponent("library.sqlite3")
        let db = try LibraryDatabase(url: url)
        let records = (0..<books).map { index in
            let id = UUID()
            return Book(
                id: id,
                title: "Backup \(index)",
                author: "A",
                fileURL: URL(fileURLWithPath: "/tmp/backup-\(id).pdf"),
                fileType: .pdf,
                totalPages: 10)
        }
        try db.importLibrary(books: records, state: LibraryState())
        try db.close()
        return url
    }

    private func makeBackup(
        source: URL,
        destination: URL,
        writeManifest: Bool = true
    ) throws -> LibrarySnapshotManifest {
        let db = try LibraryDatabase(url: source)
        defer { try? db.close() }
        let manifest = try db.makeConsistentSnapshot(to: destination)
        if writeManifest {
            try LibraryBackupManifestStore.write(manifest, for: destination)
        }
        return manifest
    }

    @Test("A manifest-backed snapshot is cataloged as verified")
    func verifiedBackup() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeLibrary(in: dir)
        let backups = dir.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let url = backups.appendingPathComponent("library-one.sqlite3")
        let manifest = try makeBackup(source: source, destination: url)

        let backup = LibraryBackupCatalog.inspect(url)
        #expect(backup.state == .verified)
        #expect(backup.manifest?.sha256 == manifest.sha256)
        #expect(backup.manifest?.counts.books == 2)
        #expect(backup.failureCode == nil)

        let drill = LibraryBackupVerifier.verify(backup, level: .drill)
        #expect(drill.state == .verified)
        #expect(drill.inspection?.manifest.counts.books == 2)
    }

    @Test("A changed backup fails its manifest hash")
    func tamperedBackupIsRejected() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeLibrary(in: dir)
        let backups = dir.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let url = backups.appendingPathComponent("library-tampered.sqlite3")
        _ = try makeBackup(source: source, destination: url)

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x00, 0x01, 0x02]))
        try handle.close()

        let backup = LibraryBackupCatalog.inspect(url)
        #expect(backup.state == .failed)
        #expect(backup.failureCode == "LR-014")
        #expect(!backup.isVerified)
    }

    @Test("A legacy snapshot is migrated without changing the database")
    func legacyMigration() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeLibrary(in: dir)
        let backups = dir.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let url = backups.appendingPathComponent("library-legacy.sqlite3")
        let manifest = try makeBackup(source: source, destination: url, writeManifest: false)
        let before = try LibraryFileSync.sha256(of: url)

        let legacy = LibraryBackupCatalog.inspect(url)
        #expect(legacy.state == .legacy)
        #expect(legacy.manifest == nil)

        let migrated = try LibraryBackupCatalog.migrateLegacy(legacy)
        #expect(migrated.state == .verified)
        #expect(migrated.manifest?.sha256 == manifest.sha256)
        #expect(try LibraryFileSync.sha256(of: url) == before)
    }

    @Test("Retention keeps ten daily and five safety snapshots")
    func retention() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeLibrary(in: dir, books: 1)
        let backups = dir.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)

        for index in 0..<12 {
            try makeBackup(
                source: source,
                destination: backups.appendingPathComponent("library-\(index).sqlite3"))
        }
        for index in 0..<7 {
            try makeBackup(
                source: source,
                destination: backups.appendingPathComponent(
                    "sentinel-pre-repair-\(index).sqlite3"))
        }

        _ = LibraryBackupCatalog.prune(directory: backups, keepDaily: 10, keepSafety: 5)
        let remaining = LibraryBackupCatalog.scan(directory: backups).backups
        #expect(remaining.filter { !$0.isSafetySnapshot }.count == 10)
        #expect(remaining.filter(\.isSafetySnapshot).count == 5)
    }

    @Test("The last verified backup is never deleted by retention")
    func lastVerifiedIsProtected() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try makeLibrary(in: dir, books: 1)
        let backups = dir.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let only = backups.appendingPathComponent("only.sqlite3")
        _ = try makeBackup(source: source, destination: only)

        _ = LibraryBackupCatalog.prune(directory: backups, keepDaily: 0, keepSafety: 0)
        #expect(FileManager.default.fileExists(atPath: only.path))
        #expect(LibraryBackupCatalog.scan(directory: backups).verifiedCount == 1)
    }
}
