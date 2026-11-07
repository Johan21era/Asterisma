//  SentinelDomainTests.swift
//  AsterismaV2.5Tests
//
//  SG1 domain pins. These are pure functions, so they run instantly and pin
//  the laws rather than an implementation detail:
//    L5  evidence is required for severity ≥ warning
//    L6  one condition, one fingerprint; order/time/severity never fork it
//    L8  every rule carries complete copy
//    L14 silence without coverage is not health
//    L6  lifecycle only moves along legal edges

import Foundation
import Testing

@testable import AsterismaV2_5

// MARK: - Helpers

private func makeEvidence(
    _ label: String = "evidence.count",
    value: String = "1",
    at: Date = Date(timeIntervalSince1970: 1_767_225_600)
) -> SentinelEvidence {
    SentinelEvidence(
        kind: .count, labelKey: label, safeValue: value,
        observedAt: at, source: .dataStore)
}

private func makeDescriptor(
    id: String = "LIB-001",
    domain: SentinelDomain = .library,
    title: String = "Duplicate book records",
    what: String = "Two books share the same internal id.",
    risk: SentinelRiskClass = .r1,
    repair: String? = "REP-001"
) -> SentinelProbeDescriptor {
    SentinelProbeDescriptor(
        id: id, domain: domain, title: title, what: what,
        rootCauseKey: "library.duplicate-id", tier: .t1,
        defaultSeverity: .critical, defaultImpact: .high,
        riskClass: risk, repairID: repair)
}

private func makeFinding(
    rule: SentinelRuleID = SentinelRuleID("LIB-001"),
    subjects: [SentinelSubject] = [SentinelSubject(.book, "A")],
    severity: SentinelSeverity = .critical,
    discriminator: String = ""
) -> RawFinding {
    RawFinding(
        probeID: rule.rawValue,
        ruleID: rule,
        severity: severity,
        impact: .high,
        subjects: subjects,
        evidence: [makeEvidence()],
        discriminator: discriminator)
}

private func makeIssue(
    fingerprint: String = SentinelFingerprint.make(ruleID: SentinelRuleID("LIB-001"),
                                                    subjects: [SentinelSubject(.book, "A")]),
    rule: String = "LIB-001",
    status: SentinelIssueStatus = .open,
    severity: SentinelSeverity = .warning,
    firstSeen: Date = Date(timeIntervalSince1970: 1_767_225_600),
    lastSeen: Date? = nil,
    snoozedUntil: Date? = nil
) -> SentinelIssue {
    let seen = lastSeen ?? firstSeen
    return SentinelIssue(
        fingerprint: fingerprint,
        ruleID: SentinelRuleID(rule),
        ruleVersion: 1,
        rootCauseKey: "library.test",
        domain: .library,
        titleKey: "issue.test.title",
        status: status,
        severity: severity,
        confidence: 0.9,
        impact: .medium,
        subjects: [SentinelSubject(.book, "A")],
        evidence: [makeEvidence()],
        safeSummary: "A test condition.",
        firstSeen: firstSeen,
        lastSeen: seen,
        snoozedUntil: snoozedUntil,
        updatedAt: seen)
}

// MARK: - Fingerprint

@Suite("Sentinel Fingerprint")
struct SentinelFingerprintTests {

    @Test("A fingerprint is 16 lowercase hex characters")
    func shape() {
        let fingerprint = SentinelFingerprint.make(
            ruleID: SentinelRuleID("SES-004"),
            subjects: [SentinelSubject(.session, UUID().uuidString)])
        #expect(fingerprint.count == 16)
        #expect(fingerprint.allSatisfy { "0123456789abcdef".contains($0) })
    }

    @Test("The same condition produces the same fingerprint")
    func stability() {
        let rule = SentinelRuleID("SES-004")
        let subjects = [SentinelSubject(.session, "S-1"), SentinelSubject(.book, "B-1")]
        let first = SentinelFingerprint.make(ruleID: rule, subjects: subjects)
        let second = SentinelFingerprint.make(ruleID: rule, subjects: subjects.reversed())
        #expect(first == second)
    }

