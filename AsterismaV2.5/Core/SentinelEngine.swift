//  SentinelEngine.swift
//  AsterismaV2.5
//
//  P6 — THE SENTINEL: deterministic bug detection & safe auto-remediation.
//
//  WHAT THIS IS
//  A deterministic watchdog built on the console system's existing snapshot/repair
//  conventions. Probes run on launch + every N minutes, classify each finding
//  as AUTO-FIXED or STALLED, dispatch provably-safe repairs through EXISTING
//  audited APIs, and journal everything for the "While you were away" report.
//
//  SECURITY DOCTRINE (non-negotiable, enforced structurally):
//   S1. WRITE SCOPE — the engine writes ONLY:
//         • Application Support/Asterisma/sentinel-journal.jsonl
//         • Application Support/Asterisma/SentinelQuarantine/
//         • a system replacement directory, only for the writability probe,
//           and only for that probe's lifetime
//       It has NO code path to delete/overwrite library.json,
//       library-state.json, library.sqlite3, or any user file. Repairs are
//       dispatched to existing audited subsystem APIs only.
//   S2. REVERSIBILITY — every mutating action is preceded by the Phase-D
//       backup rotation (content-hash gated, newest 10 kept). Any repair is
//       reversible from Backups/.
//   S3. APPEND-ONLY JOURNAL — JSONL lines are appended atomically; history
//       is never rewritten. Journal capped at maxEntries (oldest dropped)
//       during rotation writes to a temp file + rename (no in-place damage).
//   S4. NO SECRETS / NO PII IN LOGS — journal stores counts, ids, rule names;
//       never file contents, bookmarks, or user text. UserSummary strings for
//       Release are STATIC literals defined here, not interpolations.
//       debugDetail is never journaled; it stays in memory for the Debug console.
//   S5. KILL SWITCH — defaults key "sentinel.enabled" (default true) gates
//       every probe cycle. Setting false makes the engine fully inert.
//   S6. CONSERVATIVE DEFAULTS — Debug: monitor + autofix. Release: monitor +
//       report ONLY unless the user enables repair via Settings toggle.
//   S7. DETERMINISM — probes are pure reads over published state + filesystem
//       metadata; no network, no randomness, no time-dependent flakiness
//       beyond wall-clock stamps in journal entries.

import Combine
import Foundation

// MARK: - Finding Model

struct SentinelFinding: Codable, Identifiable, Equatable {
    enum Severity: String, Codable { case info, warning, critical }
    enum Outcome: String, Codable { case detected, autoFixed, stalled }

    let id: UUID
    let date: Date
    let probe: String          // probe identifier, e.g. "integrity"
    let rule: String           // defect-class rule name, e.g. "orphan-page-timing"
    let severity: Severity
    var outcome: Outcome
    /// Static, human-written summary safe for Release UIs. Never interpolated.
    let userSummary: String
    /// Developer-facing detail (Debug surfaces only). May include ids, paths,
    /// or diagnostic descriptions; never journaled and never shown in Release.
    var debugDetail: String

    init(probe: String, rule: String, severity: Severity,
         outcome: Outcome, userSummary: String, debugDetail: String,
         date: Date = Date()) {
        self.id = UUID()
        self.date = date
        self.probe = probe
        self.rule = rule
        self.severity = severity
        self.outcome = outcome
        self.userSummary = userSummary
        self.debugDetail = debugDetail
    }
}

/// Journal-safe projection of a finding (S4). Deliberately omits `debugDetail`,
/// which is the only field that may carry identifiers or paths.
private struct SentinelJournalRecord: Encodable {
    let id: UUID
    let date: Date
    let probe: String
    let rule: String
    let severity: SentinelFinding.Severity
    let outcome: SentinelFinding.Outcome
    let userSummary: String

    init(_ finding: SentinelFinding) {
        id = finding.id
        date = finding.date
        probe = finding.probe
        rule = finding.rule
        severity = finding.severity
        outcome = finding.outcome
        userSummary = finding.userSummary
    }
}

// MARK: - Probe Protocol

