//  ReadingAnalyticsPhaseZeroTests.swift
//  AsterismaV2.5Tests
//
//  PHASE ZERO — evidence capture, not a product assertion.
//
//  This test intentionally makes no claim about whether the current estimates
//  are correct. It generates one book per representative synthetic persona and
//  records every intermediate value the estimation pipeline exposes:
//
//      raw page-timing distribution
//        -> AnalyticsEngine base speed
//        -> genre speed
//        -> cross-book speed
//        -> EstimationEngine weighted effective speed
//        -> remaining-time output
//
//  The JSON attachment is the reproducible baseline referenced by
//  docs/audits/13-reading-analytics-phase-zero-2026-10-29.md. Run:
//
//      xcodebuild test -project AsterismaV2.5.xcodeproj \
//        -scheme AsterismaV2.5 -destination 'platform=macOS' \
//        -only-testing:AsterismaV2_5Tests/ReadingAnalyticsPhaseZeroProbeTests \
//        -resultBundlePath /tmp/phase-zero.xcresult
//
//  then export the attachment:
//
//      xcrun xcresulttool export attachments \
//        --path /tmp/phase-zero.xcresult --output-path /tmp/phase-zero

import Foundation
import XCTest

@testable import AsterismaV2_5

#if DEBUG

final class ReadingAnalyticsPhaseZeroProbeTests: XCTestCase {

    /// Fixed reference date so persona generation is reproducible. The
    /// Estimator itself still reads `Date()` for trend/completion, which is
    /// recorded as a Phase Zero finding rather than hidden here.
    private let referenceDate = ISO8601DateFormatter()
        .date(from: "2026-10-29T12:00:00Z")!

    private let personaIDs = [
        "winter-romantic",       // 26...50 s/page, ~1,000 h
        "fantasy-marathoner",    // 20...42 s/page, long sessions
        "night-owl-scholar",     // 30...65 s/page
        "business-grinder",      // 22...40 s/page
        "speed-demon",           // 8...15 s/page
        "slow-savorer",          // 240...420 s/page
        "commuter-snacker",      // 18...35 s/page, short sessions
        "one-book-wonder"        // 25...48 s/page, single book
    ]

