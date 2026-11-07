import Foundation
import XCTest

@testable import AsterismaV2_0

/// This is an evaluation adapter. Candidate formulas below do not change the app.
final class AdversarialEvaluationTests: XCTestCase {
    struct Segment: Codable {
        let book: String
        let pages: [Int]
        let durations: [Double]
    }
    struct Input: Codable {
        let id: String
        let target: String
        let remainingPages: Int
        let history: [Segment]
    }
    struct Prediction: Encodable {
        let id: String
        /// The fixed production estimator after the 2026-10-30 fixes.
        let baseline: Double
        /// The retired production estimator, reproduced for a same-case A/B:
        /// pooled cross-book durations with the old median-3× bound.
        let legacy: Double
        /// All usable target timings under the current page policy.
        let filtered: Double
        /// Cross-book prior over prior books only; nil without usable history.
        let prior_seconds: Double?
        /// Recent target pace; nil below the three-sample minimum.
        let recent_seconds: Double?
        /// Full candidate rule at the pre-registered 0.5 blend.
        let candidate_seconds: Double
        let target_samples: Int
        let prior_samples: Int

        enum CodingKeys: String, CodingKey {
            case id, baseline, legacy, filtered, prior_seconds, recent_seconds
            case candidate_seconds, target_samples, prior_samples
        }

