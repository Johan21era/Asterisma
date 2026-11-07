//  SentinelRules.swift
//  AsterismaV2.5
//
//  SG1 — probe descriptors, rule metadata, deterministic copy, and the
//  diagnoser that turns transient findings into durable issues.
//
//  Copy is structural, not decorative: `SentinelProbeDescriptor` requires a
//  title and a plain-English explanation, and `SentinelCopyRegistry` derives
//  the remaining what/why/now/what-if sentences from the domain and risk
//  class. A rule without copy therefore cannot compile into the registry,
//  which is how L8 ("explainability") is enforced rather than promised.
//
//  The diagnoser is pure. It owns the dedupe/lifecycle rules that used to be
//  implicit in the engine: one condition, one issue, re-detection updates.

import Foundation

// MARK: - Probe metadata

nonisolated enum SentinelProbeTier: String, Codable, CaseIterable, Comparable, Sendable {
    case t0
    case t1
    case t2
    case t3
    case t4

    var weight: Int {
        switch self {
        case .t0: return 0
        case .t1: return 1
        case .t2: return 2
        case .t3: return 3
        case .t4: return 4
        }
    }

    static func < (lhs: SentinelProbeTier, rhs: SentinelProbeTier) -> Bool {
        lhs.weight < rhs.weight
    }

    var displayName: String {
        switch self {
        case .t0: return "Instant"
        case .t1: return "Fast"
        case .t2: return "Normal"
        case .t3: return "Deep"
        case .t4: return "Maintenance"
        }
    }

    var budget: TimeInterval {
        switch self {
        case .t0: return 0.010
        case .t1: return 0.050
        case .t2: return 0.250
        case .t3: return 2.0
        case .t4: return 30.0
        }
    }

    /// Tiers that participate in the launch/fast pass.
    var isFast: Bool { self <= .t1 }
}

nonisolated enum SentinelProbeRole: String, Codable, CaseIterable, Sendable {
    case owner
    case contributor
    case corroborator
}

nonisolated struct SentinelProbeDescriptor: Hashable, Sendable {
    var id: String
    var domain: SentinelDomain
    var title: String
    var what: String
    var ruleVersion: Int
    var role: SentinelProbeRole
    var ownerProbeID: String?
    var rootCauseKey: String
    var supersedes: [String]
    var tier: SentinelProbeTier
    var timeout: TimeInterval
    var isRequired: Bool
    var defaultSeverity: SentinelSeverity
    var defaultImpact: SentinelImpact
    var riskClass: SentinelRiskClass
    var repairID: String?
    var introduced: String

    var ruleID: SentinelRuleID { SentinelRuleID(id) }

    var titleKey: String {
        "issue." + id.lowercased().replacingOccurrences(of: "-", with: "") + ".title"
    }

    init(
        id: String,
        domain: SentinelDomain,
        title: String,
        what: String,
        ruleVersion: Int = 1,
        role: SentinelProbeRole = .owner,
        ownerProbeID: String? = nil,
        rootCauseKey: String,
        supersedes: [String] = [],
        tier: SentinelProbeTier,
        timeout: TimeInterval? = nil,
        isRequired: Bool = true,
        defaultSeverity: SentinelSeverity,
        defaultImpact: SentinelImpact,
        riskClass: SentinelRiskClass = .r0,
        repairID: String? = nil,
        introduced: String = "Sentinel 2.0"
    ) {
        self.id = id
        self.domain = domain
        self.title = title
        self.what = what
        self.ruleVersion = ruleVersion
        self.role = role
        self.ownerProbeID = ownerProbeID
        self.rootCauseKey = rootCauseKey
        self.supersedes = supersedes
        self.tier = tier
        self.timeout = timeout ?? tier.budget
        self.isRequired = isRequired
        self.defaultSeverity = defaultSeverity
        self.defaultImpact = defaultImpact
        self.riskClass = riskClass
        self.repairID = repairID
        self.introduced = introduced
    }

    var metadata: SentinelRuleMetadata {
        SentinelRuleMetadata(
            ruleID: ruleID,
            domain: domain,
            title: title,
            what: what,
            why: domain.whyItMatters,
            titleKey: titleKey,
            rootCauseKey: rootCauseKey,
            ruleVersion: ruleVersion,
            defaultSeverity: defaultSeverity,
            defaultImpact: defaultImpact,
            riskClass: riskClass,
            repairID: repairID)
    }
}

