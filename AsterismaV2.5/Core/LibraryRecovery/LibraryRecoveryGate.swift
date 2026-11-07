//  LibraryRecoveryGate.swift
//  Library Safety — Phase 6
//
//  The boundary between Sentinel and Library Recovery. Sentinel may observe and
//  report, but it must stop probing and repairing while the library is being
//  recovered. This file is the only vocabulary the two subsystems share, and it
//  contains no paths, no user text, and no file access.

import Foundation

// MARK: - Operational mode

nonisolated enum LibraryOperationalMode: Sendable, Equatable {
    case normal
    case suspended(LibrarySuspensionReason)

    var isSuspended: Bool {
        if case .suspended = self { return true }
        return false
    }

    var suspensionReason: LibrarySuspensionReason? {
        if case let .suspended(reason) = self { return reason }
        return nil
    }
}

nonisolated enum LibrarySuspensionReason: String, Codable, CaseIterable, Sendable {
    case incidentOpen
    case storeFrozen
    case recoveryExecuting
    case recoveryVerifying

    var messageKey: String {
        switch self {
        case .incidentOpen: return "sentinel.suspended.incidentOpen"
        case .storeFrozen: return "sentinel.suspended.storeFrozen"
        case .recoveryExecuting: return "sentinel.suspended.recoveryExecuting"
        case .recoveryVerifying: return "sentinel.suspended.recoveryVerifying"
        }
    }
}

/// Sentinel reads this protocol; it never imports the coordinator, the incident
/// store, or any recovery implementation. The requirement is main-actor
/// isolated so the coordinator can witness it without escaping its isolation.
nonisolated protocol SentinelRecoveryGate: Sendable {
    @MainActor func operationalMode() async -> LibraryOperationalMode
}

/// A gate that is always open. Used by unit tests and by JSON-mode launches
/// where recovery does not apply.
nonisolated struct AlwaysOpenRecoveryGate: SentinelRecoveryGate {
    init() {}
    @MainActor func operationalMode() async -> LibraryOperationalMode { .normal }
}

/// A test/lifecycle gate whose value can be changed from outside.
@MainActor
final class MutableRecoveryGate: SentinelRecoveryGate {
    private var mode: LibraryOperationalMode

    init(_ mode: LibraryOperationalMode = .normal) {
        self.mode = mode
    }

    func set(_ mode: LibraryOperationalMode) {
        self.mode = mode
    }

    func operationalMode() async -> LibraryOperationalMode { mode }
}

// MARK: - Incident candidate

/// The only recovery type Sentinel may emit. It is a *candidate*: promotion to
/// an incident is decided by `SentinelIncidentPromotion`, never by Sentinel.
nonisolated struct LibraryIncidentCandidate: Sendable, Equatable {
    var kind: LibraryIncidentKind
    var ruleID: String?
    var fingerprint: String?
    var severity: SentinelSeverity
    var evidence: [LibraryEvidence]
    var detectedAt: Date
}

nonisolated enum SentinelIncidentPromotion {

    /// Structural damage that makes the store unsafe to keep writing to. These
    /// are the only rules that may freeze a healthy-looking app. Everything
    /// else stays a Sentinel issue with a previewed repair.
    ///
    /// SQL-001  integrity_check is not "ok"
    /// SQL-006  the schema is incomplete (meta/table set missing)
    ///
    /// Deliberately excluded:
    ///   SQL-002  orphan rows — writable, repaired by row repair, not a freeze
    ///   SQL-003  count parity — a consistency symptom, not structural damage
    ///   SQL-004  duplicate ids — repaired per row, does not block SQLite
    ///   SQL-005…SQL-015 — hygiene, size, timestamps, payload decode
    static let promotableRuleIDs: Set<String> = ["SQL-001", "SQL-006"]

    /// Promotion also requires a critical finding. A rule on the allowlist that
    /// fired at warning severity is evidence, not a freeze.
    static func shouldPromote(_ candidate: LibraryIncidentCandidate) -> Bool {
        guard candidate.severity == .critical else { return false }
        guard let ruleID = candidate.ruleID,
              promotableRuleIDs.contains(ruleID) else { return false }
        return true
    }

    static func candidate(
        from issue: SentinelIssue,
        now: Date = Date()
    ) -> LibraryIncidentCandidate? {
        guard issue.status.isActiveForPromotion else { return nil }
        guard promotableRuleIDs.contains(issue.ruleID.rawValue) else { return nil }
        return LibraryIncidentCandidate(
            kind: kind(forRule: issue.ruleID.rawValue),
            ruleID: issue.ruleID.rawValue,
            fingerprint: issue.fingerprint,
            severity: issue.severity,
            evidence: issue.evidence.prefix(8).map { evidence in
                LibraryEvidence(
                    code: evidence.labelKey,
                    count: nil,
                    bytes: nil,
                    hash: nil,
                    table: nil,
                    enumValue: evidence.safeValue)
            },
            detectedAt: now)
    }

    static func kind(forRule ruleID: String) -> LibraryIncidentKind {
        switch ruleID {
        case "SQL-001": return .integrityCheckFailed
        case "SQL-006": return .schemaMismatch
        default: return .unknown
        }
    }
}

private extension SentinelIssueStatus {
    /// A resolved, ignored, unactionable, or user-snoozed issue must never open
    /// an incident. Snoozing is an explicit "not now" from the owner.
    var isActiveForPromotion: Bool {
        switch self {
        case .open, .acknowledged, .repairing, .regressed: return true
        case .snoozed, .repaired, .resolved, .ignored, .unactionable: return false
        }
    }
}
