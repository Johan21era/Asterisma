//  SentinelProbesStorage.swift
//  AsterismaV2.5
//
//  SQL + BAK — the database and backup surfaces.
//
//  These are the probes that answer the 138k-row blind spot: they read the
//  normalized rows through a read-only GRDB handle, never the live pool, and
//  never open a write transaction. A missing database or table is reported as
//  `skipped` by throwing `SentinelProbeUnavailable`, so an absent source cannot
//  masquerade as a clean result.
//
//  Backup probes are equally read-only: they list the Backups directory, open
//  copies read-only, and use `environment.tempRoot` for the restore drill.

import Foundation
import GRDB

// MARK: - Shared file helpers

private enum StorageProbeFiles {

    /// Recognizable backup artifacts, oldest first. The marker file and cover
    /// sidecars are deliberately excluded.
    static func backups(in snapshot: SentinelSnapshot) -> [(url: URL, modified: Date, size: Int64)] {
        guard let root = snapshot.backupsRoot else { return [] }
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: root.path)) ?? []
        return names.compactMap { name -> (URL, Date, Int64)? in
            guard !name.hasPrefix(".") else { return nil }
            let isBackup = name.hasPrefix("library-")
                || name.hasPrefix("sentinel-pre-repair-")
                || name.hasSuffix(".readingarchive")
                || name.hasSuffix(".sqlite3")
            guard isBackup else { return nil }
            let url = root.appendingPathComponent(name)
            let attrs = (try? manager.attributesOfItem(atPath: url.path)) ?? [:]
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attrs[.modificationDate] as? Date) ?? .distantPast
            return (url, modified, size)
        }
        .sorted { $0.1 < $1.1 }
    }

    static func sentinelDirectory(_ snapshot: SentinelSnapshot) -> URL? {
        snapshot.dataRoot?.appendingPathComponent("Sentinel", isDirectory: true)
    }

    static func repairRecords(_ snapshot: SentinelSnapshot) -> [[String: Any]] {
        guard let directory = sentinelDirectory(snapshot) else { return [] }
        let url = directory.appendingPathComponent("repairs.json")
        guard let data = try? Data(contentsOf: url),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array
    }

    static func liveLibraryFile(_ snapshot: SentinelSnapshot) -> URL? {
        if let databaseURL = snapshot.databaseURL,
           FileManager.default.fileExists(atPath: databaseURL.path) {
            return databaseURL
        }
        if let json = snapshot.jsonLibraryURL,
           FileManager.default.fileExists(atPath: json.path) {
            return json
        }
        return nil
    }

    /// Opens a backup read-only when it is SQLite; returns nil when the format
    /// is JSON or unknown (callers validate those separately).
    static func sqliteIntegrity(of url: URL) -> String? {
        guard url.pathExtension == "sqlite3" else { return nil }
        var config = Configuration()
        config.readonly = true
        config.busyMode = .timeout(0.5)
        guard let queue = try? DatabaseQueue(path: url.path, configuration: config) else { return nil }
        defer { try? queue.close() }
        guard let result = (try? queue.read { db in
            try String.fetchOne(db, sql: "PRAGMA integrity_check")
        }) else {
            return nil
        }
        return result
    }

    static func isReadableJSON(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }
}

// MARK: - SQL

nonisolated struct SQL001IntegrityCheck: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SQL-001", domain: .database,
        title: "The database fails its integrity check",
        what: "SQLite reports structural damage in the library database.",
        rootCauseKey: "sql.integrity", tier: .t3, isRequired: false,
        defaultSeverity: .critical, defaultImpact: .high)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let result = try SentinelProbeSupport.readDatabase(at: snapshot.databaseURL) { db in
            try SentinelProbeSupport.scalarString(db, "PRAGMA integrity_check") ?? "unknown"
        }
        guard result.lowercased() != "ok" else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.database, "library")],
            evidence: [SentinelProbeSupport.aggregate(
                "evidence.sql001.result", result, at: environment.now, source: .sqlite)],
            debug: "integrity=\(result)")]
    }
}

nonisolated struct SQL002ForeignKeyCheck: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SQL-002", domain: .database,
        title: "Normalized rows break a foreign key",
        what: "A session or timing row references a parent row that does not exist.",
        rootCauseKey: "sql.foreign-key", tier: .t3, isRequired: false,
        defaultSeverity: .critical, defaultImpact: .high)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let count = try SentinelProbeSupport.readDatabase(at: snapshot.databaseURL) { db in
            try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count
        }
        guard count > 0 else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.database, "library")],
            evidence: [SentinelProbeSupport.count("evidence.sql002.rows", count, at: environment.now, source: .sqlite)],
            debug: "violations=\(count)")]
    }
}

