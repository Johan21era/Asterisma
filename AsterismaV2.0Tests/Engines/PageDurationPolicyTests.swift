//  PageDurationPolicyTests.swift
//  AsterismaV2.0Tests
//
//  E2 pins for the reading-speed measurement policy.
//
//  What these tests protect:
//    • A genuinely slow reader (300 s/page) is measured, not replaced by the
//      120 s/page global default.
//    • An idle page (600 s in a 20 s/page distribution) is not counted as
//      reading.
//    • A long-but-plausible page is retained; the window is the reader's own
//      distribution, not a universal one-minute ceiling.
//    • Contamination that occupies half the pages cannot drag the accepted
//      pace up to the contaminated median.
//    • `readingSpeed` and `crossBookReadingSpeed` share the same policy, and
//      cross-book pace is normalized per book before books are combined.

import Foundation
import Testing

@testable import AsterismaV2_0

@Suite("E2 — page-duration policy")
struct PageDurationPolicyTests {

    private func book(durations: [Double], genre: ReadingGenre = .fiction) -> Book {
        var book = Book(
            id: UUID(),
            title: "Policy Fixture",
            author: "Tests",
            fileURL: URL(fileURLWithPath: "/tests/policy.epub"),
            fileType: .epub,
            totalPages: max(1, durations.count),
            chapters: [],
            dateAdded: Date(timeIntervalSince1970: 1_700_000_000),
            genre: genre
        )
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var elapsed: Double = 0
        let timings = durations.enumerated().map { index, duration -> PageTiming in
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
        return book
    }

    // MARK: - Policy

    @Test("a slow reader's median is the retained window, not a 60 s ceiling")
    func slowDistributionIsRetained() {
        let durations = Array(repeating: 300.0, count: 20)
        let mean = PageDurationPolicy.robustMeanSeconds(durations)
        #expect(mean != nil)
        #expect(abs((mean ?? 0) - 300) < 0.001)
        #expect(PageDurationPolicy.acceptedRange(durations)?.upperBound == 900)
    }

    @Test("an idle page is an outlier in the reader's own distribution")
    func idlePageRejected() {
        let durations = Array(repeating: 20.0, count: 20) + [600]
        let mean = PageDurationPolicy.robustMeanSeconds(durations)
        #expect(mean != nil)
        #expect(abs((mean ?? 0) - 20) < 0.001,
                "a 10-minute idle page must not move a 20 s/page reader")
    }

    @Test("a long but plausible page survives")
    func plausibleLongPageRetained() {
        var durations = Array(repeating: 20.0, count: 19)
        durations.append(45)
        let mean = PageDurationPolicy.robustMeanSeconds(durations)
        #expect(abs((mean ?? 0) - 21.25) < 0.001,
                "45 s is 2.25× this reader's median and must be counted")
    }

    @Test("contamination in half the pages cannot become the accepted pace")
    func majorityContaminationIsBounded() {
        // Round-60 shape: four clean pages near 70 s and four interrupted pages
        // at 254–967 s. The median is one of the interrupted pages.
        let durations = [966.7, 71.3, 69.1, 254.0, 72.1, 72.3, 254.1, 759.8]
        let median = PageDurationPolicy.median(of: durations) ?? 0
        let mean = PageDurationPolicy.robustMeanSeconds(durations) ?? 0
        #expect(abs(median - 72.3) < 0.001, "fixture lower median changed")
        #expect(abs(mean - 71.2) < 0.001,
                "the 254–967 s interrupted pages must be rejected as outliers")
        #expect(mean < median * 1.01,
                "majority contamination must not be adopted as the reader's pace")
    }

    @Test("no usable duration means no estimate")
    func emptyDistribution() {
        #expect(PageDurationPolicy.robustMeanSeconds([]) == nil)
        #expect(PageDurationPolicy.robustMeanSeconds([0.1, 0.2]) == nil)
    }

    // MARK: - Call sites

    @Test("readingSpeed measures a slow reader instead of using 120 s/page")
    func slowReaderIsMeasured() {
        let slow = book(durations: Array(repeating: 300.0, count: 30))
        let speed = AnalyticsEngine.readingSpeed(for: slow)
        #expect(abs(speed - 300) < 0.001)
        #expect(speed != AnalyticsConstants.defaultSecondsPerPage)
    }

    @Test("readingSpeed rejects an idle page")
    func readingSpeedRejectsIdlePage() {
        let normal = book(durations: Array(repeating: 20.0, count: 20) + [600])
        #expect(AnalyticsEngine.readingSpeed(for: normal) < 25)
    }

    @Test("crossBookReadingSpeed shares the slow-reader policy")
    func crossBookSharesPolicy() {
        let a = book(durations: Array(repeating: 280.0, count: 10))
        let b = book(durations: Array(repeating: 320.0, count: 10))
        let cross = AnalyticsEngine.crossBookReadingSpeed(allBooks: [a, b])
        #expect(cross > 250, "cross-book speed collapsed to the global default")
    }

    @Test("cross-book pace is normalized per book, not weighted by sample count")
    func crossBookIsNormalizedPerBook() {
        let short = book(durations: Array(repeating: 100.0, count: 5))
        let long = book(durations: Array(repeating: 110.0, count: 30))
        let outlier = book(durations: Array(repeating: 400.0, count: 2))
        let cross = AnalyticsEngine.crossBookReadingSpeed(allBooks: [short, long, outlier])
        #expect(abs(cross - 110) < 0.001,
                "pooled sample counts moved the cross-book pace to \(cross)")
    }

    @Test("two books that agree within 3× are averaged")
    func twoBookConsensusAveragesPlausibleBooks() {
        let a = book(durations: Array(repeating: 100.0, count: 12))
        let b = book(durations: Array(repeating: 110.0, count: 12))
        let cross = AnalyticsEngine.crossBookReadingSpeed(allBooks: [a, b])
        #expect(abs(cross - 105) < 0.001,
                "two plausible books collapsed to the faster pace at \(cross)")
    }

    @Test("two books that disagree by more than 3× resolve to the faster pace")
    func twoBookConsensusPrefersFaster() {
        let slow = book(durations: Array(repeating: 978.0, count: 12))
        let fast = book(durations: Array(repeating: 24.9, count: 12))
        let cross = AnalyticsEngine.crossBookReadingSpeed(allBooks: [slow, fast])
        #expect(abs(cross - 24.9) < 0.001,
                "one idle-contaminated book dominated the cross-book pace at \(cross)")
    }

    @Test("three books resolve to the ordinary median pace")
    func threeBookConsensusIsMedian() {
        let a = book(durations: Array(repeating: 60.0, count: 8))
        let b = book(durations: Array(repeating: 75.0, count: 8))
        let c = book(durations: Array(repeating: 500.0, count: 8))
        #expect(AnalyticsEngine.crossBookReadingSpeed(allBooks: [a, b, c]) == 75)
    }

    @Test("a book with no timings still reports the documented default")
    func noTimingsFallback() {
        var empty = book(durations: [])
        empty.sessions = []
        #expect(AnalyticsEngine.readingSpeed(for: empty)
                == AnalyticsConstants.defaultSecondsPerPage)
    }
}
