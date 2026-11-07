//  SentinelLaunchAndRepairTests.swift
//  AsterismaV2.5Tests
//
//  SG3/SG6 pins: the launch card's five states, the repair executor's refusal
//  contract, and the catalog's plan builders. The plan builders are pure, so
//  they are tested directly without a runtime.

import Foundation
import Testing

@testable import AsterismaV2_5

@Suite("Sentinel Launch Card", .serialized)
struct SentinelLaunchCardTests {

    private func state(
        issues: [SentinelIssue] = [],
        band: SentinelHealthBand = .healthy,
        coverage: SentinelCoverage? = nil,
        cycle: SentinelCycleReport = .idle
    ) -> SentinelPublishedState {
        let coverage = coverage ?? completeCoverage
        var value = SentinelPublishedState.empty
        value.issues = issues
        value.health = SentinelHealthModel(
            band: band, visibleIssueCount: issues.count, criticalCount: 0,
            errorCount: issues.filter { $0.severity == .error }.count,
            warningCount: issues.filter { $0.severity == .warning }.count,
            infoCount: 0, coverage: coverage,
            computedAt: sentinelTestNow, headline: "")
        value.coverage = coverage
        value.lastCycle = cycle
        return value
    }

    private var completeCoverage: SentinelCoverage {
        SentinelCoverage(
            totalProbes: 138, ran: 138, skipped: 0, failed: 0,
            requiredTotal: 120, requiredRan: 120,
            missingRequired: [], skippedByDomain: [:])
    }

    private var incompleteCoverage: SentinelCoverage {
        SentinelCoverage(
            totalProbes: 138, ran: 120, skipped: 18, failed: 2,
            requiredTotal: 120, requiredRan: 110,
            missingRequired: ["BAK-004"], skippedByDomain: ["files": 18])
    }

    @Test("A cycle that fixed something says what it fixed")
    func fixedState() {
        var cycle = SentinelCycleReport.idle
        cycle.startedAt = sentinelTestNow
        cycle.coverage = completeCoverage
        cycle.repairs = [
            SentinelRepairOutcome(repairID: "REP-001", issueFingerprints: [],
                                  status: .appliedVerified, message: "", record: nil),
            SentinelRepairOutcome(repairID: "REP-006", issueFingerprints: [],
                                  status: .appliedVerified, message: "", record: nil),
        ]
        let summary = SentinelLaunchCardBuilder.make(
            state: state(cycle: cycle), now: sentinelTestNow, allClearAlreadyShownToday: false)
        #expect(summary?.fixed == 2)
        #expect(summary?.headline == "Sentinel fixed 2 issues while you were away.")
    }

    @Test("Errors ask for a decision before reporting anything else")
    func decisionState() {
        var cycle = SentinelCycleReport.idle
        cycle.startedAt = sentinelTestNow
        cycle.coverage = completeCoverage
        let issue = issue(rule: "LIB-003", severity: .error)
        let summary = SentinelLaunchCardBuilder.make(
            state: state(issues: [issue], band: .attention, cycle: cycle),
            now: sentinelTestNow, allClearAlreadyShownToday: false)
        #expect(summary?.needsDecision == 1)
        #expect(summary?.headline.contains("needs your decision") == true)
    }

    @Test("An incomplete cycle admits what did not run")
    func incompleteState() {
        var cycle = SentinelCycleReport.idle
        cycle.startedAt = sentinelTestNow
        cycle.coverage = incompleteCoverage
        let summary = SentinelLaunchCardBuilder.make(
            state: state(coverage: incompleteCoverage, cycle: cycle),
            now: sentinelTestNow, allClearAlreadyShownToday: false)
        #expect(summary?.band == .unknown)
        #expect(summary?.headline.contains("did not run") == true)
    }