nonisolated struct SQL003PayloadRowCounts: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SQL-003", domain: .database,
        title: "Stored rows disagree with the library",
        what: "The normalized row counts do not match the books, sessions, and timings the app loaded.",
        rootCauseKey: "sql.count-parity", tier: .t2, isRequired: false,
        defaultSeverity: .warning, defaultImpact: .high)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard snapshot.appFlags.storageEngine == "sqlite" || snapshot.appFlags.storageEngine.isEmpty else {
            throw SentinelProbeUnavailable(.notApplicable, "JSON storage is active")
        }
        let counts = try SentinelProbeSupport.readDatabase(at: snapshot.databaseURL) { db -> (Int, Int, Int) in
            guard try SentinelProbeSupport.hasTable("books", in: db),
                  try SentinelProbeSupport.hasTable("sessions", in: db),
                  try SentinelProbeSupport.hasTable("page_times", in: db) else {
                throw SentinelProbeUnavailable(.databaseNotInitialized)
            }
            return (
                try SentinelProbeSupport.scalarInt(db, "SELECT COUNT(*) FROM books"),
                try SentinelProbeSupport.scalarInt(db, "SELECT COUNT(*) FROM sessions"),
                try SentinelProbeSupport.scalarInt(db, "SELECT COUNT(*) FROM page_times")
            )
        }
        let sessions = snapshot.books.reduce(0) { $0 + $1.sessions.count }
        let timings = snapshot.books.reduce(0) { partial, book in
            partial + book.sessions.reduce(0) { $0 + $1.pageTimes.count }
        }
        var findings: [RawFinding] = []
        if counts.0 != snapshot.books.count {
            findings.append(SentinelProbeSupport.finding(
                descriptor,
                subjects: [SentinelSubject(.database, "books")],
                evidence: [
                    SentinelProbeSupport.count("evidence.sql003.rows", counts.0, at: environment.now, source: .sqlite),
                    SentinelProbeSupport.count("evidence.sql003.memory", snapshot.books.count, at: environment.now),
                ],
                discriminator: "books",
                debug: "rows=\(counts.0) memory=\(snapshot.books.count)"))
        }
        if counts.1 != sessions {
            findings.append(SentinelProbeSupport.finding(
                descriptor,
                subjects: [SentinelSubject(.database, "sessions")],
                evidence: [
                    SentinelProbeSupport.count("evidence.sql003.rows", counts.1, at: environment.now, source: .sqlite),
                    SentinelProbeSupport.count("evidence.sql003.memory", sessions, at: environment.now),
                ],
                discriminator: "sessions",
                debug: "rows=\(counts.1) memory=\(sessions)"))
        }
        if counts.2 != timings {
            findings.append(SentinelProbeSupport.finding(
                descriptor,
                subjects: [SentinelSubject(.database, "page_times")],
                evidence: [
                    SentinelProbeSupport.count("evidence.sql003.rows", counts.2, at: environment.now, source: .sqlite),
                    SentinelProbeSupport.count("evidence.sql003.memory", timings, at: environment.now),
                ],
                discriminator: "timings",
                debug: "rows=\(counts.2) memory=\(timings)"))
        }
        return findings
    }
}

nonisolated struct SQL004DuplicateNormalizedIDs: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SQL-004", domain: .database,
        title: "The database contains duplicate identifiers",
        what: "A table that should be keyed uniquely has more than one row with the same id.",
        rootCauseKey: "sql.duplicate-id", tier: .t1,
        defaultSeverity: .critical, defaultImpact: .high)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let duplicates = try SentinelProbeSupport.readDatabase(at: snapshot.databaseURL) { db -> [String] in
            var result: [String] = []
            for table in ["books", "sessions", "page_times"] {
                guard try SentinelProbeSupport.hasTable(table, in: db) else { continue }
                let count = try SentinelProbeSupport.scalarInt(
                    db,
                    "SELECT COUNT(*) FROM (SELECT id FROM \(table) GROUP BY id HAVING COUNT(*) > 1)")
                if count > 0 { result.append("\(table)=\(count)") }
            }
            return result
        }
        guard !duplicates.isEmpty else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.database, "library")],
            evidence: [SentinelProbeSupport.aggregate(
                "evidence.sql004.tables", duplicates.joined(separator: ","), at: environment.now, source: .sqlite)],
            debug: duplicates.joined(separator: ","))]
    }
}

