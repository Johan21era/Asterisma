//  SentinelTestSupport.swift
//  AsterismaV2.5Tests
//
//  Shared fixtures for the v2 runtime. The bridge is a real in-memory store:
//  repairs mutate it, verification re-reads it, undo restores it. That means
//  the tests exercise the same plan → apply → verify → undo path as the app,
//  not a mock that always says yes.

import Foundation
import Testing

@testable import AsterismaV2_5

let sentinelTestNow = Date(timeIntervalSince1970: 1_767_225_600)

struct SentinelTempRoot {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sentinel-v2-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Bridge

@MainActor
final class SentinelFixtureBridge: SentinelRepairBridge {
    var books: [Book]
    var state: LibraryState
    var generation: UInt64
    var root: URL
    var clock: TestSentinelClock

    var snapshotSucceeds = true
    var recentActivity = false
    /// When true, writes report success but do not change the data. This is how
    /// the verification-failure rollback is exercised.
    var ignoresChanges = false

    private(set) var snapshotCalls = 0
    private(set) var applyCalls = 0
    private(set) var restoreCalls = 0
    private var quarantined: [String: URL] = [:]

    init(books: [Book], state: LibraryState = LibraryState(),
         generation: UInt64 = 1, root: URL, clock: TestSentinelClock) {
        self.books = books
        self.state = state
        self.generation = generation
        self.root = root
        self.clock = clock
    }

    func makeSnapshot(facts: SentinelJournalFacts = .empty) -> SentinelSnapshot {
        SentinelSnapshot.fixture(
            books: books,
            state: state,
            dataRoot: root,
            generation: generation,
            now: clock.now,
            journalFacts: facts,
            isDebug: true)
    }

    func safetySnapshot() async -> Bool {
        snapshotCalls += 1
        return snapshotSucceeds
    }

    func currentGeneration() async -> UInt64 { generation }

    func currentBook(id: UUID) async -> Book? {
        books.first { $0.id == id }
    }

    func currentLibraryState() async -> LibraryState? { state }

    func replaceBook(previous: Book, updated: Book) async -> Bool {
        applyCalls += 1
        guard let index = books.firstIndex(where: { $0.id == updated.id }) else { return false }
        guard books[index] == previous else { return false }
        if ignoresChanges { return true }
        books[index] = updated
        generation += 1
        return true
    }

    func replaceLibraryState(previous: LibraryState, updated: LibraryState) async -> Bool {
        applyCalls += 1
        guard SentinelRepairEquality.equal(state, previous) else { return false }
        if ignoresChanges { return true }
        state = updated
        generation += 1
        return true
    }

    func quarantineFile(at url: URL, name: String) async -> Bool {
        applyCalls += 1
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        if ignoresChanges { return true }
        quarantined[name] = url
        try? FileManager.default.removeItem(at: url)
        return true
    }

    func restoreQuarantinedFile(named name: String, to url: URL) async -> Bool {
        restoreCalls += 1
        guard let source = quarantined.removeValue(forKey: name) else { return false }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.moveItem(at: source, to: url)
        return true
    }

    func trimJournal(maxBytes: Int64) async -> Bool { true }
    func trimDebugJournal(maxBytes: Int64) async -> Bool { true }
    func rebuildIssueStore() async -> Bool { true }
    func checkpointDatabase() async -> Bool { true }
    func writeCover(bookID: UUID, data: Data) async -> Bool { true }
    func removeCover(bookID: UUID) async -> Bool { true }
    func resetNotificationState() async -> Bool { true }
    func hasRecentReadingActivity(within interval: TimeInterval) async -> Bool { recentActivity }
}

// MARK: - Harness

@MainActor
struct SentinelRuntimeHarness {
    let runtime: SentinelRuntime
    let bridge: SentinelFixtureBridge
    let root: SentinelTempRoot
    let clock: TestSentinelClock