nonisolated struct SentinelRuleMetadata: Hashable, Sendable {
    var ruleID: SentinelRuleID
    var domain: SentinelDomain
    var title: String
    var what: String
    var why: String
    var titleKey: String
    var rootCauseKey: String
    var ruleVersion: Int
    var defaultSeverity: SentinelSeverity
    var defaultImpact: SentinelImpact
    var riskClass: SentinelRiskClass
    var repairID: String?

    var copy: SentinelCopy { SentinelCopyRegistry.copy(for: self) }
}

// MARK: - Copy

nonisolated enum SentinelCopyRegistry {
    /// Deterministic copy from structured facts. No interpolation of user text,
    /// no generated prose, no network: the same rule always reads the same way.
    static func copy(for rule: SentinelRuleMetadata) -> SentinelCopy {
        SentinelCopy(
            title: rule.title,
            what: rule.what,
            why: rule.why,
            now: nowText(for: rule),
            whatIf: whatIfText(for: rule)
        )
    }

    static func nowText(for rule: SentinelRuleMetadata) -> String {
        if rule.repairID != nil {
            switch rule.riskClass {
            case .r1:
                return "Sentinel can normalize this safely, and can undo it if you change your mind."
            case .r2:
                return "This needs your approval before anything changes; Sentinel will show exactly what it will do."
            case .r3:
                return "This is a recovery action. Sentinel will never do it automatically."
            case .r0:
                return "Sentinel only reports this; nothing has been changed."
            }
        }
        return "Sentinel only reports this; nothing has been changed."
    }

    static func whatIfText(for rule: SentinelRuleMetadata) -> String {
        guard rule.repairID != nil else {
            return "Nothing is at risk of getting worse on its own, but Sentinel will keep watching it."
        }
        switch rule.defaultImpact {
        case .high:
            return "Left alone, this can make your reading history incomplete or misleading."
        case .medium:
            return "Left alone, some totals or lists may show the wrong thing."
        case .low:
            return "Left alone, the effect is small: some clutter or an unnecessary check."
        }
    }

    /// The full registry derived from probe descriptors. Every rule a probe can
    /// emit is present by construction.
    static func registry(for descriptors: [SentinelProbeDescriptor]) -> [SentinelRuleID: SentinelRuleMetadata] {
        var registry: [SentinelRuleID: SentinelRuleMetadata] = [:]
        for descriptor in descriptors {
            registry[descriptor.ruleID] = descriptor.metadata
        }
        return registry
    }
}

// MARK: - Probe protocol

nonisolated protocol SentinelProbeV2 {
    var descriptor: SentinelProbeDescriptor { get }
    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding]
}

/// Why a probe produced no findings. Silence is never assumed to be health.
nonisolated enum SentinelProbeSkipReason: String, Codable, Sendable {
    case sourceUnavailable = "source-unavailable"
    case domainDisabled = "domain-disabled"
    case databaseNotInitialized = "database-not-initialized"
    case notApplicable = "not-applicable"
    case insufficientData = "insufficient-data"
}

nonisolated struct SentinelProbeRunResult: Sendable {
    var probeID: String
    var ruleID: SentinelRuleID
    var domain: SentinelDomain
    var tier: SentinelProbeTier
    var isRequired: Bool
    var status: SentinelProbeStatus
    var findings: [RawFinding]
    var duration: TimeInterval
    var skipReason: SentinelProbeSkipReason?
    var errorDescription: String?

    var ran: Bool {
        if case .completed = status { return true }
        return false
    }
}

nonisolated enum SentinelProbeStatus: String, Codable, Sendable {
    case completed
    case skipped
    case failed
    case timedOut
}