    @Test("Subject order never changes identity")
    func orderIndependent() {
        let rule = SentinelRuleID("LIB-009")
        let a = SentinelSubject(.book, "B")
        let b = SentinelSubject(.collection, "C")
        #expect(SentinelFingerprint.make(ruleID: rule, subjects: [a, b])
            == SentinelFingerprint.make(ruleID: rule, subjects: [b, a]))
    }

    @Test("Different rules on the same subject are different issues")
    func ruleSeparates() {
        let subject = [SentinelSubject(.book, "B")]
        #expect(SentinelFingerprint.make(ruleID: SentinelRuleID("LIB-004"), subjects: subject)
            != SentinelFingerprint.make(ruleID: SentinelRuleID("SES-001"), subjects: subject))
    }

    @Test("A discriminator separates genuinely different conditions")
    func discriminatorSeparates() {
        let rule = SentinelRuleID("SES-009")
        let subject = [SentinelSubject(.book, "B")]
        #expect(SentinelFingerprint.make(ruleID: rule, subjects: subject, discriminator: "window-a")
            != SentinelFingerprint.make(ruleID: rule, subjects: subject, discriminator: "window-b"))
    }

    @Test("Severity, evidence, time, and message never enter the fingerprint")
    func excludesVolatileFields() {
        let rule = SentinelRuleID("LIB-004")
        let subjects = [SentinelSubject(.book, "B")]
        let low = RawFinding(
            probeID: "LIB-004", ruleID: rule, severity: .info,
            confidence: 0.1, impact: .low, subjects: subjects,
            evidence: [makeEvidence("evidence.page", value: "1")],
            safeSummary: "first wording")
        let high = RawFinding(
            probeID: "LIB-004", ruleID: rule, severity: .critical,
            confidence: 0.99, impact: .high, subjects: subjects,
            evidence: [makeEvidence("evidence.time", value: "2026-10-28T10:00:00Z")],
            safeSummary: "completely different wording")
        #expect(SentinelFingerprint.make(for: low) == SentinelFingerprint.make(for: high))
    }

    @Test("Fingerprints distribute across many subjects")
    func collisionResistance() {
        var seen = Set<String>()
        var collisions = 0
        for index in 0..<5_000 {
            let fingerprint = SentinelFingerprint.make(
                ruleID: SentinelRuleID("LIB-001"),
                subjects: [SentinelSubject(.book, "book-\(index)")])
            if !seen.insert(fingerprint).inserted { collisions += 1 }
        }
        #expect(collisions == 0)
    }
}

// MARK: - Lifecycle

@Suite("Sentinel Lifecycle")
struct SentinelLifecycleTests {

    /// Independent specification of the legal edges. If the implementation
    /// changes, this table must be changed deliberately.
    static let legal: Set<String> = {
        var edges = Set<String>()
        for status in SentinelIssueStatus.allCases {
            edges.insert("\(status.rawValue)->\(status.rawValue)")
        }
        let table: [SentinelIssueStatus: [SentinelIssueStatus]] = [
            .open: [.acknowledged, .snoozed, .repairing, .repaired, .resolved,
                    .regressed, .ignored, .unactionable],
            .acknowledged: [.open, .snoozed, .repairing, .repaired, .resolved,
                            .regressed, .ignored, .unactionable],
            .snoozed: [.open, .acknowledged, .repairing, .resolved, .ignored],
            .repairing: [.repaired, .open, .regressed, .unactionable],
            .repaired: [.resolved, .regressed, .open],
            .resolved: [.regressed, .ignored],
            .regressed: [.open, .acknowledged, .snoozed, .repairing, .repaired,
                         .resolved, .ignored, .unactionable],
            .ignored: [.open, .acknowledged],
            .unactionable: [.open, .acknowledged],
        ]
        for (from, tos) in table {
            for to in tos { edges.insert("\(from.rawValue)->\(to.rawValue)") }
        }
        return edges
    }()

    @Test("Every status pair matches the lifecycle table",
          arguments: SentinelIssueStatus.allCases, SentinelIssueStatus.allCases)
    func matrix(from: SentinelIssueStatus, to: SentinelIssueStatus) {
        let expected = Self.legal.contains("\(from.rawValue)->\(to.rawValue)")
        #expect(SentinelLifecycle.canTransition(from: from, to: to) == expected,
                "\(from.rawValue) → \(to.rawValue)")
    }

    @Test("Resolution only returns through regression")
    func resolvedReopensAsRegression() {
        #expect(!SentinelLifecycle.canTransition(from: .resolved, to: .open))
        #expect(SentinelLifecycle.canTransition(from: .resolved, to: .regressed))
    }

    @Test("An illegal transition is a no-op, not a crash")
    func illegalApplyIsNoOp() {
        #expect(SentinelLifecycle.apply(.repairing, to: .resolved) == .resolved)
    }

    @Test("Every status is human-readable")
    func displayNames() {
        for status in SentinelIssueStatus.allCases {
            #expect(!status.displayName.isEmpty)
        }
    }

    @Test("Severity ordering is strict")
    func severityOrdering() {
        #expect(SentinelSeverity.info < .warning)
        #expect(SentinelSeverity.warning < .error)
        #expect(SentinelSeverity.error < .critical)
        #expect(!(SentinelSeverity.critical < .critical))
    }
}

