//  SQLiteFoundationTests.swift
//  Bedrock G3A pins: GRDB schema + JSON→SQLite parity.

import Foundation
import Testing
@testable import AsterismaV2_5

private func sqliteEnv(_ key: String) -> String? {
    let env = ProcessInfo.processInfo.environment
    return env[key] ?? env["TEST_RUNNER_\(key)"]
}

@Suite("Bedrock SQLite foundation", .serialized)
@MainActor
final class SQLiteFoundationTests {

    private func tempDB() throws -> (LibraryDatabase, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("library.sqlite3")
        return (try LibraryDatabase(url: url), dir)
    }

    @Test("Synthetic books, sessions, timings, notes, collections survive a round trip")
    func syntheticRoundTrip() throws {
        let (db, dir) = try tempDB()
        defer {
            try? db.close()
            try? FileManager.default.removeItem(at: dir)
        }

        let bookID = UUID()
        let collectionID = UUID()
        var book = Book(
            id: bookID,
            title: "SQLite Book",
            author: "A",
            fileURL: URL(fileURLWithPath: "/tmp/sqlite.pdf"),
            fileType: .pdf,
            totalPages: 200,
            currentPage: 20,
            genre: .science,
            series: "Test Series",
            isFavorite: true,
            collectionIDs: [collectionID])
        let sessionID = UUID()
        let start = Date().addingTimeInterval(-3600)
        let end = Date()
        book.sessions = [
            ReadingSession(
                id: sessionID,
                bookID: bookID,
                startTime: start,
                endTime: end,
                startPage: 1,
                endPage: 20,
                pageTimes: [
                    PageTiming(pageNumber: 1, startTime: start, endTime: start.addingTimeInterval(10)),
                    PageTiming(pageNumber: 2, startTime: start.addingTimeInterval(10), endTime: end),
                ])
        ]
        book.notes = [
            BookNote(bookID: bookID, pageNumber: 12, text: "A note", tag: .idea)
        ]

        var state = LibraryState()
        state.collections = [
            BookCollection(id: collectionID, name: "Test Shelf")
        ]
        state.earnedAchievements = [
            EarnedAchievement(kind: .firstBook, relatedBookID: bookID)
        ]
        var goals = ReadingGoalSet.empty
        goals.dailyPageTarget = 20
        state.goalSet = goals

        try db.importLibrary(books: [book], state: state)

        let counts = try db.counts()
        #expect(counts.books == 1)
        #expect(counts.sessions == 1)
        #expect(counts.pageTimes == 2)

        let loaded = try #require(try db.loadBooks().first)
        #expect(loaded.id == book.id)
        #expect(loaded.title == "SQLite Book")
        #expect(loaded.sessions.count == 1)
        // G3B: summary loads intentionally omit per-page rows.
        #expect(loaded.sessions.first?.pageTimes.isEmpty == true)
        let timings = try db.pageTimings(forSessionID: sessionID)
        #expect(timings.count == 2)
        #expect(loaded.notes.count == 1)
        #expect(loaded.collectionIDs == [collectionID])

        let loadedState = try db.loadState()
        #expect(loadedState.goalSet.dailyPageTarget == 20)
        #expect(loadedState.collections.first?.name == "Test Shelf")
        #expect(loadedState.earnedAchievements.count == 1)
    }

    @Test(
        "Real-library JSON→SQLite parity (opt-in copy)",
        .enabled(if: sqliteEnv("RT_BENCH_LIBRARY") != nil)
    )
    func realLibraryParity() throws {
        let libraryPath = try #require(sqliteEnv("RT_BENCH_LIBRARY"))
        let source = DataStore(fileURL: URL(fileURLWithPath: libraryPath))
        let (db, dir) = try tempDB()
        defer {
            try? db.close()
            try? FileManager.default.removeItem(at: dir)
        }

        try db.importLibrary(books: source.books, state: source.libraryState)

        let counts = try db.counts()
        let expectedSessions = source.books.reduce(0) { $0 + $1.sessions.count }
        let expectedPageTimes = source.books.reduce(0) { partial, book in
            partial + book.sessions.reduce(0) { $0 + $1.pageTimes.count }
        }
        #expect(counts.books == source.books.count)
        #expect(counts.sessions == expectedSessions)
        #expect(counts.pageTimes == expectedPageTimes)

        let loaded = try db.loadBooks()
        #expect(loaded.count == source.books.count)
        let loadedIDs = loaded.map { $0.id.uuidString }.sorted()
        let sourceIDs = source.books.map { $0.id.uuidString }.sorted()
        #expect(loadedIDs == sourceIDs)
        let loadedSessions = loaded.reduce(0) { $0 + $1.sessions.count }
        #expect(loadedSessions == expectedSessions)

        let state = try db.loadState()
        #expect(state.collections.count == source.libraryState.collections.count)
        #expect(state.earnedAchievements.count == source.libraryState.earnedAchievements.count)
    }
}
