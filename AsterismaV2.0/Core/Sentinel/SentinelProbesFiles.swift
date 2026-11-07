//  SentinelProbesFiles.swift
//  AsterismaV2.0
//
//  FILE + WX — everything that lives outside the library payload.
//
//  Book files move, covers go stale, and the weather store is a second SQLite
//  database with its own schema. These probes read metadata and read-only SQL;
//  they never touch the user's files and never call `Book.resolveURL()`, which
//  logs titles to the console.

import AppKit
import Foundation
import GRDB

// MARK: - Helpers

nonisolated private enum SentinelFileProbeHelpers {

    /// Resolves a book's file without logging or starting a security scope.
    /// Returns nil when neither the bookmark nor the recorded URL points at a
    /// file that exists.
    static func existingFileURL(for book: Book) -> URL? {
        if let data = book.bookmarkData {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        if FileManager.default.fileExists(atPath: book.fileURL.path) {
            return book.fileURL
        }
        return nil
    }

    static func bookmarkResolves(_ data: Data) -> Bool {
        var stale = false
        return (try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale)) != nil
    }

    static func coverFileName(for bookID: UUID) -> String {
        "\(bookID.uuidString).jpg"
    }

    static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func weatherDatabase(_ snapshot: SentinelSnapshot) -> URL? {
        snapshot.weatherDatabaseURL
    }
}

// MARK: - FILE

nonisolated struct FILE001BookFileMissing: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "FILE-001", domain: .files,
        title: "A book's file cannot be found",
        what: "The recorded file and its bookmark both fail to resolve, so the book cannot be opened.",
        rootCauseKey: "file.missing", tier: .t2, timeout: 1.0,
        defaultSeverity: .warning, defaultImpact: .high)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        snapshot.books.compactMap { book in
            guard SentinelFileProbeHelpers.existingFileURL(for: book) == nil else { return nil }
            return SentinelProbeSupport.finding(
                descriptor,
                subjects: SentinelProbeSupport.subjects(for: book),
                evidence: [
                    SentinelProbeSupport.flag("evidence.file001.bookmark", book.bookmarkData != nil, at: environment.now),
                    SentinelProbeSupport.aggregate(
                        "evidence.file001.path",
                        SentinelProbeSupport.hashedPath(book.fileURL),
                        at: environment.now),
                ],
                debug: "book=\(book.id.uuidString)")
        }
    }
}

nonisolated struct FILE002StaleBookmark: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "FILE-002", domain: .files,
        title: "A book's bookmark no longer resolves",
        what: "The security-scoped bookmark is present but cannot be resolved, even if the raw path still works.",
        rootCauseKey: "file.bookmark", tier: .t2, timeout: 1.0,
        defaultSeverity: .warning, defaultImpact: .medium)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        snapshot.books.compactMap { book in
            guard let data = book.bookmarkData,
                  !SentinelFileProbeHelpers.bookmarkResolves(data) else { return nil }
            return SentinelProbeSupport.finding(
                descriptor,
                subjects: SentinelProbeSupport.subjects(for: book),
                evidence: [
                    SentinelProbeSupport.invariant("evidence.file002.invariant", "bookmark does not resolve", at: environment.now),
                    SentinelProbeSupport.aggregate(
                        "evidence.file002.path",
                        SentinelProbeSupport.hashedPath(book.fileURL),
                        at: environment.now),
                ],
                debug: "book=\(book.id.uuidString)")
        }
    }
}

nonisolated struct FILE003DuplicateBookmarkTarget: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "FILE-003", domain: .files,
        title: "Two books resolve to the same file",
        what: "Different library entries point at one file on disk, so reading in one does not update the other.",
        rootCauseKey: "file.duplicate-target", tier: .t2, timeout: 1.0, isRequired: false,
        defaultSeverity: .info, defaultImpact: .medium)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        var groups: [String: [Book]] = [:]
        for book in snapshot.books {
            guard let url = SentinelFileProbeHelpers.existingFileURL(for: book) else { continue }
            groups[SentinelFileProbeHelpers.canonicalPath(url), default: []].append(book)
        }
        return groups.filter { $0.value.count > 1 }.map { path, books in
            SentinelProbeSupport.finding(
                descriptor,
                subjects: books.map { SentinelSubject(.book, $0.id.uuidString) },
                evidence: [
                    SentinelProbeSupport.count("evidence.file003.books", books.count, at: environment.now),
                    SentinelProbeSupport.aggregate(
                        "evidence.file003.path",
                        SentinelProbeSupport.hashedPath(URL(fileURLWithPath: path)),
                        at: environment.now),
                ],
                debug: "books=\(books.map(\.id.uuidString).joined(separator: ","))")
        }
    }
}