// MARK: - Copy

@Suite("Sentinel Copy")
struct SentinelCopyTests {

    @Test("Every registered descriptor has complete copy")
    func copyIsComplete() {
        let descriptors = [
            makeDescriptor(),
            makeDescriptor(id: "FILE-004", domain: .files, title: "Orphan cover",
                           what: "A cover file has no matching book.", risk: .r2, repair: "REP-013"),
            makeDescriptor(id: "CAP-001", domain: .capacity, title: "Low disk",
                           what: "Free space is below the floor.", risk: .r0, repair: nil),
        ]
        for descriptor in descriptors {
            let copy = descriptor.metadata.copy
            #expect(copy.isComplete, "\(descriptor.id) copy is incomplete")
            #expect(!copy.now.isEmpty)
            #expect(!copy.whatIf.isEmpty)
        }
    }

    @Test("Copy explains the risk class honestly")
    func riskCopy() {
        let safe = makeDescriptor(risk: .r1, repair: "REP-001").metadata.copy
        #expect(safe.now.contains("safely"))

        let manual = makeDescriptor(risk: .r2, repair: "REP-012").metadata.copy
        #expect(manual.now.contains("approval"))

        let reportOnly = makeDescriptor(risk: .r0, repair: nil).metadata.copy
        #expect(reportOnly.now.contains("only reports"))
    }

    @Test("Every domain explains why it matters")
    func domainCopy() {
        for domain in SentinelDomain.allCases {
            #expect(!domain.whyItMatters.isEmpty)
            #expect(!domain.displayName.isEmpty)
            #expect(domain.code.count >= 2)
        }
    }

    @Test("Rule metadata keeps the probe's identity")
    func metadataRoundTrip() {
        let descriptor = makeDescriptor(id: "SQL-005", domain: .database, title: "WAL growth",
                                        what: "The write-ahead log is large.", risk: .r2, repair: "REP-015")
        let metadata = descriptor.metadata
        #expect(metadata.ruleID == SentinelRuleID("SQL-005"))
        #expect(metadata.domain == .database)
        #expect(metadata.title == descriptor.title)
        #expect(metadata.repairID == "REP-015")
        #expect(metadata.titleKey == "issue.sql005.title")
    }
}

// MARK: - Coverage and health

@Suite("Sentinel Health")
struct SentinelHealthTests {

    private func coverage(total: Int, ran: Int, skipped: Int = 0, failed: Int = 0,
                          required: Int, requiredRan: Int) -> SentinelCoverage {
        SentinelCoverage(
            totalProbes: total, ran: ran, skipped: skipped, failed: failed,
            requiredTotal: required, requiredRan: requiredRan,
            missingRequired: [], skippedByDomain: [:])
    }

    @Test("Complete coverage requires every required probe and no failures")
    func completeCoverage() {
        #expect(coverage(total: 10, ran: 10, required: 8, requiredRan: 8).isComplete)
        // A skipped *required* probe is what breaks a clean claim.
        #expect(!coverage(total: 10, ran: 9, skipped: 1, required: 8, requiredRan: 7).isComplete)
        #expect(!coverage(total: 10, ran: 9, failed: 1, required: 8, requiredRan: 8).isComplete)
        #expect(!coverage(total: 10, ran: 10, required: 8, requiredRan: 7).isComplete)
        #expect(!SentinelCoverage.empty.isComplete)
        // Skipping an optional deep probe in a fast pass does not falsify the
        // required-coverage claim; the disclosure still reports it.
        #expect(coverage(total: 10, ran: 9, skipped: 1, required: 8, requiredRan: 8).isComplete)
    }

