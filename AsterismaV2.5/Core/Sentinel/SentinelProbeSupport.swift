//  SentinelProbeSupport.swift
//  AsterismaV2.5
//
//  Shared, read-only helpers for the probe catalog. Everything here is pure
//  apart from file metadata and a read-only SQLite handle; nothing mutates
//  user data and nothing needs the main thread.

import CryptoKit
import Foundation
import GRDB

/// Thrown when a required source is not available. The runtime records this as
/// `skipped`, never as a clean result (L14).
nonisolated struct SentinelProbeUnavailable: Error, Sendable {
    var reason: SentinelProbeSkipReason
    var detail: String?

    init(_ reason: SentinelProbeSkipReason, _ detail: String? = nil) {
        self.reason = reason
        self.detail = detail
    }
}

nonisolated enum SentinelProbeSupport {

    // MARK: - Findings

    static func finding(
        _ descriptor: SentinelProbeDescriptor,
        subjects: [SentinelSubject],
        evidence: [SentinelEvidence],
        severity: SentinelSeverity? = nil,
        impact: SentinelImpact? = nil,
        discriminator: String = "",
        summary: String? = nil,
        debug: String? = nil
    ) -> RawFinding {
        RawFinding(
            probeID: descriptor.id,
            ruleID: descriptor.ruleID,
            severity: severity ?? descriptor.defaultSeverity,
            confidence: 0.95,
            impact: impact ?? descriptor.defaultImpact,
            subjects: subjects,
            evidence: evidence,
            discriminator: discriminator,
            safeSummary: summary ?? descriptor.title,
            debugDetail: debug,
            isEvidenceOnly: descriptor.role != .owner)
    }

    // MARK: - Evidence

    static func count(
        _ key: String,
        _ value: Int,
        at now: Date,
        source: SentinelEvidenceSource = .dataStore,
        debug: String? = nil
    ) -> SentinelEvidence {
        SentinelEvidence(kind: .count, labelKey: key, safeValue: "\(value)",
                         debugValue: debug, observedAt: now, source: source)
    }

    static func flag(
        _ key: String,
        _ value: Bool,
        at now: Date,
        source: SentinelEvidenceSource = .dataStore
    ) -> SentinelEvidence {
        SentinelEvidence(kind: .boolean, labelKey: key, safeValue: value ? "true" : "false",
                         observedAt: now, source: source)
    }

    static func timestamp(
        _ key: String,
        _ date: Date?,
        at now: Date,
        source: SentinelEvidenceSource = .dataStore,
        debug: String? = nil
    ) -> SentinelEvidence {
        SentinelEvidence(kind: .timestamp, labelKey: key,
                         safeValue: date.map(SentinelFormat.iso) ?? "none",
                         debugValue: debug, observedAt: now, source: source)
    }

    static func aggregate(
        _ key: String,
        _ value: String,
        at now: Date,
        source: SentinelEvidenceSource = .dataStore
    ) -> SentinelEvidence {
        SentinelEvidence(kind: .aggregate, labelKey: key, safeValue: value,
                         observedAt: now, source: source)
    }

    static func invariant(
        _ key: String,
        _ value: String,
        at now: Date
    ) -> SentinelEvidence {
        SentinelEvidence(kind: .invariant, labelKey: key, safeValue: value,
                         observedAt: now, source: .sentinel)
    }

    static func bytes(
        _ key: String,
        _ value: Int64,
        at now: Date,
        source: SentinelEvidenceSource = .fileSystem
    ) -> SentinelEvidence {
        SentinelEvidence(kind: .bytes, labelKey: key, safeValue: SentinelFormat.bytes(value),
                         observedAt: now, source: source)
    }

    static func record(
        _ kind: SentinelSubjectKind,
        _ id: String,
        key: String,
        at now: Date
    ) -> SentinelEvidence {
        SentinelEvidence(kind: .recordRef, labelKey: key, safeValue: "\(kind.rawValue):\(id)",
                         observedAt: now, source: .dataStore)
    }

    /// Stable, non-reversible path reference for evidence. The real path stays
    /// in debug detail only.
    static func hashedPath(_ url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Database (read-only)

    static func readDatabase<T>(at url: URL?, _ body: (Database) throws -> T) throws -> T {
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            throw SentinelProbeUnavailable(.databaseNotInitialized)
        }
        var config = Configuration()
        config.readonly = true
        config.busyMode = .timeout(0.5)
        let queue = try DatabaseQueue(path: url.path, configuration: config)
        defer { try? queue.close() }
        return try queue.read { db in try body(db) }
    }

    static func tableNames(in db: Database) throws -> Set<String> {
        let names = try String.fetchAll(
            db,
            sql: "SELECT name FROM sqlite_master WHERE type='table'")
        return Set(names)
    }

    static func hasTable(_ name: String, in db: Database) throws -> Bool {
        try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?",
            arguments: [name]) ?? 0 > 0
    }

    static func scalarInt(_ db: Database, _ sql: String, _ arguments: StatementArguments = []) throws -> Int {
        try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0
    }

    static func scalarDouble(_ db: Database, _ sql: String, _ arguments: StatementArguments = []) throws -> Double? {
        try Double.fetchOne(db, sql: sql, arguments: arguments)
    }

    static func scalarString(_ db: Database, _ sql: String, _ arguments: StatementArguments = []) throws -> String? {
        try String.fetchOne(db, sql: sql, arguments: arguments)
    }

    // MARK: - Files

    static func fileExists(_ url: URL?) -> Bool {
        guard let url else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static func fileSize(_ url: URL?) -> Int64? {
        guard let url else { return nil }
        return ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value
    }

    static func modificationDate(_ url: URL?) -> Date? {
        guard let url else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    static func directoryNames(_ url: URL?) -> [String] {
        guard let url else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    /// Reads a JSON object without trusting its contents. Used for defensive
    /// parsing of Sentinel's own and subsystem files.
    static func jsonObject(at url: URL?) -> [String: Any]? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func jsonArray(at url: URL?) -> [Any]? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [Any]
    }

    // MARK: - Domain helpers

    static func pageInRange(_ page: Int, totalPages: Int) -> Bool {
        guard totalPages > 0 else { return false }
        return page >= 0 && page < totalPages
    }

    static func subjects(for book: Book) -> [SentinelSubject] {
        [SentinelSubject(.book, book.id.uuidString)]
    }

    static func subjects(for book: Book, session: ReadingSession) -> [SentinelSubject] {
        [
            SentinelSubject(.book, book.id.uuidString),
            SentinelSubject(.session, session.id.uuidString),
        ]
    }

    static func sessionsWithTiming(
        in snapshot: SentinelSnapshot
    ) -> [(book: Book, session: ReadingSession)] {
        snapshot.books.flatMap { book in book.sessions.map { (book, $0) } }
    }
}

// MARK: - Convenience

extension SentinelProbeDescriptor {
    /// A probe can be report-only while still having a repair: the repair is
    /// user-initiated when riskClass is R2+.
    var isFastProbe: Bool { tier.isFast }
}

extension SentinelEnvironment {
    /// Defaults to the configuration value when the runtime sets it.
    var effectiveOrphanSessionAge: TimeInterval {
        orphanSessionAge > 0 ? orphanSessionAge : 24 * 3600
    }
}