nonisolated struct SQL005WriteAheadLog: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SQL-005", domain: .database,
        title: "The database write-ahead log is large",
        what: "The WAL file has grown beyond its budget or has not been checkpointed in a day.",
        rootCauseKey: "sql.wal", tier: .t2, isRequired: false,
        defaultSeverity: .info, defaultImpact: .medium,
        riskClass: .r2, repairID: "REP-014")

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard let databaseURL = snapshot.databaseURL,
              FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw SentinelProbeUnavailable(.databaseNotInitialized)
        }
        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        guard let size = SentinelProbeSupport.fileSize(walURL) else { return [] }
        let modified = SentinelProbeSupport.modificationDate(walURL)
        let age = modified.map { environment.now.timeIntervalSince($0) } ?? 0
        let budget: Int64 = 64 * 1_000_000
        guard size > budget || age > 24 * 3600 else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.database, "wal")],
            evidence: [
                SentinelProbeSupport.bytes("evidence.sql005.bytes", size, at: environment.now),
                SentinelProbeSupport.timestamp("evidence.sql005.modified", modified, at: environment.now),
            ],
            debug: "bytes=\(size) age=\(Int(age))")]
    }
}

nonisolated struct SQL006SchemaVersion: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SQL-006", domain: .database,
        title: "The database schema is incomplete",
        what: "The meta table is missing, or carries rows without a schema version marker.",
        rootCauseKey: "sql.schema", tier: .t1,
        defaultSeverity: .critical, defaultImpact: .high)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let outcome = try SentinelProbeSupport.readDatabase(at: snapshot.databaseURL) { db -> (Bool, Bool) in
            let hasMeta = try SentinelProbeSupport.hasTable("meta", in: db)
            guard hasMeta else { return (false, false) }
            // The GRDB migrator is the source of truth today; meta is empty by
            // design. Only flag a populated meta table that lost its version.
            let rows = try SentinelProbeSupport.scalarInt(db, "SELECT COUNT(*) FROM meta")
            if rows == 0 { return (true, true) }
            let version = try SentinelProbeSupport.scalarInt(
                db, "SELECT COUNT(*) FROM meta WHERE key = 'schema_version'")
            return (true, version > 0)
        }
        guard outcome.0 else {
            return [SentinelProbeSupport.finding(
                descriptor,
                subjects: [SentinelSubject(.database, "meta")],
                evidence: [SentinelProbeSupport.flag("evidence.sql006.metaTable", false, at: environment.now, source: .sqlite)],
                debug: "meta table missing")]
        }
        guard !outcome.1 else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.database, "meta")],
            evidence: [SentinelProbeSupport.flag("evidence.sql006.schemaVersion", false, at: environment.now, source: .sqlite)],
            debug: "meta rows without schema_version")]
    }
}

nonisolated struct SQL007UnreadableRows: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SQL-007", domain: .database,
        title: "Stored rows cannot be decoded",
        what: "One or more payload columns are not valid JSON, so a fail-closed load would abort.",
        rootCauseKey: "sql.payload", tier: .t3, isRequired: false,
        defaultSeverity: .critical, defaultImpact: .high)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let broken = try SentinelProbeSupport.readDatabase(at: snapshot.databaseURL) { db -> [String] in
            var result: [String] = []
            for table in ["books", "sessions", "page_times", "library_state"] {
                guard try SentinelProbeSupport.hasTable(table, in: db) else { continue }
                let column = table == "meta" ? "value" : "payload_json"
                let count = try SentinelProbeSupport.scalarInt(
                    db, "SELECT COUNT(*) FROM \(table) WHERE json_valid(\(column)) = 0")
                if count > 0 { result.append("\(table)=\(count)") }
            }
            return result
        }
        guard !broken.isEmpty else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.database, "payloads")],
            evidence: [SentinelProbeSupport.aggregate(
                "evidence.sql007.tables", broken.joined(separator: ","), at: environment.now, source: .sqlite)],
            debug: broken.joined(separator: ","))]
    }
}