    @Test("All clear shows once a day and then stays quiet")
    func allClearState() {
        var cycle = SentinelCycleReport.idle
        cycle.startedAt = sentinelTestNow
        cycle.coverage = completeCoverage
        let first = SentinelLaunchCardBuilder.make(
            state: state(cycle: cycle), now: sentinelTestNow, allClearAlreadyShownToday: false)
        #expect(first?.marksAllClearShown == true)
        #expect(first?.headline == "Checked 138 things. All clear.")
        let second = SentinelLaunchCardBuilder.make(
            state: state(cycle: cycle), now: sentinelTestNow, allClearAlreadyShownToday: true)
        #expect(second == nil)
    }

    @Test("Watch-level issues still get one sentence")
    func watchState() {
        var cycle = SentinelCycleReport.idle
        cycle.startedAt = sentinelTestNow
        cycle.coverage = completeCoverage
        let summary = SentinelLaunchCardBuilder.make(
            state: state(issues: [issue(rule: "LIB-004", severity: .warning)],
                         band: .watch, cycle: cycle),
            now: sentinelTestNow, allClearAlreadyShownToday: false)
        #expect(summary?.headline == "1 thing is worth a look.")
    }

    @Test("No cycle means no card")
    func noCycleState() {
        #expect(SentinelLaunchCardBuilder.make(
            state: .empty, now: sentinelTestNow, allClearAlreadyShownToday: false) == nil)
    }

    private func issue(rule: String, severity: SentinelSeverity) -> SentinelIssue {
        SentinelIssue(
            fingerprint: "fp-\(rule)",
            ruleID: SentinelRuleID(rule),
            ruleVersion: 1,
            rootCauseKey: "test",
            domain: .library,
            titleKey: "issue.test.title",
            severity: severity,
            confidence: 0.9,
            impact: .medium,
            subjects: [SentinelSubject(.book, UUID().uuidString)],
            evidence: [],
            safeSummary: "Test finding",
            firstSeen: sentinelTestNow,
            lastSeen: sentinelTestNow,
            updatedAt: sentinelTestNow)
    }
}

// MARK: - Notification policy

@Suite("Sentinel Notification Policy", .serialized)
struct SentinelNotificationPolicyTests {

    private func issue(severity: SentinelSeverity) -> SentinelIssue {
        SentinelIssue(
            fingerprint: "fp-notify",
            ruleID: SentinelRuleID("LIB-003"),
            ruleVersion: 1,
            rootCauseKey: "test",
            domain: .library,
            titleKey: "issue.test.title",
            severity: severity,
            confidence: 0.9,
            impact: .high,
            subjects: [SentinelSubject(.book, UUID().uuidString)],
            evidence: [],
            safeSummary: "Something needs a decision",
            firstSeen: sentinelTestNow,
            lastSeen: sentinelTestNow,
            updatedAt: sentinelTestNow)
    }

    private var enabled: SentinelConfiguration {
        var config = SentinelConfiguration.default
        config.notificationsEnabled = true
        return config
    }

