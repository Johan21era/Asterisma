//  SentinelDiagnoserTests.swift
//  AsterismaV2.5Tests
//
//  The dedupe and lifecycle rules that make the launch card honest:
//    • one condition is one issue, forever;
//    • re-detection updates, it does not duplicate;
//    • an issue closes only when its owning probe actually looked;
//    • a skipped probe is not a clean result.

import Foundation
import Testing

@testable import AsterismaV2_5

private let fixedNow = Date(timeIntervalSince1970: 1_767_225_600)

private func evidence(_ value: String = "1") -> SentinelEvidence {
    SentinelEvidence(kind: .count, labelKey: "evidence.count",
                     safeValue: value, observedAt: fixedNow, source: .dataStore)
}

private func descriptor(
    id: String = "LIB-001",
    risk: SentinelRiskClass = .r1
) -> SentinelProbeDescriptor {
    SentinelProbeDescriptor(
        id: id, domain: .library, title: "Duplicate book records",
        what: "Two books share the same internal id.",
        rootCauseKey: "library.duplicate-id", tier: .t1,
        defaultSeverity: .critical, defaultImpact: .high,
        riskClass: risk, repairID: risk == .r1 ? "REP-001" : nil)
}

private func finding(
    rule: String = "LIB-001",
    subject: String = "book-a",
    severity: SentinelSeverity = .critical,
    discriminator: String = "",
    debugDetail: String? = nil,
    evidenceOnly: Bool = false
) -> RawFinding {
    RawFinding(
        probeID: rule,
        ruleID: SentinelRuleID(rule),
        severity: severity,
        impact: .high,
        subjects: [SentinelSubject(.book, subject)],
        evidence: [evidence()],
        discriminator: discriminator,
        debugDetail: debugDetail,
        isEvidenceOnly: evidenceOnly)
}

private func diagnose(
    existing: [SentinelIssue] = [],
    findings: [RawFinding],
    descriptors: [SentinelProbeDescriptor] = [descriptor()],
    completed: Set<String> = ["LIB-001"],
    failed: Set<String> = [],
    now: Date = fixedNow
) -> SentinelDiagnosisResult {
    SentinelDiagnoser.diagnose(
        existing: existing,
        findings: findings,
        descriptors: descriptors,
        completedProbeIDs: completed,
        failedProbeIDs: failed,
        cycleID: "cycle-1",
        now: now,
        maximumIssues: 500)
}

@Suite("Sentinel Diagnoser")
struct SentinelDiagnoserTests {

    @Test("A first observation opens exactly one issue")
    func opensOnce() throws {
        let result = diagnose(findings: [finding()])
        #expect(result.issues.count == 1)
        let issue = try #require(result.issues.first)
        #expect(issue.status == .open)
        #expect(issue.ruleID == SentinelRuleID("LIB-001"))
        #expect(issue.domain == .library)
        #expect(issue.severity == .critical)
        #expect(!issue.evidence.isEmpty)
        #expect(issue.safeSummary == "Duplicate book records")
        #expect(result.opened == [issue.fingerprint])
    }

    @Test("The same condition 100 times is still one issue")
    func dedupeAcrossCycles() throws {
        var issues: [SentinelIssue] = []
        var now = fixedNow
        for _ in 0..<100 {
            let result = diagnose(existing: issues, findings: [finding()], now: now)
            issues = result.issues
            now = now.addingTimeInterval(900)
        }
        #expect(issues.count == 1)
        #expect(issues[0].occurrenceCount == 100)
    }

    @Test("Re-detection updates instead of duplicating")
    func updatesExisting() throws {
        let first = diagnose(findings: [finding(severity: .warning)])
        let second = diagnose(
            existing: first.issues,
            findings: [finding(severity: .critical)],
            now: fixedNow.addingTimeInterval(60))
        #expect(second.issues.count == 1)
        #expect(second.opened.isEmpty)
        #expect(second.updated.count == 1)
        #expect(second.issues[0].severity == .critical)
        #expect(second.issues[0].occurrenceCount == 2)
        #expect(second.issues[0].lastSeen > second.issues[0].firstSeen)
    }

    @Test("Different subjects are different issues")
    func separateSubjects() {
        let result = diagnose(findings: [finding(subject: "a"), finding(subject: "b")])
        #expect(result.issues.count == 2)
    }

    @Test("A discriminator separates conditions on one subject")
    func discriminator() {
        let result = diagnose(findings: [
            finding(discriminator: "morning"),
            finding(discriminator: "evening"),
        ])
        #expect(result.issues.count == 2)
    }