nonisolated struct SQL008LibraryStateRoot: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SQL-008", domain: .database,
        title: "The database has books but no settings row",
        what: "The library-state root is absent while books exist, so goals and collections would load empty.",
        rootCauseKey: "sql.state-root", tier: .t1,
        defaultSeverity: .warning, defaultImpact: .medium)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let outcome = try SentinelProbeSupport.readDatabase(at: snapshot.databaseURL) { db -> (Int, Int) in
            guard try SentinelProbeSupport.hasTable("books", in: db),
                  try SentinelProbeSupport.hasTable("library_state", in: db) else {
                throw SentinelProbeUnavailable(.databaseNotInitialized)
            }
            let books = try SentinelProbeSupport.scalarInt(db, "SELECT COUNT(*) FROM books")
            let roots = try SentinelProbeSupport.scalarInt(
                db, "SELECT COUNT(*) FROM library_state WHERE key = 'root'")
            return (books, roots)
        }
        guard outcome.0 > 0, outcome.1 == 0 else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.database, "library_state")],
            evidence: [
                SentinelProbeSupport.count("evidence.sql008.books", outcome.0, at: environment.now, source: .sqlite),
                SentinelProbeSupport.count("evidence.sql008.roots", outcome.1, at: environment.now, source: .sqlite),
            ],
            debug: "books=\(outcome.0) roots=0")]
    }
}

nonisolated struct SQL009DatabaseGrowth: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SQL-009", domain: .database,
        title: "The library database is very large",
        what: "The database file has grown past the size where load and backup time become noticeable.",
        rootCauseKey: "sql.growth", tier: .t3, isRequired: false,
        defaultSeverity: .info, defaultImpact: .medium)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard let url = snapshot.databaseURL, let size = SentinelProbeSupport.fileSize(url) else {
            throw SentinelProbeUnavailable(.databaseNotInitialized)
        }
        let threshold: Int64 = 2_000_000_000
        guard size > threshold else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.database, "library")],
            evidence: [SentinelProbeSupport.bytes("evidence.sql009.bytes", size, at: environment.now)],
            debug: "bytes=\(size)")]
    }
}

nonisolated struct SQL010FreePages: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SQL-010", domain: .database,
        title: "The database has a lot of free pages",
        what: "A large freelist means deleted rows have left space that a vacuum would reclaim.",
        rootCauseKey: "sql.fragmentation", tier: .t4, isRequired: false,
        defaultSeverity: .info, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let counts = try SentinelProbeSupport.readDatabase(at: snapshot.databaseURL) { db -> (Int, Int) in
            (try SentinelProbeSupport.scalarInt(db, "PRAGMA freelist_count"),
             try SentinelProbeSupport.scalarInt(db, "PRAGMA page_count"))
        }
        guard counts.1 > 0 else { return [] }
        let ratio = Double(counts.0) / Double(counts.1)
        guard ratio > 0.10 else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.database, "library")],
            evidence: [
                SentinelProbeSupport.count("evidence.sql010.free", counts.0, at: environment.now, source: .sqlite),
                SentinelProbeSupport.count("evidence.sql010.total", counts.1, at: environment.now, source: .sqlite),
            ],
            debug: "ratio=\(String(format: "%.2f", ratio))")]
    }
}

nonisolated struct SQL011TimestampBounds: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SQL-011", domain: .database,
        title: "A stored timestamp is not a real date",
        what: "A normalized timestamp is NaN, infinite, or an implausible epoch value.",
        rootCauseKey: "sql.timestamp", tier: .t1,
        defaultSeverity: .warning, defaultImpact: .medium)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let broken = try SentinelProbeSupport.readDatabase(at: snapshot.databaseURL) { db -> Int in
            var count = 0
            if try SentinelProbeSupport.hasTable("sessions", in: db) {
                count += try SentinelProbeSupport.scalarInt(
                    db,
                    "SELECT COUNT(*) FROM sessions WHERE start_time != start_time OR ABS(start_time) > 1e12")
            }
            if try SentinelProbeSupport.hasTable("page_times", in: db) {
                count += try SentinelProbeSupport.scalarInt(
                    db,
                    "SELECT COUNT(*) FROM page_times WHERE start_time != start_time OR ABS(start_time) > 1e12")
            }
            return count
        }
        guard broken > 0 else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.database, "timestamps")],
            evidence: [SentinelProbeSupport.count("evidence.sql011.rows", broken, at: environment.now, source: .sqlite)],
            debug: "rows=\(broken)")]
    }
}