nonisolated struct FILE004OrphanCover: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "FILE-004", domain: .files,
        title: "A cover belongs to no book",
        what: "A cover file remains after its book was removed, so it is never displayed and only takes space.",
        rootCauseKey: "file.cover-orphan", tier: .t3, timeout: 2.0, isRequired: false,
        defaultSeverity: .info, defaultImpact: .low,
        riskClass: .r2, repairID: "REP-012")

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard let covers = snapshot.coversRoot else {
            throw SentinelProbeUnavailable(.sourceUnavailable)
        }
        let bookIDs = Set(snapshot.books.map { SentinelFileProbeHelpers.coverFileName(for: $0.id) })
        let names = SentinelProbeSupport.directoryNames(covers).filter { $0.hasSuffix(".jpg") }
        return names.filter { !bookIDs.contains($0) }.map { name in
            SentinelProbeSupport.finding(
                descriptor,
                subjects: [SentinelSubject(.cover, name)],
                evidence: [
                    SentinelProbeSupport.record(.cover, name, key: "evidence.file004.cover", at: environment.now),
                    SentinelProbeSupport.bytes(
                        "evidence.file004.size",
                        SentinelProbeSupport.fileSize(covers.appendingPathComponent(name)) ?? 0,
                        at: environment.now),
                ],
                debug: "cover=\(name)")
        }
    }
}

nonisolated struct FILE005MissingCover: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "FILE-005", domain: .files,
        title: "A book's cover file is missing",
        what: "There is no cover file on disk; when the book still carries an embedded image, Sentinel can write it back.",
        rootCauseKey: "file.cover-missing", tier: .t3, timeout: 2.0, isRequired: false,
        defaultSeverity: .info, defaultImpact: .low,
        riskClass: .r1, repairID: "REP-025")

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard let covers = snapshot.coversRoot else {
            throw SentinelProbeUnavailable(.sourceUnavailable)
        }
        return snapshot.books.compactMap { book in
            let file = covers.appendingPathComponent(SentinelFileProbeHelpers.coverFileName(for: book.id))
            guard !FileManager.default.fileExists(atPath: file.path) else { return nil }
            let hasEmbedded = !(book.coverImageData?.isEmpty ?? true)
            return SentinelProbeSupport.finding(
                descriptor,
                subjects: SentinelProbeSupport.subjects(for: book),
                evidence: [
                    SentinelProbeSupport.flag("evidence.file005.file", false, at: environment.now),
                    SentinelProbeSupport.flag("evidence.file005.embedded", hasEmbedded, at: environment.now),
                ],
                debug: "book=\(book.id.uuidString)")
        }
    }
}

nonisolated struct FILE006CorruptCover: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "FILE-006", domain: .files,
        title: "A cover file is damaged",
        what: "The cover exists but is empty or cannot be decoded, so the shelf shows a broken image.",
        rootCauseKey: "file.cover-corrupt", tier: .t3, timeout: 2.0, isRequired: false,
        defaultSeverity: .info, defaultImpact: .low,
        riskClass: .r2, repairID: "REP-013")

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard let covers = snapshot.coversRoot else {
            throw SentinelProbeUnavailable(.sourceUnavailable)
        }
        var findings: [RawFinding] = []
        for book in snapshot.books {
            let name = SentinelFileProbeHelpers.coverFileName(for: book.id)
            let url = covers.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let size = SentinelProbeSupport.fileSize(url) ?? 0
            let decodes = size > 0 && NSImage(contentsOf: url) != nil
            guard !decodes else { continue }
            findings.append(SentinelProbeSupport.finding(
                descriptor,
                subjects: SentinelProbeSupport.subjects(for: book)
                    + [SentinelSubject(.cover, name)],
                evidence: [
                    SentinelProbeSupport.bytes("evidence.file006.size", size, at: environment.now),
                    SentinelProbeSupport.flag("evidence.file006.decodes", decodes, at: environment.now),
                ],
                debug: "book=\(book.id.uuidString) cover=\(name)"))
        }
        return findings
    }
}

