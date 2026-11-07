//  SQLiteDataStoreTests.swift
//  G3B pins: SQLite storage mode, summary loads, incremental page timings.

import Foundation
import Testing
@testable import AsterismaV2_5

@Suite("G3B · SQLite DataStore", .serialized)
@MainActor
final class SQLiteDataStoreTests {

    private func tempPaths() throws -> (json: URL, db: URL, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir.appendingPathComponent("library.json"),
                dir.appendingPathComponent("library.sqlite3"), dir)
    }

    @Test("Books, sessions, state and summaries survive a SQLite reopen")
    func sqliteRoundTrip() throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.dir) }

        let store = DataStore(
            fileURL: paths.json,
            storageEngine: .sqlite,
            databaseURL: paths.db)
        let bookID = UUID()
        let start = Date().addingTimeInterval(-3600)
        let end = Date()
        var book = Book(
            id: bookID,
            title: "SQLite DataStore",
            author: "A",
            fileURL: URL(fileURLWithPath: "/tmp/sdb.pdf"),
            fileType: .pdf,
            totalPages: 200)
        book.sessions = [
            ReadingSession(
                bookID: bookID,
                startTime: start,
                endTime: end,
                startPage: 0,
                endPage: 20,
                pageTimes: [
                    PageTiming(pageNumber: 1, startTime: start, endTime: start.addingTimeInterval(10)),
                    PageTiming(pageNumber: 2, startTime: start.addingTimeInterval(10), endTime: end),
                ])
        ]
        store.addBook(book)
        var goals = ReadingGoalSet.empty
        goals.dailyPageTarget = 30
        store.updateGoalSet(goals)
        let collection = store.addCollection(name: "Shelf")
        store.setBook(bookID, membershipIn: collection.id, isMember: true)
        store.saveImmediately()

        let db = try LibraryDatabase(url: paths.db)
        defer { try? db.close() }
        let counts = try db.counts()
        #expect(counts.books == 1)
        #expect(counts.sessions == 1)
        #expect(counts.pageTimes == 2)

        let reopened = DataStore(
            fileURL: paths.json,
            storageEngine: .sqlite,
            databaseURL: paths.db)
        let loaded = try #require(reopened.books.first)
        #expect(loaded.title == "SQLite DataStore")
        #expect(loaded.sessions.count == 1)
        // Summary load: sessions are present, per-page rows are lazy.
        #expect(loaded.sessions[0].pageTimes.isEmpty)
        #expect((loaded.sessions[0].cachedAverageSecondsPerPage ?? 0) > 0)
        #expect((loaded.cachedSecondsPerPage ?? 0) > 0)
        #expect(reopened.libraryState.goalSet.dailyPageTarget == 30)
        #expect(reopened.libraryState.collections.first?.name == "Shelf")
        #expect(loaded.collectionIDs == [collection.id])

        let sessionID = try #require(loaded.sessions.first?.id)
        let timings = try db.pageTimings(forSessionID: sessionID)
        #expect(timings.count == 2)
        #expect(timings.allSatisfy { $0.endTime != nil })
    }

    @Test(
        "Real-library JSON→SQLite DataStore parity (opt-in copy)",
        .enabled(if: ProcessInfo.processInfo.environment["RT_BENCH_LIBRARY"] != nil
            || ProcessInfo.processInfo.environment["TEST_RUNNER_RT_BENCH_LIBRARY"] != nil)
    )
    func realLibraryDataStoreParity() throws {
        let env = ProcessInfo.processInfo.environment
        let path = try #require(env["RT_BENCH_LIBRARY"] ?? env["TEST_RUNNER_RT_BENCH_LIBRARY"])
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.dir) }

        let jsonStore = DataStore(fileURL: URL(fileURLWithPath: path))
        let importDB = try LibraryDatabase(url: paths.db)
        try importDB.importLibrary(books: jsonStore.books, state: jsonStore.libraryState)
        try importDB.close()

        let loadStart = CFAbsoluteTimeGetCurrent()
        let sqliteStore = DataStore(
            fileURL: paths.json,
            storageEngine: .sqlite,
            databaseURL: paths.db)
        let loadMS = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000
        print("G3B_SQLITE_LOAD_MS \(loadMS)")

        #expect(sqliteStore.books.count == jsonStore.books.count)
        #expect(sqliteStore.books.reduce(0) { $0 + $1.sessions.count }
            == jsonStore.books.reduce(0) { $0 + $1.sessions.count })

        let jsonProfile = AnalyticsEngine.readerProfile(books: jsonStore.books)
        let sqliteProfile = AnalyticsEngine.readerProfile(books: sqliteStore.books)
        #expect(jsonProfile.totalPagesRead == sqliteProfile.totalPagesRead)
        #expect(abs(jsonProfile.totalReadingTime - sqliteProfile.totalReadingTime) < 0.01)

        let jsonStreak = AnalyticsEngine.streak(books: jsonStore.books)
        let sqliteStreak = AnalyticsEngine.streak(books: sqliteStore.books)
        #expect(jsonStreak.currentStreak == sqliteStreak.currentStreak)
        #expect(jsonStreak.longestStreak == sqliteStreak.longestStreak)

        for j in jsonStore.books {
            guard let s = sqliteStore.books.first(where: { $0.id == j.id }) else {
                #expect(Bool(false), "SQLite store missing \(j.title)")
                continue
            }
            let jSpeed = AnalyticsEngine.readingSpeed(for: j)
            let sSpeed = AnalyticsEngine.readingSpeed(for: s)
            #expect(abs(jSpeed - sSpeed) < 0.01,
                    "\(j.title): JSON \(jSpeed) vs SQLite \(sSpeed)")
            #expect(s.sessions.allSatisfy { $0.pageTimes.isEmpty })
        }

        let db = try LibraryDatabase(url: paths.db)
        defer { try? db.close() }
        let counts = try db.counts()
        #expect(counts.books == jsonStore.books.count)
        #expect(counts.sessions == jsonStore.books.reduce(0) { $0 + $1.sessions.count })
        #expect(counts.pageTimes > 0)
    }

    @Test("Archive export from SQLite rehydrates full page timings and round-trips")
    func archiveRoundTrip() throws {
        let sourcePaths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: sourcePaths.dir) }
        let source = DataStore(
            fileURL: sourcePaths.json,
            storageEngine: .sqlite,
            databaseURL: sourcePaths.db)
        var book = Book(
            title: "Archive SQLite",
            author: "A",
            fileURL: URL(fileURLWithPath: "/tmp/archive-sqlite.pdf"),
            fileType: .pdf,
            totalPages: 50)
        book.sessions = [
            ReadingSession(
                bookID: book.id,
                startTime: Date().addingTimeInterval(-600),
                endTime: Date(),
                startPage: 0,
                endPage: 12,
                pageTimes: [
                    PageTiming(pageNumber: 1,
                               startTime: Date().addingTimeInterval(-590),
                               endTime: Date().addingTimeInterval(-580)),
                    PageTiming(pageNumber: 2,
                               startTime: Date().addingTimeInterval(-580),
                               endTime: Date().addingTimeInterval(-570)),
                ])
        ]
        source.addBook(book)
        source.saveImmediately()

        let archive = try LibraryArchiveManager.shared.exportLibrary(from: source)
        let summary = try LibraryArchiveManager.shared.summarize(archiveData: archive)
        #expect(summary.bookCount == 1)
        #expect(summary.sessionCount == 1)

        let restorePaths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: restorePaths.dir) }
        let restored = DataStore(
            fileURL: restorePaths.json,
            storageEngine: .sqlite,
            databaseURL: restorePaths.db)
        try LibraryArchiveManager.shared.importLibrary(archive, into: restored)

        let db = try LibraryDatabase(url: restorePaths.db)
        defer { try? db.close() }
        #expect(try db.counts().books == 1)
        #expect(try db.counts().pageTimes == 2)
    }

    @Test("Empty SQLite DB bootstraps the legacy JSON library in place")
    func legacyBootstrap() throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.dir) }

        let legacy = DataStore(fileURL: paths.json)
        var book = Book(
            title: "Legacy Migrated",
            author: "A",
            fileURL: URL(fileURLWithPath: "/tmp/legacy.pdf"),
            fileType: .pdf,
            totalPages: 100)
        book.sessions = [
            ReadingSession(
                bookID: book.id,
                startTime: Date().addingTimeInterval(-600),
                endTime: Date(),
                startPage: 0,
                endPage: 10,
                pageTimes: [
                    PageTiming(
                        pageNumber: 1,
                        startTime: Date().addingTimeInterval(-590),
                        endTime: Date().addingTimeInterval(-580)),
                ])
        ]
        legacy.addBook(book)
        legacy.saveImmediately()
        #expect(FileManager.default.fileExists(atPath: paths.json.path))

        let sqlite = DataStore(
            fileURL: paths.json,
            storageEngine: .sqlite,
            databaseURL: paths.db)
        #expect(sqlite.storageEngine == .sqlite)
        #expect(sqlite.books.count == 1)
        #expect(sqlite.books.first?.title == "Legacy Migrated")
        #expect(sqlite.books.first?.sessions.first?.pageTimes.isEmpty == true)
        // JSON remains as the fallback, untouched.
        #expect(FileManager.default.fileExists(atPath: paths.json.path))

        let db = try LibraryDatabase(url: paths.db)
        defer { try? db.close() }
        #expect(try db.counts().books == 1)
        #expect(try db.counts().sessions == 1)
        #expect(try db.counts().pageTimes == 1)
    }

    @Test("Analytics parity: cached summary speeds match the JSON baseline within tolerance")
    func analyticsParity() throws {
        let paths = try tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.dir) }

        let jsonStore = DataStore(fileURL: paths.json)
        var book = Book(
            title: "Parity",
            author: "A",
            fileURL: URL(fileURLWithPath: "/tmp/parity.pdf"),
            fileType: .pdf,
            totalPages: 300)
        let start = Date().addingTimeInterval(-7200)
        book.sessions = [
            ReadingSession(
                bookID: book.id,
                startTime: start,
                endTime: start.addingTimeInterval(3600),
                startPage: 0,
                endPage: 60,
                pageTimes: (0..<20).map { i in
                    PageTiming(
                        pageNumber: i,
                        startTime: start.addingTimeInterval(Double(i * 30)),
                        endTime: start.addingTimeInterval(Double(i * 30 + 20)))
                })
        ]
        jsonStore.addBook(book)
        jsonStore.saveImmediately()
        let jsonSpeed = AnalyticsEngine.readingSpeed(for: book)

        let sqliteStore = DataStore(
            fileURL: paths.json,
            storageEngine: .sqlite,
            databaseURL: paths.db)
        sqliteStore.addBook(book)
        sqliteStore.saveImmediately()

        let reopened = DataStore(
            fileURL: paths.json,
            storageEngine: .sqlite,
            databaseURL: paths.db)
        let loaded = try #require(reopened.books.first)
        let sqliteSpeed = AnalyticsEngine.readingSpeed(for: loaded)
        #expect(abs(jsonSpeed - sqliteSpeed) < 0.001,
                "JSON \(jsonSpeed) vs SQLite \(sqliteSpeed)")
        #expect(loaded.sessions.first?.pageTimes.isEmpty == true)
    }
}