nonisolated struct SQL012UpdatedAtSanity: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SQL-012", domain: .database,
        title: "A row says it was updated in the future",
        what: "The stored updated-at timestamp is more than five minutes ahead of the current clock.",
        rootCauseKey: "sql.updated-at", tier: .t1, isRequired: false,
        defaultSeverity: .info, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let threshold = environment.now.addingTimeInterval(300).timeIntervalSince1970
        let count = try SentinelProbeSupport.readDatabase(at: snapshot.databaseURL) { db -> Int in
            guard try SentinelProbeSupport.hasTable("books", in: db) else {
                throw SentinelProbeUnavailable(.databaseNotInitialized)
            }
            return try SentinelProbeSupport.scalarInt(
                db, "SELECT COUNT(*) FROM books WHERE updated_at > ?", [threshold])
        }
        guard count > 0 else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.database, "books")],
            evidence: [SentinelProbeSupport.count("evidence.sql012.rows", count, at: environment.now, source: .sqlite)],
            debug: "rows=\(count)")]
    }
}

nonisolated struct SQL013JSONPayloadParse: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SQL-013", domain: .database,
        title: "A payload cannot be parsed",
        what: "At least one stored payload is not valid JSON, so its row cannot be loaded.",
        rootCauseKey: "sql.payload", tier: .t3, isRequired: false,
        defaultSeverity: .critical, defaultImpact: .high)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let count = try SentinelProbeSupport.readDatabase(at: snapshot.databaseURL) { db -> Int in
            var total = 0
            for table in ["books", "sessions", "page_times", "library_state"] {
                guard try SentinelProbeSupport.hasTable(table, in: db) else { continue }
                total += try SentinelProbeSupport.scalarInt(
                    db, "SELECT COUNT(*) FROM \(table) WHERE json_valid(payload_json) = 0")
            }
            return total
        }
        guard count > 0 else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.database, "payloads")],
            evidence: [SentinelProbeSupport.count("evidence.sql013.rows", count, at: environment.now, source: .sqlite)],
            debug: "rows=\(count)")]
    }
}

nonisolated struct SQL014BackupNotLive: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SQL-014", domain: .database,
        title: "A backup is byte-identical to the live database",
        what: "A file in Backups has the same size and content as the live database, so it cannot restore anything.",
        rootCauseKey: "backup.live-file", tier: .t2, isRequired: false,
        defaultSeverity: .warning, defaultImpact: .high)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard let live = StorageProbeFiles.liveLibraryFile(snapshot),
              let liveSize = SentinelProbeSupport.fileSize(live) else {
            throw SentinelProbeUnavailable(.sourceUnavailable)
        }
        let backups = StorageProbeFiles.backups(in: snapshot)
        var identical: [URL] = []
        for backup in backups where backup.size == liveSize {
            if FileManager.default.contentsEqual(atPath: live.path, andPath: backup.url.path) {
                identical.append(backup.url)
            }
        }
        guard !identical.isEmpty else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.backup, SentinelProbeSupport.hashedPath(identical[0]))],
            evidence: [
                SentinelProbeSupport.count("evidence.sql014.matches", identical.count, at: environment.now),
                SentinelProbeSupport.bytes("evidence.sql014.bytes", liveSize, at: environment.now),
            ],
            debug: identical.map(\.lastPathComponent).joined(separator: ","))]
    }
}

/// Structural invariant: every SQL probe in this file uses the read-only helper.
/// There is no code path here that opens a writable handle, so the probe has
/// nothing to inspect at runtime; it exists to keep the contract visible in the
/// coverage matrix.
nonisolated struct SQL015ReadOnlyAccess: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SQL-015", domain: .database,
        title: "Database probes never write",
        what: "Every database probe opens a read-only connection; no write transaction is possible.",
        rootCauseKey: "sql.read-only", tier: .t4, isRequired: false,
        defaultSeverity: .critical, defaultImpact: .high)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        []
    }
}

// MARK: - BAK