nonisolated struct FILE007SecurityScopeFailure: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "FILE-007", domain: .files,
        title: "A book's file cannot be reached safely",
        what: "The security-scoped URL resolves but macOS refuses to grant access, so opening the book will fail.",
        rootCauseKey: "file.security-scope", tier: .t2, timeout: 1.0,
        defaultSeverity: .warning, defaultImpact: .high)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        snapshot.books.compactMap { book in
            guard let data = book.bookmarkData else { return nil }
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale) else { return nil }

            // Balance the scope immediately; the probe only asks whether the
            // grant succeeds, it never keeps access open.
            let granted = url.startAccessingSecurityScopedResource()
            if granted { url.stopAccessingSecurityScopedResource() }
            guard !granted else { return nil }

            return SentinelProbeSupport.finding(
                descriptor,
                subjects: SentinelProbeSupport.subjects(for: book),
                evidence: [
                    SentinelProbeSupport.flag("evidence.file007.scope", false, at: environment.now),
                    SentinelProbeSupport.aggregate(
                        "evidence.file007.path",
                        SentinelProbeSupport.hashedPath(url),
                        at: environment.now),
                ],
                debug: "book=\(book.id.uuidString)")
        }
    }
}

nonisolated struct FILE008DataRootPermissions: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "FILE-008", domain: .files,
        title: "The data folder is not writable",
        what: "Asterisma cannot write to its own data folder, so saving and repair will fail.",
        rootCauseKey: "file.data-root", tier: .t1,
        defaultSeverity: .critical, defaultImpact: .high)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard let root = snapshot.dataRoot else { return [] }
        let manager = FileManager.default
        let exists = manager.fileExists(atPath: root.path)
        let writable = exists && manager.isWritableFile(atPath: root.path)
        guard !writable else { return [] }
        // Deliberately no probe write: writability is checked with metadata, so
        // Sentinel never creates an artifact in the user's data root.
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.store, "data-root")],
            evidence: [
                SentinelProbeSupport.flag("evidence.file008.exists", exists, at: environment.now),
                SentinelProbeSupport.flag("evidence.file008.writable", writable, at: environment.now),
                SentinelProbeSupport.aggregate(
                    "evidence.file008.path",
                    SentinelProbeSupport.hashedPath(root),
                    at: environment.now),
            ],
            debug: "root=\(root.lastPathComponent)")]
    }
}

nonisolated struct FILE009FileTypeMismatch: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "FILE-009", domain: .files,
        title: "A book's file type does not match its extension",
        what: "The stored file type disagrees with the file's extension, so the wrong reader may open it.",
        rootCauseKey: "file.type", tier: .t2, timeout: 1.0, isRequired: false,
        defaultSeverity: .info, defaultImpact: .medium)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        snapshot.books.compactMap { book in
            // Image-folder comics are containers, not extension-typed files:
            // a folder called "Webtoon.v2" is still a valid comic.
            guard book.fileType != .comic else { return nil }
            let ext = book.fileURL.pathExtension.lowercased()
            let expected = book.fileType.rawValue.lowercased()
            guard !ext.isEmpty, ext != expected else { return nil }
            return SentinelProbeSupport.finding(
                descriptor,
                subjects: SentinelProbeSupport.subjects(for: book),
                evidence: [
                    SentinelProbeSupport.aggregate("evidence.file009.declared", expected, at: environment.now),
                    SentinelProbeSupport.aggregate("evidence.file009.extension", ext, at: environment.now),
                ],
                debug: "book=\(book.id.uuidString)")
        }
    }
}

nonisolated struct FILE010DuplicateBookFileURL: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "FILE-010", domain: .files,
        title: "Two library entries record one file path",
        what: "The saved file paths are identical even before bookmark resolution, which usually means a duplicate import.",
        rootCauseKey: "file.duplicate-url", tier: .t2, timeout: 1.0, isRequired: false,
        defaultSeverity: .warning, defaultImpact: .medium)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        var groups: [String: [Book]] = [:]
        for book in snapshot.books {
            groups[SentinelFileProbeHelpers.canonicalPath(book.fileURL), default: []].append(book)
        }
        return groups.filter { $0.value.count > 1 }.map { path, books in
            SentinelProbeSupport.finding(
                descriptor,
                subjects: books.map { SentinelSubject(.book, $0.id.uuidString) },
                evidence: [
                    SentinelProbeSupport.count("evidence.file010.books", books.count, at: environment.now),
                    SentinelProbeSupport.aggregate(
                        "evidence.file010.path",
                        SentinelProbeSupport.hashedPath(URL(fileURLWithPath: path)),
                        at: environment.now),
                ],
                debug: "books=\(books.map(\.id.uuidString).joined(separator: ","))")
        }
    }
}

