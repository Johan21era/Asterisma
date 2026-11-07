//  SentinelDiagnostics.swift
//  AsterismaV2.5
//
//  §14.3 — a deliberately small, safe diagnostics bundle. It contains rules,
//  fingerprints, counts, coverage, and repair outcomes. It never contains book
//  titles, paths, note text, or `debugDetail`; those stay in the Debug console.

import Foundation

nonisolated enum SentinelDiagnostics {
    static let schemaVersion = 2

    struct Document: Codable {
        var schemaVersion: Int
        var generatedAt: Date
        var appVersion: String
        var sentinelVersion: String
        var band: String
        var headline: String
        var coverage: SentinelCoverage
        var registry: Registry
        var issues: [IssueRow]
        var repairs: [RepairRow]
        var probes: [ProbeRow]
        /// Added in schema 2 (P6-5). Optional so a schema-1 reader still
        /// decodes the file.
        var recovery: RecoveryRow?
    }

    /// Gate state only. Incident ids, receipt ids, hashes, and counts belong to
    /// the Recovery support summary, never to this bundle.
    struct RecoveryRow: Codable {
        var mode: String
        var suspensionReason: String?
        var lastCycleTrigger: String?
        var lastCycleHadError: Bool
    }

    struct Registry: Codable {
        var probes: Int
        var domains: Int
        var repairs: Int
        var required: Int
    }

    struct IssueRow: Codable {
        var fingerprint: String
        var ruleID: String
        var domain: String
        var severity: String
        var status: String
        var occurrenceCount: Int
        var firstSeen: Date
        var lastSeen: Date
        var evidenceCount: Int
    }

    struct RepairRow: Codable {
        var repairID: String
        var status: String
        var appliedAt: Date
        var ruleIDs: [String]
    }

    struct ProbeRow: Codable {
        var probeID: String
        var ruleID: String
        var status: String
        var durationMilliseconds: Int
        var findingCount: Int
    }

    static func document(
        state: SentinelPublishedState,
        appVersion: String,
        now: Date = Date()
    ) -> Document {
        let recovery = RecoveryRow(
            mode: state.operationalMode.isSuspended ? "suspended" : "normal",
            suspensionReason: state.operationalMode.suspensionReason?.rawValue,
            lastCycleTrigger: state.lastCycle.trigger.rawValue,
            lastCycleHadError: state.lastCycle.error != nil)

        let issueRows: [IssueRow] = state.issues.map { issue in
            IssueRow(
                fingerprint: issue.fingerprint,
                ruleID: issue.ruleID.rawValue,
                domain: issue.domain.rawValue,
                severity: issue.severity.rawValue,
                status: issue.status.rawValue,
                occurrenceCount: issue.occurrenceCount,
                firstSeen: issue.firstSeen,
                lastSeen: issue.lastSeen,
                evidenceCount: issue.evidence.count)
        }

        let repairRows: [RepairRow] = state.repairs.map { record in
            RepairRow(
                repairID: record.repairID,
                status: record.status.rawValue,
                appliedAt: record.appliedAt,
                ruleIDs: record.ruleIDs)
        }

        let probeRows: [ProbeRow] = state.probes.map { result in
            ProbeRow(
                probeID: result.probeID,
                ruleID: result.ruleID.rawValue,
                status: result.status.rawValue,
                durationMilliseconds: Int((result.duration * 1000).rounded()),
                findingCount: result.findings.count)
        }

        return Document(
            schemaVersion: schemaVersion,
            generatedAt: now,
            appVersion: appVersion,
            sentinelVersion: "2.0",
            band: state.health.band.rawValue,
            headline: state.health.headline,
            coverage: state.coverage,
            registry: Registry(
                probes: SentinelProbeCatalog.descriptors.count,
                domains: SentinelProbeCatalog.domainCount,
                repairs: SentinelRepairCatalog.implementedIDs.count,
                required: SentinelProbeCatalog.requiredCount),
            issues: issueRows,
            repairs: repairRows,
            probes: probeRows,
            recovery: recovery)
    }

    static func export(
        state: SentinelPublishedState,
        appVersion: String,
        now: Date = Date()
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(document(state: state, appVersion: appVersion, now: now))
    }

    /// The bundle is safe by construction, but callers can still assert the
    /// guardrail before handing the bytes to a save panel.
    static func containsDebugDetail(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("debugDetail") || text.contains("debug_detail")
    }
}