    func testProfileSensitivityProbe() throws {
        var rows: [[String: Any]] = []

        for id in personaIDs {
            guard let persona = DemoProfileCatalog.persona(withID: id) else {
                XCTFail("missing persona \(id)")
                continue
            }

            let books = DemoProfileCatalog.generateBooks(
                for: persona,
                referenceDate: referenceDate
            )

            // Prefer a genuinely unfinished book so the integrated estimate
            // exercises a non-zero remaining-time path. The first generated
            // book is often read to the last page while `isCompleted` is still
            // false — itself a generator observation recorded below.
            guard let book = books.first(where: {
                !$0.isCompleted
                    && $0.currentPage < $0.totalPages - 1
                    && $0.sessions.contains { !$0.pageTimes.isEmpty }
            }) ?? books.first else {
                XCTFail("\(id): no generated book")
                continue
            }

            let totalDuration = book.sessions.reduce(0.0) { $0 + $1.duration }
            let totalPagesRead = book.sessions.reduce(0) { $0 + $1.pagesRead }

            // The demo horizon fills most books to their last page while
            // leaving isCompleted == false, so rewind a copy to 50% and
            // exercise the non-zero remaining-time path deterministically.
            var projection = book
            projection.currentPage = max(0, book.totalPages / 2)
            projection.isCompleted = false
            let projectedEstimate = EstimationEngine.estimate(
                for: projection,
                allBooks: books
            )
            let projectedRemainingPages = max(
                0,
                projection.totalPages - 1 - projection.currentPage
            )
            let projectedImpliedSecondsPerPage = projectedRemainingPages > 0
                ? projectedEstimate.remainingSeconds / Double(projectedRemainingPages)
                : 0

            let genreBooks = books.filter { $0.genre == book.genre }
            let genreTimings = genreBooks
                .flatMap(\.sessions)
                .flatMap(\.pageTimes)
                .map(\.duration)
                .filter { $0 > 0 }
            let genreTimingMean = genreTimings.isEmpty
                ? 0
                : genreTimings.reduce(0, +) / Double(genreTimings.count)
            let genreSessionPages = genreBooks
                .flatMap(\.sessions)
                .reduce(0) { $0 + $1.pagesRead }
            let genreSessionSeconds = genreBooks
                .flatMap(\.sessions)
                .reduce(0.0) { $0 + $1.duration }
            let sessionsWithOnePage = book.sessions.filter { $0.pagesRead == 1 }.count

            let timings = book.sessions
                .flatMap(\.pageTimes)
                .map(\.duration)
                .filter { $0 > 0 }
                .sorted()

            let medianTiming = timings.isEmpty ? 0 : timings[timings.count / 2]
            // E2: the probe now records the documented policy window, not the
            // retired absolute 0.5…60 s ceiling.
            let policyRange = PageDurationPolicy.acceptedRange(timings)
            let withinPolicyWindow = policyRange.map { range in
                timings.filter { range.contains($0) }.count
            } ?? 0

            let base = AnalyticsEngine.readingSpeed(for: book)
            let adjusted = AnalyticsEngine.adjustedReadingSpeed(for: book)
            let effective = AnalyticsEngine.effectiveReadingSpeed(for: book, allBooks: books)
            let cross = AnalyticsEngine.crossBookReadingSpeed(allBooks: books)
            let genreSpeed = AnalyticsEngine.genreAdjustedReadingSpeed(for: book, books: books)
            let genreProfile = AnalyticsEngine.genreProfiles(from: books)[book.genre]

            // E3 — ablation. A = reader's own robust page speed; B = A plus a
            // genre signal measured against the reader's own overall pace
            // (shrunk 50%); C = A with cross-book cold start; D = the shipped
            // 40/25/20/15 blend. The target here is the persona's own timing
            // median, so this measures self-consistency, not real accuracy.
            let genreRatio = (genreProfile?.averageSecondsPerPage ?? cross) / max(cross, 1)
            let ablationA = base
            let ablationB = base * (1 + 0.5 * (genreRatio - 1))
            let hasPersonal = book.sessions
                .flatMap(\.pageTimes)
                .filter { $0.duration > PageDurationPolicy.minimumSeconds }
                .count >= AnalyticsConstants.minimumTimingsForPersonalSpeed
            let ablationC = hasPersonal ? base : cross
            let ablationD = {
                let trendM = 1.0
                return base * 0.40 + genreSpeed * 0.25
                    + (cross * trendM) * 0.20 + cross * 0.15
            }()

            let estimate = EstimationEngine.estimate(for: book, allBooks: books)
            let remainingPages = max(0, book.totalPages - 1 - book.currentPage)
            let impliedSecondsPerPage = remainingPages > 0
                ? estimate.remainingSeconds / Double(remainingPages)
                : 0

            // Simulate the SQLite summary path: it persists
            // AnalyticsEngine.readingSpeed before dropping page-timing rows.
            var summary = book
            summary.cachedSecondsPerPage = base
            summary.sessions = summary.sessions.map { session in
                var copy = session
                copy.pageTimes = []
                return copy
            }
            let summarySpeed = AnalyticsEngine.readingSpeed(for: summary)

            let row: [String: Any] = [
                "persona": id,
                "personaName": persona.name,
                "declaredSecondsPerPage": [
                    "lower": finite(persona.secondsPerPage.lowerBound),
                    "upper": finite(persona.secondsPerPage.upperBound)
                ],
                "book": book.title,
                "genre": book.genre.rawValue,
                "totalPages": book.totalPages,
                "currentPage": book.currentPage,
                "remainingPages": remainingPages,
                "isCompleted": book.isCompleted,
                "progressFraction": finite(book.progressFraction),
                "totalSessionDurationSeconds": finite(totalDuration),
                "totalPagesReadInSessions": totalPagesRead,
                "sessionCount": book.sessions.count,
                "timingCount": timings.count,
                "timingMedianSeconds": finite(medianTiming),
                "timingMinSeconds": finite(timings.first ?? 0),
                "timingMaxSeconds": finite(timings.last ?? 0),
                "policyWindowSeconds": [
                    "lower": finite(policyRange?.lowerBound ?? 0),
                    "upper": finite(policyRange?.upperBound ?? 0)
                ],
                "timingsInsidePolicyWindow": withinPolicyWindow,
                "timingsDroppedByPolicyWindow": timings.count - withinPolicyWindow,
                "baseSecondsPerPage": finite(base),
                "adjustedSecondsPerPage": finite(adjusted),
                "effectiveSecondsPerPage": finite(effective),
                "crossBookSecondsPerPage": finite(cross),
                "genreAdjustedSecondsPerPage": finite(genreSpeed),
                "genreProfileSecondsPerPage": finite(genreProfile?.averageSecondsPerPage ?? 0),
                "genreProfileSessions": genreProfile?.totalSessions ?? 0,
                "genreProfilePages": genreProfile?.totalPages ?? 0,
                "genreProfileAverageSessionSeconds": finite(genreProfile?.averageSessionDuration ?? 0),
                "genreTimingMeanSeconds": finite(genreTimingMean),
                "genreTimingCount": genreTimings.count,
                "genreSessionPagesRead": genreSessionPages,
                "genreSessionHours": finite(genreSessionSeconds / 3600),
                "sessionsWithOnePageRead": sessionsWithOnePage,
                "estimateSpeedModel": [
                    "base": finite(estimate.speedModel.baseSpeed),
                    "genre": finite(estimate.speedModel.genreAdjustedSpeed),
                    "trend": finite(estimate.speedModel.trendAdjustedSpeed),
                    "crossBook": finite(estimate.speedModel.crossBookSpeed),
                    "effective": finite(estimate.speedModel.effectiveSpeed),
                    "volatility": finite(estimate.speedModel.volatility)
                ],
                "estimateRemainingSeconds": finite(estimate.remainingSeconds),
                "estimateRemainingHours": finite(estimate.remainingHours),
                "estimateImpliedSecondsPerPage": finite(impliedSecondsPerPage),
                "projectedCurrentPage": projection.currentPage,
                "projectedRemainingPages": projectedRemainingPages,
                "projectedRemainingHours": finite(projectedEstimate.remainingHours),
                "projectedImpliedSecondsPerPage": finite(projectedImpliedSecondsPerPage),
                "ablation": [
                    "A_base": finite(ablationA),
                    "B_baseGenre": finite(ablationB),
                    "C_coldStart": finite(ablationC),
                    "D_shippedBlend": finite(ablationD)
                ],
                "estimateConfidence": finite(estimate.confidence.score),
                "persistedSummarySpeed": finite(summarySpeed),
                "effectiveOverObservedMedian": medianTiming > 0
                    ? finite(effective / medianTiming)
                    : NSNull()
            ]

            rows.append(row)
        }

        XCTAssertFalse(rows.isEmpty, "probe produced no rows")

        let payload: [String: Any] = [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "referenceDate": ISO8601DateFormatter().string(from: referenceDate),
            "note": "Phase Zero diagnostic only. No assertion that these values are correct.",
            "rows": rows
        ]

        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )

        let attachment = XCTAttachment(
            data: data,
            uniformTypeIdentifier: "public.json"
        )
        attachment.name = "reading-analytics-phase-zero.json"
        attachment.lifetime = .keepAlways
        add(attachment)

        // A compact console line so a failed export is still diagnosable.
        for row in rows {
            let id = row["persona"] as? String ?? "?"
            let median = row["timingMedianSeconds"] as? Double ?? 0
            let base = row["baseSecondsPerPage"] as? Double ?? 0
            let effective = row["effectiveSecondsPerPage"] as? Double ?? 0
            print("PHASE0 \(id) median=\(median)s base=\(base)s effective=\(effective)s")
        }
    }

    private func finite(_ value: Double) -> Any {
        value.isFinite ? value : NSNull()
    }
}
#endif
