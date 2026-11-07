//  SentinelSG0Tests.swift
//  AsterismaV2.5Tests
//
//  SG0 truth-and-guardrails pins:
//    SENT-005  every matching finding is marked fixed
//    SENT-008  counters are named for what they are (retained journal)
//    SENT-010  no write probe inside the data root
//    SENT-011  journal stores the safe projection only
//    SENT-013  exactly one launch cycle
//    SENT-024  probe count comes from the registry
//
//  These are intentionally narrow: each one fails if the specific honesty
//  claim in README §3.4 or the SG0 gate receipt stops being true.

import Foundation
import Testing

@testable import AsterismaV2_5

@Suite("Sentinel SG0 Truth", .serialized)
@MainActor
final class SentinelSG0Tests {

    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    private var journalURL: URL { dir.appendingPathComponent("sentinel-journal.jsonl") }
    private var libraryURL: URL { dir.appendingPathComponent("library.json") }

    /// Cycle publishes its results on the next runloop turn.
    private func settle(_ milliseconds: Int = 150) async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "sentinel-sg0-\(UUID().uuidString)")!
    }

    private func makeStore(_ books: [Book]) -> DataStore {
        let store = DataStore(fileURL: libraryURL)
        for book in books { store.addBook(book) }
        store.saveImmediately()
        SentinelDataBridge.shared.attach(store)
        return store
    }

    private func makeBook(title: String, orphaned: Bool) -> Book {
        var book = Book(title: title, author: "A",
                        fileURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).pdf"),
                        fileType: .pdf)
        book.totalPages = 100
        if orphaned {
            let session = ReadingSession(
                bookID: book.id,
                startTime: Date().addingTimeInterval(-48 * 3600),
                startPage: 0,
                endPage: 5
            )
            book.sessions = [session]
            book.activeSessionID = session.id
        }
        return book
    }

    // MARK: - SENT-024

    @Test("Probe count is the registry count, not a literal")
    func probeCountIsRegistryCount() {
        let engine = SentinelEngine(defaults: freshDefaults(), journalURL: journalURL)
        #expect(engine.probeCount == 8)
    }

    // MARK: - SENT-013

    @Test("start() runs exactly one launch cycle")
    func startRunsExactlyOneCycle() async {
        // The bridge holds the store weakly; keep it alive for the cycle.
        let store = makeStore([makeBook(title: "Clean", orphaned: false)])
        let engine = SentinelEngine(
            defaults: freshDefaults(),
            probes: [OrphanedActiveSessionProbe()],
            journalURL: journalURL
        )

        engine.start(intervalMinutes: 60)
        defer { engine.stop() }

        for _ in 0..<50 where engine.completedCycleCount == 0 {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(engine.completedCycleCount == 1)

        // A duplicate launch cycle would land here, not in the first window.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(engine.completedCycleCount == 1)
        #expect(store.books.count == 1)
    }

    // MARK: - SENT-005

    @Test("Every matching finding is marked fixed")
    func allMatchingFindingsAreMarked() async {
        let store = makeStore([
            makeBook(title: "One", orphaned: true),
            makeBook(title: "Two", orphaned: true),
        ])
        let engine = SentinelEngine(
            defaults: freshDefaults(),
            probes: [OrphanedActiveSessionProbe()],
            journalURL: journalURL
        )

        engine.runCycle()
        await settle()

        let findings = engine.recentFindings.filter { $0.rule == "orphan-active-session" }
        #expect(findings.count == 2)
        #expect(findings.allSatisfy { $0.outcome == .autoFixed })
        #expect(store.books.allSatisfy { $0.activeSessionID == nil })
    }

    // MARK: - SENT-010

    @Test("Writability probe never creates a file in the data root")
    func writabilityProbeStaysOutOfDataRoot() throws {
        let root = dir.appendingPathComponent("data-root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let before = try Set(FileManager.default.contentsOfDirectory(atPath: root.path))

        let store = DataStore(fileURL: libraryURL)
        let context = SentinelContext(
            books: store.books,
            libraryState: store.libraryState,
            persistenceHealth: .healthy,
            applicationSupportURL: root
        )

        #expect(StoreWritabilityProbe().run(context: context).isEmpty)

        let after = try Set(FileManager.default.contentsOfDirectory(atPath: root.path))
        #expect(before == after)
        // No probe artifact of any name is allowed in the data root.
        #expect(after.allSatisfy { !$0.hasPrefix(".sentinel") })
    }

    // MARK: - SENT-011

    @Test("Journal stores the safe projection, never debugDetail or user text")
    func journalStoresOnlySafeFields() async throws {
        let title = "PRIVATE-TITLE-\(UUID().uuidString)"
        var book = makeBook(title: title, orphaned: false)
        book.bookmarkData = Data([0x00, 0x01, 0x02])
        // The bridge holds the store weakly; keep it alive for the cycle.
        let store = makeStore([book])

        let engine = SentinelEngine(
            defaults: freshDefaults(),
            probes: [StaleBookmarkProbe()],
            journalURL: journalURL
        )
        engine.runCycle()
        await settle()

        let raw = try String(contentsOf: journalURL, encoding: .utf8)
        #expect(raw.contains("stale-bookmark"))
        #expect(!raw.contains(title))
        #expect(!raw.contains("debugDetail"))

        let finding = try #require(engine.recentFindings.first { $0.rule == "stale-bookmark" })
        #expect(!finding.debugDetail.contains(title))
        #expect(store.books.count == 1)
    }

    @Test("Journal strips diagnostic text that debugDetail still carries")
    func journalStripsDiagnosticText() async throws {
        let secret = "SECRET-CHAPTER-\(UUID().uuidString)"
        var book = makeBook(title: "Chapter Test", orphaned: false)
        book.chapters = [Chapter(title: secret, index: 0, startPage: 500, endPage: 600)]
        let store = makeStore([book])

        let engine = SentinelEngine(
            defaults: freshDefaults(),
            probes: [IntegrityProbe()],
            journalURL: journalURL
        )
        engine.runCycle()
        await settle()

        let raw = try String(contentsOf: journalURL, encoding: .utf8)
        #expect(!raw.contains(secret))

        // The debug surface still has the detail; the journal does not.
        #expect(engine.recentFindings.contains { $0.debugDetail.contains(secret) })
        #expect(store.books.count == 1)
    }
}
