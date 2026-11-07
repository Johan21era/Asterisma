//  LibraryRecoveryGateTests.swift
//  Library Safety — Phase 6 gate pins.
//
//  G6: Sentinel performs no probes or repairs during an incident; the journal
//  records the boundary once; a full verification cycle runs after recovery;
//  diagnostics stay redacted; only structural rules may open an incident.

import Foundation
import Testing

@testable import AsterismaV2_5

@Suite("Library recovery · Sentinel gate", .serialized)
@MainActor
final class LibraryRecoveryGateTests {

    // MARK: - Suspension

    @Test("A suspended gate runs no probe and reports the reason")
    func suspendedCycleRunsNothing() async {
        let probe = SentinelToggleProbe()
        let harness = await SentinelRuntimeHarness.make(probes: [probe])
        defer { harness.root.remove() }
        let gate = MutableRecoveryGate(.suspended(.storeFrozen))
        await harness.runtime.setRecoveryGate(gate)

        let report = await harness.runtime.runCycle(trigger: .scheduled, scope: .deep)

        #expect(report.error == SentinelRuntime.suspendedMessage)
        #expect(report.probeResults.isEmpty)
        #expect(report.coverage.totalProbes == 0)
        #expect(probe.runCount == 0)

        let state = await harness.runtime.publishedState()
        #expect(state.issues.isEmpty)
        #expect(state.operationalMode == .suspended(.storeFrozen))
    }

    @Test("The boundary is journaled once, not once per attempt")
    func boundaryIsRecordedOnce() async {
        let harness = await SentinelRuntimeHarness.make(probes: [SentinelToggleProbe()])
        defer { harness.root.remove() }
        let gate = MutableRecoveryGate(.suspended(.incidentOpen))
        await harness.runtime.setRecoveryGate(gate)

        for _ in 0..<5 {
            _ = await harness.runtime.runCycle(trigger: .scheduled, scope: .fast)
        }

        let suspended = await harness.runtime.history().filter { $0.event == .sentinelSuspended }
        #expect(suspended.count == 1)
        #expect(suspended.first?.status == LibrarySuspensionReason.incidentOpen.rawValue)
    }

    @Test("Resuming records the resume and lets probes run again")
    func resumeReopensProbing() async {
        let probe = SentinelToggleProbe()
        let harness = await SentinelRuntimeHarness.make(probes: [probe])
        defer { harness.root.remove() }
        let gate = MutableRecoveryGate(.suspended(.recoveryVerifying))
        await harness.runtime.setRecoveryGate(gate)

        _ = await harness.runtime.runCycle(trigger: .scheduled, scope: .fast)
        await gate.set(.normal)
        let report = await harness.runtime.runCycle(trigger: .scheduled, scope: .fast)

        #expect(report.error == nil)
        #expect(report.coverage.ran == 1)
        #expect(probe.runCount == 1)

        let resumed = await harness.runtime.history().filter { $0.event == .sentinelResumed }
        #expect(resumed.count == 1)
    }

    @Test("Repairs and previews are blocked while recovery owns the store")
    func repairsAreBlocked() async {
        let harness = await SentinelRuntimeHarness.make(
            probes: [SentinelToggleProbe()],
            autonomy: .autoSafe)
        defer { harness.root.remove() }
        await harness.runtime.setRecoveryGate(MutableRecoveryGate(.suspended(.recoveryExecuting)))

        let outcome = await harness.runtime.repair(fingerprint: "any")
        #expect(outcome.status == .blocked)
        #expect(outcome.message == SentinelRuntime.suspendedMessage)

        let preview = await harness.runtime.previewRepair(fingerprint: "any")
        #expect(preview == nil)
    }

    @Test("A verification request while suspended does not probe")
    func verificationRefusesWhileSuspended() async {
        let probe = SentinelToggleProbe()
        let harness = await SentinelRuntimeHarness.make(probes: [probe])
        defer { harness.root.remove() }
        await harness.runtime.setRecoveryGate(MutableRecoveryGate(.suspended(.incidentOpen)))

        let report = await harness.runtime.runRecoveryVerification()
        #expect(report.error == SentinelRuntime.suspendedMessage)
        #expect(probe.runCount == 0)
    }

    @Test("Recovery verification runs the deep set after the gate opens")
    func verificationRunsDeepAfterRecovery() async {
        let probe = SentinelToggleProbe()
        let harness = await SentinelRuntimeHarness.make(probes: [probe])
        defer { harness.root.remove() }
        let gate = MutableRecoveryGate(.suspended(.recoveryVerifying))
        await harness.runtime.setRecoveryGate(gate)
        await gate.set(.normal)

        let report = await harness.runtime.runRecoveryVerification()
        #expect(report.error == nil)
        #expect(report.trigger == .recovery)
        #expect(report.scope == .deep)
        #expect(probe.runCount == 1)

        let verified = await harness.runtime.history().filter { $0.event == .recoveryVerified }
        #expect(verified.count == 1)
    }

    // MARK: - Promotion matrix

