//  LibrarySnapshot.swift
//  Library Safety — Phase 0
//
//  A backup is a snapshot plus evidence. This file owns:
//    • the durable file primitives (full fsync, directory fsync, streaming hash);
//    • a read-only inspector for snapshots and preserved copies;
//    • the manifest that records what the snapshot contains;
//    • the consistent-snapshot entry point on LibraryDatabase.
//
//  The operator is `VACUUM INTO`, not a copy of the main file. SQLite writes a
//  new database containing the committed state (including committed WAL pages)
//  without exposing a half-written file at the destination.

import CryptoKit
import Darwin
import Foundation
import GRDB

// MARK: - Errors

nonisolated enum LibrarySnapshotError: LocalizedError, Equatable {
    case destinationExists(String)
    case unreadableStore(String)
    case insufficientSpace(required: Int64, available: Int64)
    case snapshotFailed(String)
    case manifestFailed(String)

    var errorDescription: String? {
        switch self {
        case let .destinationExists(path):
            return "A snapshot already exists at \(path)."
        case let .unreadableStore(path):
            return "The database at \(path) could not be opened read-only."
        case let .insufficientSpace(required, available):
            return "Not enough free space for a safe snapshot: need \(required) bytes, have \(available)."
        case let .snapshotFailed(message):
            return "The consistent snapshot failed: \(message)"
        case let .manifestFailed(message):
            return "The snapshot manifest could not be built: \(message)"
        }
    }
}

// MARK: - Counts

/// Row counts for every table the app owns. Kept explicit so an unexpected
/// table is evidence, not silently ignored.
nonisolated struct LibraryTableCounts: Codable, Hashable, Sendable {
    var books: Int = 0
    var sessions: Int = 0
    var pageTimes: Int = 0
    var collections: Int = 0
    var bookCollections: Int = 0
    var notes: Int = 0
    var achievements: Int = 0
    var libraryStateRows: Int = 0
    var weatherSnapshots: Int = 0
    var audioProfiles: Int = 0
    var behaviorEvents: Int = 0
    var applicationSessions: Int = 0
    var inactivityRecords: Int = 0
    var deviceStateEvents: Int = 0
    var meta: Int = 0

    static let tableMap: [(table: String, keyPath: WritableKeyPath<LibraryTableCounts, Int>)] = [
        ("books", \.books),
        ("sessions", \.sessions),
        ("page_times", \.pageTimes),
        ("collections", \.collections),
        ("book_collections", \.bookCollections),
        ("notes", \.notes),
        ("achievements", \.achievements),
        ("library_state", \.libraryStateRows),
        ("weather_snapshots", \.weatherSnapshots),
        ("audio_profiles", \.audioProfiles),
        ("behavior_events", \.behaviorEvents),
        ("application_sessions", \.applicationSessions),
        ("inactivity_records", \.inactivityRecords),
        ("device_state_events", \.deviceStateEvents),
        ("meta", \.meta),
    ]

    static var knownTableNames: Set<String> {
        Set(tableMap.map(\.table))
    }

    var totalRows: Int {
        Self.tableMap.reduce(0) { $0 + self[keyPath: $1.keyPath] }
    }

    var asDictionary: [String: Int] {
        Dictionary(uniqueKeysWithValues: Self.tableMap.map {
            ($0.table, self[keyPath: $0.keyPath])
        })
    }
}

// MARK: - Manifest

nonisolated struct LibrarySnapshotManifest: Codable, Hashable, Sendable {
    static let currentFormatVersion = 1

    var formatVersion: Int
    var createdAt: Date
    var appVersion: String
    var appBuild: String
    var sha256: String
    var bytes: Int64
    var pageCount: Int
    var pageSize: Int
    var freelistCount: Int
    var journalMode: String
    var userVersion: Int
    var tableNames: [String]
    var counts: LibraryTableCounts
    var quickCheck: String
    var foreignKeyViolations: Int
}

// MARK: - Inspection

nonisolated struct LibrarySnapshotInspection: Codable, Hashable, Sendable {
    var manifest: LibrarySnapshotManifest
    var missingTables: [String]
    var unexpectedTables: [String]
    var integrityMessages: [String]

    var isStructurallyUsable: Bool {
        missingTables.isEmpty && integrityMessages.isEmpty
    }
}

// MARK: - Durable file primitives