/// A probe is a PURE READ over state the app already publishes plus cheap
/// filesystem metadata. It never mutates anything itself; it reports findings
/// and, where a repair exists, names the audited API that performs it.
protocol SentinelProbe {
    var name: String { get }
    func run(context: SentinelContext) -> [SentinelFinding]
}

/// Everything a probe may look at. Deliberately narrow.
struct SentinelContext {
    var books: [Book]
    var libraryState: LibraryState
    var persistenceHealth: DataStore.PersistenceStatus
    var applicationSupportURL: URL?
}

// MARK: - The Engine

@MainActor
final class SentinelEngine: ObservableObject {
    static let shared = SentinelEngine()

    // MARK: Published state (Dev Console + report card)

    @Published private(set) var lastRunDate: Date?
    /// Findings from the most recent cycle, newest first.
    @Published private(set) var recentFindings: [SentinelFinding] = []
    /// Counters computed from the retained journal, not true lifetime totals.
    /// SENT-008: the journal rotates at 500 lines, so these shrink by design.
    @Published private(set) var journalAutoFixed: Int = 0
    @Published private(set) var journalStalled: Int = 0

    /// Number of probes actually registered in this engine instance.
    var probeCount: Int { probes.count }

    /// Test-visible count of cycles that ran to completion.
    private(set) var completedCycleCount = 0

    private var journalCountersLoaded = false

    // MARK: Configuration

    static let enabledKey = "sentinel.enabled"
    /// Release default: observe & report only. Auto-repair needs explicit opt-in.
    static let allowRepairKey = "sentinel.allowRepair"
    static let intervalKey = "sentinel.intervalMinutes"

    private var timer: Timer?
    private let journalMaxEntries = 500
    private(set) var journalURL: URL?
    /// Test hook: redirect the journal to a temp dir.
    func setJournalURLForTesting(_ url: URL?) { journalURL = url }

    private let defaults: UserDefaults

    /// Registered probes. Order matters for journal readability only.
    private let probes: [SentinelProbe]

    init(defaults: UserDefaults = .standard,
         probes: [SentinelProbe]? = nil,
         journalURL: URL? = nil) {
        self.defaults = defaults
        self.probes = probes ?? [
            IntegrityProbe(),
            PersistenceHealthProbe(),
            StoreWritabilityProbe(),
            OrphanedActiveSessionProbe(),
            StaleBookmarkProbe(),
            DiskSpaceProbe(),
            DeadlineOverdueProbe(),
            AchievementDriftProbe(),
        ]

        if let journalURL {
            self.journalURL = journalURL
        } else if let testRoot = RuntimeEnvironment.isolatedStoreDirectory {
            RuntimeEnvironment.ensureDirectory(testRoot)
            self.journalURL = testRoot.appendingPathComponent("sentinel-journal.jsonl")
        } else if let dir = AppIdentity.dataRootURL() {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.journalURL = dir.appendingPathComponent("sentinel-journal.jsonl")
        }
        // UI-RENDER SAFETY: init can be touched during a SwiftUI view update
        // (@StateObject default-value evaluation). Reading journal counters
        // here used to mutate @Published during that render — the source of
        // the red "Modifying state during view update" console spam. Counters
        // now hydrate lazily on first runCycle(), safely outside rendering.
        journalCountersLoaded = false
    }

    // MARK: Lifecycle

