//  G1CorrectnessPinsTests.swift
//  Bedrock G1 pins: duplicate achievements, goal merge, write ordering,
//  crash-window clamping, cache day-bucket.

import Foundation
import Testing
@testable import AsterismaV2_5

// MARK: - Achievements

@Suite("G1 · Achievement uniqueness", .serialized)
@MainActor
final class G1AchievementPinsTests {

    private func qualifyingBook() -> Book {
        var book = Book(
            title: "Speed and Endurance",
            author: "A",
            fileURL: URL(fileURLWithPath: "/tmp/g1.pdf"),
            fileType: .pdf
        )
        book.totalPages = 100
        let end = Date()
        let start = end.addingTimeInterval(-10_800) // 3h → Marathon Session
        let timing = PageTiming(
            pageNumber: 1,
            startTime: end.addingTimeInterval(-10),
            endTime: end)
        book.sessions = [
            ReadingSession(
                bookID: book.id,
                startTime: start,
                endTime: end,
                startPage: 0,
                endPage: 10,
                pageTimes: [timing]),
        ]
        return book
    }

    @Test("A loop over many qualifying sessions awards each badge exactly once")
    func loopDoesNotDuplicateBadges() {
        var book = qualifyingBook()
        // Several sessions would each fire the old speed/marathon loop.
        book.sessions = (0..<8).map { index in
            let end = Date().addingTimeInterval(TimeInterval(-index * 60))
            let start = end.addingTimeInterval(-10_800)
            return ReadingSession(
                bookID: book.id,
                startTime: start,
                endTime: end,
                startPage: index,
                endPage: index + 5,
                pageTimes: [PageTiming(
                    pageNumber: index,
                    startTime: end.addingTimeInterval(-10),
                    endTime: end)])
        }

        let (all, newly) = AchievementEngine.detectAll(
            books: [book], goalSet: .empty, existing: [])

        #expect(all.filter { $0.kind == .speedReader }.count == 1)
        #expect(all.filter { $0.kind == .marathonSession }.count == 1)
        #expect(newly.filter { $0.kind == .speedReader }.count == 1)
        #expect(newly.filter { $0.kind == .marathonSession }.count == 1)
    }

    @Test("Legacy duplicate records collapse to the earliest award per kind")
    func dedupeKeepsEarliest() {
        let early = Date().addingTimeInterval(-86_400)
        let late = Date()
        let first = EarnedAchievement(kind: .speedReader, earnedAt: early)
        let second = EarnedAchievement(kind: .speedReader, earnedAt: late)
        let other = EarnedAchievement(kind: .marathonSession, earnedAt: late)

        let result = AchievementEngine.deduplicated([second, first, other])
        #expect(result.removed == 1)
        #expect(result.kept.count == 2)
        #expect(result.kept.contains { $0.id == first.id })
        #expect(!result.kept.contains { $0.id == second.id })
    }
}

// MARK: - Goal merge

@Suite("G1 · Goal merge")
@MainActor
final class G1GoalMergeTests {

    @Test("Setting a daily target preserves annual, weekly, and time goals")
    func dailyTargetMergePreservesOtherFields() {
        var original = ReadingGoalSet.empty
        original.annualBookTarget = 24
        original.weeklyReadingDays = 5
        original.dailyTimeTarget = 2700

        let merged = original.withDailyPageTarget(30)

        #expect(merged.dailyPageTarget == 30)
        #expect(merged.annualBookTarget == 24)
        #expect(merged.weeklyReadingDays == 5)
        #expect(merged.dailyTimeTarget == 2700)
    }
}

// MARK: - Persistence writer ordering

@Suite("G1 · Persistence writer ordering", .serialized)
@MainActor
final class G1PersistenceWriterPinsTests {

    @Test("A slow older write cannot be overtaken by a newer write")
    func fifoThroughTheDiskWrite() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("order.txt")

        let writer = PersistenceWriter(label: "g1-writer-order")
        let first = writer.enqueue(
            encode: {
                Thread.sleep(forTimeInterval: 0.20)
                return Data("older".utf8)
            },
            write: { try $0.write(to: url, options: .atomic) })
        let second = writer.enqueue(
            encode: { Data("newer".utf8) },
            write: { try $0.write(to: url, options: .atomic) })

        _ = await first.value
        _ = await second.value

        let final = try String(contentsOf: url, encoding: .utf8)
        #expect(final == "newer", "older write landed last: \(final)")
    }
}

// MARK: - Crash-window clamping

@Suite("G1 · Crash-window duration")
@MainActor
final class G1CrashWindowPinsTests {

    @Test("An orphan session closes at last activity, not at now")
    func orphanSessionDoesNotInflateReadingTime() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DataStore(fileURL: dir.appendingPathComponent("library.json"))

        let now = Date()
        let sessionStart = now.addingTimeInterval(-10_800) // 3h ago
        let lastActivity = now.addingTimeInterval(-7_200) // 2h ago
        let sessionID = UUID()
        var book = Book(
            title: "Crash Survivor",
            author: "A",
            fileURL: URL(fileURLWithPath: "/tmp/crash.pdf"),
            fileType: .pdf)
        book.totalPages = 100
        book.sessions = [
            ReadingSession(
                id: sessionID,
                bookID: book.id,
                startTime: sessionStart,
                startPage: 0,
                endPage: 10,
                pageTimes: [PageTiming(
                    pageNumber: 1,
                    startTime: lastActivity.addingTimeInterval(-10),
                    endTime: lastActivity)]),
        ]
        book.activeSessionID = sessionID
        store.addBook(book)

        // This is the launch/startSession recovery path.
        store.startSession(bookID: book.id, onPage: 10)

        let recovered = try #require(store.book(id: book.id)?.sessions.first { $0.id == sessionID })
        let duration = try #require(recovered.endTime).timeIntervalSince(recovered.startTime)
        // 3h session, last real activity 2h ago → ~1h + 5m grace, never 3h.
        #expect(duration < 2 * 3600,
                "crash gap was counted as reading time: \(duration)s")
        #expect(duration > 3_000)
    }
}

// MARK: - Cache midnight bucket

@Suite("G1 · Analytics cache day boundary")
@MainActor
final class G1AnalyticsCachePinsTests {

    @Test("Signature carries a day bucket so midnight invalidates cached values")
    func signatureHasDayBucket() {
        let sig = AnalyticsCache.Signature.signature(for: [], epoch: 1)
        #expect(sig.dayBucket > 0)
    }
}
