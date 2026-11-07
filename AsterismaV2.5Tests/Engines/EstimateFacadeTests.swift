//  EstimateFacadeTests.swift
//  AsterismaV2.5Tests
//
//  E8 pins: every estimate surface resolves the same canonical pace.
//    • The measured per-book pace wins and is not re-scaled by difficulty.
//    • A new book uses the cross-book pace, not its difficulty multiplier.
//    • Predictions, forecasts, and chapter estimates agree with the main estimate.

import Foundation
import Testing

@testable import AsterismaV2_5

@Suite("E8 — canonical estimate facade")
struct EstimateFacadeTests {

    private func makeBook(
        title: String,
        durations: [Double],
        totalPages: Int = 200,
        difficulty: ReadingDifficultyProfile? = nil
    ) -> Book {
        var book = Book(
            id: UUID(),
            title: title,
            author: "Tests",
            fileURL: URL(fileURLWithPath: "/tests/\(title).epub"),
            fileType: .epub,
            totalPages: totalPages,
            chapters: [
                Chapter(title: "First", index: 0, startPage: 0, endPage: 19),
                Chapter(title: "Second", index: 1, startPage: 20, endPage: 39),
            ],
            dateAdded: Date(timeIntervalSince1970: 1_700_000_000),
            genre: .fiction
        )
        book.difficultyProfile = difficulty
        guard !durations.isEmpty else { return book }

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var elapsed: Double = 0
        let timings = durations.enumerated().map { index, duration in
            let t0 = start.addingTimeInterval(elapsed)
            elapsed += duration
            return PageTiming(pageNumber: index, startTime: t0,
                              endTime: t0.addingTimeInterval(duration))
        }
        book.sessions = [ReadingSession(
            bookID: book.id,
            startTime: start,
            endTime: start.addingTimeInterval(elapsed),
            startPage: 0,
            endPage: durations.count,
            pageTimes: timings
        )]
        book.currentPage = min(10, totalPages - 1)
        return book
    }

    private var denseProfile: ReadingDifficultyProfile {
        ReadingDifficultyProfile(
            gradeLevel: 14,
            averageWordLength: 5.2,
            averageSentenceLength: 20,
            rareLexiconRatio: 0.10
        )
    }

    @Test("measured pace is shared by every estimate surface")
    func measuredPaceIsShared() {
        let book = makeBook(
            title: "measured",
            durations: Array(repeating: 30.0, count: 20),
            difficulty: denseProfile
        )
        let books = [book]
        let estimate = EstimationEngine.estimate(for: book, allBooks: books)
        let prediction = AnalyticsEngine.predictions(for: book, allBooks: books)
        let singleBook = AnalyticsEngine.predictions(for: book)
        let forecast = AnalyticsEngine.bookForecast(for: book)
        let chapters = AnalyticsEngine.chapterPredictions(for: book)

        #expect(abs(estimate.speedModel.effectiveSpeed - 30) < 0.001)
        #expect(abs(prediction.adjustedSecondsPerPage - estimate.speedModel.effectiveSpeed) < 0.001)
        #expect(abs(singleBook.adjustedSecondsPerPage - estimate.speedModel.effectiveSpeed) < 0.001)
        #expect(abs(forecast.remainingHours - estimate.remainingHours) < 0.001)
        #expect(chapters.count == 2)
        if let first = chapters.first {
            let expected = Double(book.chapters[0].pageCount) * estimate.speedModel.effectiveSpeed
            #expect(abs(first.estimatedSeconds - expected) < 0.001)
        }
    }

    @Test("a new book gets the cross-book pace, not its difficulty multiplier")
    func newBookUsesCrossBookPace() {
        let measured = makeBook(title: "measured", durations: Array(repeating: 30.0, count: 20))
        let fresh = makeBook(title: "fresh", durations: [], difficulty: denseProfile)
        let books = [measured, fresh]
        let estimate = EstimationEngine.estimate(for: fresh, allBooks: books)
        let prediction = AnalyticsEngine.predictions(for: fresh, allBooks: books)

        #expect(estimate.provenance.status == .crossBookBaseline)
        #expect(abs(estimate.speedModel.effectiveSpeed - 30) < 0.001)
        #expect(abs(prediction.adjustedSecondsPerPage - estimate.speedModel.effectiveSpeed) < 0.001)
    }
}