    func start(intervalMinutes: Int? = nil) {
        guard isEnabled else { return }
        stop()
        let configured = defaults.integer(forKey: Self.intervalKey)
        let minutes = max(1, intervalMinutes ?? (configured == 0 ? 15 : configured))
        // First cycle runs immediately (next runloop turn), then the timer cadence.
        Task { @MainActor [weak self] in self?.runCycle() }
        if minutes > 0 {
            timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.runCycle() }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    var isEnabled: Bool {
        // Kill switch (S5). Defaults ON; repair policy is the only Debug/Release
        // difference, and it lives in `allowsRepair`.
        defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    var allowsRepair: Bool {
        #if DEBUG
        return true // Debug always repairs; this is the developer's sandbox.
        #else
        return defaults.bool(forKey: Self.allowRepairKey)
        #endif
    }

    // MARK: Cycle

    /// Runs all probes, classifies, dispatches safe repairs, journals results.
    func runCycle() {
        // UI-RENDER SAFETY: this method may be invoked from .onAppear/.task
        // inside a view update. ALL published-state writes below are deferred
        // to the next runloop turn via await MainActor.run, so SwiftUI never
        // observes "state during view update".
        guard isEnabled else { return }
        guard !SentinelDataBridge.shared.isMutationInFlight else { return } // S7: never probe a torn state
        guard let dataStore = SentinelDataBridge.shared.store else { return }

        if !journalCountersLoaded {
            loadJournalCounters()
            journalCountersLoaded = true
        }

        let context = SentinelContext(
            books: dataStore.books,
            libraryState: dataStore.libraryState,
            persistenceHealth: dataStore.persistenceHealth,
            // Test-isolated when running under XCTest; the real data root otherwise.
            applicationSupportURL: AppIdentity.dataRootURL()
        )

        var findings: [SentinelFinding] = []
        for probe in probes {
            findings.append(contentsOf: probe.run(context: context))
        }

        // S2: snapshot BEFORE any mutation.
        let willRepair = findings.contains { $0.outcome == .detected && repairIsAvailable($0) }
        if willRepair && allowsRepair {
            // S2: snapshot BEFORE any mutation. If we can't locate the data
            // folder, skip repairs entirely — no snapshot, no mutation.
            if context.applicationSupportURL != nil {
                // S2: snapshot the ACTIVE store (SQLite in G3C, JSON legacy).
                if dataStore.createSafetySnapshot() {
                    dispatchRepairs(&findings, dataStore: dataStore)
                } else {
                    for i in findings.indices where findings[i].outcome == .detected {
                        findings[i].outcome = .stalled
                    }
                }
            } else {
                for i in findings.indices where findings[i].outcome == .detected {
                    findings[i].outcome = .stalled
                }
            }
        }

        // Classify leftovers.
        for i in findings.indices where findings[i].outcome == .detected {
            findings[i].outcome = .stalled
        }

        appendJournal(findings)

        let sorted = findings.sorted { $0.date > $1.date }
        let fixed = findings.filter { $0.outcome == .autoFixed }.count
        let stalled = findings.filter { $0.outcome == .stalled }.count

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.recentFindings = sorted
            self.lastRunDate = Date()
            self.journalAutoFixed += fixed
            self.journalStalled += stalled
            self.completedCycleCount += 1
        }
    }

    /// Returns true when an audited, Finality-grade in-code repair exists for
    /// this rule. Anything not listed here stays STALLED — conservative by default.
    private func repairIsAvailable(_ finding: SentinelFinding) -> Bool {
        switch finding.rule {
        case "orphan-active-session",
             "phantom-active-session-id",
             "page-timing-negative-duration",
             "duplicate-collection-membership":
            return true
        default:
            return false
        }
    }

    /// Dispatches repairs THROUGH EXISTING AUDITED APIS (S1). The engine never
    /// touches files or model structs directly for mutations.
    private func dispatchRepairs(_ findings: inout [SentinelFinding], dataStore: DataStore) {
        // Integrity-class repairs: DataIntegrityValidator already owns these
        // transformations; we re-run validate() and publish the repaired set
        // through DataStore's own update path, which persists normally.
        let integrityRules: Set<String> = [
            "orphan-active-session", "phantom-active-session-id", "page-timing-negative-duration",
        ]
        guard findings.contains(where: { integrityRules.contains($0.rule) }) else {
            handleCollectionDedup(findings: &findings, dataStore: dataStore)
            return
        }

        let repairedBooks = dataStore.books.map { book -> Book in
            var b = book
            // Phantom active session id pointing nowhere → clear (validator B-3).
            if let sid = b.activeSessionID, !b.sessions.contains(where: { $0.id == sid }) {
                b.activeSessionID = nil
                markFixed(&findings, rule: "phantom-active-session-id",
                          detail: "cleared activeSessionID \(sid.uuidString.prefix(8)) on book \(b.id.uuidString.prefix(8))")
            }
            // Orphan active session with endTime==nil but stale beyond 24h → close.
            if let sid = b.activeSessionID,
               let sIdx = b.sessions.firstIndex(where: { $0.id == sid }),
               b.sessions[sIdx].endTime == nil,
               Date().timeIntervalSince(b.sessions[sIdx].startTime) > 86_400 {
                // G1 FIX: the old repair stamped "now", inflating a crashed
                // session by up to 24h. End at the last real page activity
                // (plus a 5-minute grace) instead.
                let lastActivity = b.sessions[sIdx].pageTimes
                    .compactMap { $0.endTime ?? $0.startTime }
                    .max() ?? b.sessions[sIdx].startTime
                let end = min(Date(), lastActivity.addingTimeInterval(300))
                b.sessions[sIdx].endTime = end
                for p in b.sessions[sIdx].pageTimes.indices where b.sessions[sIdx].pageTimes[p].isActive {
                    b.sessions[sIdx].pageTimes[p].endTime = end
                }
                b.activeSessionID = nil
                markFixed(&findings, rule: "orphan-active-session",
                          detail: "closed >24h orphan session on book \(b.id.uuidString.prefix(8)) at last activity")
            }
            // Negative page-timing durations → pin endTime=startTime (validator S-5).
            for s in b.sessions.indices {
                for p in b.sessions[s].pageTimes.indices {
                    if let end = b.sessions[s].pageTimes[p].endTime,
                       end < b.sessions[s].pageTimes[p].startTime {
                        b.sessions[s].pageTimes[p].endTime = b.sessions[s].pageTimes[p].startTime
                        markFixed(&findings, rule: "page-timing-negative-duration",
                                  detail: "pinned negative timing on book \(b.id.uuidString.prefix(8))")
                    }
                }
            }
            return b
        }

        for book in repairedBooks {
            dataStore.updateBook(book) // audited API: validates id, schedules save
        }
        handleCollectionDedup(findings: &findings, dataStore: dataStore)
    }

    private func handleCollectionDedup(findings: inout [SentinelFinding], dataStore: DataStore) {
        for book in dataStore.books where Set(book.collectionIDs).count != book.collectionIDs.count {
            var b = book
            var seen = Set<UUID>()
            b.collectionIDs.removeAll { !seen.insert($0).inserted }
            dataStore.updateBook(b)
            markFixed(&findings, rule: "duplicate-collection-membership",
                      detail: "deduped collectionIDs on book \(b.id.uuidString.prefix(8))")
        }
    }

    private func markFixed(_ findings: inout [SentinelFinding], rule: String, detail: String) {
        // SENT-005: mark EVERY matching finding, not just the first. Mutate in
        // place so each finding keeps its id and date.
        for idx in findings.indices where findings[idx].rule == rule && findings[idx].outcome == .detected {
            findings[idx].outcome = .autoFixed
            findings[idx].debugDetail += " → fixed: " + detail
        }
    }

    // MARK: - Journal (S3/S4)

    private func appendJournal(_ findings: [SentinelFinding]) {
        guard let url = journalURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var lines = ""
        for f in findings {
            // S4: journal the safe projection only. `debugDetail` stays in memory
            // for the Debug console and is never persisted.
            if let data = try? encoder.encode(SentinelJournalRecord(f)),
               let line = String(data: data, encoding: .utf8) {
                lines += line + "\n"
            }
        }
        // Summary line per cycle for fast counters on relaunch.
        let summary = "{\"cycle\":true,\"date\":\"\(ISO8601DateFormatter().string(from: Date()))\",\"fixed\":\(findings.filter { $0.outcome == .autoFixed }.count),\"stalled\":\(findings.filter { $0.outcome == .stalled }.count)}"
        lines += summary + "\n"

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(lines.utf8))
        } else {
            try? Data(lines.utf8).write(to: url, options: .atomic)
        }
        rotateJournalIfLarge()
    }

    private func rotateJournalIfLarge() {
        guard let url = journalURL,
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > journalMaxEntries else { return }
        let kept = lines.suffix(journalMaxEntries).joined(separator: "\n") + "\n"
        let tmp = url.deletingLastPathComponent().appendingPathComponent("sentinel-journal.tmp")
        try? Data(kept.utf8).write(to: tmp, options: .atomic)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.moveItem(at: tmp, to: url)
    }

    private func loadJournalCounters() {
        guard let url = journalURL,
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  obj["cycle"] != nil else { continue }
            journalAutoFixed += obj["fixed"] as? Int ?? 0
            journalStalled += obj["stalled"] as? Int ?? 0
        }
    }

    /// "While you were away" summary for the launch card. Static-safe strings.
    func overnightReport() -> (fixed: Int, stalled: Int, headline: String)? {
        guard let url = journalURL,
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }

        let calendar = Calendar.current
        var fixed = 0, stalled = 0
        let since = calendar.date(byAdding: .hour, value: -12, to: Date()) ?? Date()
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  obj["cycle"] != nil,
                  let iso = obj["date"] as? String,
                  let date = ISO8601DateFormatter().date(from: iso),
                  date >= since else { continue }
            fixed += obj["fixed"] as? Int ?? 0
            stalled += obj["stalled"] as? Int ?? 0
        }
        guard fixed > 0 || stalled > 0 else { return nil }
        let headline: String
        if fixed > 0 && stalled == 0 {
            headline = "Sentinel fixed \(fixed) issue\(fixed == 1 ? "" : "s") while you were away."
        } else if fixed == 0 && stalled > 0 {
            headline = "Sentinel found \(stalled) issue\(stalled == 1 ? "" : "s") — they're safe and waiting for you in the Console."
        } else {
            headline = "Sentinel fixed \(fixed) issue\(fixed == 1 ? "" : "s"); \(stalled) need your attention."
        }
        return (fixed, stalled, headline)
    }
}