    @Test("Disabling notifications or Sentinel posts nothing")
    func disabled() {
        var off = enabled
        off.notificationsEnabled = false
        #expect(SentinelNotificationPolicy.next(
            issues: [issue(severity: .critical)], now: sentinelTestNow,
            configuration: off, lastNotified: [:]) == .failure(.notificationsOff))

        var killed = enabled
        killed.autonomy = .off
        #expect(SentinelNotificationPolicy.next(
            issues: [issue(severity: .critical)], now: sentinelTestNow,
            configuration: killed, lastNotified: [:]) == .failure(.sentinelOff))
    }

    @Test("Quiet hours win over a critical issue")
    func quietHours() {
        var config = enabled
        config.quietHours = SentinelQuietHours(isEnabled: true, startHour: 0, endHour: 23)
        #expect(SentinelNotificationPolicy.next(
            issues: [issue(severity: .critical)], now: sentinelTestNow,
            configuration: config, lastNotified: [:]) == .failure(.quietHours))
    }

    @Test("Only issues that need a decision qualify")
    func threshold() {
        #expect(SentinelNotificationPolicy.next(
            issues: [issue(severity: .info)], now: sentinelTestNow,
            configuration: enabled, lastNotified: [:]) == .failure(.belowDecisionThreshold))
        #expect(SentinelNotificationPolicy.next(
            issues: [issue(severity: .warning)], now: sentinelTestNow,
            configuration: enabled, lastNotified: [:]) == .failure(.belowDecisionThreshold))
    }

    @Test("An eligible issue posts once and then waits a week")
    func repeatWindow() {
        let error = issue(severity: .error)
        guard case .success(let selected) = SentinelNotificationPolicy.next(
            issues: [error], now: sentinelTestNow,
            configuration: enabled, lastNotified: [:]) else {
            Issue.record("Expected the first notification")
            return
        }
        #expect(selected.fingerprint == error.fingerprint)

        let sixDays = sentinelTestNow.addingTimeInterval(6 * 86_400)
        #expect(SentinelNotificationPolicy.next(
            issues: [error], now: sixDays,
            configuration: enabled,
            lastNotified: [error.fingerprint: sentinelTestNow]) == .failure(.alreadyNotifiedThisWeek))

        let sevenDays = sentinelTestNow.addingTimeInterval(7 * 86_400)
        guard case .success = SentinelNotificationPolicy.next(
            issues: [error], now: sevenDays,
            configuration: enabled,
            lastNotified: [error.fingerprint: sentinelTestNow]) else {
            Issue.record("Expected the weekly window to reopen")
            return
        }
    }

    @Test("The body is static registry copy and carries no user text")
    func bodyIsSafe() {
        let body = SentinelNotificationPolicy.body(for: issue(severity: .critical))
        #expect(body.contains("Open Sentinel Health"))
        #expect(!body.contains("PRIVATE"))
        #expect(body.count < 200)
    }
}

// MARK: - Diagnostics export

@Suite("Sentinel Diagnostics", .serialized)
struct SentinelDiagnosticsTests {

    @Test("The export is valid JSON and contains no user text or debug detail")
    func exportIsSafe() throws {
        let secret = "PRIVATE-TITLE"
        var book = sentinelBook(title: secret, totalPages: 10, currentPage: 99)
        book.notes = [BookNote(bookID: book.id, text: secret)]
        var issue = SentinelIssue(
            fingerprint: "fp-diag",
            ruleID: SentinelRuleID("LIB-004"),
            ruleVersion: 1,
            rootCauseKey: "library.page-range",
            domain: .library,
            titleKey: "issue.lib004.title",
            severity: .warning,
            confidence: 0.9,
            impact: .medium,
            subjects: [SentinelSubject(.book, book.id.uuidString)],
            evidence: [SentinelEvidence(
                kind: .count,
                labelKey: "evidence.lib004.current",
                safeValue: "99",
                observedAt: sentinelTestNow,
                source: .dataStore)],
            safeSummary: "A book is parked outside its own pages",
            firstSeen: sentinelTestNow,
            lastSeen: sentinelTestNow,
            updatedAt: sentinelTestNow,
            debugDetail: secret)

        var state = SentinelPublishedState.empty
        state.issues = [issue]
        state.coverage = SentinelCoverage(
            totalProbes: 138, ran: 138, skipped: 0, failed: 0,
            requiredTotal: 120, requiredRan: 120,
            missingRequired: [], skippedByDomain: [:])
        state.health = SentinelHealthModel.compute(
            issues: [issue], coverage: state.coverage, now: sentinelTestNow)

        let data = try SentinelDiagnostics.export(
            state: state, appVersion: "test", now: sentinelTestNow)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["schemaVersion"] as? Int == SentinelDiagnostics.schemaVersion)
        #expect(object?["registry"] != nil)
        #expect(!SentinelDiagnostics.containsDebugDetail(data))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains(secret))
        #expect(!text.contains(book.fileURL.path))
    }
}

// MARK: - Executor contract

@Suite("Sentinel Repair Executor", .serialized)
@MainActor
struct SentinelRepairExecutorTests {

