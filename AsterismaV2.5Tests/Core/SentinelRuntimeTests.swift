//  SentinelRuntimeTests.swift
//  AsterismaV2.5Tests
//
//  SG2/SG3 pins for the actor: one cycle at a time, isolated failures,
//  honest coverage, generation-guarded repairs, verification, rollback, undo,
//  and a journal that cannot carry user text.

import Foundation
import Testing

@testable import AsterismaV2_5

@Suite("Sentinel Runtime", .serialized)
@MainActor
final class SentinelRuntimeTests {

    // MARK: - Cycle basics

    @Test("One cycle opens one issue and records complete coverage")
    func cycleOpensIssue() async {
        let probe = SentinelToggleProbe()
        let harness = await SentinelRuntimeHarness.make(probes: [probe], books: [sentinelBook()])
        defer { harness.root.remove() }

        let report = await harness.runtime.runCycle(trigger: .manual, scope: .fast)
        #expect(report.error == nil)
        #expect(report.coverage.ran == 1)
        #expect(report.coverage.isComplete)
        #expect(report.opened.count == 1)

        let state = await harness.runtime.publishedState()
        #expect(state.issues.count == 1)
        #expect(state.issues[0].status == .open)
        #expect(state.issues[0].evidence.isEmpty == false)
        #expect(state.health.band == .watch)
    }

    @Test("The same condition across 100 cycles stays one issue")
    func dedupeAcrossCycles() async {
        let probe = SentinelToggleProbe()
        let harness = await SentinelRuntimeHarness.make(probes: [probe])
        defer { harness.root.remove() }

        for _ in 0..<100 {
            _ = await harness.runtime.runCycle(trigger: .scheduled, scope: .fast)
        }
        let state = await harness.runtime.publishedState()
        #expect(state.issues.count == 1)
        #expect(state.issues[0].occurrenceCount == 100)
        #expect(state.counters["cycles"] == 100)
    }

    @Test("An issue resolves only after the probe actually stops finding it")
    func resolvesWhenConditionEnds() async {
        let probe = SentinelToggleProbe()
        let harness = await SentinelRuntimeHarness.make(probes: [probe])
        defer { harness.root.remove() }

        _ = await harness.runtime.runCycle(trigger: .manual, scope: .fast)
        probe.setEmit(false)
        let report = await harness.runtime.runCycle(trigger: .scheduled, scope: .fast)

        #expect(report.resolved.count == 1)
        let state = await harness.runtime.publishedState()
        #expect(state.issues[0].status == .resolved)
        #expect(state.health.band == .healthy)
    }

    @Test("A skipped probe makes coverage incomplete and the band unknown")
    func skippedProbeIsNotHealthy() async {
        let harness = await SentinelRuntimeHarness.make(probes: [SentinelUnavailableProbe()])
        defer { harness.root.remove() }

        let report = await harness.runtime.runCycle(trigger: .manual, scope: .deep)
        #expect(report.coverage.skipped == 1)
        #expect(!report.coverage.isComplete)
        #expect(report.health.band == .unknown)
        #expect(!report.health.headline.contains("All clear"))
    }

    @Test("A throwing probe is isolated; the rest of the cycle completes")
    func failureIsIsolated() async {
        let harness = await SentinelRuntimeHarness.make(
            probes: [SentinelToggleProbe(), SentinelFailingProbe()])
        defer { harness.root.remove() }

        let report = await harness.runtime.runCycle(trigger: .manual, scope: .fast)
        #expect(report.coverage.failed == 1)
        #expect(report.coverage.ran == 1)
        #expect(report.opened.count == 1)
        #expect(report.probeResults.contains { $0.probeID == "TST-002" && $0.status == .failed })
    }

    @Test("A slow probe times out without blocking the others")
    func timeoutIsIsolated() async {
        let harness = await SentinelRuntimeHarness.make(
            probes: [SentinelToggleProbe(), SentinelSlowProbe(timeout: 0.1)])
        defer { harness.root.remove() }

        let report = await harness.runtime.runCycle(trigger: .manual, scope: .fast)
        let slow = report.probeResults.first { $0.probeID == "TST-004" }
        #expect(slow?.status == .timedOut)
        #expect((slow?.duration ?? 99) < 1.0)
        #expect(report.opened.count == 1)
    }

    @Test("The cycle lock prevents overlapping cycles")
    func cycleLock() async {
        let harness = await SentinelRuntimeHarness.make(
            probes: [SentinelSlowProbe(timeout: 5)])
        defer { harness.root.remove() }

        async let first = harness.runtime.runCycle(trigger: .manual, scope: .fast)
        async let second = harness.runtime.runCycle(trigger: .manual, scope: .fast)
        _ = await (first, second)

        let state = await harness.runtime.publishedState()
        #expect(state.counters["cycles"] == 1)
    }

