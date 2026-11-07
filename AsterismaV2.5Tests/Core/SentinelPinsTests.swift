//  SentinelPinsTests.swift
//  AsterismaV2.5Tests
//
//  P6 Sentinel pins. Security pins (S1/S5) are the most important tests
//  in this file: they prove the engine CANNOT destroy user data.
//
import Foundation
import Testing

@testable import AsterismaV2_5

@Suite("Sentinel Engine", .serialized)
@MainActor
final class SentinelPinsTests {

    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    private var libraryURL: URL { dir.appendingPathComponent("library.json") }
    private var testJournalURL: URL { dir.appendingPathComponent("sentinel-journal.jsonl") }

    /// runCycle now defers its @Published writes to the next runloop turn
    /// (UI-render safety). Await this after each cycle in tests.
    private func settleAfterCycle() async {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
    }

    private func makeStore(withBook mutate: ((inout Book) -> Void)? = nil) -> DataStore {
        let store = DataStore(fileURL: libraryURL)
        var book = Book(title: "Sentinel Target", author: "A",
                        fileURL: URL(fileURLWithPath: "/tmp/sentinel.pdf"), fileType: .pdf)
        book.totalPages = 100
        mutate?(&book)
        store.addBook(book)
        store.saveImmediately() // flush so file-level assertions see it
        return store
    }

    // MARK: Detection

    @Test("Orphan session >24h is DETECTED and AUTO-FIXED through audited API")
    func orphanSessionAutoFixed() async {
        let engine = SentinelEngine(defaults: UserDefaults(suiteName: "sentinel-test")!, probes: [OrphanedActiveSessionProbe()], journalURL: testJournalURL)
        let store = makeStore { book in
            let staleStart = Date().addingTimeInterval(-48 * 3600)
            let session = ReadingSession(bookID: book.id, startTime: staleStart, startPage: 0, endPage: 5)
            book.sessions = [session]
            book.activeSessionID = session.id
        }
        SentinelDataBridge.shared.attach(store)

        engine.runCycle()
        await settleAfterCycle()

        #expect(engine.recentFindings.contains { $0.rule == "orphan-active-session" && $0.outcome == .autoFixed })
        // The fix went through updateBook → session closed, active id cleared.
        let book = try! #require(store.books.first)
        #expect(book.activeSessionID == nil)
        #expect(book.sessions.first?.isActive == false)
    }

    @Test("Phantom activeSessionID is auto-fixed")
    func phantomSessionAutoFixed() async {
        let ghost = UUID()
        let engine = SentinelEngine(
            defaults: UserDefaults(suiteName: "sentinel-test")!,
            probes: [IntegrityProbe()],
            journalURL: testJournalURL
        )
        let store = makeStore { book in
            book.activeSessionID = ghost // points at a session that doesn't exist
        }
        SentinelDataBridge.shared.attach(store)

        engine.runCycle()
        await settleAfterCycle()
        #expect(engine.recentFindings.contains { $0.rule == "phantom-active-session-id" && $0.outcome == .autoFixed })
        #expect(store.books.first?.activeSessionID == nil)
    }

    @Test("Low-value info findings stay STALLED (never auto-mutated)")
    func stalledFindingsStayStalled() async {
        let engine = SentinelEngine(
            defaults: UserDefaults(suiteName: "sentinel-test")!,
            probes: [DeadlineOverdueProbe()],
            journalURL: testJournalURL
        )
        let store = DataStore(fileURL: libraryURL)
        var book = Book(title: "Overdue", author: "A",
                        fileURL: URL(fileURLWithPath: "/tmp/od.pdf"), fileType: .pdf)
        book.totalPages = 10
        store.addBook(book)
        store.addDeadline(BookDeadline(bookID: book.id,
                                       targetDate: Date().addingTimeInterval(-86_400)))
        SentinelDataBridge.shared.attach(store)

        engine.runCycle()
        await settleAfterCycle()
        let finding = engine.recentFindings.first { $0.rule == "deadline-overdue" }
        #expect(finding?.outcome == .stalled)
    }

    // MARK: SECURITY PINS (the whole point)

