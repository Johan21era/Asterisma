//  SentinelJournal.swift
//  AsterismaV2.5
//
//  SG1 — journal v2: segmented, checksummed, safe-by-default.
//
//  S3 (append-only) survives, but the v1 journal had three weaknesses this
//  fixes:
//    1. every finding was journaled every cycle → 96 duplicate lines/day;
//    2. rotation rewrote the file, which could lose a tail mid-crash;
//    3. there was no integrity check, so a torn line looked like data.
//
//  V2 writes an entry only when something *changes* (issue opened, state
//  changed, repair event, one cycle summary). Each line carries a checksum of
//  its canonical body. Segments rotate at a fixed line count and old segments
//  are pruned by count, never rewritten in place.
//
//  PRIVACY (L13): entries carry rule IDs, fingerprints, counts, and enum
//  values only. `debugValue`, titles, paths, and free-form text cannot reach
//  this file because the entry type has no field for them.

import Foundation

nonisolated enum SentinelJournalEvent: String, Codable, CaseIterable, Sendable {
    case cycle
    case issueOpened
    case issueUpdated
    case issueClosed
    case probeSkipped
    case coverage
    case repairPlanned
    case repairApplied
    case repairVerified
    case repairFailed
    case repairUndone
    case migration
    // Phase 6 — recovery boundary. No probes run while suspended.
    case sentinelSuspended
    case sentinelResumed
    case recoveryVerified
    /// Forward compatibility (P6-4): a build that does not know an event must
    /// count it as unknown, never as a corrupt line.
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

nonisolated struct SentinelJournalEntry: Codable, Hashable, Sendable {
    var sequence: Int
    var event: SentinelJournalEvent
    var at: Date
    var cycleID: String
    var fingerprint: String?
    var ruleID: String?
    var domain: String?
    var severity: String?
    var status: String?
    var ruleVersion: Int?
    var rootCauseKey: String?
    var titleKey: String?
    var repairID: String?
    /// Set only on recovery-boundary events. The incident id is opaque and
    /// contains no path.
    var incidentID: String?
    var counts: [String: Int]
    /// Static, rule-owned note. Never user text.
    var note: String?

    init(
        sequence: Int,
        event: SentinelJournalEvent,
        at: Date,
        cycleID: String = "",
        fingerprint: String? = nil,
        ruleID: String? = nil,
        domain: String? = nil,
        severity: String? = nil,
        status: String? = nil,
        ruleVersion: Int? = nil,
        rootCauseKey: String? = nil,
        titleKey: String? = nil,
        repairID: String? = nil,
        incidentID: String? = nil,
        counts: [String: Int] = [:],
        note: String? = nil
    ) {
        self.sequence = sequence
        self.event = event
        self.at = at
        self.cycleID = cycleID
        self.fingerprint = fingerprint
        self.ruleID = ruleID
        self.domain = domain
        self.severity = severity
        self.status = status
        self.ruleVersion = ruleVersion
        self.rootCauseKey = rootCauseKey
        self.titleKey = titleKey
        self.repairID = repairID
        self.incidentID = incidentID
        self.counts = counts
        self.note = note
    }
}

nonisolated final class SentinelJournalV2 {
    struct ReadResult: Sendable {
        var entries: [SentinelJournalEntry]
        var corruptLines: Int
        var totalLines: Int
        var segments: Int
    }

    private let directory: URL
    private let clock: any SentinelClock
    private let maxEntriesPerSegment: Int
    private let maxSegments: Int
    private var lineCounts: [Int: Int] = [:]
    private let lock = NSLock()

    init(
        directory: URL,
        clock: any SentinelClock = SystemSentinelClock(),
        maxEntriesPerSegment: Int = 1_000,
        maxSegments: Int = 4
    ) {
        self.directory = directory
        self.clock = clock
        self.maxEntriesPerSegment = max(100, maxEntriesPerSegment)
        self.maxSegments = max(1, maxSegments)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        loadLineCounts()
    }

    // MARK: - Encoding

    /// Shared formatters. Journal access is serialized by the runtime actor;
    /// tests use one journal at a time.
    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let isoFormatterNoFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(isoFormatter.string(from: date))
        }
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self),
               let date = isoFormatter.date(from: text) ?? isoFormatterNoFraction.date(from: text) {
                return date
            }
            return Date(timeIntervalSinceReferenceDate: try container.decode(Double.self))
        }
        return decoder
    }

    /// FNV-1a 64. Fast, deterministic, and adequate for detecting torn lines.
    static func checksum(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf0_29ce_4842_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    private struct Envelope: Codable {
        var v: Int
        var crc: String
        var body: SentinelJournalEntry
    }

    private func encodeLine(_ entry: SentinelJournalEntry) -> Data? {
        let encoder = Self.makeEncoder()
        guard let body = try? encoder.encode(entry) else { return nil }
        let envelope = Envelope(v: 2, crc: Self.checksum(body), body: entry)
        guard var data = try? encoder.encode(envelope) else { return nil }
        data.append(0x0A)
        return data
    }

    // MARK: - Segment bookkeeping

    private func segmentURL(_ index: Int) -> URL {
        directory.appendingPathComponent(String(format: "journal-%06d.jsonl", index))
    }

    private var segmentIndices: [Int] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name -> Int? in
            guard name.hasPrefix("journal-"), name.hasSuffix(".jsonl") else { return nil }
            let digits = name.dropFirst("journal-".count).dropLast(".jsonl".count)
            return Int(digits)
        }.sorted()
    }

    private func loadLineCounts() {
        for index in segmentIndices {
            let url = segmentURL(index)
            guard let data = try? Data(contentsOf: url) else { continue }
            lineCounts[index] = data.split(separator: 0x0A, omittingEmptySubsequences: true).count
        }
    }

    private var activeSegment: Int {
        segmentIndices.last ?? 0
    }

    // MARK: - Append

    @discardableResult
    func append(_ entry: SentinelJournalEntry) -> Bool {
        guard let line = encodeLine(entry) else { return false }
        lock.lock()
        defer { lock.unlock() }

        var index = activeSegment
        if (lineCounts[index] ?? 0) >= maxEntriesPerSegment {
            index += 1
            lineCounts[index] = 0
        }

        let url = segmentURL(index)
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
            guard (try? line.write(to: url, options: .atomic)) != nil else { return false }
        } else {
            guard let handle = try? FileHandle(forWritingTo: url) else { return false }
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } catch {
                return false
            }
        }
        lineCounts[index, default: 0] += 1
        pruneIfNeeded()
        return true
    }

    @discardableResult
    func append(contentsOf entries: [SentinelJournalEntry]) -> Int {
        entries.reduce(0) { $0 + (append($1) ? 1 : 0) }
    }

    private func pruneIfNeeded() {
        let indices = segmentIndices
        guard indices.count > maxSegments else { return }
        for index in indices.dropLast(maxSegments) {
            try? FileManager.default.removeItem(at: segmentURL(index))
            lineCounts[index] = nil
        }
    }

    // MARK: - Read

    func readAll() -> ReadResult {
        lock.lock()
        defer { lock.unlock() }

        let decoder = Self.makeDecoder()
        var entries: [SentinelJournalEntry] = []
        var corrupt = 0
        var total = 0
        let indices = segmentIndices

        for index in indices {
            guard let data = try? Data(contentsOf: segmentURL(index)) else { continue }
            for lineSlice in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                total += 1
                let line = Data(lineSlice)
                guard let envelope = try? decoder.decode(Envelope.self, from: line),
                      let body = try? Self.makeEncoder().encode(envelope.body),
                      Self.checksum(body) == envelope.crc
                else {
                    corrupt += 1
                    continue
                }
                entries.append(envelope.body)
            }
        }

        return ReadResult(
            entries: entries.sorted { $0.sequence < $1.sequence },
            corruptLines: corrupt,
            totalLines: total,
            segments: indices.count
        )
    }

    // MARK: - Budget

    func totalBytes() -> Int64 {
        segmentIndices.reduce(Int64(0)) { partial, index in
            partial + (fileSize(at: segmentURL(index)) ?? 0)
        }
    }

    private func fileSize(at url: URL) -> Int64? {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value
    }

    /// Deletes the oldest segment(s) until the byte budget is met. Used by
    /// REP-018; the newest segment is never deleted.
    @discardableResult
    func trimToByteBudget(_ maxBytes: Int64) -> Int {
        lock.lock()
        defer { lock.unlock() }
        var removed = 0
        var indices = segmentIndices
        var bytes = totalBytesLocked()
        while bytes > maxBytes && indices.count > 1 {
            let oldest = indices.removeFirst()
            try? FileManager.default.removeItem(at: segmentURL(oldest))
            lineCounts[oldest] = nil
            removed += 1
            bytes = totalBytesLocked()
        }
        return removed
    }

    private func totalBytesLocked() -> Int64 {
        segmentIndices.reduce(Int64(0)) { partial, index in
            partial + (fileSize(at: segmentURL(index)) ?? 0)
        }
    }

    // MARK: - Migration

    /// Imports the v1 journal's cycle summaries as one migration record, then
    /// archives the file. It never deletes history: the v1 file is moved, not
    /// removed.
    @discardableResult
    func migrateFromV1(at legacyURL: URL) -> (importedCycles: Int, archivedAt: URL?) {
        guard FileManager.default.fileExists(atPath: legacyURL.path),
              let data = try? Data(contentsOf: legacyURL),
              let text = String(data: data, encoding: .utf8) else {
            return (0, nil)
        }

        var cycles = 0
        var fixed = 0
        var stalled = 0
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  object["cycle"] != nil else { continue }
            cycles += 1
            fixed += object["fixed"] as? Int ?? 0
            stalled += object["stalled"] as? Int ?? 0
        }

        if cycles > 0 {
            append(SentinelJournalEntry(
                sequence: -1,
                event: .migration,
                at: clock.now,
                counts: ["cycles": cycles, "fixed": fixed, "stalled": stalled],
                note: "Imported the v1 journal summary."))
        }

        let archive = directory.deletingLastPathComponent()
            .appendingPathComponent("archive", isDirectory: true)
        try? FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let target = archive.appendingPathComponent("sentinel-journal-v1.migrated.jsonl")
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.moveItem(at: legacyURL, to: target)
            return (cycles, target)
        } catch {
            return (cycles, nil)
        }
    }
}