    @Test("No snapshot source produces an honest error, not a fake clean cycle")
    func missingSnapshotSource() async {
        let clock = TestSentinelClock(sentinelTestNow)
        let env = SentinelEnvironment.test(clock: clock, dataRoot: nil, isDebug: true)
        let runtime = SentinelRuntime(environment: env, configuration: .default,
                                      probes: [SentinelToggleProbe()])
        let report = await runtime.runCycle(trigger: .manual, scope: .fast)
        #expect(report.error != nil)
        #expect(report.coverage.totalProbes == 0)
        #expect(report.health.band == .unknown)
    }

    // MARK: - Repair guardrails

    @Test("Auto-safe repairs an orphan session and verifies it")
    func autoRepairVerifies() async {
        let book = sentinelOrphanBook()
        let harness = await SentinelRuntimeHarness.make(
            probes: [SES004OrphanActiveSession()],
            autonomy: .autoSafe,
            books: [book])
        defer { harness.root.remove() }

        let report = await harness.runtime.runCycle(trigger: .manual, scope: .fast)
        #expect(report.repairs.count == 1)
        #expect(report.repairs.first?.status == .appliedVerified)
        #expect(harness.bridge.snapshotCalls == 1)

        let repaired = harness.bridge.books.first
        #expect(repaired?.activeSessionID == nil)
        #expect(repaired?.sessions.first?.endTime != nil)

        let state = await harness.runtime.publishedState()
        #expect(state.issues.first?.status == .repaired)
        #expect(state.repairs.first?.status == .verified)
        #expect(state.counters["repairsVerified"] == 1)
    }

    @Test("A generation change between probe and repair blocks the mutation")
    func generationGuard() async {
        let book = sentinelOrphanBook()
        let root = SentinelTempRoot()
        defer { root.remove() }
        let clock = TestSentinelClock(sentinelTestNow)
        let bridge = SentinelFixtureBridge(books: [book], root: root.url, clock: clock)

        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func next() -> Int {
                lock.lock(); defer { lock.unlock() }
                value += 1
                return value
            }
        }
        let counter = Counter()
        let provider = SentinelSnapshotProvider { facts in
            let capture = counter.next()
            return await MainActor.run {
                var snapshot = bridge.makeSnapshot(facts: facts)
                snapshot.generation = capture == 1 ? 1 : 99
                return snapshot
            }
        }

        let harness = await SentinelRuntimeHarness.make(
            probes: [SES004OrphanActiveSession()],
            autonomy: .autoSafe,
            books: [book],
            root: root,
            bridgeOverride: bridge,
            providerOverride: provider)