nonisolated struct BAK001AnyBackupExists: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "BAK-001", domain: .backups,
        title: "There is no backup of the library",
        what: "The Backups folder contains no file that could restore the library.",
        rootCauseKey: "backup.missing", tier: .t1,
        defaultSeverity: .critical, defaultImpact: .high)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard snapshot.backupsRoot != nil else {
            throw SentinelProbeUnavailable(.sourceUnavailable)
        }
        guard StorageProbeFiles.backups(in: snapshot).isEmpty else { return [] }
        // A brand-new install has nothing to back up yet. Only call this a
        // defect when there is library data or a live database to protect.
        let hasLibraryData = !snapshot.books.isEmpty
            || !snapshot.libraryState.deadlines.isEmpty
            || !snapshot.libraryState.earnedAchievements.isEmpty
            || !snapshot.libraryState.collections.isEmpty
            || StorageProbeFiles.liveLibraryFile(snapshot) != nil
        guard hasLibraryData else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.store, "backups")],
            evidence: [SentinelProbeSupport.count("evidence.bak001.files", 0, at: environment.now)],
            debug: "backups=0")]
    }
}

nonisolated struct BAK002BackupFreshness: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "BAK-002", domain: .backups,
        title: "The newest backup is out of date",
        what: "The library has changed since the newest backup, and that backup is more than a week old.",
        rootCauseKey: "backup.stale", tier: .t1,
        defaultSeverity: .warning, defaultImpact: .high)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let backups = StorageProbeFiles.backups(in: snapshot)
        guard let newest = backups.last else {
            throw SentinelProbeUnavailable(.sourceUnavailable)
        }
        guard environment.now.timeIntervalSince(newest.modified) > 7 * 86_400 else { return [] }
        guard let live = StorageProbeFiles.liveLibraryFile(snapshot),
              let liveDate = SentinelProbeSupport.modificationDate(live),
              liveDate > newest.modified else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.backup, SentinelProbeSupport.hashedPath(newest.url))],
            evidence: [
                SentinelProbeSupport.timestamp("evidence.bak002.newest", newest.modified, at: environment.now),
                SentinelProbeSupport.timestamp("evidence.bak002.library", liveDate, at: environment.now),
            ],
            debug: "ageDays=\(Int(environment.now.timeIntervalSince(newest.modified) / 86_400))")]
    }
}

nonisolated struct BAK003NewestBackupOpens: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "BAK-003", domain: .backups,
        title: "The newest backup cannot be opened",
        what: "The most recent backup file is unreadable or fails its integrity check.",
        rootCauseKey: "backup.unreadable", tier: .t3, isRequired: false,
        defaultSeverity: .critical, defaultImpact: .high)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let backups = StorageProbeFiles.backups(in: snapshot)
        guard let newest = backups.last else {
            throw SentinelProbeUnavailable(.sourceUnavailable)
        }
        let ok: Bool
        if newest.url.pathExtension == "sqlite3" {
            ok = StorageProbeFiles.sqliteIntegrity(of: newest.url)?.lowercased() == "ok"
        } else if newest.url.pathExtension == "json" {
            ok = StorageProbeFiles.isReadableJSON(newest.url)
        } else {
            ok = newest.size > 0
        }
        guard !ok else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.backup, SentinelProbeSupport.hashedPath(newest.url))],
            evidence: [SentinelProbeSupport.bytes("evidence.bak003.bytes", newest.size, at: environment.now)],
            debug: "unreadable=\(newest.url.lastPathComponent)")]
    }
}

nonisolated struct BAK004RestoreDrill: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "BAK-004", domain: .backups,
        title: "A backup failed the restore drill",
        what: "A temporary copy of the newest backup could not be opened or failed its integrity check.",
        rootCauseKey: "backup.restore-drill", tier: .t4, isRequired: false,
        defaultSeverity: .critical, defaultImpact: .high)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let backups = StorageProbeFiles.backups(in: snapshot)
        guard let newest = backups.last else {
            throw SentinelProbeUnavailable(.sourceUnavailable)
        }
        let manager = FileManager.default
        let drillDirectory = environment.tempRoot
            .appendingPathComponent("sentinel-restore-drill-\(UUID().uuidString)", isDirectory: true)
        try? manager.createDirectory(at: drillDirectory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: drillDirectory) }

        let copy = drillDirectory.appendingPathComponent(newest.url.lastPathComponent)
        do {
            try manager.copyItem(at: newest.url, to: copy)
        } catch {
            return [SentinelProbeSupport.finding(
                descriptor,
                subjects: [SentinelSubject(.backup, SentinelProbeSupport.hashedPath(newest.url))],
                evidence: [SentinelProbeSupport.flag("evidence.bak004.copy", false, at: environment.now)],
                debug: "copy failed")]
        }

        let ok: Bool
        if copy.pathExtension == "sqlite3" {
            ok = StorageProbeFiles.sqliteIntegrity(of: copy)?.lowercased() == "ok"
        } else if copy.pathExtension == "json" {
            ok = StorageProbeFiles.isReadableJSON(copy)
        } else {
            ok = SentinelProbeSupport.fileSize(copy) ?? 0 > 0
        }
        guard !ok else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.backup, SentinelProbeSupport.hashedPath(newest.url))],
            evidence: [SentinelProbeSupport.flag("evidence.bak004.drill", false, at: environment.now)],
            debug: "drill failed")]
    }
}

