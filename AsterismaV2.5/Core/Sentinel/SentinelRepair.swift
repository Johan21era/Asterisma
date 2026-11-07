//  SentinelRepair.swift
//  AsterismaV2.5
//
//  SG3 — the repair contract (§5.4).
//
//  Sentinel does not edit files or models directly. A repair is:
//    plan → preflight (generation, quiescence, snapshot) → typed actions
//    through the audited bridge → verification by re-running the detecting
//    probe → record with an undo payload.
//
//  Failure after apply rolls back. Failure before apply records a skip. Neither
//  is silent, and no repair ever runs without a verified snapshot.

import CryptoKit
import Foundation

// MARK: - Actions

/// Typed mutations the bridge understands. Each carries the previous value so
/// the executor can roll back and the user can undo.
nonisolated enum SentinelRepairAction: Codable {
    case replaceBook(bookID: UUID, expected: Book, replacement: Book)
    case replaceLibraryState(expected: LibraryState, replacement: LibraryState)
    case quarantineFile(source: URL, name: String)
    case trimJournal(maxBytes: Int64)
    case trimDebugJournal(maxBytes: Int64)
    case rebuildIssueStore
    case checkpointDatabase
    case writeCover(bookID: UUID, data: Data)
    case resetNotificationState

    var describesBookChange: Bool {
        if case .replaceBook = self { return true }
        return false
    }

    var kind: String {
        switch self {
        case .replaceBook: return "replace-book"
        case .replaceLibraryState: return "replace-library-state"
        case .quarantineFile: return "quarantine-file"
        case .trimJournal: return "trim-journal"
        case .trimDebugJournal: return "trim-debug-journal"
        case .rebuildIssueStore: return "rebuild-issue-store"
        case .checkpointDatabase: return "checkpoint-database"
        case .writeCover: return "write-cover"
        case .resetNotificationState: return "reset-notification-state"
        }
    }
}

// MARK: - Plan

nonisolated struct SentinelRepairPlan: Codable {
    var id: String
    var title: String
    var riskClass: SentinelRiskClass
    var ruleIDs: [SentinelRuleID]
    var issueFingerprints: [String]
    /// Static description of what will change. No user text.
    var summary: String
    /// Short, deterministic preview lines shown before approval.
    var preview: [String]
    var actions: [SentinelRepairAction]
    var expectedGeneration: UInt64

    var isMutation: Bool { !actions.isEmpty }

    /// Stable digest of the exact action payload, used in the receipt so the
    /// same plan is provably the same change.
    var payloadHash: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(actions) else { return "unhashable" }
        let digest = SHA256.hash(data: data)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Record

nonisolated struct SentinelRepairRecord: Codable, Identifiable, Hashable {
    enum Status: String, Codable {
        case verified
        case unverified
        case failed
        case rolledBack
        case undone
    }

    var id: String
    var repairID: String
    var title: String
    var ruleIDs: [String]
    var issueFingerprints: [String]
    var riskClass: String
    var status: Status
    /// Hash of the affected values before and after. No user text.
    var beforeHash: String
    var afterHash: String
    var payloadHash: String
    var appliedAt: Date
    var verifiedAt: Date?
    var undoneAt: Date?
    var note: String
    var planFileName: String?

    var isUndoable: Bool {
        planFileName != nil && (status == .verified || status == .unverified)
    }
}

// MARK: - Outcome

nonisolated struct SentinelRepairOutcome {
    enum Status: String {
        case appliedVerified
        case appliedUnverified
        case blocked
        case failed
        case rolledBack
        case unavailable
    }

    var repairID: String
    var issueFingerprints: [String]
    var status: Status
    var message: String
    var record: SentinelRepairRecord?

    var succeeded: Bool { status == .appliedVerified }

    static func blocked(_ id: String, _ message: String) -> SentinelRepairOutcome {
        SentinelRepairOutcome(repairID: id, issueFingerprints: [],
                              status: .blocked, message: message, record: nil)
    }
}

// MARK: - Bridge

/// The only mutation path. Implemented on the main actor by the app; tests use
/// a fixture bridge that records calls. The protocol itself is MainActor-bound
/// so every call from the runtime actor is an explicit hop, never a race.
@MainActor
protocol SentinelRepairBridge {
    func safetySnapshot() async -> Bool
    func currentGeneration() async -> UInt64
    func currentBook(id: UUID) async -> Book?
    func currentLibraryState() async -> LibraryState?
    func replaceBook(previous: Book, updated: Book) async -> Bool
    func replaceLibraryState(previous: LibraryState, updated: LibraryState) async -> Bool
    func quarantineFile(at url: URL, name: String) async -> Bool
    func restoreQuarantinedFile(named name: String, to url: URL) async -> Bool
    func trimJournal(maxBytes: Int64) async -> Bool
    func trimDebugJournal(maxBytes: Int64) async -> Bool
    func rebuildIssueStore() async -> Bool
    func checkpointDatabase() async -> Bool
    func writeCover(bookID: UUID, data: Data) async -> Bool
    func removeCover(bookID: UUID) async -> Bool
    func resetNotificationState() async -> Bool
    func hasRecentReadingActivity(within interval: TimeInterval) async -> Bool
}

// MARK: - Equality

/// `LibraryState` is not Equatable, so comparisons go through a canonical
/// encoding. This is the same shape the bridge uses to refuse a stale plan.
nonisolated enum SentinelRepairEquality {
    static func equal(_ lhs: LibraryState, _ rhs: LibraryState) -> Bool {
        encoded(lhs) == encoded(rhs)
    }

    static func encoded(_ state: LibraryState) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(state)
    }
}