nonisolated struct FILE011CoverCacheSize: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "FILE-011", domain: .files,
        title: "The cover cache is larger than its budget",
        what: "Cover files on disk exceed the expected budget, which usually means removed books left files behind.",
        rootCauseKey: "file.cover-budget", tier: .t3, timeout: 3.0, isRequired: false,
        defaultSeverity: .info, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard let covers = snapshot.coversRoot else {
            throw SentinelProbeUnavailable(.sourceUnavailable)
        }
        let names = SentinelProbeSupport.directoryNames(covers)
        let total = names.reduce(Int64(0)) {
            $0 + (SentinelProbeSupport.fileSize(covers.appendingPathComponent($1)) ?? 0)
        }
        let budget: Int64 = 100 * 1_000_000
        guard total > budget else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.store, "covers")],
            evidence: [
                SentinelProbeSupport.bytes("evidence.file011.bytes", total, at: environment.now),
                SentinelProbeSupport.count("evidence.file011.files", names.count, at: environment.now),
            ],
            debug: "budget=\(budget)")]
    }
}

nonisolated struct FILE012BookFileModifiedAfterImport: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "FILE-012", domain: .files,
        title: "A book file changed after it was imported",
        what: "The file's modification date is later than the import date, so page counts or positions may have shifted.",
        rootCauseKey: "file.modified", tier: .t3, timeout: 2.0, isRequired: false,
        defaultSeverity: .info, defaultImpact: .medium)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        snapshot.books.compactMap { book in
            guard let url = SentinelFileProbeHelpers.existingFileURL(for: book),
                  let modified = SentinelProbeSupport.modificationDate(url),
                  modified.timeIntervalSince(book.dateAdded) > 60 else { return nil }
            return SentinelProbeSupport.finding(
                descriptor,
                subjects: SentinelProbeSupport.subjects(for: book),
                evidence: [
                    SentinelProbeSupport.timestamp("evidence.file012.modified", modified, at: environment.now),
                    SentinelProbeSupport.timestamp("evidence.file012.imported", book.dateAdded, at: environment.now),
                ],
                debug: "book=\(book.id.uuidString)")
        }
    }
}

// MARK: - WX

nonisolated struct WX001WeatherStoreOpens: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "WX-001", domain: .weather,
        title: "The weather store cannot be opened",
        what: "The weather snapshot database is missing or unreadable, so reading context cannot be saved.",
        rootCauseKey: "weather.store", tier: .t1, timeout: 1.0,
        defaultSeverity: .warning, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let url = SentinelFileProbeHelpers.weatherDatabase(snapshot)
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            // The weather store is created on first use. Its absence is "not
            // enabled", not damage; silence here keeps clean installs clean.
            throw SentinelProbeUnavailable(.databaseNotInitialized)
        }
        let hasTable = try SentinelProbeSupport.readDatabase(at: url) { db in
            try SentinelProbeSupport.hasTable("weather_snapshots", in: db)
        }
        guard !hasTable else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.database, "weather")],
            evidence: [SentinelProbeSupport.flag("evidence.wx001.table", false, at: environment.now)],
            debug: "weather table missing")]
    }
}