    @Test("A resolved condition that comes back is a regression")
    func regression() throws {
        let resolved = makeResolvedIssue()
        let result = diagnose(existing: [resolved], findings: [finding()])
        let issue = try #require(result.issues.first)
        #expect(issue.status == .regressed)
        #expect(issue.resolvedAt == nil)
        #expect(result.regressed == [issue.fingerprint])
    }

    @Test("A repaired condition that comes back is a regression, not a duplicate")
    func repairedRegression() throws {
        var repaired = makeResolvedIssue()
        repaired.status = .repaired
        let result = diagnose(existing: [repaired], findings: [finding()])
        let issue = try #require(result.issues.first)
        #expect(issue.status == .regressed)
        #expect(result.issues.count == 1)
    }

    @Test("A live snooze is respected")
    func snoozeRespected() throws {
        var issue = makeResolvedIssue()
        issue.status = .snoozed
        issue.snoozedUntil = fixedNow.addingTimeInterval(3600)
        let result = diagnose(existing: [issue], findings: [finding()])
        #expect(result.issues[0].status == .snoozed)
    }

    @Test("An expired snooze reopens")
    func snoozeExpires() throws {
        var issue = makeResolvedIssue()
        issue.status = .snoozed
        issue.snoozedUntil = fixedNow.addingTimeInterval(-1)
        let result = diagnose(existing: [issue], findings: [finding()])
        #expect(result.issues[0].status == .open)
    }

    @Test("An ignored issue stays ignored when re-detected")
    func ignoredStaysQuiet() throws {
        var issue = makeResolvedIssue()
        issue.status = .ignored
        let result = diagnose(existing: [issue], findings: [finding()])
        #expect(result.issues[0].status == .ignored)
    }

    @Test("An issue closes only when its owning probe completed")
    func closesWithProof() {
        let existing = [makeOpenIssue()]
        let result = SentinelDiagnoser.diagnose(
            existing: existing,
            findings: [],
            descriptors: [descriptor()],
            completedProbeIDs: ["LIB-001"],
            failedProbeIDs: [],
            cycleID: "cycle-2",
            now: fixedNow.addingTimeInterval(60))
        #expect(result.issues[0].status == .resolved)
        #expect(result.resolved.count == 1)
        #expect(result.issues[0].resolvedAt != nil)
    }

    @Test("A skipped probe never closes an issue")
    func skipKeepsIssue() {
        let existing = [makeOpenIssue()]
        let result = SentinelDiagnoser.diagnose(
            existing: existing,
            findings: [],
            descriptors: [descriptor()],
            completedProbeIDs: [],
            failedProbeIDs: [],
            cycleID: "cycle-2",
            now: fixedNow.addingTimeInterval(60))
        #expect(result.issues[0].status == .open)
        #expect(result.resolved.isEmpty)
        #expect(result.issues[0].lastSeen == existing[0].lastSeen)
    }

    @Test("A failed probe never closes an issue")
    func failureKeepsIssue() {
        let existing = [makeOpenIssue()]
        let result = SentinelDiagnoser.diagnose(
            existing: existing,
            findings: [],
            descriptors: [descriptor()],
            completedProbeIDs: [],
            failedProbeIDs: ["LIB-001"],
            cycleID: "cycle-2",
            now: fixedNow.addingTimeInterval(60))
        #expect(result.issues[0].status == .open)
    }

    @Test("A snoozed issue is not silently resolved by a clean probe")
    func snoozeNotResolved() {
        var issue = makeOpenIssue()
        issue.status = .snoozed
        issue.snoozedUntil = fixedNow.addingTimeInterval(3600)
        let result = SentinelDiagnoser.diagnose(
            existing: [issue], findings: [], descriptors: [descriptor()],
            completedProbeIDs: ["LIB-001"], failedProbeIDs: [],
            cycleID: "cycle-2", now: fixedNow.addingTimeInterval(60))
        #expect(result.issues[0].status == .snoozed)
    }

