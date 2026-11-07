//  SentinelDomain.swift
//  AsterismaV2.5
//
//  SG1 — the durable domain. Pure value types and pure functions: no I/O,
//  no SwiftUI, no singletons. This is the most heavily tested layer.
//
//  Laws enforced here (see SENTINEL-ROADWORK §5.1):
//    L5  every issue carries typed evidence
//    L6  one condition, one fingerprint; time/count/severity never enter it
//    L8  every rule has copy (structurally, via SentinelProbeDescriptor)
//    L14 "clean" requires complete coverage, not silence
//
//  PRIVACY: `safeSummary` and evidence `safeValue`s are static or hashed.
//  They never contain titles, paths, bookmarks, or reading content. Anything
//  diagnostic belongs in `debugDetail`, which never reaches the safe journal.

import CryptoKit
import Foundation

// MARK: - Domain

nonisolated enum SentinelDomain: String, Codable, CaseIterable, Hashable, Sendable {
    case library
    case sessions
    case goals
    case collections
    case database
    case backups
    case files
    case weather
    case audio
    case behavior
    case mirage
    case app
    case selfAudit = "self"
    case security
    case capacity

    /// Stable three-letter family code used by rule IDs (LIB-001).
    var code: String {
        switch self {
        case .library: return "LIB"
        case .sessions: return "SES"
        case .goals: return "GOL"
        case .collections: return "COL"
        case .database: return "SQL"
        case .backups: return "BAK"
        case .files: return "FILE"
        case .weather: return "WX"
        case .audio: return "AUD"
        case .behavior: return "BHV"
        case .mirage: return "MIR"
        case .app: return "APP"
        case .selfAudit: return "SELF"
        case .security: return "SEC"
        case .capacity: return "CAP"
        }
    }

    var displayName: String {
        switch self {
        case .library: return "Library"
        case .sessions: return "Sessions"
        case .goals: return "Goals"
        case .collections: return "Collections"
        case .database: return "Database"
        case .backups: return "Backups"
        case .files: return "Files"
        case .weather: return "Weather"
        case .audio: return "Audio"
        case .behavior: return "Behavior"
        case .mirage: return "Mirage"
        case .app: return "App state"
        case .selfAudit: return "Sentinel itself"
        case .security: return "Security"
        case .capacity: return "Capacity"
        }
    }

    /// Why this domain matters, in one static sentence. Used by copy.
    var whyItMatters: String {
        switch self {
        case .library: return "Your library is the record of everything you have read; a wrong field can hide or misreport a book."
        case .sessions: return "Reading sessions are what every statistic is built from; damaged timings distort your history."
        case .goals: return "Goals and deadlines only help if they point at books that still exist."
        case .collections: return "Collections should contain exactly the books you put in them, once each."
        case .database: return "The database is the live copy of your library; silent row damage is the hardest kind to notice."
        case .backups: return "A backup you cannot restore is not a backup; it is reassurance."
        case .files: return "Book files and covers can move or disappear outside Asterisma."
        case .weather: return "Reading context is only meaningful when the stored conditions are real and honest."
        case .audio: return "Audio profiles add context to sessions; stale profiles grow without improving anything."
        case .behavior: return "Behavioral evidence feeds your reading-context report; corrupt evidence would fabricate it."
        case .mirage: return "Mirage owns its own data; Sentinel may explain a problem there but must never edit it."
        case .app: return "App state decides what you see on launch; stale state looks like a bug when it is only residue."
        case .selfAudit: return "A watchdog that cannot report its own failures is indistinguishable from a healthy one."
        case .security: return "Sentinel's guarantees are only real if writes, privacy, and scope are checked continuously."
        case .capacity: return "Running out of disk or memory turns small problems into lost reading progress."
        }
    }
}

// MARK: - Rule identity