    static func make(
        probes: [any SentinelProbeV2],
        autonomy: SentinelAutonomy = .observe,
        books: [Book] = [],
        state: LibraryState = LibraryState(),
        root: SentinelTempRoot = SentinelTempRoot(),
        bridgeOverride: SentinelFixtureBridge? = nil,
        providerOverride: SentinelSnapshotProvider? = nil
    ) async -> SentinelRuntimeHarness {
        let clock = TestSentinelClock(sentinelTestNow)
        let environment = SentinelEnvironment.test(
            clock: clock,
            dataRoot: root.url,
            backupRoot: root.url.appendingPathComponent("Backups", isDirectory: true),
            tempRoot: root.url.appendingPathComponent("tmp", isDirectory: true),
            isDebug: true,
            capacity: 50_000_000_000)

        var configuration = SentinelConfiguration.default
        configuration.autonomy = autonomy
        configuration.cadenceMinutes = 60

        let runtime = SentinelRuntime(
            environment: environment,
            configuration: configuration,
            probes: probes)
        await runtime.open(dataRoot: root.url)

        let bridge = bridgeOverride ?? SentinelFixtureBridge(
            books: books, state: state, root: root.url, clock: clock)

        let provider = providerOverride ?? SentinelSnapshotProvider { facts in
            await MainActor.run {
                bridge.makeSnapshot(facts: facts)
            }
        }
        await runtime.setSnapshotProvider(provider)
        await runtime.setBridge(bridge)
        return SentinelRuntimeHarness(runtime: runtime, bridge: bridge, root: root, clock: clock)
    }
}

// MARK: - Probes

/// Emits a finding every cycle unless turned off.
nonisolated final class SentinelToggleProbe: SentinelProbeV2, @unchecked Sendable {
    let descriptor: SentinelProbeDescriptor
    private let lock = NSLock()
    private var emit = true
    private(set) var runCount = 0

    init(rule: String = "TST-001", severity: SentinelSeverity = .warning,
         required: Bool = true) {
        descriptor = SentinelProbeDescriptor(
            id: rule, domain: .library,
            title: "Test condition",
            what: "A deterministic fixture condition.",
            rootCauseKey: "test.condition", tier: .t1, isRequired: required,
            defaultSeverity: severity, defaultImpact: .low)
    }

    func setEmit(_ value: Bool) {
        lock.lock()
        emit = value
        lock.unlock()
    }

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        lock.lock()
        runCount += 1
        let shouldEmit = emit
        lock.unlock()
        guard shouldEmit else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.store, "fixture")],
            evidence: [SentinelProbeSupport.count("evidence.test", 1, at: environment.now)])]
    }
}

nonisolated struct SentinelFailingProbe: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "TST-002", domain: .library,
        title: "Failing fixture",
        what: "Always throws.",
        rootCauseKey: "test.failure", tier: .t1,
        defaultSeverity: .warning, defaultImpact: .low)

    struct Boom: Error {}

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        throw Boom()
    }
}

nonisolated struct SentinelUnavailableProbe: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "TST-003", domain: .database,
        title: "Unavailable fixture",
        what: "Requires a source that is absent.",
        rootCauseKey: "test.unavailable", tier: .t2,
        defaultSeverity: .warning, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        throw SentinelProbeUnavailable(.databaseNotInitialized)
    }
}

nonisolated struct SentinelSlowProbe: SentinelProbeV2 {
    let descriptor: SentinelProbeDescriptor

    init(timeout: TimeInterval = 0.1) {
        descriptor = SentinelProbeDescriptor(
            id: "TST-004", domain: .library,
            title: "Slow fixture",
            what: "Sleeps past its budget.",
            rootCauseKey: "test.slow", tier: .t1,
            timeout: timeout,
            defaultSeverity: .warning, defaultImpact: .low)
    }

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        try await Task.sleep(for: .seconds(2))
        return []
    }
}

// MARK: - Fixtures

func sentinelBook(
    title: String = "Fixture",
    totalPages: Int = 100,
    currentPage: Int = 0,
    sessions: [ReadingSession] = [],
    activeSessionID: UUID? = nil,
    root: URL? = nil
) -> Book {
    var book = Book(
        title: title,
        author: "Author",
        fileURL: (root ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("\(UUID().uuidString).pdf"),
        fileType: .pdf,
        totalPages: totalPages,
        currentPage: currentPage,
        sessions: sessions,
        activeSessionID: activeSessionID)
    book.chapters = [Chapter(title: "One", index: 0, startPage: 0, endPage: max(0, totalPages - 1))]
    return book
}

func sentinelOrphanBook(now: Date = sentinelTestNow) -> Book {
    let bookID = UUID()
    let session = ReadingSession(
        bookID: bookID,
        startTime: now.addingTimeInterval(-48 * 3600),
        startPage: 0,
        endPage: 5)
    var book = sentinelBook(sessions: [session], activeSessionID: session.id)
    book.id = bookID
    return book
}