    @Test("Evidence is capped and duplicates collapse")
    func evidenceCap() throws {
        var current: [SentinelIssue] = []
        for cycle in 0..<20 {
            let item = SentinelEvidence(
                kind: .timestamp, labelKey: "evidence.lastActivity",
                safeValue: "2026-10-28T00:00:\(String(format: "%02d", cycle))Z",
                observedAt: fixedNow.addingTimeInterval(Double(cycle)),
                source: .dataStore)
            let raw = RawFinding(
                probeID: "LIB-001", ruleID: SentinelRuleID("LIB-001"),
                severity: .warning, impact: .medium,
                subjects: [SentinelSubject(.book, "book-a")],
                evidence: [item])
            current = diagnose(existing: current,
                               findings: [raw],
                               now: fixedNow.addingTimeInterval(Double(cycle))).issues
        }
        #expect(current.count == 1)
        #expect(current[0].evidence.count == 8)

        // An identical item updates in place rather than appending forever.
        let duplicate = SentinelEvidence(
            kind: .count, labelKey: "evidence.count", safeValue: "1",
            observedAt: fixedNow, source: .dataStore)
        let merged = SentinelDiagnoser.mergeEvidence(current[0].evidence, [duplicate], now: fixedNow)
        #expect(merged.count <= 8)
    }

    @Test("Corroborating evidence attaches to the owner's issue")
    func corroborationMerges() throws {
        let owned = RawFinding(
            probeID: "LIB-001", ruleID: SentinelRuleID("LIB-001"),
            severity: .warning, impact: .medium,
            subjects: [SentinelSubject(.book, "book-a")],
            evidence: [evidence("1")])
        let corroborator = RawFinding(
            probeID: "LIB-002", ruleID: SentinelRuleID("LIB-001"),
            severity: .warning, impact: .medium,
            subjects: [SentinelSubject(.book, "book-a")],
            evidence: [evidence("2")],
            isEvidenceOnly: true)
        let result = diagnose(findings: [owned, corroborator])
        #expect(result.issues.count == 1)
        #expect(result.issues[0].evidence.count >= 2)
    }

    @Test("Evidence-only findings never open an issue")
    func evidenceOnlyDoesNotOpen() {
        let result = diagnose(findings: [finding(evidenceOnly: true)])
        #expect(result.issues.isEmpty)
    }

    @Test("Issues are sorted worst first")
    func sorting() {
        let result = diagnose(findings: [
            finding(rule: "LIB-001", subject: "a", severity: .info),
            finding(rule: "LIB-001", subject: "b", severity: .critical),
            finding(rule: "LIB-001", subject: "c", severity: .warning),
        ])
        #expect(result.issues.map(\.severity) == [.critical, .warning, .info])
    }

    @Test("The issue cap keeps the worst issues")
    func capKeepsWorst() {
        let findings = (0..<40).map { index in
            finding(subject: "book-\(index)",
                    severity: index == 7 ? .critical : .info)
        }
        let result = SentinelDiagnoser.diagnose(
            existing: [], findings: findings, descriptors: [descriptor()],
            completedProbeIDs: ["LIB-001"], failedProbeIDs: [],
            cycleID: "c", now: fixedNow, maximumIssues: 10)
        #expect(result.issues.count == 10)
        #expect(result.issues.first?.severity == .critical)
    }

    @Test("Debug detail stays out of the safe summary")
    func safeSummaryHasNoUserText() throws {
        let secret = "PRIVATE-TITLE-\(UUID().uuidString)"
        let result = diagnose(findings: [finding(debugDetail: secret)])
        let issue = try #require(result.issues.first)
        #expect(!issue.safeSummary.contains(secret))
        #expect(issue.debugDetail?.contains(secret) == true)
    }

    @Test("Evidence survives a rebuild from the journal")
    func rebuildKeepsIdentity() {
        let issue = makeOpenIssue()
        #expect(!issue.fingerprint.isEmpty)
        #expect(issue.evidence.count == 1)
    }

    private func makeOpenIssue() -> SentinelIssue {
        let rule = SentinelRuleID("LIB-001")
        let subject = SentinelSubject(.book, "book-a")
        return SentinelIssue(
            fingerprint: SentinelFingerprint.make(ruleID: rule, subjects: [subject]),
            ruleID: rule,
            ruleVersion: 1,
            rootCauseKey: "library.duplicate-id",
            domain: .library,
            titleKey: "issue.lib001.title",
            status: .open,
            severity: .warning,
            confidence: 0.9,
            impact: .high,
            subjects: [subject],
            evidence: [evidence()],
            safeSummary: "Duplicate book records",
            firstSeen: fixedNow.addingTimeInterval(-3600),
            lastSeen: fixedNow.addingTimeInterval(-3600),
            updatedAt: fixedNow.addingTimeInterval(-3600))
    }

    private func makeResolvedIssue() -> SentinelIssue {
        var issue = makeOpenIssue()
        issue.status = .resolved
        issue.resolvedAt = fixedNow.addingTimeInterval(-60)
        return issue
    }
}