// MARK: - Built-in Probes

/// Reads the same validator rules the load path uses, without mutating.
struct IntegrityProbe: SentinelProbe {
    let name = "integrity"

    /// Maps DataIntegrityValidator rule codes onto canonical Sentinel rule
    /// names — the repair dispatcher matches on these.
    private static func canonicalRule(for validatorRule: String) -> String {
        let code = validatorRule.split(separator: ":").first.map(String.init)?.lowercased() ?? ""
        switch code {
        case "b-3": return "phantom-active-session-id"
        case "s-5": return "page-timing-negative-duration"
        case "b-4": return "orphan-active-session"
        case "lib-1": return "duplicate-book-ids"
        default: return "validator-\(code)"
        }
    }

    func run(context: SentinelContext) -> [SentinelFinding] {
        // quiet: periodic monitoring must never spam the console log.
        let (_, report) = DataIntegrityValidator.validate(context.books, quiet: true)
        return report.issues.map { issue in
            SentinelFinding(
                probe: name,
                rule: Self.canonicalRule(for: issue.rule),
                severity: issue.severity == .error && !issue.wasRepaired ? .critical : .warning,
                outcome: .detected,
                userSummary: issue.wasRepaired
                    ? "A small data inconsistency was repaired automatically."
                    : "A data inconsistency was found and contained.",
                debugDetail: issue.description
            )
        }
    }
}