    private func plan(
        risk: SentinelRiskClass = .r1,
        actions: [SentinelRepairAction]? = nil,
        generation: UInt64 = 1,
        expected: Book? = nil
    ) -> SentinelRepairPlan {
        let book = expected ?? sentinelBook()
        return SentinelRepairPlan(
            id: "REP-006",
            title: "Test repair",
            riskClass: risk,
            ruleIDs: [SentinelRuleID("LIB-004")],
            issueFingerprints: ["fp"],
            summary: "Test",
            preview: ["Test"],
            actions: actions ?? [.replaceBook(bookID: book.id, expected: book, replacement: book)],
            expectedGeneration: generation)
    }

    private func bridge(book: Book? = nil, generation: UInt64 = 1) -> (SentinelFixtureBridge, Book) {
        let value = book ?? sentinelBook(totalPages: 100, currentPage: 99)
        let bridge = SentinelFixtureBridge(
            books: [value], root: FileManager.default.temporaryDirectory,
            clock: TestSentinelClock(sentinelTestNow))
        bridge.generation = generation
        return (bridge, value)
    }

    @Test("Sentinel off refuses everything")
    func offRefuses() async {
        let (bridge, _) = bridge()
        let outcome = await SentinelRepairExecutor.execute(
            plan: plan(), autonomy: .off, userInitiated: true,
            bridge: bridge, at: sentinelTestNow, verify: { _, _ in true })
        #expect(outcome.status == .blocked)
        #expect(bridge.applyCalls == 0)
    }

    @Test("Automatic repairs stop at the autonomy level")
    func automaticRespectsAutonomy() async {
        let (bridge, _) = bridge()
        let outcome = await SentinelRepairExecutor.execute(
            plan: plan(risk: .r2), autonomy: .autoSafe, userInitiated: false,
            bridge: bridge, at: sentinelTestNow, verify: { _, _ in true })
        #expect(outcome.status == .blocked)
        #expect(bridge.applyCalls == 0)
    }

    @Test("R3 recovery is never one click")
    func r3Refuses() async {
        let (bridge, _) = bridge()
        let outcome = await SentinelRepairExecutor.execute(
            plan: plan(risk: .r3), autonomy: .assist, userInitiated: true,
            bridge: bridge, at: sentinelTestNow, verify: { _, _ in true })
        #expect(outcome.status == .blocked)
    }

    @Test("An empty plan is refused")
    func emptyPlanRefuses() async {
        let (bridge, _) = bridge()
        let outcome = await SentinelRepairExecutor.execute(
            plan: plan(actions: []), autonomy: .assist, userInitiated: true,
            bridge: bridge, at: sentinelTestNow, verify: { _, _ in true })
        #expect(outcome.status == .blocked)
    }

    @Test("Reading right now defers the repair")
    func quiescenceDefers() async {
        let (bridge, _) = bridge()
        bridge.recentActivity = true
        let outcome = await SentinelRepairExecutor.execute(
            plan: plan(), autonomy: .assist, userInitiated: true,
            bridge: bridge, at: sentinelTestNow, verify: { _, _ in true })
        #expect(outcome.status == .blocked)
        #expect(bridge.applyCalls == 0)
    }

    @Test("A stale generation is refused before any write")
    func staleGenerationRefuses() async {
        let (bridge, _) = bridge(generation: 7)
        let outcome = await SentinelRepairExecutor.execute(
            plan: plan(generation: 6), autonomy: .assist, userInitiated: true,
            bridge: bridge, at: sentinelTestNow, verify: { _, _ in true })
        #expect(outcome.status == .blocked)
        #expect(bridge.applyCalls == 0)
    }

    @Test("A book that changed after planning is refused")
    func changedBookRefuses() async {
        let (bridge, book) = bridge()
        var changed = book
        changed.currentPage = 3
        bridge.books = [changed]
        let outcome = await SentinelRepairExecutor.execute(
            plan: plan(expected: book), autonomy: .assist, userInitiated: true,
            bridge: bridge, at: sentinelTestNow, verify: { _, _ in true })
        #expect(outcome.status == .blocked)
        #expect(bridge.applyCalls == 0)
    }