// MARK: - Diagnoser

nonisolated struct SentinelDiagnosisResult: Sendable {
    var issues: [SentinelIssue]
    var opened: [String]
    var updated: [String]
    var resolved: [String]
    var regressed: [String]
}

nonisolated enum SentinelDiagnoser {
    /// The only place findings become issues.
    ///
    /// - A condition already present updates its issue; it never opens a second.
    /// - A resolved condition that reappears becomes `regressed`.
    /// - An issue disappears only when its owning probe actually ran and found
    ///   nothing. A skipped or failed probe leaves the issue exactly as it was.
    static func diagnose(
        existing: [SentinelIssue],
        findings: [RawFinding],
        descriptors: [SentinelProbeDescriptor],
        completedProbeIDs: Set<String>,
        failedProbeIDs: Set<String>,
        cycleID: String,
        now: Date,
        maximumIssues: Int = 500
    ) -> SentinelDiagnosisResult {
        let ruleMetadata = SentinelCopyRegistry.registry(for: descriptors)
        let ownerByRule: [SentinelRuleID: String] = descriptors.reduce(into: [:]) { result, descriptor in
            guard descriptor.role == .owner else { return }
            result[descriptor.ruleID] = descriptor.id
        }

        // Merge findings that describe the same condition. Corroborators add
        // evidence; they never create a second issue.
        var grouped: [String: RawFinding] = [:]
        var groupOrder: [String] = []
        for finding in findings {
            let fingerprint = SentinelFingerprint.make(for: finding)
            if var existingFinding = grouped[fingerprint] {
                existingFinding.evidence.append(contentsOf: finding.evidence)
                existingFinding.severity = max(existingFinding.severity, finding.severity)
                existingFinding.impact = max(existingFinding.impact, finding.impact)
                existingFinding.confidence = max(existingFinding.confidence, finding.confidence)
                if existingFinding.debugDetail == nil { existingFinding.debugDetail = finding.debugDetail }
                existingFinding.isEvidenceOnly = existingFinding.isEvidenceOnly && finding.isEvidenceOnly
                grouped[fingerprint] = existingFinding
            } else {
                grouped[fingerprint] = finding
                groupOrder.append(fingerprint)
            }
        }

        var byFingerprint: [String: SentinelIssue] = [:]
        var order: [String] = []
        for issue in existing {
            if byFingerprint[issue.fingerprint] == nil {
                order.append(issue.fingerprint)
            }
            byFingerprint[issue.fingerprint] = issue
        }

        var opened: [String] = []
        var updated: [String] = []
        var resolved: [String] = []
        var regressed: [String] = []

        for fingerprint in groupOrder {
            guard let finding = grouped[fingerprint], !finding.isEvidenceOnly else { continue }
            let metadata = ruleMetadata[finding.ruleID]

            if var issue = byFingerprint[fingerprint] {
                issue.lastSeen = now
                issue.occurrenceCount += 1
                issue.severity = max(issue.severity, finding.severity)
                issue.impact = max(issue.impact, finding.impact)
                issue.confidence = max(issue.confidence, finding.confidence)
                issue.ruleVersion = max(issue.ruleVersion, metadata?.ruleVersion ?? issue.ruleVersion)
                if issue.subjects.isEmpty { issue.subjects = finding.subjects }
                issue.evidence = mergeEvidence(issue.evidence, finding.evidence, now: now)
                if let detail = finding.debugDetail { issue.debugDetail = detail }
                if !finding.subjects.isEmpty && issue.subjects.isEmpty { issue.subjects = finding.subjects }

                let previous = issue.status
                switch issue.status {
                case .resolved:
                    issue.status = SentinelLifecycle.apply(.regressed, to: issue.status)
                    issue.resolvedAt = nil
                case .ignored, .unactionable:
                    break // The user asked not to be re-alerted; keep the state.
                case .repaired:
                    issue.status = SentinelLifecycle.apply(.regressed, to: issue.status)
                case .snoozed:
                    if let until = issue.snoozedUntil, until <= now {
                        issue.status = SentinelLifecycle.apply(.open, to: issue.status)
                        issue.snoozedUntil = nil
                    }
                default:
                    break
                }
                if issue.status != previous {
                    regressed.append(fingerprint)
                }
                issue.updatedAt = now
                byFingerprint[fingerprint] = issue
                updated.append(fingerprint)
            } else {
                let metadata = metadata ?? fallbackMetadata(for: finding)
                let copy = metadata.copy
                let issue = SentinelIssue(
                    fingerprint: fingerprint,
                    ruleID: finding.ruleID,
                    ruleVersion: metadata.ruleVersion,
                    rootCauseKey: metadata.rootCauseKey,
                    domain: metadata.domain,
                    titleKey: metadata.titleKey,
                    status: .open,
                    severity: finding.severity,
                    confidence: finding.confidence,
                    impact: finding.impact,
                    subjects: finding.subjects,
                    evidence: mergeEvidence([], finding.evidence, now: now),
                    safeSummary: finding.safeSummary ?? copy.title,
                    firstSeen: now,
                    lastSeen: now,
                    occurrenceCount: 1,
                    updatedAt: now,
                    debugDetail: finding.debugDetail)
                byFingerprint[fingerprint] = issue
                order.append(fingerprint)
                opened.append(fingerprint)
            }
        }

        // Resolution requires proof: the owning probe completed successfully.
        for fingerprint in order {
            guard var issue = byFingerprint[fingerprint],
                  grouped[fingerprint] == nil,
                  issue.status.isOpen || issue.status == .repaired || issue.status == .repairing
            else { continue }

            guard let owner = ownerByRule[issue.ruleID] else { continue }
            guard completedProbeIDs.contains(owner), !failedProbeIDs.contains(owner) else { continue }

            if issue.status == .snoozed, let until = issue.snoozedUntil, until > now {
                continue
            }

            let previous = issue.status
            issue.status = SentinelLifecycle.apply(.resolved, to: issue.status)
            issue.resolvedAt = now
            issue.updatedAt = now
            issue.snoozedUntil = nil
            byFingerprint[fingerprint] = issue
            if issue.status != previous {
                resolved.append(fingerprint)
            }
        }

        var issues = order.compactMap { byFingerprint[$0] }
        issues.sort {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            if $0.lastSeen != $1.lastSeen { return $0.lastSeen > $1.lastSeen }
            return $0.fingerprint < $1.fingerprint
        }
        if issues.count > maximumIssues {
            issues = Array(issues.prefix(maximumIssues))
        }

        return SentinelDiagnosisResult(
            issues: issues,
            opened: opened,
            updated: updated,
            resolved: resolved,
            regressed: regressed)
    }

    /// Keeps the newest eight distinct evidence items. Repeated identical
    /// evidence on every cycle would otherwise grow without bound and drown
    /// the useful signal.
    static func mergeEvidence(
        _ existing: [SentinelEvidence],
        _ incoming: [SentinelEvidence],
        now: Date
    ) -> [SentinelEvidence] {
        var result = existing
        for item in incoming {
            if let index = result.firstIndex(where: {
                $0.labelKey == item.labelKey && $0.safeValue == item.safeValue
            }) {
                result[index].observedAt = item.observedAt
                if let debug = item.debugValue { result[index].debugValue = debug }
            } else {
                result.append(item)
            }
        }
        if result.count > 8 {
            result = Array(result.suffix(8))
        }
        return result
    }

    private static func fallbackMetadata(for finding: RawFinding) -> SentinelRuleMetadata {
        SentinelRuleMetadata(
            ruleID: finding.ruleID,
            domain: .library,
            title: "A library condition was detected",
            what: "Sentinel found a condition that does not match its rule registry.",
            why: SentinelDomain.library.whyItMatters,
            titleKey: "issue.unknown.title",
            rootCauseKey: "unknown",
            ruleVersion: 1,
            defaultSeverity: .warning,
            defaultImpact: .medium,
            riskClass: .r0,
            repairID: nil)
    }
}