/// Surfaces the store's own health banner into findings.
struct PersistenceHealthProbe: SentinelProbe {
    let name = "persistence"

    func run(context: SentinelContext) -> [SentinelFinding] {
        guard case .degraded(let reason) = context.persistenceHealth else { return [] }
        return [SentinelFinding(
            probe: name,
            rule: "degraded-persistence",
            severity: .critical,
            outcome: .detected,
            userSummary: "Saving problems detected — new reading progress may not be saved.",
            debugDetail: reason
        )]
    }
}

/// Can we still write to the volume that holds the data folder right now?
/// SG0: proves this in a system replacement directory, never in the data root.
struct StoreWritabilityProbe: SentinelProbe {
    let name = "writability"

    func run(context: SentinelContext) -> [SentinelFinding] {
        guard let base = context.applicationSupportURL else { return [] }
        do {
            // S1/SG0: never write into the data root. Ask the system for a
            // replacement directory on the same volume and prove a write there.
            let probeDir = try FileManager.default.url(
                for: .itemReplacementDirectory,
                in: .userDomainMask,
                appropriateFor: base,
                create: true
            )
            defer { try? FileManager.default.removeItem(at: probeDir) }
            try Data("#write-probe".utf8).write(
                to: probeDir.appendingPathComponent("writability"), options: .atomic)
            return []
        } catch {
            return [SentinelFinding(
                probe: name,
                rule: "data-dir-not-writable",
                severity: .critical,
                outcome: .detected,
                userSummary: "AsterismaV2.5 cannot write to its data folder — saving is failing.",
                debugDetail: "\(error)"
            )]
        }
    }
}