nonisolated enum LibraryFileSync {

    /// `fsync` alone does not guarantee the platter on all macOS hardware.
    /// `F_FULLFSYNC` does; fall back only when the volume rejects it.
    static func fsyncFile(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw LibrarySnapshotError.snapshotFailed(
                "open \(url.lastPathComponent) failed: errno \(errno)")
        }
        defer { _ = Darwin.close(descriptor) }

        if fcntl(descriptor, F_FULLFSYNC) == -1 {
            if errno == EINVAL || errno == ENOTSUP {
                if fsync(descriptor) == -1 {
                    throw LibrarySnapshotError.snapshotFailed(
                        "fsync \(url.lastPathComponent) failed: errno \(errno)")
                }
            } else {
                throw LibrarySnapshotError.snapshotFailed(
                    "F_FULLFSYNC \(url.lastPathComponent) failed: errno \(errno)")
            }
        }
    }

    static func fsyncDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else {
            throw LibrarySnapshotError.snapshotFailed(
                "open directory \(url.lastPathComponent) failed: errno \(errno)")
        }
        defer { _ = Darwin.close(descriptor) }

        if fcntl(descriptor, F_FULLFSYNC) == -1 {
            if errno == EINVAL || errno == ENOTSUP {
                if fsync(descriptor) == -1 {
                    throw LibrarySnapshotError.snapshotFailed(
                        "fsync directory \(url.lastPathComponent) failed: errno \(errno)")
                }
            } else {
                throw LibrarySnapshotError.snapshotFailed(
                    "F_FULLFSYNC directory \(url.lastPathComponent) failed: errno \(errno)")
            }
        }
    }

    /// Streaming SHA-256. Never loads a multi-gigabyte store into memory.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The factor of two covers the new snapshot while the live store remains.
    /// `VACUUM INTO` also needs temporary space for its new database.
    static func requireSnapshotSpace(for storeURL: URL, destinationDirectory: URL) throws {
        let values = try storeURL.resourceValues(forKeys: [.fileSizeKey])
        let bytes = Int64(values.fileSize ?? 0)
        let required = max(bytes * 2 + 64 * 1_048_576, 128 * 1_048_576)

        let destinationValues = try destinationDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available = destinationValues.volumeAvailableCapacityForImportantUsage ?? 0
        guard available >= required else {
            throw LibrarySnapshotError.insufficientSpace(
                required: required, available: available)
        }
    }
}

// MARK: - Read-only inspector

/// Opens a snapshot as data, never as code. No migration runs, no extension
/// loads, no schema SQL from the snapshot is executed, and the connection is
/// query-only.
nonisolated final class LibraryReadOnlyConnection {
    let url: URL
    let queue: DatabaseQueue
    private var scratchDirectory: URL?

    init(url: URL) throws {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LibrarySnapshotError.unreadableStore(url.path)
        }

        do {
            queue = try Self.openQueue(at: url, readonly: true)
            scratchDirectory = nil
        } catch {
            // A WAL database that has no -shm cannot be opened read-only: SQLite
            // needs a writable shared-memory index. Work on a disposable copy
            // instead. The original is never opened read-write.
            do {
                let scratch = try Self.makeScratchCopy(of: url)
                self.scratchDirectory = scratch
                let copyURL = scratch.appendingPathComponent(url.lastPathComponent)
                queue = try Self.openQueue(at: copyURL, readonly: false)
            } catch {
                throw LibrarySnapshotError.unreadableStore(
                    "\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    deinit {
        try? queue.close()
        if let scratchDirectory {
            try? FileManager.default.removeItem(at: scratchDirectory)
        }
    }

    func close() {
        try? queue.close()
        if let scratchDirectory {
            try? FileManager.default.removeItem(at: scratchDirectory)
            self.scratchDirectory = nil
        }
    }

    private static func openQueue(at url: URL, readonly: Bool) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.readonly = readonly
        configuration.busyMode = .timeout(2)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA trusted_schema = OFF")
            try db.execute(sql: "PRAGMA query_only = ON")
        }
        return try DatabaseQueue(path: url.path, configuration: configuration)
    }

    private static func makeScratchCopy(of url: URL) throws -> URL {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryInspection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let copyURL = scratch.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: copyURL)
        for suffix in ["-wal", "-shm"] {
            let source = URL(fileURLWithPath: url.path + suffix)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try FileManager.default.copyItem(
                at: source,
                to: URL(fileURLWithPath: copyURL.path + suffix))
        }
        return scratch
    }

    func inspect(fullIntegrity: Bool = false) throws -> LibrarySnapshotInspection {
        try queue.read { db in
            let tableNames = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
            let known = LibraryTableCounts.knownTableNames
            let present = Set(tableNames)
            let missing = known.subtracting(present).sorted()
            let unexpected = present
                .filter {
                    !$0.hasPrefix("sqlite_")
                        && !$0.hasPrefix("grdb_")
                        && !known.contains($0)
                }
                .sorted()

            var counts = LibraryTableCounts()
            for entry in LibraryTableCounts.tableMap where present.contains(entry.table) {
                let value = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM \(entry.table)") ?? 0
                counts[keyPath: entry.keyPath] = value
            }

            let quickRows = try String.fetchAll(db, sql: "PRAGMA quick_check")
            let quickCheck = quickRows.joined(separator: "; ")

            let foreignKeyRows = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
            let integrityMessages: [String]
            if fullIntegrity {
                integrityMessages = try String.fetchAll(
                    db, sql: "PRAGMA integrity_check")
                    .filter { $0.lowercased() != "ok" }
            } else {
                integrityMessages = quickCheck.lowercased() == "ok" ? [] : [quickCheck]
            }

            let pageCount = try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0
            let pageSize = try Int.fetchOne(db, sql: "PRAGMA page_size") ?? 0
            let freelistCount = try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
            let journalMode = try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "unknown"
            let userVersion = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let hash = try LibraryFileSync.sha256(of: url)

            let info = Bundle.main.infoDictionary
            let manifest = LibrarySnapshotManifest(
                formatVersion: LibrarySnapshotManifest.currentFormatVersion,
                createdAt: Date(),
                appVersion: (info?["CFBundleShortVersionString"] as? String) ?? "unknown",
                appBuild: (info?["CFBundleVersion"] as? String) ?? "unknown",
                sha256: hash,
                bytes: bytes,
                pageCount: pageCount,
                pageSize: pageSize,
                freelistCount: freelistCount,
                journalMode: journalMode,
                userVersion: userVersion,
                tableNames: tableNames.filter { !$0.hasPrefix("sqlite_") },
                counts: counts,
                quickCheck: quickCheck,
                foreignKeyViolations: foreignKeyRows.count)

            return LibrarySnapshotInspection(
                manifest: manifest,
                missingTables: missing,
                unexpectedTables: unexpected,
                integrityMessages: integrityMessages)
        }
    }

    func tableCounts() throws -> LibraryTableCounts {
        try inspect().manifest.counts
    }

    /// `PRAGMA foreign_key_check` rows are grouped by table. Only table names
    /// from the known schema are returned; anything else is omitted.
    func foreignKeyViolationCounts() throws -> [String: Int] {
        try queue.read { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
            var counts: [String: Int] = [:]
            for row in rows {
                let table: String = row["table"]
                counts[table, default: 0] += 1
            }
            return counts
        }
    }
}