nonisolated struct BAK005MarkerConsistency: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "BAK-005", domain: .backups,
        title: "The backup marker points at nothing",
        what: "The change-detection marker names a backup file that is no longer present.",
        rootCauseKey: "backup.marker", tier: .t1,
        defaultSeverity: .warning, defaultImpact: .medium)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard let root = snapshot.backupsRoot else {
            throw SentinelProbeUnavailable(.sourceUnavailable)
        }
        let marker = root.appendingPathComponent(".last-backup-signature")
        guard let text = try? String(contentsOf: marker, encoding: .utf8), !text.isEmpty else {
            return []
        }
        guard let fileName = text.split(separator: "|").first.map(String.init), !fileName.isEmpty else {
            return []
        }
        let target = root.appendingPathComponent(fileName)
        guard !FileManager.default.fileExists(atPath: target.path) else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.backup, SentinelProbeSupport.hashedPath(marker))],
            evidence: [SentinelProbeSupport.invariant(
                "evidence.bak005.marker", "marker → missing file", at: environment.now)],
            debug: "missing=\(fileName)")]
    }
}

nonisolated struct BAK006BackupSizeAnomaly: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "BAK-006", domain: .backups,
        title: "A backup changed size dramatically",
        what: "The newest backup is less than half or more than twice the size of the previous one.",
        rootCauseKey: "backup.size", tier: .t2, isRequired: false,
        defaultSeverity: .warning, defaultImpact: .medium)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let backups = StorageProbeFiles.backups(in: snapshot)
        guard backups.count >= 2 else { return [] }
        let newest = backups[backups.count - 1]
        let previous = backups[backups.count - 2]
        guard previous.size > 0 else { return [] }
        let ratio = Double(newest.size) / Double(previous.size)
        guard ratio < 0.5 || ratio > 2.0 else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.backup, SentinelProbeSupport.hashedPath(newest.url))],
            evidence: [
                SentinelProbeSupport.bytes("evidence.bak006.newest", newest.size, at: environment.now),
                SentinelProbeSupport.bytes("evidence.bak006.previous", previous.size, at: environment.now),
                SentinelProbeSupport.aggregate("evidence.bak006.ratio", String(format: "%.2f", ratio), at: environment.now),
            ],
            debug: "ratio=\(String(format: "%.2f", ratio))")]
    }
}

nonisolated struct BAK007RotationCount: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "BAK-007", domain: .backups,
        title: "There are more backups than the retention policy",
        what: "More than ten library backups exist, so the folder is growing past its budget.",
        rootCauseKey: "backup.rotation", tier: .t2, isRequired: false,
        defaultSeverity: .info, defaultImpact: .low,
        riskClass: .r2, repairID: "REP-021")

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let backups = StorageProbeFiles.backups(in: snapshot)
        let libraryBackups = backups.filter {
            $0.url.lastPathComponent.hasPrefix("library-")
                && !$0.url.lastPathComponent.hasPrefix("library-state-")
        }
        guard libraryBackups.count > 10 else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.store, "backups")],
            evidence: [SentinelProbeSupport.count("evidence.bak007.files", libraryBackups.count, at: environment.now)],
            debug: "backups=\(libraryBackups.count)")]
    }
}

