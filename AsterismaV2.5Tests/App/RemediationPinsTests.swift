//  RemediationPinsTests.swift
//  AsterismaV2.5Tests
//
//  RA-002 remediation pins (REMEDIATION_ROADMAP.md Phases 1–2).
//  Every test names the roadmap item it pins, mirroring ReliabilityTests'
//  defect-class convention.
//
//    GoalPersistenceTests   → 1.2b — goals/deadlines persist via Settings APIs
//    GoalStreakTests        → 1.2c / F-08 — weekGoalStreak detection contract
//    RebindIdempotenceTests → 1.2b companion + 2.3 / F-12 — $libraryState
//                             propagation and bind(to:) idempotence
//
import Foundation
import Testing

@testable import AsterismaV2_5

// MARK: - Goal Persistence (roadmap 1.2b — NA-2)

@Suite("Goal & Deadline Persistence")
@MainActor
final class GoalPersistenceTests {

    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    private var libraryURL: URL { dir.appendingPathComponent("library.json") }
    private var stateURL: URL { dir.appendingPathComponent("library-state.json") }

    private func rawStateFile() -> String {
        (try? String(contentsOf: stateURL, encoding: .utf8)) ?? "<no file>"
    }

    @Test("Goals set via updateGoalSet survive a fresh store reload")
    func goalsRoundTripAcrossRelaunch() throws {
        let url = libraryURL
        let store = DataStore(fileURL: url)

        var set = ReadingGoalSet.empty
        set.dailyPageTarget = 25
        set.dailyTimeTarget = 2700.0 // 45 minutes, literal Double
        set.annualBookTarget = 20
        set.weeklyReadingDays = 5
        store.updateGoalSet(set)
        store.saveImmediately()

        // Pre-fix this failed at the RELOAD step: updateGoalSet had no callers,
        // and nothing proved the state file round-trips a non-empty goal set.
        let reopened = DataStore(fileURL: url)
        let raw = rawStateFile()

        // Typed intermediates: no cross-type comparison inside the macro, and
        // full-precision + bit-pattern diagnostics if this ever fails again.
        let reloadedPages: Int? = reopened.libraryState.goalSet.dailyPageTarget
        let reloadedTime: TimeInterval? = reopened.libraryState.goalSet.dailyTimeTarget
        let reloadedAnnual: Int? = reopened.libraryState.goalSet.annualBookTarget
        let reloadedWeekly: Int? = reopened.libraryState.goalSet.weeklyReadingDays

        var timeDetail = "nil"
        if let t = reloadedTime {
            timeDetail = String(format: "%.17f", t) + " bits=0x" + String(t.bitPattern, radix: 16)
        }

        #expect(reloadedPages == 25, "raw=\(raw)")
        #expect(reloadedTime == TimeInterval(2700), "time=\(timeDetail) raw=\(raw)")
        #expect(reloadedAnnual == 20, "raw=\(raw)")
        #expect(reloadedWeekly == 5, "raw=\(raw)")
    }

    @Test("Deadlines replace per book and remove cleanly across reload")
    func deadlinesRoundTripAndReplace() {
        let url = libraryURL
        let store = DataStore(fileURL: url)

        var book = Book(title: "Deadline Target", author: "A",
                        fileURL: URL(fileURLWithPath: "/tmp/dt.pdf"), fileType: .pdf)
        book.totalPages = 300
        store.addBook(book)

        let target = Date().addingTimeInterval(14 * 86_400)
        store.addDeadline(BookDeadline(bookID: book.id, targetDate: target))
        store.addDeadline(BookDeadline(bookID: book.id, targetDate: target)) // replaces, never duplicates
        store.saveImmediately()

        let reopened = DataStore(fileURL: url)
        #expect(reopened.libraryState.deadlines.count == 1)
        #expect(reopened.libraryState.deadlines.first?.bookID == book.id)

        reopened.removeDeadline(bookID: book.id)
        reopened.saveImmediately()

        let final = DataStore(fileURL: url)
        #expect(final.libraryState.deadlines.isEmpty)
    }

    @Test("Emptying all goals persists as an empty set (Clear All path)")
    func clearingGoalsPersists() {
        let url = libraryURL
        let store = DataStore(fileURL: url)

        var set = ReadingGoalSet.empty
        set.dailyPageTarget = 10
        store.updateGoalSet(set)
        store.updateGoalSet(.empty)
        store.saveImmediately()

        let reopened = DataStore(fileURL: url)
        #expect(reopened.libraryState.goalSet.dailyPageTarget == nil)
    }
}

// MARK: - weekGoalStreak detection (roadmap 1.2c — F-08)

@Suite("weekGoalStreak Detection")
struct GoalStreakTests {

    /// One closed session of `pages` pages on the calendar day `offset` days before today.
    private func sessionOn(dayOffset: Int, pages: Int, bookID: UUID) -> ReadingSession {
        var start = Calendar.current.startOfDay(for: Date())
        start = Calendar.current.date(byAdding: .day, value: dayOffset, to: start)!
            .addingTimeInterval(12 * 3_600) // noon local — stable inside its own day
        return ReadingSession(
            bookID: bookID,
            startTime: start,
            endTime: start.addingTimeInterval(3_600),
            startPage: 0,
            endPage: pages
        )
    }