// MARK: - Live database snapshot

extension LibraryDatabase {

    /// A single consistent snapshot. `VACUUM INTO` sees one committed state and
    /// writes it to a fresh file; the live file is never copied while WAL is
    /// pending. The temporary file is fsynced, renamed on the same volume, then
    /// the directory is fsynced.
    @discardableResult
    func makeConsistentSnapshot(to destination: URL) throws -> LibrarySnapshotManifest {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw LibrarySnapshotError.destinationExists(destination.path)
        }

        try LibraryFileSync.requireSnapshotSpace(
            for: dbURL, destinationDirectory: directory)

        let temporary = directory.appendingPathComponent(
            ".snapshot-\(UUID().uuidString).sqlite3")
        defer {
            if FileManager.default.fileExists(atPath: temporary.path) {
                try? FileManager.default.removeItem(at: temporary)
            }
        }

        do {
            try pool.writeWithoutTransaction { db in
                do {
                    try db.execute(
                        sql: "VACUUM INTO ?",
                        arguments: [temporary.path])
                } catch {
                    // Some SQLite builds only accept a literal in VACUUM INTO.
                    // Remove any partial output before the one fallback attempt.
                    if FileManager.default.fileExists(atPath: temporary.path) {
                        try? FileManager.default.removeItem(at: temporary)
                    }
                    // Quote the path as a SQL string; never concatenate raw text.
                    let quoted = temporary.path.replacingOccurrences(of: "'", with: "''")
                    try db.execute(sql: "VACUUM INTO '\(quoted)'")
                }
            }
        } catch {
            throw LibrarySnapshotError.snapshotFailed(error.localizedDescription)
        }

        try LibraryFileSync.fsyncFile(temporary)

        do {
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            throw LibrarySnapshotError.snapshotFailed(
                "could not publish snapshot: \(error.localizedDescription)")
        }
        try LibraryFileSync.fsyncDirectory(directory)

        do {
            let inspection = try LibraryReadOnlyConnection(url: destination).inspect()
            guard inspection.missingTables.isEmpty else {
                throw LibrarySnapshotError.manifestFailed(
                    "snapshot is missing tables: \(inspection.missingTables.joined(separator: ", "))")
            }
            guard inspection.integrityMessages.isEmpty else {
                throw LibrarySnapshotError.manifestFailed(
                    "snapshot failed quick_check: \(inspection.integrityMessages.joined(separator: "; "))")
            }
            return inspection.manifest
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Folds the WAL into the main file through the live pool. This is the only
    /// checkpoint path; callers must not open a second connection.
    func checkpoint() throws {
        try pool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }

    var schemaVersion: Int {
        get throws {
            try pool.read { db in
                try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
            }
        }
    }

    func tableCounts() throws -> LibraryTableCounts {
        try pool.read { db in
            let present = Set(try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
            var counts = LibraryTableCounts()
            for entry in LibraryTableCounts.tableMap where present.contains(entry.table) {
                counts[keyPath: entry.keyPath] = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM \(entry.table)") ?? 0
            }
            return counts
        }
    }
}