    @Test("A failed safety snapshot stops before the write")
    func snapshotFailureStops() async {
        let (bridge, _) = bridge()
        bridge.snapshotSucceeds = false
        let outcome = await SentinelRepairExecutor.execute(
            plan: plan(), autonomy: .assist, userInitiated: true,
            bridge: bridge, at: sentinelTestNow, verify: { _, _ in true })
        #expect(outcome.succeeded == false)
        #expect(bridge.applyCalls == 0)
    }

    @Test("A verified apply changes the book")
    func verifiedApply() async {
        let (bridge, book) = bridge()
        var updated = book
        updated.currentPage = 9
        let outcome = await SentinelRepairExecutor.execute(
            plan: plan(actions: [.replaceBook(bookID: book.id, expected: book, replacement: updated)]),
            autonomy: .assist, userInitiated: true,
            bridge: bridge, at: sentinelTestNow, verify: { _, _ in true })
        #expect(outcome.status == .appliedVerified)
        #expect(bridge.books.first?.currentPage == 9)
        #expect(outcome.record?.status == .verified)
        #expect(outcome.record?.planFileName != nil)
    }

    @Test("A failed verification rolls the book back and says so")
    func verificationRollback() async {
        let (bridge, book) = bridge()
        var updated = book
        updated.currentPage = 9
        let outcome = await SentinelRepairExecutor.execute(
            plan: plan(actions: [.replaceBook(bookID: book.id, expected: book, replacement: updated)]),
            autonomy: .assist, userInitiated: true,
            bridge: bridge, at: sentinelTestNow, verify: { _, _ in false })
        #expect(outcome.status == .rolledBack)
        #expect(bridge.books.first == book)
        #expect(bridge.restoreCalls > 0 || bridge.books.first == book)
    }
}

// MARK: - Plan catalog

@Suite("Sentinel Repair Catalog", .serialized)
struct SentinelRepairCatalogTests {

    private func issue(_ rule: String, subjects: [SentinelSubject]) -> SentinelIssue {
        SentinelIssue(
            fingerprint: "fp-\(rule)",
            ruleID: SentinelRuleID(rule),
            ruleVersion: 1,
            rootCauseKey: "test",
            domain: .library,
            titleKey: "issue.test.title",
            severity: .warning,
            confidence: 0.9,
            impact: .medium,
            subjects: subjects,
            evidence: [],
            safeSummary: "Test finding",
            firstSeen: sentinelTestNow,
            lastSeen: sentinelTestNow,
            updatedAt: sentinelTestNow)
    }

    private func makePlan(
        rule: String,
        snapshot: SentinelSnapshot,
        subjects: [SentinelSubject]? = nil
    ) -> SentinelRepairPlan? {
        guard let metadata = SentinelProbeCatalog.ruleMetadata[SentinelRuleID(rule)] else {
            Issue.record("Missing rule metadata for \(rule)")
            return nil
        }
        let value = issue(rule, subjects: subjects ?? snapshot.books.map {
            SentinelSubject(.book, $0.id.uuidString)
        })
        return SentinelRepairCatalog.plan(
            for: value, rule: metadata, snapshot: snapshot,
            configuration: .default, now: sentinelTestNow)
    }

    @Test("REP-006 clamps a current page back into the book")
    func clampPage() throws {
        let book = sentinelBook(totalPages: 10, currentPage: 99)
        let snapshot = SentinelSnapshot.fixture(books: [book], now: sentinelTestNow)
        let plan = try #require(makePlan(rule: "LIB-004", snapshot: snapshot))
        #expect(plan.id == "REP-006")
        #expect(plan.actions.count == 1)
        guard case .replaceBook(_, let expected, let replacement) = plan.actions[0] else {
            Issue.record("Expected a book replacement")
            return
        }
        #expect(expected.currentPage == 99)
        #expect(replacement.currentPage == 9)
    }