nonisolated struct WX002WeatherColumns: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "WX-002", domain: .weather,
        title: "The weather store is missing columns",
        what: "The schema lacks a column the reader expects, so snapshots may fail to decode.",
        rootCauseKey: "weather.schema", tier: .t2, timeout: 1.0, isRequired: false,
        defaultSeverity: .warning, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let required = [
            "id", "timestamp", "session_id", "temperature_celsius",
            "humidity", "condition", "season", "day_period",
        ]
        let present = try SentinelProbeSupport.readDatabase(at: SentinelFileProbeHelpers.weatherDatabase(snapshot)) { db in
            guard try SentinelProbeSupport.hasTable("weather_snapshots", in: db) else {
                throw SentinelProbeUnavailable(.databaseNotInitialized)
            }
            let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(weather_snapshots)")
            return Set(rows.compactMap { $0["name"] as String? })
        }
        let missing = required.filter { !present.contains($0) }
        guard !missing.isEmpty else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.database, "weather")],
            evidence: [
                SentinelProbeSupport.count("evidence.wx002.missing", missing.count, at: environment.now, source: .sqlite),
                SentinelProbeSupport.aggregate("evidence.wx002.columns", missing.joined(separator: ","), at: environment.now, source: .sqlite),
            ],
            debug: "missing=\(missing)")]
    }
}

nonisolated struct WX003WeatherCoverage: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "WX-003", domain: .weather,
        title: "Many sessions have no weather snapshot",
        what: "Weather context is only available for part of the reading history; the ratio is reported exactly as measured.",
        rootCauseKey: "weather.coverage", tier: .t2, timeout: 1.5, isRequired: false,
        defaultSeverity: .info, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let finishedSessions = SentinelProbeSupport.sessionsWithTiming(in: snapshot)
            .filter { $0.session.endTime != nil }
        guard !finishedSessions.isEmpty else { return [] }

        let snapshotCount = try SentinelProbeSupport.readDatabase(at: SentinelFileProbeHelpers.weatherDatabase(snapshot)) { db in
            guard try SentinelProbeSupport.hasTable("weather_snapshots", in: db) else {
                throw SentinelProbeUnavailable(.databaseNotInitialized)
            }
            return try SentinelProbeSupport.scalarInt(db, "SELECT COUNT(*) FROM weather_snapshots WHERE session_id IS NOT NULL")
        }
        let ratio = min(1.0, Double(snapshotCount) / Double(finishedSessions.count))
        guard ratio < 0.5 else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.store, "weather")],
            evidence: [
                SentinelProbeSupport.count("evidence.wx003.snapshots", snapshotCount, at: environment.now, source: .sqlite),
                SentinelProbeSupport.count("evidence.wx003.sessions", finishedSessions.count, at: environment.now),
                SentinelProbeSupport.aggregate("evidence.wx003.ratio", SentinelFormat.percent(ratio), at: environment.now),
            ],
            debug: "ratio=\(String(format: "%.2f", ratio))")]
    }
}

nonisolated struct WX004OrphanWeatherSnapshots: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "WX-004", domain: .weather,
        title: "Weather snapshots outlive their sessions",
        what: "Snapshot rows reference a session id that no longer exists in the database.",
        rootCauseKey: "weather.orphan", tier: .t3, timeout: 1.5, isRequired: false,
        defaultSeverity: .info, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let count = try SentinelProbeSupport.readDatabase(at: SentinelFileProbeHelpers.weatherDatabase(snapshot)) { db in
            guard try SentinelProbeSupport.hasTable("weather_snapshots", in: db),
                  try SentinelProbeSupport.hasTable("sessions", in: db) else {
                throw SentinelProbeUnavailable(.databaseNotInitialized)
            }
            return try SentinelProbeSupport.scalarInt(
                db,
                "SELECT COUNT(*) FROM weather_snapshots w LEFT JOIN sessions s ON s.id = w.session_id WHERE w.session_id IS NOT NULL AND s.id IS NULL")
        }
        guard count > 0 else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.database, "weather")],
            evidence: [SentinelProbeSupport.count("evidence.wx004.rows", count, at: environment.now, source: .sqlite)],
            debug: "orphanSnapshots=\(count)")]
    }
}

nonisolated struct WX005WeatherTimestampSanity: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "WX-005", domain: .weather,
        title: "A weather snapshot has an impossible date",
        what: "A snapshot is dated before 2000 or in the future, so it would distort seasonal analysis.",
        rootCauseKey: "weather.timestamp", tier: .t1, timeout: 1.0,
        defaultSeverity: .warning, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let future = environment.now.addingTimeInterval(300).timeIntervalSince1970
        let count = try SentinelProbeSupport.readDatabase(at: SentinelFileProbeHelpers.weatherDatabase(snapshot)) { db in
            guard try SentinelProbeSupport.hasTable("weather_snapshots", in: db) else {
                throw SentinelProbeUnavailable(.databaseNotInitialized)
            }
            return try SentinelProbeSupport.scalarInt(
                db,
                "SELECT COUNT(*) FROM weather_snapshots WHERE timestamp < 946684800 OR timestamp > ?",
                [future])
        }
        guard count > 0 else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.database, "weather")],
            evidence: [SentinelProbeSupport.count("evidence.wx005.rows", count, at: environment.now, source: .sqlite)],
            debug: "impossibleTimestamps=\(count)")]
    }
}