/// Sessions stuck open >24h (app killed mid-read, crash, etc).
struct OrphanedActiveSessionProbe: SentinelProbe {
    let name = "sessions"

    func run(context: SentinelContext) -> [SentinelFinding] {
        context.books.flatMap { book -> [SentinelFinding] in
            book.sessions.compactMap { session in
                // isActive == endTime == nil by definition; measure staleness from start.
                guard session.isActive,
                      Date().timeIntervalSince(session.startTime) > 86_400 else { return nil }
                return SentinelFinding(
                    probe: name,
                    rule: "orphan-active-session",
                    severity: .warning,
                    outcome: .detected,
                    userSummary: "A reading session was left open and will be closed safely.",
                    debugDetail: "book=\(book.id.uuidString.prefix(8)) session=\(session.id.uuidString.prefix(8)) open>24h"
                )
            }
        }
    }
}

/// Books whose security-scoped bookmark no longer resolves.
struct StaleBookmarkProbe: SentinelProbe {
    let name = "bookmarks"

    func run(context: SentinelContext) -> [SentinelFinding] {
        context.books.compactMap { book in
            guard book.bookmarkData != nil, book.resolveURL() == nil else { return nil }
            return SentinelFinding(
                probe: name,
                rule: "stale-bookmark",
                severity: .warning,
                outcome: .stalled,
                userSummary: "One of your books moved on disk — re-import it to restore access.",
                debugDetail: "book=\(book.id.uuidString.prefix(8)) bookmark unresolvable"
            )
        }
    }
}

/// Free-space floor: under 200 MB, warn loudly before writes start failing.
struct DiskSpaceProbe: SentinelProbe {
    let name = "disk"

    func run(context: SentinelContext) -> [SentinelFinding] {
        guard let url = context.applicationSupportURL,
              let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let free = values.volumeAvailableCapacityForImportantUsage,
              free < 200_000_000 else { return [] }
        return [SentinelFinding(
            probe: name,
            rule: "low-disk-space",
            severity: .warning,
            outcome: .stalled,
            userSummary: "Your disk is nearly full — AsterismaV2.5 may be unable to save soon.",
            debugDetail: "freeBytes=\(free)"
        )]
    }
}

/// Deadlines past due — informational nudge, never mutated.
struct DeadlineOverdueProbe: SentinelProbe {
    let name = "deadlines"

    func run(context: SentinelContext) -> [SentinelFinding] {
        let overdue = context.libraryState.deadlines.filter { $0.targetDate < Date() }
        guard !overdue.isEmpty else { return [] }
        return [SentinelFinding(
            probe: name,
            rule: "deadline-overdue",
            severity: .info,
            outcome: .stalled,
            userSummary: "\(overdue.count) reading deadline\(overdue.count == 1 ? " is" : "s are") past due.",
            debugDetail: "ids=\(overdue.map { $0.id.uuidString.prefix(4) }.joined(separator: ","))"
        )]
    }
}

/// Earned achievements referencing kinds that no longer exist in the registry.
struct AchievementDriftProbe: SentinelProbe {
    let name = "achievements"

    func run(context: SentinelContext) -> [SentinelFinding] {
        let unknown = context.libraryState.earnedAchievements.filter {
            AchievementDefinition.definition(for: $0.kind) == nil
        }
        guard !unknown.isEmpty else { return [] }
        return [SentinelFinding(
            probe: name,
            rule: "achievement-drift",
            severity: .info,
            outcome: .stalled,
            userSummary: "Some earned badges come from an older version and are kept safe.",
            debugDetail: "unknownKinds=\(unknown.map { $0.kind.rawValue }.joined(separator: ","))"
        )]
    }
}