    @Test("Only structural critical rules may open an incident")
    func promotionMatrix() {
        let structural = issue(rule: "SQL-001", severity: .critical)
        #expect(SentinelIncidentPromotion.shouldPromote(
            SentinelIncidentPromotion.candidate(from: structural)!))

        let warning = issue(rule: "SQL-001", severity: .warning)
        #expect(SentinelIncidentPromotion.shouldPromote(
            SentinelIncidentPromotion.candidate(from: warning)!) == false)

        let schema = issue(rule: "SQL-006", severity: .critical)
        #expect(SentinelIncidentPromotion.kind(forRule: "SQL-006") == .schemaMismatch)
        #expect(SentinelIncidentPromotion.shouldPromote(
            SentinelIncidentPromotion.candidate(from: schema)!))

        for rule in ["SQL-002", "SQL-003", "SQL-004", "SQL-005", "SQL-009", "SQL-010"] {
            #expect(SentinelIncidentPromotion.candidate(from: issue(rule: rule)) == nil)
        }

        let resolved = issue(rule: "SQL-001", severity: .critical, status: .resolved)
        #expect(SentinelIncidentPromotion.candidate(from: resolved) == nil)

        let snoozed = issue(rule: "SQL-001", severity: .critical, status: .snoozed)
        #expect(SentinelIncidentPromotion.candidate(from: snoozed) == nil)
    }

    @Test("A coordinator opens an incident only from a promotable candidate")
    func coordinatorPromotesStructuralCandidate() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try LibraryIncidentStore(root: dir)
        let coordinator = LibraryHealthCoordinator(store: store)

        #expect(SentinelIncidentPromotion.candidate(
            from: issue(rule: "SQL-009", severity: .critical)) == nil)
        let cosmetic = LibraryIncidentCandidate(
            kind: .unknown,
            ruleID: "SQL-009",
            fingerprint: "cosmetic",
            severity: .critical,
            evidence: [],
            detectedAt: sentinelTestNow)
        await coordinator.handleSentinelCandidate(cosmetic)
        #expect(coordinator.incident == nil)

        let structural = SentinelIncidentPromotion.candidate(
            from: issue(rule: "SQL-001", severity: .critical))!
        await coordinator.handleSentinelCandidate(structural)
        #expect(coordinator.incident?.kind == .integrityCheckFailed)
        #expect(coordinator.incident?.state == .detected)
        #expect(coordinator.incident?.trigger == .probeFinding(
            ruleID: "SQL-001", fingerprint: structural.fingerprint ?? ""))

        let mode = await coordinator.operationalMode()
        #expect(mode == .suspended(.incidentOpen))
    }

    // MARK: - Diagnostics

    @Test("Diagnostics schema 2 carries gate state and no debug detail")
    func diagnosticsCarryGateState() throws {
        var state = SentinelPublishedState.empty
        state.operationalMode = .suspended(.storeFrozen)

        let document = SentinelDiagnostics.document(
            state: state, appVersion: "test", now: sentinelTestNow)
        #expect(document.schemaVersion == 2)
        #expect(document.recovery?.mode == "suspended")
        #expect(document.recovery?.suspensionReason == "storeFrozen")

        let data = try SentinelDiagnostics.export(
            state: state, appVersion: "test", now: sentinelTestNow)
        #expect(SentinelDiagnostics.containsDebugDetail(data) == false)
        let text = String(data: data, encoding: .utf8) ?? ""
        #expect(text.contains("\"recovery\""))
        #expect(text.contains("storeFrozen"))
    }

    @Test("A schema-1 diagnostics file without a recovery row still decodes")
    func diagnosticsBackwardCompatible() throws {
        let data = try SentinelDiagnostics.export(
            state: .empty, appVersion: "test", now: sentinelTestNow)
        var object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["schemaVersion"] = 1
        object.removeValue(forKey: "recovery")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(
            SentinelDiagnostics.Document.self, from: legacy)
        #expect(document.schemaVersion == 1)
        #expect(document.recovery == nil)
    }

    // MARK: - Journal forward compatibility

    @Test("An unknown journal event decodes as unknown, not corrupt")
    func unknownJournalEvent() throws {
        let json = """
            {"sequence":1,"event":"futureEvent","at":"2026-01-01T00:00:00Z",
             "cycleID":"cycle","counts":{}}
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(SentinelJournalEntry.self, from: Data(json.utf8))
        #expect(entry.event == .unknown)
        #expect(SentinelJournalEvent.allCases.contains(.unknown))
    }

    // MARK: - Helpers

    private func issue(
        rule: String,
        severity: SentinelSeverity = .critical,
        status: SentinelIssueStatus = .open
    ) -> SentinelIssue {
        SentinelIssue(
            fingerprint: SentinelFingerprint.make(
                ruleID: SentinelRuleID(rule),
                subjects: [SentinelSubject(.database, "library")]),
            ruleID: SentinelRuleID(rule),
            ruleVersion: 1,
            rootCauseKey: "test",
            domain: .database,
            titleKey: "test.title",
            status: status,
            severity: severity,
            confidence: 1,
            impact: .high,
            subjects: [SentinelSubject(.database, "library")],
            evidence: [
                SentinelEvidence(
                    kind: .count,
                    labelKey: "evidence.sql001.rows",
                    safeValue: "3",
                    observedAt: sentinelTestNow,
                    source: .sqlite)
            ],
            safeSummary: "Structural damage",
            firstSeen: sentinelTestNow,
            lastSeen: sentinelTestNow,
            updatedAt: sentinelTestNow)
    }

    private func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