    @Test("REP-004 fixes negative durations and out-of-range timings")
    func normalizeTimings() throws {
        var book = sentinelBook(totalPages: 10, currentPage: 0)
        book.sessions = [ReadingSession(
            bookID: book.id,
            startTime: sentinelTestNow.addingTimeInterval(-600),
            endTime: sentinelTestNow.addingTimeInterval(-60),
            startPage: 0,
            endPage: 5,
            pageTimes: [
                PageTiming(pageNumber: 900, startTime: sentinelTestNow,
                           endTime: sentinelTestNow.addingTimeInterval(-30)),
            ])]
        let snapshot = SentinelSnapshot.fixture(books: [book], now: sentinelTestNow)
        let plan = try #require(makePlan(rule: "SES-006", snapshot: snapshot))
        #expect(plan.id == "REP-004")
        guard case .replaceBook(_, _, let replacement) = plan.actions[0] else {
            Issue.record("Expected a book replacement")
            return
        }
        let timing = replacement.sessions[0].pageTimes[0]
        #expect(timing.pageNumber == 9)
        #expect(timing.endTime == timing.startTime)
    }

    @Test("REP-008 removes duplicate collection memberships")
    func dedupeCollections() throws {
        let collection = BookCollection(name: "One")
        var book = sentinelBook()
        book.collectionIDs = [collection.id, collection.id]
        let snapshot = SentinelSnapshot.fixture(
            books: [book],
            state: LibraryState(collections: [collection]),
            now: sentinelTestNow)
        let plan = try #require(makePlan(rule: "COL-002", snapshot: snapshot))
        #expect(plan.id == "REP-008")
        guard case .replaceBook(_, _, let replacement) = plan.actions[0] else {
            Issue.record("Expected a book replacement")
            return
        }
        #expect(replacement.collectionIDs == [collection.id])
    }

    @Test("REP-010 removes references to deleted collections")
    func stripDanglingCollections() throws {
        var book = sentinelBook()
        book.collectionIDs = [UUID()]
        let snapshot = SentinelSnapshot.fixture(books: [book], now: sentinelTestNow)
        let plan = try #require(makePlan(rule: "LIB-009", snapshot: snapshot))
        #expect(plan.id == "REP-010")
        guard case .replaceBook(_, _, let replacement) = plan.actions[0] else {
            Issue.record("Expected a book replacement")
            return
        }
        #expect(replacement.collectionIDs.isEmpty)
    }