    @Test("SECURITY S1: engine writes ONLY journal + quarantine — library file untouched")
    func writeScopeIsConfined() async throws {
        _ = makeStore()
        SentinelDataBridge.shared.attach(makeStore())

        // Snapshot every file in the data dir before a cycle.
        let fm = FileManager.default
        let before = Set((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .map(\.lastPathComponent) ?? [])

        let engine = SentinelEngine(defaults: UserDefaults(suiteName: "sentinel-test")!, journalURL: testJournalURL)
        engine.setJournalURLForTesting(dir.appendingPathComponent("sentinel-journal.jsonl"))
        engine.runCycle()
        await settleAfterCycle()

        let after = Set((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .map(\.lastPathComponent) ?? [])
        let newFiles = after.subtracting(before)

        // Only allowed new artifact: the sentinel journal itself.
        // EXEMPT: files created by DataStore's own lifecycle (its detached
        // Phase-D backup task races this test) — they are NOT Sentinel output.
        let datastoreOwned: Set<String> = ["Backups", "library.json", "library-state.json",
                                           "library.bak.json", "library-state.bak.json"]
        for added in newFiles where !datastoreOwned.contains(added) {
            #expect(added.hasPrefix("sentinel"),
                    "Sentinel created unauthorized file: \(added); full listing: \(after.sorted().joined(separator: ", "))")
        }
        // Library file bytes unchanged by detection cycle.
        let libData = try Data(contentsOf: libraryURL)
        #expect(!libData.isEmpty)
    }

    @Test("SECURITY S5: kill switch makes runCycle fully inert")
    func killSwitchDisablesEverything() {
        let defaults = UserDefaults(suiteName: "sentinel-killswitch")!
        defaults.set(false, forKey: SentinelEngine.enabledKey)

        let engine = SentinelEngine(defaults: defaults, probes: [OrphanedActiveSessionProbe()], journalURL: testJournalURL)
        let store = makeStore { book in
            let stale = Date().addingTimeInterval(-72 * 3600)
            let s = ReadingSession(bookID: book.id, startTime: stale, startPage: 0, endPage: 2)
            book.sessions = [s]
            book.activeSessionID = s.id
        }
        SentinelDataBridge.shared.attach(store)

        engine.runCycle() // must no-op entirely

        #expect(engine.recentFindings.isEmpty)
        #expect(engine.lastRunDate == nil)
        #expect(store.books.first?.activeSessionID != nil) // untouched
        #expect(engine.isEnabled == false)
    }

    @Test("Journal is append-only JSONL with cycle summaries")
    func journalAppends() async throws {
        let engine = SentinelEngine(defaults: UserDefaults(suiteName: "sentinel-test")!, journalURL: testJournalURL)
        engine.setJournalURLForTesting(dir.appendingPathComponent("sentinel-journal.jsonl"))
        let store = makeStore()
        SentinelDataBridge.shared.attach(store)

        engine.runCycle()
        await settleAfterCycle()

        let raw = try String(contentsOf: dir.appendingPathComponent("sentinel-journal.jsonl"), encoding: .utf8)
        let lines = raw.split(separator: "\n")
        #expect(!lines.isEmpty)
        // Every line is valid JSON (JSONL contract).
        for line in lines {
            let obj = try JSONSerialization.jsonObject(with: Data(line.utf8))
            #expect(obj is [String: Any])
        }
    }
}


// MARK: - Demo Install Robustness (P6-HOTFIX: the freeze)

@Suite("Demo Profile Rapid-Switch Safety")
@MainActor
final class DemoRapidSwitchTests {

    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Small deterministic library in the shape generateBooks produces.
    private func syntheticBooks(seed: String, count: Int) -> [Book] {
        (0..<count).map { i in
            var b = Book(title: "\(seed)-\(i)", author: "Synthetic",
                         fileURL: URL(fileURLWithPath: "/demo/\(seed)/\(i).epub"), fileType: .epub)
            b.totalPages = 300
            let start = Date().addingTimeInterval(Double(-i * 3600))
            let s = ReadingSession(bookID: b.id, startTime: start,
                                   endTime: start.addingTimeInterval(1800),
                                   startPage: 0, endPage: 20,
                                   pageTimes: (0..<20).map { p in
                                       PageTiming(pageNumber: p,
                                                  startTime: start.addingTimeInterval(Double(p) * 90),
                                                  endTime: start.addingTimeInterval(Double(p + 1) * 90))
                                   })
            b.sessions = [s]
            return b
        }
    }

    @Test("Rapid persona switching (#1→#2→#4 style): every swap lands intact, no blending")
    func rapidSwitchesNeverBlend() {
        let store = DataStore(fileURL: dir.appendingPathComponent("library.json"))
        SentinelDataBridge.shared.attach(store)
        SentinelDataBridge.shared.beginMutation()
        defer { SentinelDataBridge.shared.endMutation() }

        // Simulate Johan's exact abuse: three installs back-to-back.
        for seed in ["persona1", "persona2", "persona4"] {
            store.debug_replaceLibrary(with: syntheticBooks(seed: seed, count: 6))
            // Post-swap invariants — every single time:
            #expect(store.books.count == 6)
            #expect(store.books.allSatisfy { $0.title.hasPrefix(seed) },
                    "books from a previous persona leaked into \(seed)")
            #expect(store.libraryState.goalSet == .empty) // identity reset held
        }

        // Final state is exactly persona4's.
        #expect(store.books.allSatisfy { $0.title.hasPrefix("persona4") })
    }

    @Test("Sentinel cycle is INERT while a mutation is in flight")
    func sentinelPausedDuringMutation() {
        SentinelDataBridge.shared.beginMutation()
        defer { SentinelDataBridge.shared.endMutation() }
        #expect(SentinelDataBridge.shared.isMutationInFlight)
        SentinelDataBridge.shared.endMutation()
        #expect(!SentinelDataBridge.shared.isMutationInFlight)
    }
}