nonisolated struct WX006WeatherStoreGrowth: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "WX-006", domain: .weather,
        title: "The weather store is growing unusually",
        what: "The weather database is large relative to the number of sessions it describes.",
        rootCauseKey: "weather.growth", tier: .t3, timeout: 2.0, isRequired: false,
        defaultSeverity: .info, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let url = SentinelFileProbeHelpers.weatherDatabase(snapshot)
        guard let url, let size = SentinelProbeSupport.fileSize(url) else { return [] }
        let count = try SentinelProbeSupport.readDatabase(at: url) { db in
            guard try SentinelProbeSupport.hasTable("weather_snapshots", in: db) else { return 0 }
            return try SentinelProbeSupport.scalarInt(db, "SELECT COUNT(*) FROM weather_snapshots")
        }
        let budget: Int64 = 50 * 1_000_000
        guard size > budget else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.database, "weather")],
            evidence: [
                SentinelProbeSupport.bytes("evidence.wx006.bytes", size, at: environment.now),
                SentinelProbeSupport.count("evidence.wx006.snapshots", count, at: environment.now, source: .sqlite),
            ],
            debug: "budget=\(budget)")]
    }
}

nonisolated struct WX007LocationHonesty: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "WX-007", domain: .weather,
        title: "Weather has no recorded location",
        what: "Snapshots exist but neither a manual location nor a cached location is recorded, so the conditions have no honest source.",
        rootCauseKey: "weather.location", tier: .t2, timeout: 1.5, isRequired: false,
        defaultSeverity: .warning, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        // Real keys used by WeatherKitService2: manual override and cached fix.
        let manualLat = snapshot.defaults.double(forKey: "wks_manual_lat")
        let manualLon = snapshot.defaults.double(forKey: "wks_manual_lon")
        let cachedLat = snapshot.defaults.double(forKey: "wks_lat")
        let cachedLon = snapshot.defaults.double(forKey: "wks_lon")
        let hasManual = manualLat != 0 || manualLon != 0
        let hasCached = cachedLat != 0 || cachedLon != 0
        guard !hasManual && !hasCached else { return [] }

        let snapshotCount = try SentinelProbeSupport.readDatabase(at: SentinelFileProbeHelpers.weatherDatabase(snapshot)) { db in
            guard try SentinelProbeSupport.hasTable("weather_snapshots", in: db) else { return 0 }
            return try SentinelProbeSupport.scalarInt(db, "SELECT COUNT(*) FROM weather_snapshots")
        }
        guard snapshotCount > 0 else { return [] }

        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.subsystem, "weather-location")],
            evidence: [
                SentinelProbeSupport.flag("evidence.wx007.manual", hasManual, at: environment.now),
                SentinelProbeSupport.flag("evidence.wx007.cached", hasCached, at: environment.now),
                SentinelProbeSupport.count("evidence.wx007.snapshots", snapshotCount, at: environment.now, source: .sqlite),
            ],
            debug: "snapshots=\(snapshotCount) no location source")]
    }
}

// MARK: - Catalog

nonisolated enum SentinelFileProbes {
    static let all: [any SentinelProbeV2] = [
        FILE001BookFileMissing(), FILE002StaleBookmark(), FILE003DuplicateBookmarkTarget(),
        FILE004OrphanCover(), FILE005MissingCover(), FILE006CorruptCover(),
        FILE007SecurityScopeFailure(), FILE008DataRootPermissions(), FILE009FileTypeMismatch(),
        FILE010DuplicateBookFileURL(),
        FILE011CoverCacheSize(), FILE012BookFileModifiedAfterImport(),
        WX001WeatherStoreOpens(), WX002WeatherColumns(), WX003WeatherCoverage(),
        WX004OrphanWeatherSnapshots(), WX005WeatherTimestampSanity(),
        WX006WeatherStoreGrowth(), WX007LocationHonesty(),
    ]
}