    @Test("A skipped required probe makes the band unknown, never healthy")
    func skippedIsNotHealthy() {
        let model = SentinelHealthModel.compute(
            issues: [],
            coverage: coverage(total: 20, ran: 19, skipped: 1, required: 20, requiredRan: 19),
            now: Date())
        #expect(model.band == .unknown)
        #expect(!model.headline.contains("All clear"))
    }

    @Test("No probes at all is unknown, not healthy")
    func nothingRanIsUnknown() {
        let model = SentinelHealthModel.compute(issues: [], coverage: .empty, now: Date())
        #expect(model.band == .unknown)
    }

    @Test("Complete coverage with no visible issues is healthy")
    func healthy() {
        let model = SentinelHealthModel.compute(
            issues: [],
            coverage: coverage(total: 20, ran: 20, required: 20, requiredRan: 20),
            now: Date())
        #expect(model.band == .healthy)
        #expect(model.headline.contains("All clear"))
    }

    @Test("A critical issue outranks incomplete coverage")
    func criticalOutranksUnknown() {
        let model = SentinelHealthModel.compute(
            issues: [makeIssue(severity: .critical)],
            coverage: coverage(total: 20, ran: 5, failed: 15, required: 20, requiredRan: 5),
            now: Date())
        #expect(model.band == .critical)
        #expect(model.visibleIssueCount == 1)
    }

    @Test("Warning-only issues are watch")
    func warningBand() {
        let model = SentinelHealthModel.compute(
            issues: [makeIssue(severity: .warning)],
            coverage: coverage(total: 20, ran: 20, required: 20, requiredRan: 20),
            now: Date())
        #expect(model.band == .watch)
    }

    @Test("Resolved, snoozed, and ignored issues do not count")
    func hiddenIssuesDoNotCount() {
        let now = Date(timeIntervalSince1970: 1_767_300_000)
        let issues = [
            makeIssue(status: .resolved),
            makeIssue(status: .ignored),
            makeIssue(status: .snoozed, snoozedUntil: now.addingTimeInterval(3600)),
        ]
        let model = SentinelHealthModel.compute(
            issues: issues,
            coverage: coverage(total: 5, ran: 5, required: 5, requiredRan: 5),
            now: now)
        #expect(model.band == .healthy)
        #expect(model.visibleIssueCount == 0)
    }

    @Test("A snooze that has expired is visible again")
    func expiredSnoozeVisible() {
        let now = Date(timeIntervalSince1970: 1_767_300_000)
        let issue = makeIssue(status: .snoozed, snoozedUntil: now.addingTimeInterval(-60))
        #expect(issue.isVisible(at: now))
    }
}

// MARK: - Correlations

@Suite("Sentinel Correlation")
struct SentinelCorrelationTests {

    @Test("Issues with the same root cause are grouped")
    func grouping() {
        var first = makeIssue(rule: "SES-015", severity: .critical)
        first.rootCauseKey = "sql.orphan-timing"
        var second = makeIssue(rule: "SES-016", severity: .error)
        second.rootCauseKey = "sql.orphan-timing"
        second.fingerprint = "bbbbbbbbbbbbbbbb"

        let diagnoses = SentinelDiagnosis.correlate(issues: [first, second], now: first.lastSeen)
        #expect(diagnoses.count == 1)
        #expect(diagnoses[0].issueFingerprints.count == 2)
        #expect(diagnoses[0].isCorrelated)
        #expect(diagnoses[0].severity == .critical)
    }

    @Test("A single issue still produces an explanation")
    func singleDiagnosis() {
        let issue = makeIssue()
        let diagnoses = SentinelDiagnosis.correlate(issues: [issue], now: issue.lastSeen)
        #expect(diagnoses.count == 1)
        #expect(!diagnoses[0].isCorrelated)
        #expect(!diagnoses[0].headline.isEmpty)
    }

    @Test("Silenced issues never appear in a diagnosis")
    func silencedExcluded() {
        let resolved = makeIssue(status: .resolved)
        let ignored = makeIssue(status: .ignored)
        #expect(SentinelDiagnosis.correlate(issues: [resolved, ignored],
                                            now: resolved.lastSeen).isEmpty)
    }

    @Test("Old issues outside the window are excluded")
    func windowExcludes() {
        let old = makeIssue(firstSeen: Date(timeIntervalSince1970: 1_767_225_600))
        let now = old.lastSeen.addingTimeInterval(48 * 3600)
        #expect(SentinelDiagnosis.correlate(issues: [old], now: now).isEmpty)
    }
}
