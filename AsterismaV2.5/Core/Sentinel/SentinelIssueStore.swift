//  SentinelIssueStore.swift
//  AsterismaV2.5
//
//  SG1 — durable issue memory.
//
//  Two files, both inside `Sentinel/`:
//    state.json         authoritative issue set, atomic write
//    state.backup.json  previous good copy, written before every save
//
//  Crash safety: a torn or unreadable state file falls back to the backup,
//  and then to a rebuild from journal events. Sentinel never starts with a
//  silently empty memory when evidence exists on disk.
//
//  This type performs synchronous file I/O by design. It is owned by the
//  runtime actor, never by a view.

import Foundation

nonisolated final class SentinelIssueStore {
    struct State: Codable, Sendable {
        var schemaVersion: Int
        var sequence: Int
        var updatedAt: Date
        var issues: [SentinelIssue]
        /// True lifetime totals. Unlike the SG0 journal counters, these do not
        /// shrink when a journal segment is pruned.
        var counters: [String: Int]

        static let empty = State(
            schemaVersion: SentinelIssue.currentSchemaVersion,
            sequence: 0,
            updatedAt: Date(timeIntervalSinceReferenceDate: 0),
            issues: [],
            counters: [:])
    }

    enum LoadOutcome: Equatable, Sendable {
        case loaded
        case recoveredFromBackup
        case rebuiltFromJournal
        case empty
        case failed(String)

        var isDegraded: Bool {
            switch self {
            case .recoveredFromBackup, .rebuiltFromJournal, .failed:
                return true
            case .loaded, .empty:
                return false
            }
        }
    }

    private let paths: SentinelPaths
    private let clock: any SentinelClock
    let journal: SentinelJournalV2

    private(set) var sequence: Int = 0
    private(set) var lastLoadOutcome: LoadOutcome = .empty
    private(set) var lastSaveError: String?
    private(set) var counters: [String: Int] = [:]

    init(paths: SentinelPaths, clock: any SentinelClock, journal: SentinelJournalV2) {
        self.paths = paths
        self.clock = clock
        self.journal = journal
        paths.ensureDirectories()
    }

    // MARK: - Load

    @discardableResult
    func load() -> [SentinelIssue] {
        if let state = decodeState(at: paths.stateFile) {
            sequence = max(sequence, state.sequence)
            counters = state.counters
            lastLoadOutcome = .loaded
            return sanitize(state.issues)
        }

        if let backup = decodeState(at: paths.stateBackup) {
            sequence = max(sequence, backup.sequence)
            counters = backup.counters
            lastLoadOutcome = .recoveredFromBackup
            return sanitize(backup.issues)
        }

        let rebuilt = recoverFromJournal()
        if !rebuilt.isEmpty {
            lastLoadOutcome = .rebuiltFromJournal
            return rebuilt
        }

        lastLoadOutcome = FileManager.default.fileExists(atPath: paths.stateFile.path) ? .failed("state unreadable") : .empty
        return []
    }

    private func decodeState(at url: URL) -> State? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        guard let state = try? decoder.decode(State.self, from: data) else { return nil }
        guard state.schemaVersion <= SentinelIssue.currentSchemaVersion else { return nil }
        return state
    }

    /// Repairs impossible values rather than dropping the issue. Fingerprint is
    /// the identity; an issue without one cannot be deduped, so it is dropped
    /// and reported by SELF-002 instead.
    private func sanitize(_ issues: [SentinelIssue]) -> [SentinelIssue] {
        var seen = Set<String>()
        var result: [SentinelIssue] = []
        for var issue in issues {
            guard !issue.fingerprint.isEmpty, issue.fingerprint.count == 16 else { continue }
            guard seen.insert(issue.fingerprint).inserted else { continue }
            if issue.subjects.isEmpty, issue.severity >= .warning {
                // L5: evidence-bearing severity requires a subject. Keep the
                // issue but flag it unactionable rather than fabricating one.
                issue.status = .unactionable
            }
            if issue.evidence.isEmpty, issue.severity >= .warning {
                issue.status = .unactionable
            }
            issue.schemaVersion = SentinelIssue.currentSchemaVersion
            result.append(issue)
        }
        return result
    }

    // MARK: - Save

    @discardableResult
    func save(_ issues: [SentinelIssue]) -> Bool {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: paths.root, withIntermediateDirectories: true)

            if manager.fileExists(atPath: paths.stateFile.path) {
                try? manager.removeItem(at: paths.stateBackup)
                try? manager.copyItem(at: paths.stateFile, to: paths.stateBackup)
            }

            let state = State(
                schemaVersion: SentinelIssue.currentSchemaVersion,
                sequence: sequence,
                updatedAt: clock.now,
                issues: issues,
                counters: counters)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .deferredToDate
            let data = try encoder.encode(state)
            try data.write(to: paths.stateFile, options: .atomic)
            lastSaveError = nil
            return true
        } catch {
            lastSaveError = error.localizedDescription
            return false
        }
    }

    // MARK: - Journal

    func record(_ entry: SentinelJournalEntry) {
        sequence = max(sequence, entry.sequence)
        journal.append(entry)
    }

    func nextSequence() -> Int {
        sequence + 1
    }

    func bump(_ key: String, by amount: Int = 1) {
        counters[key, default: 0] += amount
    }

    func replaceCounters(_ newValue: [String: Int]) {
        counters = newValue
    }

    // MARK: - Rebuild

    /// Reconstructs identity and lifecycle from journal events. This is
    /// deliberately minimal: fingerprints, rule, status, and first/last seen.
    /// Evidence and copy are re-derived by the next cycle.
    func recoverFromJournal() -> [SentinelIssue] {
        let result = journal.readAll()
        var byFingerprint: [String: SentinelIssue] = [:]
        var order: [String] = []

        for entry in result.entries {
            guard let fingerprint = entry.fingerprint,
                  let ruleText = entry.ruleID else { continue }

            if var existing = byFingerprint[fingerprint] {
                if let statusText = entry.status,
                   let status = SentinelIssueStatus(rawValue: statusText) {
                    existing.status = status
                }
                existing.lastSeen = max(existing.lastSeen, entry.at)
                existing.occurrenceCount += entry.counts["occurrences"] ?? 0
                if let severityText = entry.severity,
                   let severity = SentinelSeverity(rawValue: severityText),
                   severity > existing.severity {
                    existing.severity = severity
                }
                byFingerprint[fingerprint] = existing
                continue
            }

            let status = entry.status.flatMap(SentinelIssueStatus.init(rawValue:)) ?? .open
            byFingerprint[fingerprint] = SentinelIssue(
                fingerprint: fingerprint,
                ruleID: SentinelRuleID(ruleText),
                ruleVersion: entry.ruleVersion ?? 1,
                rootCauseKey: entry.rootCauseKey ?? "recovered",
                domain: entry.domain.flatMap(SentinelDomain.init(rawValue:)) ?? .library,
                titleKey: entry.titleKey ?? "issue.recovered.title",
                status: status,
                severity: entry.severity.flatMap(SentinelSeverity.init(rawValue:)) ?? .warning,
                confidence: 0.5,
                impact: .medium,
                subjects: [],
                evidence: [
                    SentinelEvidence(
                        kind: .coverage,
                        labelKey: "evidence.recovered",
                        safeValue: "rebuilt from journal",
                        observedAt: entry.at,
                        source: .sentinel)
                ],
                safeSummary: entry.note ?? "A condition was recorded earlier and rebuilt from the journal.",
                firstSeen: entry.at,
                lastSeen: entry.at,
                occurrenceCount: max(1, entry.counts["occurrences"] ?? 1),
                updatedAt: entry.at)
            order.append(fingerprint)
        }

        sequence = max(sequence, result.entries.map(\.sequence).max() ?? 0)
        return order.compactMap { byFingerprint[$0] }
    }

    // MARK: - Maintenance

    /// Archival copy used before a deliberate rebuild (REP-034). Returns the
    /// archived URL so a receipt can point at it.
    func archiveState(reason: String) -> URL? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: paths.stateFile.path) else { return nil }
        do {
            try manager.createDirectory(at: paths.archiveDirectory, withIntermediateDirectories: true)
            let stamp = SentinelFormat.iso(clock.now).replacingOccurrences(of: ":", with: "-")
            let url = paths.archiveDirectory.appendingPathComponent("state-\(reason)-\(stamp).json")
            try manager.copyItem(at: paths.stateFile, to: url)
            return url
        } catch {
            return nil
        }
    }

    var stateFileByteSize: Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: paths.stateFile.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    var hasStateFile: Bool {
        FileManager.default.fileExists(atPath: paths.stateFile.path)
    }
}