/// A rule ID such as `SES-004`. A struct, not an enum, so a new probe never
/// requires editing a central enum (and never breaks decoding of old issues).
nonisolated struct SentinelRuleID: RawRepresentable, Hashable, Codable, CustomStringConvertible, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    var description: String { rawValue }

    var domainCode: String {
        rawValue.split(separator: "-").first.map(String.init) ?? ""
    }

    var numericPart: Int {
        Int(rawValue.split(separator: "-").last ?? "") ?? 0
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Severity, impact, risk

nonisolated enum SentinelSeverity: String, Codable, CaseIterable, Comparable, Sendable {
    case info
    case warning
    case error
    case critical

    var weight: Int {
        switch self {
        case .info: return 0
        case .warning: return 1
        case .error: return 2
        case .critical: return 3
        }
    }

    static func < (lhs: SentinelSeverity, rhs: SentinelSeverity) -> Bool {
        lhs.weight < rhs.weight
    }

    var label: String {
        switch self {
        case .info: return "Informational"
        case .warning: return "Warning"
        case .error: return "Problem"
        case .critical: return "Critical"
        }
    }
}

nonisolated enum SentinelImpact: String, Codable, CaseIterable, Comparable, Sendable {
    case low
    case medium
    case high

    var weight: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    static func < (lhs: SentinelImpact, rhs: SentinelImpact) -> Bool {
        lhs.weight < rhs.weight
    }

    var label: String {
        switch self {
        case .low: return "Low impact"
        case .medium: return "Medium impact"
        case .high: return "High impact"
        }
    }
}

/// §5.3 risk classes. R3 is never automatic and never offered in one click.
nonisolated enum SentinelRiskClass: String, Codable, CaseIterable, Sendable {
    case r0
    case r1
    case r2
    case r3

    var label: String {
        switch self {
        case .r0: return "Report only"
        case .r1: return "Safe to fix"
        case .r2: return "Needs your approval"
        case .r3: return "Recovery — explicit confirmation"
        }
    }

    var isMutation: Bool { self != .r0 }

    var isReversibleByDesign: Bool { self == .r1 || self == .r2 }
}

// MARK: - Lifecycle

/// Nine states. `repaired` exists so the launch card can say "fixed" without
/// pretending the issue is gone before verification; `resolved` means a later
/// cycle ran the detecting probe and the condition no longer appears.
nonisolated enum SentinelIssueStatus: String, Codable, CaseIterable, Sendable {
    case open
    case acknowledged
    case snoozed
    case repairing
    case repaired
    case resolved
    case regressed
    case ignored
    case unactionable

    var isOpen: Bool {
        switch self {
        case .open, .acknowledged, .snoozed, .repairing, .regressed:
            return true
        case .repaired, .resolved, .ignored, .unactionable:
            return false
        }
    }

    var isTerminalForNow: Bool {
        switch self {
        case .resolved, .ignored, .unactionable:
            return true
        default:
            return false
        }
    }

    var displayName: String {
        switch self {
        case .open: return "Open"
        case .acknowledged: return "Acknowledged"
        case .snoozed: return "Snoozed"
        case .repairing: return "Fixing"
        case .repaired: return "Repaired"
        case .resolved: return "Resolved"
        case .regressed: return "Came back"
        case .ignored: return "Ignored"
        case .unactionable: return "Can't be fixed"
        }
    }
}

nonisolated enum SentinelLifecycle {
    /// The legal edge table. Same-state is always allowed (idempotent updates).
    /// Anything absent is a programming error, not a user choice.
    static func canTransition(from: SentinelIssueStatus, to: SentinelIssueStatus) -> Bool {
        if from == to { return true }
        switch from {
        case .open:
            return [.acknowledged, .snoozed, .repairing, .repaired, .resolved,
                    .regressed, .ignored, .unactionable].contains(to)
        case .acknowledged:
            return [.open, .snoozed, .repairing, .repaired, .resolved,
                    .regressed, .ignored, .unactionable].contains(to)
        case .snoozed:
            return [.open, .acknowledged, .repairing, .resolved, .ignored].contains(to)
        case .repairing:
            return [.repaired, .open, .regressed, .unactionable].contains(to)
        case .repaired:
            return [.resolved, .regressed, .open].contains(to)
        case .resolved:
            // Resolution is a proof, not a toggle. If the condition returns,
            // it returns as a regression so the user sees that it came back.
            return [.regressed, .ignored].contains(to)
        case .regressed:
            return [.open, .acknowledged, .snoozed, .repairing, .repaired,
                    .resolved, .ignored, .unactionable].contains(to)
        case .ignored:
            return [.open, .acknowledged].contains(to)
        case .unactionable:
            return [.open, .acknowledged].contains(to)
        }
    }

    /// Applies an edge or returns the current status untouched. Callers can
    /// assert on `canTransition` when a silent no-op would be harmful.
    static func apply(_ target: SentinelIssueStatus, to current: SentinelIssueStatus) -> SentinelIssueStatus {
        canTransition(from: current, to: target) ? target : current
    }
}

// MARK: - Subjects and evidence

nonisolated enum SentinelSubjectKind: String, Codable, CaseIterable, Hashable, Sendable {
    case book
    case session
    case timing
    case collection
    case deadline
    case achievement
    case note
    case file
    case cover
    case database
    case backup
    case journal
    case profile
    case subsystem
    case store
    case issue
}

/// A typed reference a repair can re-read. `id` is a UUID string, a rule-stable
/// key, or a hashed path. It is never a free-form user path or a title.
nonisolated struct SentinelSubject: Codable, Hashable, Sendable {
    var kind: SentinelSubjectKind
    var id: String

    init(_ kind: SentinelSubjectKind, _ id: String) {
        self.kind = kind
        self.id = id
    }

    var token: String { "\(kind.rawValue):\(id)" }
}

nonisolated enum SentinelEvidenceKind: String, Codable, CaseIterable, Sendable {
    case timestamp
    case count
    case aggregate
    case recordRef
    case invariant
    case fileRef
    case queryResult
    case coverage
    case boolean
    case duration
    case bytes
}

nonisolated enum SentinelEvidenceSource: String, Codable, CaseIterable, Sendable {
    case dataStore
    case sqlite
    case fileSystem
    case subsystem
    case sentinel
}

nonisolated struct SentinelEvidence: Codable, Hashable, Sendable {
    var kind: SentinelEvidenceKind
    var labelKey: String
    /// Safe value: a date, count, band, boolean, hash, or invariant statement.
    /// Must never contain user text.
    var safeValue: String
    /// Debug-only detail. Never journaled, never exported, never shown in Release.
    var debugValue: String?
    var observedAt: Date
    var source: SentinelEvidenceSource

    init(
        kind: SentinelEvidenceKind,
        labelKey: String,
        safeValue: String,
        debugValue: String? = nil,
        observedAt: Date,
        source: SentinelEvidenceSource
    ) {
        self.kind = kind
        self.labelKey = labelKey
        self.safeValue = safeValue
        self.debugValue = debugValue
        self.observedAt = observedAt
        self.source = source
    }
}

// MARK: - Copy

nonisolated struct SentinelCopy: Codable, Hashable, Sendable {
    var title: String
    var what: String
    var why: String
    var now: String
    var whatIf: String

    /// Every field must be non-empty for L8 to hold.
    var isComplete: Bool {
        ![title, what, why, now, whatIf].contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

// MARK: - Raw findings

/// A probe's output. Deliberately has no id, status, or lifecycle: those are
/// assigned by the diagnoser so re-detection can never fork an issue.
nonisolated struct RawFinding: Hashable, Sendable {
    var probeID: String
    var ruleID: SentinelRuleID
    var severity: SentinelSeverity
    var confidence: Double
    var impact: SentinelImpact
    var subjects: [SentinelSubject]
    var evidence: [SentinelEvidence]
    /// Stable within a rule; separates two genuinely different conditions that
    /// share a subject (for example two different session windows).
    var discriminator: String
    /// Optional static sentence. Never interpolated with user text.
    var safeSummary: String?
    var debugDetail: String?
    /// Contributor/corroborator findings attach to the owner's issue.
    var isEvidenceOnly: Bool

    init(
        probeID: String,
        ruleID: SentinelRuleID,
        severity: SentinelSeverity,
        confidence: Double = 0.9,
        impact: SentinelImpact,
        subjects: [SentinelSubject],
        evidence: [SentinelEvidence],
        discriminator: String = "",
        safeSummary: String? = nil,
        debugDetail: String? = nil,
        isEvidenceOnly: Bool = false
    ) {
        self.probeID = probeID
        self.ruleID = ruleID
        self.severity = severity
        self.confidence = max(0, min(1, confidence))
        self.impact = impact
        self.subjects = subjects
        self.evidence = evidence
        self.discriminator = discriminator
        self.safeSummary = safeSummary
        self.debugDetail = debugDetail
        self.isEvidenceOnly = isEvidenceOnly
    }
}

// MARK: - Issue

nonisolated struct SentinelIssue: Codable, Hashable, Identifiable, Sendable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    /// Internal id. May change when rebuilt from the journal; the fingerprint
    /// is the identity that matters.
    var id: String
    var fingerprint: String
    var ruleID: SentinelRuleID
    var ruleVersion: Int
    var rootCauseKey: String
    var domain: SentinelDomain
    var titleKey: String
    var status: SentinelIssueStatus
    var severity: SentinelSeverity
    var confidence: Double
    var impact: SentinelImpact
    var subjects: [SentinelSubject]
    var evidence: [SentinelEvidence]
    var safeSummary: String
    var firstSeen: Date
    var lastSeen: Date
    var occurrenceCount: Int
    var attemptCount: Int
    var lastRepairID: String?
    var resolvedAt: Date?
    var snoozedUntil: Date?
    var acknowledgedAt: Date?
    var ignoredAt: Date?
    var updatedAt: Date

    /// Debug-only. Never persisted in the safe journal or exported.
    var debugDetail: String?

    init(
        id: String = "iss_" + UUID().uuidString,
        fingerprint: String,
        ruleID: SentinelRuleID,
        ruleVersion: Int,
        rootCauseKey: String,
        domain: SentinelDomain,
        titleKey: String,
        status: SentinelIssueStatus = .open,
        severity: SentinelSeverity,
        confidence: Double,
        impact: SentinelImpact,
        subjects: [SentinelSubject],
        evidence: [SentinelEvidence],
        safeSummary: String,
        firstSeen: Date,
        lastSeen: Date,
        occurrenceCount: Int = 1,
        attemptCount: Int = 0,
        lastRepairID: String? = nil,
        resolvedAt: Date? = nil,
        snoozedUntil: Date? = nil,
        acknowledgedAt: Date? = nil,
        ignoredAt: Date? = nil,
        updatedAt: Date,
        debugDetail: String? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.fingerprint = fingerprint
        self.ruleID = ruleID
        self.ruleVersion = ruleVersion
        self.rootCauseKey = rootCauseKey
        self.domain = domain
        self.titleKey = titleKey
        self.status = status
        self.severity = severity
        self.confidence = confidence
        self.impact = impact
        self.subjects = subjects
        self.evidence = evidence
        self.safeSummary = safeSummary
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.occurrenceCount = occurrenceCount
        self.attemptCount = attemptCount
        self.lastRepairID = lastRepairID
        self.resolvedAt = resolvedAt
        self.snoozedUntil = snoozedUntil
        self.acknowledgedAt = acknowledgedAt
        self.ignoredAt = ignoredAt
        self.updatedAt = updatedAt
        self.debugDetail = debugDetail
    }

    // MARK: Tolerant decoding

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, fingerprint, ruleID, ruleVersion, rootCauseKey
        case domain, titleKey, status, severity, confidence, impact
        case subjects, evidence, safeSummary, firstSeen, lastSeen
        case occurrenceCount, attemptCount, lastRepairID
        case resolvedAt, snoozedUntil, acknowledgedAt, ignoredAt, updatedAt, debugDetail
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        id = try c.decode(String.self, forKey: .id)
        fingerprint = try c.decode(String.self, forKey: .fingerprint)
        ruleID = try c.decode(SentinelRuleID.self, forKey: .ruleID)
        ruleVersion = try c.decodeIfPresent(Int.self, forKey: .ruleVersion) ?? 1
        rootCauseKey = try c.decodeIfPresent(String.self, forKey: .rootCauseKey) ?? "unknown"
        domain = try c.decodeIfPresent(SentinelDomain.self, forKey: .domain) ?? .library
        titleKey = try c.decodeIfPresent(String.self, forKey: .titleKey) ?? "issue.unknown.title"
        status = try c.decodeIfPresent(SentinelIssueStatus.self, forKey: .status) ?? .open
        severity = try c.decodeIfPresent(SentinelSeverity.self, forKey: .severity) ?? .warning
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0.5
        impact = try c.decodeIfPresent(SentinelImpact.self, forKey: .impact) ?? .medium
        subjects = try c.decodeIfPresent([SentinelSubject].self, forKey: .subjects) ?? []
        evidence = try c.decodeIfPresent([SentinelEvidence].self, forKey: .evidence) ?? []
        safeSummary = try c.decodeIfPresent(String.self, forKey: .safeSummary) ?? "A condition was detected."
        firstSeen = try c.decodeIfPresent(Date.self, forKey: .firstSeen) ?? Date()
        lastSeen = try c.decodeIfPresent(Date.self, forKey: .lastSeen) ?? firstSeen
        occurrenceCount = try c.decodeIfPresent(Int.self, forKey: .occurrenceCount) ?? 1
        attemptCount = try c.decodeIfPresent(Int.self, forKey: .attemptCount) ?? 0
        lastRepairID = try c.decodeIfPresent(String.self, forKey: .lastRepairID)
        resolvedAt = try c.decodeIfPresent(Date.self, forKey: .resolvedAt)
        snoozedUntil = try c.decodeIfPresent(Date.self, forKey: .snoozedUntil)
        acknowledgedAt = try c.decodeIfPresent(Date.self, forKey: .acknowledgedAt)
        ignoredAt = try c.decodeIfPresent(Date.self, forKey: .ignoredAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? lastSeen
        debugDetail = try c.decodeIfPresent(String.self, forKey: .debugDetail)
    }
}

extension SentinelIssue {
    /// Visible to the user right now: not resolved, not ignored, not snoozed
    /// into the future, not unactionable.
    func isVisible(at now: Date) -> Bool {
        switch status {
        case .resolved, .ignored, .unactionable:
            return false
        case .snoozed:
            return !(snoozedUntil.map { $0 > now } ?? false)
        default:
            return true
        }
    }

    var isSilenced: Bool {
        status == .ignored || status == .resolved || status == .unactionable
    }

    var subjectTokenPreview: String {
        subjects.prefix(3).map(\.token).joined(separator: ",")
    }
}

// MARK: - Fingerprint

nonisolated enum SentinelFingerprint {
    /// Stable identity. Excludes time, message, count, and severity by
    /// construction: only the rule, sorted subjects, and a rule-owned
    /// discriminator participate. 16 lowercase hex characters.
    static func make(
        ruleID: SentinelRuleID,
        subjects: [SentinelSubject],
        discriminator: String = ""
    ) -> String {
        let subjectPart = subjects.map(\.token).sorted().joined(separator: ",")
        let payload = "sentinel-v2|\(ruleID.rawValue)|\(subjectPart)|\(discriminator)"
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func make(for finding: RawFinding) -> String {
        make(ruleID: finding.ruleID, subjects: finding.subjects, discriminator: finding.discriminator)
    }
}

// MARK: - Coverage and health

/// Honest coverage. A skipped or failed required probe makes a clean claim
/// impossible, no matter how many other probes ran.
nonisolated struct SentinelCoverage: Codable, Hashable, Sendable {
    var totalProbes: Int
    var ran: Int
    var skipped: Int
    var failed: Int
    var requiredTotal: Int
    var requiredRan: Int
    /// Rule IDs that did not run, for the coverage disclosure.
    var missingRequired: [String]
    var skippedByDomain: [String: Int]

    static let empty = SentinelCoverage(
        totalProbes: 0, ran: 0, skipped: 0, failed: 0,
        requiredTotal: 0, requiredRan: 0,
        missingRequired: [], skippedByDomain: [:])

    var isComplete: Bool {
        guard requiredTotal > 0 else { return false }
        return requiredRan >= requiredTotal && failed == 0
    }

    var completionFraction: Double {
        guard totalProbes > 0 else { return 0 }
        return Double(ran) / Double(totalProbes)
    }

    var summary: String {
        if totalProbes == 0 { return "No checks have run yet." }
        if isComplete { return "Checked \(ran) of \(totalProbes) checks." }
        return "Checked \(ran) of \(totalProbes) checks; \(skipped + failed) did not run."
    }
}

nonisolated enum SentinelHealthBand: String, Codable, CaseIterable, Sendable {
    case healthy
    case watch
    case attention
    case critical
    case unknown

    var displayName: String {
        switch self {
        case .healthy: return "All clear"
        case .watch: return "Worth a look"
        case .attention: return "Needs attention"
        case .critical: return "Critical"
        case .unknown: return "Incomplete check"
        }
    }

    var systemImage: String {
        switch self {
        case .healthy: return "checkmark.shield.fill"
        case .watch: return "eye.fill"
        case .attention: return "exclamationmark.shield.fill"
        case .critical: return "xmark.shield.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }
}

nonisolated struct SentinelHealthModel: Codable, Hashable, Sendable {
    var band: SentinelHealthBand
    var visibleIssueCount: Int
    var criticalCount: Int
    var errorCount: Int
    var warningCount: Int
    var infoCount: Int
    var coverage: SentinelCoverage
    var computedAt: Date
    var headline: String

    static func compute(
        issues: [SentinelIssue],
        coverage: SentinelCoverage,
        now: Date
    ) -> SentinelHealthModel {
        let visible = issues.filter { $0.isVisible(at: now) }
        let critical = visible.filter { $0.severity == .critical }.count
        let errors = visible.filter { $0.severity == .error }.count
        let warnings = visible.filter { $0.severity == .warning }.count
        let infos = visible.filter { $0.severity == .info }.count

        let band: SentinelHealthBand
        if critical > 0 {
            band = .critical
        } else if errors > 0 {
            band = .attention
        } else if warnings > 0 {
            band = .watch
        } else if !coverage.isComplete {
            band = .unknown
        } else {
            band = .healthy
        }

        let headline: String
        switch band {
        case .critical:
            headline = critical == 1
                ? "1 critical issue needs attention."
                : "\(critical) critical issues need attention."
        case .attention:
            headline = errors == 1 ? "1 issue needs a decision." : "\(errors) issues need a decision."
        case .watch:
            headline = warnings == 1 ? "1 thing is worth a look." : "\(warnings) things are worth a look."
        case .healthy:
            headline = "Checked \(coverage.ran) things. All clear."
        case .unknown:
            headline = coverage.totalProbes == 0
                ? "Sentinel has not checked anything yet."
                : "The check was incomplete — this is not a clean bill of health."
        }

        return SentinelHealthModel(
            band: band,
            visibleIssueCount: visible.count,
            criticalCount: critical,
            errorCount: errors,
            warningCount: warnings,
            infoCount: infos,
            coverage: coverage,
            computedAt: now,
            headline: headline
        )
    }
}

// MARK: - Timeline / correlation

nonisolated enum SentinelTrend: String, Codable, CaseIterable, Sendable {
    case new
    case persistent
    case worsening
    case improving
    case regressed
    case repaired

    var displayName: String {
        switch self {
        case .new: return "New"
        case .persistent: return "Persistent"
        case .worsening: return "Worsening"
        case .improving: return "Improving"
        case .regressed: return "Came back"
        case .repaired: return "Repaired"
        }
    }
}

/// A diagnosis groups issues that plausibly share a cause. Grouping is
/// advisory: it never merges issues and never authorizes a repair.
nonisolated struct SentinelDiagnosis: Identifiable, Hashable, Sendable {
    var id: String { rootCauseKey }
    var rootCauseKey: String
    var domain: SentinelDomain
    var headline: String
    var detail: String
    var issueFingerprints: [String]
    var severity: SentinelSeverity
    var isCorrelated: Bool

    /// Correlates issues by root cause with a small, deterministic rule set.
    /// Only issues observed within the window participate.
    static func correlate(
        issues: [SentinelIssue],
        now: Date,
        window: TimeInterval = 24 * 3600
    ) -> [SentinelDiagnosis] {
        let recent = issues.filter {
            !$0.isSilenced && now.timeIntervalSince($0.lastSeen) <= window
        }
        var groups: [String: [SentinelIssue]] = [:]
        for issue in recent {
            groups[issue.rootCauseKey, default: []].append(issue)
        }

        return groups.compactMap { key, group -> SentinelDiagnosis? in
            guard let worst = group.max(by: { $0.severity < $1.severity }) else { return nil }
            let distinctRules = Set(group.map(\.ruleID.rawValue))
            // Single issues are still diagnoses: a diagnosis is the explanation
            // layer, correlation is an optional extra sentence.
            let correlated = group.count > 1
            let headline: String
            let detail: String
            if correlated {
                headline = "\(group.count) findings may share one cause"
                detail = "\(distinctRules.count) rules in \(worst.domain.displayName.lowercased()) point at \(key)."
            } else {
                headline = worst.safeSummary
                detail = "One finding in \(worst.domain.displayName.lowercased())."
            }
            return SentinelDiagnosis(
                rootCauseKey: key,
                domain: worst.domain,
                headline: headline,
                detail: detail,
                issueFingerprints: group.map(\.fingerprint).sorted(),
                severity: worst.severity,
                isCorrelated: correlated
            )
        }
        .sorted { $0.severity > $1.severity }
    }
}

// MARK: - Formatting helpers

nonisolated enum SentinelFormat {
    static func iso(_ date: Date) -> String {
        ISO8601DateFormatter.sentinel.string(from: date)
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", max(0, min(1, fraction)) * 100)
    }
}

extension ISO8601DateFormatter {
    /// One shared formatter for journal and evidence timestamps.
    nonisolated(unsafe) static let sentinel: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