        /// Explicit `null` for an absent prior/recent value. The synthesized
        /// encoder omits nil keys, which makes a receipt ambiguous about
        /// whether a sample count was zero or a field was never written.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(baseline, forKey: .baseline)
            try container.encode(legacy, forKey: .legacy)
            try container.encode(filtered, forKey: .filtered)
            if let prior_seconds {
                try container.encode(prior_seconds, forKey: .prior_seconds)
            } else {
                try container.encodeNil(forKey: .prior_seconds)
            }
            if let recent_seconds {
                try container.encode(recent_seconds, forKey: .recent_seconds)
            } else {
                try container.encodeNil(forKey: .recent_seconds)
            }
            try container.encode(candidate_seconds, forKey: .candidate_seconds)
            try container.encode(target_samples, forKey: .target_samples)
            try container.encode(prior_samples, forKey: .prior_samples)
        }
    }
    enum InvalidInput: Error { case invalid }

    /// Candidate minimum sample count. Two timings cannot distinguish a pace
    /// from one interrupted page; the audit of the 100-round run found the
    /// entire sparse tail came from trusting exactly two.
    static let minimumRecentTimings = 3
    /// Two-sided plausibility window against the reader's other books.
    static let guardLowerRatio = 0.35
    static let guardUpperRatio = 3.0

    func predict(_ input: Input) throws -> Prediction {
        guard input.remainingPages > 0 else { throw InvalidInput.invalid }
        let current = input.history.last(where: { $0.book == input.target })?.pages.last ?? 0
        guard current >= 0 else { throw InvalidInput.invalid }
        func makeBook(_ name: String, _ pages: Int) -> Book {
            Book(id: UUID(), title: name, author: "Synthetic",
                 fileURL: URL(fileURLWithPath: "/synthetic/\(name).epub"),
                 fileType: .epub, totalPages: pages, chapters: [],
                 dateAdded: Date(timeIntervalSince1970: 1_700_000_000), genre: .fiction)
        }
        var target = makeBook(input.target, current + input.remainingPages + 1)
        target.currentPage = current
        var books = [input.target: target]
        var usable: [Double] = []
        var priorBookDurations: [Double] = []
        for (index, segment) in input.history.enumerated() {
            guard !segment.pages.isEmpty, segment.pages.count == segment.durations.count,
                  segment.pages.allSatisfy({ $0 >= 0 }),
                  segment.durations.allSatisfy({ $0.isFinite && $0 > 0 }) else { throw InvalidInput.invalid }
            var book = books[segment.book] ?? makeBook(segment.book, max(200, (segment.pages.max() ?? 0) + 1))
            let start = Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 86_400)
            var cursor = start
            var timings: [PageTiming] = []
            for (page, duration) in zip(segment.pages, segment.durations) {
                let end = cursor.addingTimeInterval(duration)
                timings.append(PageTiming(pageNumber: page, startTime: cursor, endTime: end))
                cursor = end
            }
            book.sessions.append(ReadingSession(bookID: book.id, startTime: start, endTime: cursor,
                                                startPage: segment.pages.first!, endPage: segment.pages.last!, pageTimes: timings))
            books[segment.book] = book
            if segment.book != input.target {
                priorBookDurations.append(contentsOf: segment.durations)
            }
            if segment.book == input.target {
                for index in segment.pages.indices {
                    let previous = index > 0 ? segment.pages[index - 1] : nil
                    let next = index + 1 < segment.pages.count ? segment.pages[index + 1] : nil
                    // Exploratory navigation rule, not a claim about real intent.
                    let backward = previous.map { segment.pages[index] < $0 } ?? false
                    let jump = next.map { abs($0 - segment.pages[index]) > 1 } ?? false
                    if segment.durations[index] >= 2 && !backward && !jump {
                        usable.append(segment.durations[index])
                    }
                }
            }
        }
        target = try XCTUnwrap(books[input.target])
        let allBooks = books.keys.sorted().compactMap { books[$0] }
        let estimate = EstimationEngine.estimate(for: target, allBooks: allBooks)
        let baseline = estimate.remainingSeconds
        let scale = Double(input.remainingPages)

        // Retired production baseline, for a same-case A/B of the pooling fix.
        let allDurations = allBooks.flatMap(\.sessions).flatMap(\.pageTimes).map(\.duration)
        let hasPersonal = target.sessions.flatMap(\.pageTimes)
            .filter { $0.duration > PageDurationPolicy.minimumSeconds }
            .count >= AnalyticsConstants.minimumTimingsForPersonalSpeed
        let legacySpeed = hasPersonal
            ? AnalyticsEngine.readingSpeed(for: target)
            : (legacyPooledPace(allDurations) ?? AnalyticsConstants.defaultSecondsPerPage)
        let legacy = scale * legacySpeed

        let all = PageDurationPolicy.robustMeanSeconds(usable)
        let filtered = all.map { $0 * scale } ?? baseline

        // Prior reference: the fixed production cross-book consensus over the
        // books that are not the target. Nothing candidate-specific here.
        let priorDurations = priorBookDurations
        let priorPace: Double? = PageDurationPolicy.robustMeanSeconds(priorDurations) == nil
            ? nil
            : AnalyticsEngine.crossBookReadingSpeed(
                allBooks: books.filter { $0.key != input.target }
                    .sorted { $0.key < $1.key }.map(\.value))

        // Recent target pace only above the sample minimum; two timings are a
        // mean of two, not a pace.
        let recentPace = usable.count >= Self.minimumRecentTimings
            ? PageDurationPolicy.robustMeanSeconds(Array(usable.suffix(8)))
            : nil

        let priorSeconds = priorPace.map { $0 * scale }
        let recentSeconds = recentPace.map { $0 * scale }
        let candidate = Self.candidateSeconds(baseline: baseline, prior: priorSeconds,
                                              recent: recentSeconds, weight: 0.5)
        return Prediction(id: input.id, baseline: baseline, legacy: legacy,
                          filtered: filtered, prior_seconds: priorSeconds,
                          recent_seconds: recentSeconds, candidate_seconds: candidate,
                          target_samples: usable.count, prior_samples: priorDurations.count)
    }

    /// The retired cross-book formula, reproduced: one pooled median, one 3×
    /// ceiling, one mean. Never used by the app; only for the A/B receipt.
    private func legacyPooledPace(_ durations: [Double]) -> Double? {
        let positive = durations.filter { $0 > PageDurationPolicy.minimumSeconds }.sorted()
        guard let median = PageDurationPolicy.median(of: positive) else { return nil }
        let retained = positive.filter { $0 <= median * 3.0 }
        return retained.isEmpty ? median : retained.reduce(0, +) / Double(retained.count)
    }

    /// One rule, two languages: `tools/cde/fresh_100.py` mirrors this exactly.
    ///
    /// - fewer than three target samples: use the prior reference, or the
    ///   production baseline when there is no prior;
    /// - a recent pace outside the plausibility window in either direction: use
    ///   the prior reference;
    /// - otherwise blend recent and prior.
    static func candidateSeconds(baseline: Double, prior: Double?, recent: Double?,
                                 weight: Double) -> Double {
        guard let recent else { return prior ?? baseline }
        guard let prior else { return recent }
        let ratio = recent / prior
        if ratio < guardLowerRatio || ratio > guardUpperRatio { return prior }
        return weight * recent + (1 - weight) * prior
    }

    func testAdapterUsesProductionBaseline() throws {
        let sample = Input(id: "x", target: "t", remainingPages: 40,
                           history: [Segment(book: "t", pages: Array(0..<10), durations: Array(repeating: 60, count: 10))])
        let result = try predict(sample)
        XCTAssertEqual(result.baseline, 2400, accuracy: 0.001)
        XCTAssertEqual(result.legacy, 2400, accuracy: 0.001)
        XCTAssertEqual(result.filtered, 2400, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result.recent_seconds), 2400, accuracy: 0.001)
        XCTAssertNil(result.prior_seconds)
        XCTAssertEqual(result.candidate_seconds, 2400, accuracy: 0.001)
        XCTAssertEqual(result.target_samples, 10)
    }

    func testTwoSamplesAreNotAPace() throws {
        let sample = Input(id: "x", target: "t", remainingPages: 40,
                           history: [Segment(book: "p", pages: Array(0..<12), durations: Array(repeating: 30, count: 12)),
                                     Segment(book: "t", pages: [0, 1], durations: [700, 720])])
        let result = try predict(sample)
        XCTAssertEqual(result.target_samples, 2)
        XCTAssertNil(result.recent_seconds, "two timings must not be trusted as a pace")
        XCTAssertEqual(result.candidate_seconds, 1200, accuracy: 0.001,
                       "the candidate must fall back to the 30 s/page prior")
    }

    func testGuardRejectsAnImplausiblyFastTarget() throws {
        let sample = Input(id: "x", target: "t", remainingPages: 40,
                           history: [Segment(book: "p", pages: Array(0..<12), durations: Array(repeating: 80, count: 12)),
                                     Segment(book: "t", pages: Array(0..<6), durations: Array(repeating: 10, count: 6))])
        let result = try predict(sample)
        XCTAssertEqual(result.candidate_seconds, 40 * 80, accuracy: 0.001)
    }

    func testGuardRejectsAnImplausiblySlowTarget() throws {
        let sample = Input(id: "x", target: "t", remainingPages: 40,
                           history: [Segment(book: "p", pages: Array(0..<12), durations: Array(repeating: 40, count: 12)),
                                     Segment(book: "t", pages: Array(0..<6), durations: Array(repeating: 600, count: 6))])
        let result = try predict(sample)
        XCTAssertEqual(result.candidate_seconds, 40 * 40, accuracy: 0.001,
                       "a slow, contaminated target must fall back to the prior")
    }

    func testOptionalBatch() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let request = root.appendingPathComponent(".adversarial-eval-request")
        guard FileManager.default.fileExists(atPath: request.path) else { return }
        let directory = try String(contentsOf: request, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directory.isEmpty, !directory.hasPrefix("/"),
              !directory.split(separator: "/").contains("..") else { throw InvalidInput.invalid }
        let input = try JSONDecoder().decode([Input].self, from: Data(contentsOf: root.appendingPathComponent(directory).appendingPathComponent("app-input.json")))
        XCTAssertEqual(Set(input.map(\.id)).count, input.count)
        let results = try input.map(predict)
        let attachment = XCTAttachment(data: try JSONEncoder().encode(results), uniformTypeIdentifier: "public.json")
        attachment.name = "adversarial-predictions"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("ADVERSARIAL_EVAL cases=\(results.count)")
    }
}