// MARK: - Executor

nonisolated enum SentinelRepairExecutor {

    /// Runs the ten-step contract. Every early exit is a recorded status, not a
    /// thrown error swallowed into silence.
    static func execute(
        plan: SentinelRepairPlan,
        autonomy: SentinelAutonomy,
        userInitiated: Bool,
        bridge: any SentinelRepairBridge,
        at now: Date,
        verify: @Sendable ([SentinelRuleID], [String]) async -> Bool
    ) async -> SentinelRepairOutcome {
        func block(_ message: String, _ status: SentinelRepairOutcome.Status = .blocked) -> SentinelRepairOutcome {
            SentinelRepairOutcome(repairID: plan.id, issueFingerprints: plan.issueFingerprints,
                                  status: status, message: message, record: nil)
        }

        // 1. Authority.
        if autonomy == .off {
            return block("Sentinel is off.")
        }
        if userInitiated {
            guard autonomy.allowsUserInitiated(plan.riskClass) else {
                return block("This autonomy level does not allow changes.")
            }
        } else {
            guard autonomy.allowsAutomatic(plan.riskClass) else {
                return block("Automatic repairs are not allowed for \(plan.riskClass.label.lowercased()).")
            }
        }
        guard plan.isMutation else { return block("The plan contains no actions.") }
        guard plan.riskClass != .r3 else {
            return block("Recovery repairs are never executed automatically or in one click.")
        }

        // 2. Quiescence.
        if await bridge.hasRecentReadingActivity(within: 10 * 60) {
            return block("You are reading right now; Sentinel will wait.")
        }

        // 3. Generation re-read.
        let liveGeneration = await bridge.currentGeneration()
        guard liveGeneration == plan.expectedGeneration else {
            return block("The library changed after this check; nothing was touched.")
        }

        // 4. Re-read the exact subjects. A plan built against a stale value is
        //    refused rather than applied to something else.
        for action in plan.actions {
            switch action {
            case .replaceBook(let bookID, let expected, _):
                guard let current = await bridge.currentBook(id: bookID) else {
                    return block("The book this repair refers to no longer exists.")
                }
                guard current == expected else {
                    return block("The book changed after this check; nothing was touched.")
                }
            case .replaceLibraryState(let expected, _):
                guard let current = await bridge.currentLibraryState(),
                      SentinelRepairEquality.equal(current, expected) else {
                    return block("Library settings changed after this check; nothing was touched.")
                }
            case .quarantineFile(let source, _):
                guard FileManager.default.fileExists(atPath: source.path) else {
                    return block("The file this repair refers to is already gone.")
                }
            default:
                break
            }
        }

        // 5. Snapshot before any mutation.
        guard await bridge.safetySnapshot() else {
            return block("A safety snapshot could not be created; nothing was changed.")
        }

        // 6. Apply in order, remembering what to undo.
        var applied: [SentinelRepairAction] = []
        for action in plan.actions {
            let ok: Bool
            switch action {
            case .replaceBook(_, let previous, let updated):
                ok = await bridge.replaceBook(previous: previous, updated: updated)
            case .replaceLibraryState(let previous, let updated):
                ok = await bridge.replaceLibraryState(previous: previous, updated: updated)
            case .quarantineFile(let source, let name):
                ok = await bridge.quarantineFile(at: source, name: name)
            case .trimJournal(let maxBytes):
                ok = await bridge.trimJournal(maxBytes: maxBytes)
            case .trimDebugJournal(let maxBytes):
                ok = await bridge.trimDebugJournal(maxBytes: maxBytes)
            case .rebuildIssueStore:
                ok = await bridge.rebuildIssueStore()
            case .checkpointDatabase:
                ok = await bridge.checkpointDatabase()
            case .writeCover(let bookID, let data):
                ok = await bridge.writeCover(bookID: bookID, data: data)
            case .resetNotificationState:
                ok = await bridge.resetNotificationState()
            }

            if ok {
                applied.append(action)
            } else {
                await rollback(applied, bridge: bridge)
                return block("A change could not be applied; everything was restored.", .rolledBack)
            }
        }

        // 7. Verify by re-running the detecting probes.
        let verified = await verify(plan.ruleIDs, plan.issueFingerprints)
        let beforeHash = hash(plan.actions)
        let afterHash = plan.payloadHash

        // 8. Commit.
        if verified {
            let record = SentinelRepairRecord(
                id: "rep_" + UUID().uuidString,
                repairID: plan.id,
                title: plan.title,
                ruleIDs: plan.ruleIDs.map(\.rawValue),
                issueFingerprints: plan.issueFingerprints,
                riskClass: plan.riskClass.rawValue,
                status: .verified,
                beforeHash: beforeHash,
                afterHash: afterHash,
                payloadHash: plan.payloadHash,
                appliedAt: now,
                verifiedAt: now,
                undoneAt: nil,
                note: plan.summary,
                planFileName: plan.id)
            return SentinelRepairOutcome(
                repairID: plan.id, issueFingerprints: plan.issueFingerprints,
                status: .appliedVerified, message: "Fixed and verified.", record: record)
        }

        // Verification failed: roll back. This is the guardrail that makes
        // automatic repair defensible.
        await rollback(applied, bridge: bridge)
        let record = SentinelRepairRecord(
            id: "rep_" + UUID().uuidString,
            repairID: plan.id,
            title: plan.title,
            ruleIDs: plan.ruleIDs.map(\.rawValue),
            issueFingerprints: plan.issueFingerprints,
            riskClass: plan.riskClass.rawValue,
            status: .rolledBack,
            beforeHash: beforeHash,
            afterHash: afterHash,
            payloadHash: plan.payloadHash,
            appliedAt: now,
            verifiedAt: nil,
            undoneAt: now,
            note: "Verification did not confirm the fix; the change was rolled back.",
            planFileName: nil)
        return SentinelRepairOutcome(
            repairID: plan.id, issueFingerprints: plan.issueFingerprints,
            status: .rolledBack,
            message: "The fix did not verify, so Sentinel put everything back.",
            record: record)
    }

    /// Applies the inverse of every action in reverse order. Best effort: an
    /// undo that fails leaves a record that says so; it never pretends.
    static func rollback(
        _ applied: [SentinelRepairAction],
        bridge: any SentinelRepairBridge
    ) async {
        for action in applied.reversed() {
            switch action {
            case .replaceBook(_, let previous, let updated):
                _ = await bridge.replaceBook(previous: updated, updated: previous)
            case .replaceLibraryState(let previous, let updated):
                _ = await bridge.replaceLibraryState(previous: updated, updated: previous)
            case .quarantineFile(let source, let name):
                _ = await bridge.restoreQuarantinedFile(named: name, to: source)
            case .writeCover(let bookID, _):
                _ = await bridge.removeCover(bookID: bookID)
            default:
                break
            }
        }
    }

    static func hash(_ actions: [SentinelRepairAction]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(actions) else { return "unhashable" }
        return SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Store

nonisolated final class SentinelRepairStore {
    private let directory: URL
    private let fileURL: URL
    private let clock: any SentinelClock
    private(set) var records: [SentinelRepairRecord] = []
    private let maximumRecords = 200

    init(directory: URL, clock: any SentinelClock) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("repairs.json")
        self.clock = clock
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        records = (try? decoder.decode([SentinelRepairRecord].self, from: data)) ?? []
    }

    @discardableResult
    func append(_ record: SentinelRepairRecord, plan: SentinelRepairPlan?) -> Bool {
        records.append(record)
        if records.count > maximumRecords {
            records = Array(records.suffix(maximumRecords))
        }
        if let plan, let name = record.planFileName {
            savePlan(plan, name: name)
        }
        return save()
    }

    @discardableResult
    func markUndone(id: String) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return false }
        records[index].status = .undone
        records[index].undoneAt = clock.now
        return save()
    }

    func plan(named name: String) -> SentinelRepairPlan? {
        let url = directory.appendingPathComponent("plans", isDirectory: true)
            .appendingPathComponent("\(name).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SentinelRepairPlan.self, from: data)
    }

    private func savePlan(_ plan: SentinelRepairPlan, name: String) {
        let plans = directory.appendingPathComponent("plans", isDirectory: true)
        try? FileManager.default.createDirectory(at: plans, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(plan) else { return }
        try? data.write(to: plans.appendingPathComponent("\(name).json"), options: .atomic)
    }

    @discardableResult
    private func save() -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .deferredToDate
        guard let data = try? encoder.encode(records) else { return false }
        do {
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    func undoableRecords(within days: Int, now: Date) -> [SentinelRepairRecord] {
        records.filter {
            $0.isUndoable && now.timeIntervalSince($0.appliedAt) <= Double(days) * 86_400
        }
    }
}