    private func book(with sessions: [ReadingSession]) -> Book {
        var b = Book(title: "Streak", author: "A",
                     fileURL: URL(fileURLWithPath: "/tmp/streak.pdf"), fileType: .pdf)
        b.totalPages = 400
        b.sessions = sessions
        return b
    }

    private func goalSet(dailyPages target: Int) -> ReadingGoalSet {
        var s = ReadingGoalSet.empty
        s.dailyPageTarget = target
        return s
    }

    @Test("F-08: seven consecutive qualifying days earn weekGoalStreak exactly once")
    func sevenConsecutiveQualifyingDaysEarn() {
        let id = UUID()
        // Offsets −7…−1: seven distinct calendar days, 30 pages each, target 20.
        let sessions = (-7 ... -1).map { sessionOn(dayOffset: $0, pages: 30, bookID: id) }
        let books = [book(with: sessions)]

        #expect(AchievementEngine.hasSevenConsecutiveGoalDays(books: books, goalSet: goalSet(dailyPages: 20)))

        let (allEarned, newly) = AchievementEngine.detectAll(
            books: books, goalSet: goalSet(dailyPages: 20), existing: []
        )
        #expect(allEarned.contains { $0.kind == .weekGoalStreak })
        #expect(newly.filter { $0.kind == .weekGoalStreak }.count == 1)

        // Idempotency: passing the earned set back yields no duplicate award.
        let (_, secondNewly) = AchievementEngine.detectAll(
            books: books, goalSet: goalSet(dailyPages: 20), existing: allEarned
        )
        #expect(!secondNewly.contains { $0.kind == .weekGoalStreak })
    }

    @Test("F-08: interleaved misses break the run — no award")
    func interleavedMissesDoNotEarn() {
        let id = UUID()
        // Eight qualifying days but NO two adjacent (gaps between every one).
        let offsets = [-15, -13, -11, -9, -7, -5, -3, -1]
        let sessions = offsets.map { sessionOn(dayOffset: $0, pages: 30, bookID: id) }
        let books = [book(with: sessions)]

        #expect(!AchievementEngine.hasSevenConsecutiveGoalDays(books: books, goalSet: goalSet(dailyPages: 20)))

        let (_, newly) = AchievementEngine.detectAll(
            books: books, goalSet: goalSet(dailyPages: 20), existing: []
        )
        #expect(!newly.contains { $0.kind == .weekGoalStreak })
    }

    @Test("F-08: no daily page target set — structurally unearnable (pre-editor reality)")
    func unsetTargetNeverEarns() {
        let id = UUID()
        let sessions = (-7 ... -1).map { sessionOn(dayOffset: $0, pages: 300, bookID: id) }
        #expect(!AchievementEngine.hasSevenConsecutiveGoalDays(books: [book(with: sessions)],
                                                              goalSet: ReadingGoalSet.empty))
    }

    @Test("F-08: six consecutive qualifying days fall one short")
    func sixDaysFallShort() {
        let id = UUID()
        let sessions = (-6 ... -1).map { sessionOn(dayOffset: $0, pages: 30, bookID: id) }
        #expect(!AchievementEngine.hasSevenConsecutiveGoalDays(books: [book(with: sessions)],
                                                              goalSet: goalSet(dailyPages: 20)))
    }
}

// MARK: - ViewModel rebind + libraryState propagation (roadmap 1.2b + 2.3 — F-12)

@Suite("ViewModel Rebind Idempotence")
@MainActor
final class RebindIdempotenceTests {

    /// Combine sinks bound with `.receive(on: RunLoop.main)` deliver on a later
    /// main-loop turn; this mirrors ReliabilityTests' poll pattern instead of
    /// asserting synchronously.
    private func waitFor(
        _ condition: () -> Bool,
        maxMilliseconds: Int = 2000,
        stepMilliseconds: Int = 25
    ) async throws -> Bool {
        for _ in 0 ..< (maxMilliseconds / stepMilliseconds) {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(stepMilliseconds))
        }
        return condition()
    }

    @Test("F-12/1.2b: repeated binds stay consistent; saved goals propagate without manual re-bind")
    func repeatedBindsAndLiveGoalPropagation() async throws {
        let store = DataStore(fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString + ".json"))

        var book = Book(title: "Rebind", author: "A",
                        fileURL: URL(fileURLWithPath: "/tmp/rb.pdf"), fileType: .pdf)
        book.totalPages = 100
        store.addBook(book)

        let vm = GoalProgressViewModel()
        vm.bind(to: store, goalSet: ReadingGoalSet.empty, deadlines: [])
        vm.bind(to: store, goalSet: ReadingGoalSet.empty, deadlines: []) // window close/reopen re-runs root .task
        vm.bind(to: store, goalSet: ReadingGoalSet.empty, deadlines: [])

        // Pre-F-12 each re-bind stacked sinks. With the fix, one live chain
        // reflects exactly the empty-set truth.
        let emptySettled = try await self.waitFor { vm.statuses.isEmpty }
        #expect(emptySettled)

        // The 1.2b companion change ($libraryState observation): saving a goal
        // through the Settings API must reach this VM without any manual re-bind.
        var set = ReadingGoalSet.empty
        set.dailyPageTarget = 5
        store.updateGoalSet(set)

        let propagated = try await self.waitFor {
            vm.statuses.count == 1 && vm.statuses.first?.goal == .dailyPages
        }
        #expect(propagated, "saved goal did not propagate to GoalProgressViewModel via $libraryState observation")
    }
}