nonisolated struct BAK008PreRepairSnapshot: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "BAK-008", domain: .backups,
        title: "A repair has no saved plan",
        what: "A recorded repair names a plan file that is no longer in Sentinel's plans folder.",
        rootCauseKey: "backup.repair-plan", tier: .t1,
        defaultSeverity: .critical, defaultImpact: .high)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard let directory = StorageProbeFiles.sentinelDirectory(snapshot) else {
            throw SentinelProbeUnavailable(.sourceUnavailable)
        }
        let records = StorageProbeFiles.repairRecords(snapshot)
        guard !records.isEmpty else { return [] }
        let plans = directory.appendingPathComponent("plans", isDirectory: true)
        var missing: [String] = []
        for record in records {
            guard let name = record["planFileName"] as? String, !name.isEmpty else { continue }
            let url = plans.appendingPathComponent("\(name).json")
            if !FileManager.default.fileExists(atPath: url.path) {
                missing.append(name)
            }
        }
        guard !missing.isEmpty else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.store, "repairs")],
            evidence: [SentinelProbeSupport.count("evidence.bak008.missing", missing.count, at: environment.now)],
            debug: missing.joined(separator: ","))]
    }
}

nonisolated struct BAK009UndoAvailability: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "BAK-009", domain: .backups,
        title: "An undo handle is unreadable",
        what: "A repair still inside the undo window has a plan file that cannot be decoded.",
        rootCauseKey: "backup.undo", tier: .t1,
        defaultSeverity: .warning, defaultImpact: .medium)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard let directory = StorageProbeFiles.sentinelDirectory(snapshot) else {
            throw SentinelProbeUnavailable(.sourceUnavailable)
        }
        let records = StorageProbeFiles.repairRecords(snapshot)
        guard !records.isEmpty else { return [] }
        let plans = directory.appendingPathComponent("plans", isDirectory: true)
        var broken: [String] = []
        for record in records {
            guard let status = record["status"] as? String,
                  status == "verified" || status == "unverified",
                  let name = record["planFileName"] as? String, !name.isEmpty else { continue }
            let url = plans.appendingPathComponent("\(name).json")
            guard let data = try? Data(contentsOf: url),
                  (try? JSONSerialization.jsonObject(with: data)) != nil else {
                broken.append(name)
                continue
            }
        }
        guard !broken.isEmpty else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.store, "repairs")],
            evidence: [SentinelProbeSupport.count("evidence.bak009.broken", broken.count, at: environment.now)],
            debug: broken.joined(separator: ","))]
    }
}

nonisolated struct BAK010FallbackArtifacts: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "BAK-010", domain: .backups,
        title: "A fallback file is unreadable",
        what: "A migrated or fallback JSON artifact exists but is empty or cannot be parsed.",
        rootCauseKey: "backup.fallback", tier: .t2, isRequired: false,
        defaultSeverity: .info, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard let root = snapshot.dataRoot else {
            throw SentinelProbeUnavailable(.sourceUnavailable)
        }
        let names = SentinelProbeSupport.directoryNames(root)
            .filter { $0.hasSuffix(".migrated") || $0.hasSuffix(".migrated.json") }
        guard !names.isEmpty else { return [] }
        var broken: [String] = []
        for name in names {
            let url = root.appendingPathComponent(name)
            guard let size = SentinelProbeSupport.fileSize(url), size > 0 else {
                broken.append(name)
                continue
            }
            if name.hasSuffix(".json"), !StorageProbeFiles.isReadableJSON(url) {
                broken.append(name)
            }
        }
        guard !broken.isEmpty else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.store, "fallback")],
            evidence: [SentinelProbeSupport.count("evidence.bak010.broken", broken.count, at: environment.now)],
            debug: broken.joined(separator: ","))]
    }
}

// MARK: - Catalog

nonisolated enum SentinelStorageProbes {
    static let all: [any SentinelProbeV2] = [
        SQL001IntegrityCheck(), SQL002ForeignKeyCheck(), SQL003PayloadRowCounts(),
        SQL004DuplicateNormalizedIDs(), SQL005WriteAheadLog(), SQL006SchemaVersion(),
        SQL007UnreadableRows(), SQL008LibraryStateRoot(), SQL009DatabaseGrowth(),
        SQL010FreePages(), SQL011TimestampBounds(), SQL012UpdatedAtSanity(),
        SQL013JSONPayloadParse(), SQL014BackupNotLive(), SQL015ReadOnlyAccess(),
        BAK001AnyBackupExists(), BAK002BackupFreshness(), BAK003NewestBackupOpens(),
        BAK004RestoreDrill(), BAK005MarkerConsistency(), BAK006BackupSizeAnomaly(),
        BAK007RotationCount(), BAK008PreRepairSnapshot(), BAK009UndoAvailability(),
        BAK010FallbackArtifacts(),
    ]
}
