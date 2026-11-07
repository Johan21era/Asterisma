//  EstimationProvenanceTests.swift
//  AsterismaV2.0Tests
//
//  E6 pins: an estimate always says where its speed came from.
//    • A book with page timings is `personalized` with no fallback reason.
//    • A book without timings in a library that has them is `crossBookBaseline`.
//    • A library with no timings at all is `globalDefault`.
//    • `validate` preserves provenance instead of dropping it.

import Foundation
import Testing

@testable import AsterismaV2_0

@Suite("E6 — estimate provenance")
struct EstimationProvenanceTests {

    private func makeBook(
        title: String,
        durations: [Double],
        totalPages: Int = 200
    ) -> Book {
        var book = Book(
            id: UUID(),
            title: title,
            author: "Tests",
            fileURL: URL(fileURLWithPath: "/tests/\(title).epub"),
            fileType: .epub,
            totalPages: totalPages,
            chapters: [],
            dateAdded: Date(timeIntervalSince1970: 1_700_000_000),
            genre: .fiction
        )
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

    @Test("a measured book is personalized with no fallback reason")
    func personalized() {
        let book = makeBook(title: "measured", durations: Array(repeating: 30.0, count: 20))
        let result = EstimationEngine.estimate(for: book, allBooks: [book])

        #expect(result.provenance.status == .personalized)
        #expect(result.provenance.fallbackReason == nil)
        #expect(!result.provenance.status.isFallback)
        #expect(!result.provenance.modelVersion.isEmpty)
        #expect(result.provenance.measuredSecondsPerPage > 0)
    }

    @Test("an unmeasured book in a measured library is a cross-book baseline")
    func crossBookBaseline() {
        let measured = makeBook(title: "measured", durations: Array(repeating: 30.0, count: 20))
        let fresh = makeBook(title: "fresh", durations: [])
        let result = EstimationEngine.estimate(for: fresh, allBooks: [measured, fresh])

        #expect(result.provenance.status == .crossBookBaseline)
        #expect(result.provenance.fallbackReason != nil)
        #expect(result.provenance.status.isFallback)
    }

    @Test("a library with no timings reports the global default")
    func globalDefault() {
        let empty = makeBook(title: "empty", durations: [])
        let result = EstimationEngine.estimate(for: empty, allBooks: [empty])

        #expect(result.provenance.status == .globalDefault)
        #expect(result.provenance.fallbackReason != nil)
        #expect(result.provenance.measuredSecondsPerPage
                == AnalyticsConstants.defaultSecondsPerPage)
    }

    @Test("validate preserves provenance")
    func validateKeepsProvenance() {
        let book = makeBook(title: "measured", durations: Array(repeating: 30.0, count: 20))
        let raw = EstimationEngine.estimate(for: book, allBooks: [book])
        let validated = EstimationEngine.validate(result: raw)

        #expect(validated.provenance.status == raw.provenance.status)
        #expect(validated.provenance.modelVersion == raw.provenance.modelVersion)
        #expect(validated.provenance.predictionTarget == raw.provenance.predictionTarget)
    }

    @Test("measured book pace is not multiplied by an unvalidated difficulty profile")
    func measuredPaceIsNotAdjustedAgain() {
        var book = makeBook(title: "measured", durations: Array(repeating: 30.0, count: 20))
        book.difficultyProfile = ReadingDifficultyProfile(
            gradeLevel: 14, averageWordLength: 5.2,
            averageSentenceLength: 20, rareLexiconRatio: 0.10
        )
        let estimate = EstimationEngine.estimate(for: book, allBooks: [book])
        #expect(book.difficultyProfile!.difficultyMultiplier != 1)
        #expect(abs(estimate.speedModel.effectiveSpeed - 30) < 0.001)
        #expect(abs(estimate.remainingSeconds - 189 * 30) < 0.001)
    }

    @Test("book, chapter, and page estimates use the same measured pace")
    func estimatePathsUseSamePace() throws {
        var book = makeBook(title: "measured", durations: Array(repeating: 30.0, count: 20))
        book.chapters = [
            Chapter(title: "First", index: 0, startPage: 0, endPage: 19),
            Chapter(title: "Last", index: 1, startPage: 20, endPage: 39)
        ]
        let books = [book]
        let estimate = EstimationEngine.estimate(for: book, allBooks: books)
        let chapters = EstimationEngine.estimateAllChapters(for: book, allBooks: books)
        let chapter = try #require(EstimationEngine.estimateChapter(
            for: book, chapterID: book.chapters[0].id, allBooks: books
        ))
        let context = ReadingContext(currentPage: 10, selectedChapterID: nil,
                                     isTableOfContentsMode: true,
                                     timeOfDay: Date(timeIntervalSince1970: 0), dayOfWeek: 1)
        #expect(chapters.map(\.estimatedSeconds) == estimate.chapterEstimates.map(\.estimatedSeconds))
        #expect(chapter.estimatedSeconds == estimate.chapterEstimates[0].estimatedSeconds)
        #expect(EstimationEngine.estimatePageTime(for: book, page: 10,
                                                 context: context, allBooks: books)
                == estimate.speedModel.effectiveSpeed)
    }

    @Test("every status has a non-empty disclosure")
    func disclosuresExist() {
        for status in [EstimationStatus.personalized, .crossBookBaseline, .globalDefault] {
            #expect(!status.disclosure.isEmpty)
        }
    }
}