        let report = await harness.runtime.runCycle(trigger: .manual, scope: .fast)
        #expect(report.repairs.isEmpty)
        #expect(harness.bridge.snapshotCalls == 0)
        #expect(harness.bridge.books.first?.activeSessionID != nil)
    }

    @Test("Recent reading activity blocks every repair")
    func quiescenceBlocks() async {
        let book = sentinelOrphanBook()
        let harness = await SentinelRuntimeHarness.make(
            probes: [SES004OrphanActiveSession()],
            autonomy: .autoSafe,
            books: [book])
        defer { harness.root.remove() }
        harness.bridge.recentActivity = true

        let report = await harness.runtime.runCycle(trigger: .manual, scope: .fast)
        #expect(report.repairs.first?.status == .blocked)
        #expect(harness.bridge.snapshotCalls == 0)
        #expect(harness.bridge.books.first?.activeSessionID != nil)
    }

    @Test("No snapshot means no mutation")
    func snapshotFailureBlocks() async {
        let book = sentinelOrphanBook()
        let harness = await SentinelRuntimeHarness.make(
            probes: [SES004OrphanActiveSession()],
            autonomy: .autoSafe,
            books: [book])
        defer { harness.root.remove() }
        harness.bridge.snapshotSucceeds = false

        let report = await harness.runtime.runCycle(trigger: .manual, scope: .fast)
        #expect(report.repairs.first?.status == .blocked)
        #expect(harness.bridge.applyCalls == 0)
        #expect(harness.bridge.books.first?.activeSessionID != nil)
    }

    @Test("Failed verification rolls the change back")
    func verificationFailureRollsBack() async {
        let book = sentinelOrphanBook()
        let harness = await SentinelRuntimeHarness.make(
            probes: [SES004OrphanActiveSession()],
            autonomy: .autoSafe,
            books: [book])
        defer { harness.root.remove() }
        harness.bridge.ignoresChanges = true

        let report = await harness.runtime.runCycle(trigger: .manual, scope: .fast)
        #expect(report.repairs.first?.status == .rolledBack)
        #expect(harness.bridge.restoreCalls == 0)
        let state = await harness.runtime.publishedState()
        #expect(state.repairs.first?.status == .rolledBack)
        #expect(state.issues.first?.status != .repaired)
    }

    @Test("Undo restores the exact values a verified repair changed")
    func undoRestores() async {
        let book = sentinelOrphanBook()
        let originalSessionID = book.activeSessionID
        let harness = await SentinelRuntimeHarness.make(
            probes: [SES004OrphanActiveSession()],
            autonomy: .autoSafe,
            books: [book])
        defer { harness.root.remove() }

        _ = await harness.runtime.runCycle(trigger: .manual, scope: .fast)
        let state = await harness.runtime.publishedState()
        guard let record = state.repairs.first else {
            Issue.record("Expected a repair record")
            return
        }

        let outcome = await harness.runtime.undoRepair(recordID: record.id)
        #expect(outcome.status == .appliedVerified)
        #expect(harness.bridge.books.first?.activeSessionID == originalSessionID)
        #expect(harness.bridge.books.first?.sessions.first?.endTime == nil)
    }

    @Test("Observe mode refuses even a user-initiated repair")
    func observeBlocksUserRepair() async {
        let harness = await SentinelRuntimeHarness.make(
            probes: [SES004OrphanActiveSession()],
            autonomy: .observe,
            books: [sentinelOrphanBook()])
        defer { harness.root.remove() }

        _ = await harness.runtime.runCycle(trigger: .manual, scope: .fast)
        let state = await harness.runtime.publishedState()
        let fingerprint = state.issues.first?.fingerprint ?? ""
        let outcome = await harness.runtime.repair(fingerprint: fingerprint)
        #expect(outcome.status == .blocked)
        #expect(harness.bridge.applyCalls == 0)
    }

    // MARK: - Status actions

    @Test("Acknowledge, snooze, and ignore move only along legal edges")
    func statusActions() async {
        let harness = await SentinelRuntimeHarness.make(
            probes: [SentinelToggleProbe()])
        defer { harness.root.remove() }
        _ = await harness.runtime.runCycle(trigger: .manual, scope: .fast)
        let fingerprint = await harness.runtime.publishedState().issues.first?.fingerprint ?? ""

        let acknowledged = await harness.runtime.setStatus(fingerprint: fingerprint, status: .acknowledged)
        #expect(acknowledged)
        let snoozed = await harness.runtime.setStatus(
            fingerprint: fingerprint, status: .snoozed,
            snoozedUntil: sentinelTestNow.addingTimeInterval(3600))
        #expect(snoozed)
        let ignored = await harness.runtime.setStatus(fingerprint: fingerprint, status: .ignored)
        #expect(ignored)

        let state = await harness.runtime.publishedState()
        #expect(state.issues.first?.status == .ignored)
    }

    // MARK: - Privacy and durability

    @Test("The safe journal never contains user text, even from debug detail")
    func journalPrivacy() async throws {
        final class SecretProbe: SentinelProbeV2, @unchecked Sendable {
            let secret: String
            let descriptor = SentinelProbeDescriptor(
                id: "TST-005", domain: .library,
                title: "Privacy fixture", what: "Carries a secret in debug only.",
                rootCauseKey: "test.privacy", tier: .t1,
                defaultSeverity: .warning, defaultImpact: .low)
            init(secret: String) { self.secret = secret }
            func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
                [SentinelProbeSupport.finding(
                    descriptor,
                    subjects: [SentinelSubject(.store, "fixture")],
                    evidence: [SentinelProbeSupport.count("evidence.test", 1, at: environment.now)],
                    debug: secret)]
            }
        }

        let secret = "PRIVATE-TITLE-\(UUID().uuidString)"
        let harness = await SentinelRuntimeHarness.make(probes: [SecretProbe(secret: secret)])
        defer { harness.root.remove() }
        _ = await harness.runtime.runCycle(trigger: .manual, scope: .fast)

        let journalDir = harness.root.url.appendingPathComponent("Sentinel/journal")
        let files = try FileManager.default.contentsOfDirectory(atPath: journalDir.path)
        for file in files {
            let text = try String(contentsOf: journalDir.appendingPathComponent(file), encoding: .utf8)
            #expect(!text.contains(secret))
        }

        // The debug surface still has it; only the journal is stripped.
        let state = await harness.runtime.publishedState()
        #expect(state.issues.first?.debugDetail?.contains(secret) == true)
    }

    @Test("The issue store can rebuild identity from the journal")
    func storeRebuild() async {
        let harness = await SentinelRuntimeHarness.make(probes: [SentinelToggleProbe()])
        defer { harness.root.remove() }
        _ = await harness.runtime.runCycle(trigger: .manual, scope: .fast)

        let rebuilt = await harness.runtime.performStoreRebuild()
        #expect(rebuilt)
        let state = await harness.runtime.publishedState()
        #expect(!state.issues.isEmpty)
    }

    @Test("Opening the same root twice is idempotent")
    func openIsIdempotent() async {
        let harness = await SentinelRuntimeHarness.make(probes: [SentinelToggleProbe()])
        defer { harness.root.remove() }
        _ = await harness.runtime.runCycle(trigger: .manual, scope: .fast)
        await harness.runtime.open(dataRoot: harness.root.url)
        let state = await harness.runtime.publishedState()
        #expect(state.issues.count == 1)
    }
}