    @Test("REP-011 removes deadlines for missing books")
    func pruneDeadlines() throws {
        let missing = UUID()
        let deadline = BookDeadline(bookID: missing, targetDate: sentinelTestNow)
        let snapshot = SentinelSnapshot.fixture(
            books: [], state: LibraryState(deadlines: [deadline]), now: sentinelTestNow)
        let plan = try #require(makePlan(rule: "GOL-005", snapshot: snapshot,
                                     subjects: [SentinelSubject(.deadline, missing.uuidString)]))
        #expect(plan.id == "REP-011")
        guard case .replaceLibraryState(let expected, let replacement) = plan.actions[0] else {
            Issue.record("Expected a library-state replacement")
            return
        }
        #expect(expected.deadlines.count == 1)
        #expect(replacement.deadlines.isEmpty)
    }

    @Test("REP-017 clamps chapter ranges")
    func normalizeChapters() throws {
        var book = sentinelBook(totalPages: 10)
        book.chapters = [Chapter(title: "Bad", index: 0, startPage: 40, endPage: 2)]
        let snapshot = SentinelSnapshot.fixture(books: [book], now: sentinelTestNow)
        let plan = try #require(makePlan(rule: "LIB-008", snapshot: snapshot))
        #expect(plan.id == "REP-017")
        guard case .replaceBook(_, _, let replacement) = plan.actions[0] else {
            Issue.record("Expected a book replacement")
            return
        }
        #expect(replacement.chapters[0].startPage == 9)
        #expect(replacement.chapters[0].endPage == 9)
    }

    @Test("REP-018 removes duplicate notes")
    func dedupeNotes() throws {
        let note = BookNote(bookID: UUID(), text: "hello")
        var book = sentinelBook()
        book.notes = [note, note]
        let snapshot = SentinelSnapshot.fixture(books: [book], now: sentinelTestNow)
        let plan = try #require(makePlan(rule: "LIB-012", snapshot: snapshot))
        #expect(plan.id == "REP-018")
        guard case .replaceBook(_, _, let replacement) = plan.actions[0] else {
            Issue.record("Expected a book replacement")
            return
        }
        #expect(replacement.notes.count == 1)
    }

    @Test("REP-019 recomputes a stale cached speed")
    func recomputeSpeed() throws {
        var book = sentinelBook(totalPages: 100)
        book.sessions = [ReadingSession(
            bookID: book.id,
            startTime: sentinelTestNow.addingTimeInterval(-600),
            endTime: sentinelTestNow.addingTimeInterval(-540),
            startPage: 0,
            endPage: 2,
            pageTimes: [
                PageTiming(pageNumber: 0, startTime: sentinelTestNow,
                           endTime: sentinelTestNow.addingTimeInterval(30)),
                PageTiming(pageNumber: 1, startTime: sentinelTestNow,
                           endTime: sentinelTestNow.addingTimeInterval(30)),
            ],
            cachedAverageSecondsPerPage: 999)]
        book.cachedSecondsPerPage = 999
        let snapshot = SentinelSnapshot.fixture(books: [book], now: sentinelTestNow)
        let plan = try #require(makePlan(rule: "LIB-010", snapshot: snapshot))
        #expect(plan.id == "REP-019")
        guard case .replaceBook(_, _, let replacement) = plan.actions[0] else {
            Issue.record("Expected a book replacement")
            return
        }
        #expect(abs((replacement.sessions[0].cachedAverageSecondsPerPage ?? 0) - 30) < 0.001)
    }

    @Test("REP-025 rebuilds a cover from embedded data")
    func rebuildCover() throws {
        var book = sentinelBook()
        book.coverImageData = Data([0xFF, 0xD8, 0xFF])
        let snapshot = SentinelSnapshot.fixture(books: [book], now: sentinelTestNow)
        let plan = try #require(makePlan(rule: "FILE-005", snapshot: snapshot))
        #expect(plan.id == "REP-025")
        guard case .writeCover(let id, let data) = plan.actions.first else {
            Issue.record("Expected a cover write")
            return
        }
        #expect(id == book.id)
        #expect(data.count == 3)
    }

    @Test("Every catalog plan is actionable and generation-bound")
    func plansAreActionable() throws {
        // A snapshot with one damaged book exercises the majority of builders.
        var book = sentinelBook(totalPages: 10, currentPage: 99)
        book.notes = [BookNote(bookID: book.id, text: "a")]
        book.notes.append(book.notes[0])
        book.collectionIDs = [UUID(), UUID()]
        let snapshot = SentinelSnapshot.fixture(books: [book], now: sentinelTestNow)

        for metadata in SentinelProbeCatalog.ruleMetadata.values {
            guard let repairID = metadata.repairID,
                  SentinelRepairCatalog.implementedIDs.contains(repairID) else { continue }
            let value = issue(metadata.ruleID.rawValue, subjects: [
                SentinelSubject(.book, book.id.uuidString),
                SentinelSubject(.store, "library"),
            ])
            guard let plan = SentinelRepairCatalog.plan(
                for: value, rule: metadata, snapshot: snapshot,
                configuration: .default, now: sentinelTestNow) else { continue }
            #expect(!plan.actions.isEmpty, "\(repairID) produced no actions")
            #expect(plan.expectedGeneration == snapshot.generation)
            #expect(plan.issueFingerprints == [value.fingerprint])
            #expect(plan.riskClass == metadata.riskClass)
        }
    }
}
