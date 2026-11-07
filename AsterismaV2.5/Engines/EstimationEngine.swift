//  EstimationEngine.swift
//  AsterismaV2.5
//  Stateless deterministic prediction layer built on AnalyticsEngine
//
//  ROADMAP 3.4 / F-13a (RA-002): three verified-dead members removed —
//    • buildSpeedModel's `totalWeight` (computed, never used)
//    • instance-level clamp(_:min:max:) (zero callers; engines are static namespaces)
//    • mapConfidence(_:) (zero callers; ConfidenceModel is built inline in estimate())
//  Verified by repo-wide reference search during RA-002. No behavior change:
//  every remaining path is byte-equivalent.

import Foundation

// MARK: - ReadingContext

/// Optional context retained for callers; the page estimate does not apply
/// context adjustments until their effect has been validated.
struct ReadingContext {
    var currentPage: Int?
    var selectedChapterID: UUID?
    var isTableOfContentsMode: Bool
    var timeOfDay: Date?
    var dayOfWeek: Int? // 1...7 (Calendar weekday)
}

// MARK: - Speed Components

private struct SpeedComponents {
    let base: Double?
    let genre: Double?
    let trend: Double?
    let crossBook: Double?
}

// MARK: - Speed Model

struct SpeedModel {
    let baseSpeed: Double
    let genreAdjustedSpeed: Double
    let trendAdjustedSpeed: Double
    let crossBookSpeed: Double
    let effectiveSpeed: Double
    let volatility: Double
}

// MARK: - Confidence Model

struct ConfidenceModel {
    let score: Double
    let level: ConfidenceLevel
}

// MARK: - Chapter Estimation

struct ChapterEstimation {
    let chapterID: UUID
    let estimatedSeconds: TimeInterval
    let estimatedFormatted: String
    let pages: Int
    let completionDate: Date
}

// MARK: - Estimation Provenance (E6)

/// Where an estimate's speed actually came from. Before E6 the UI showed a
/// number with no way to tell a measured reader from the 120 s/page constant;
/// Rule 8 of the analytics plan forbids silent fallbacks.
enum EstimationStatus: String {
    /// Built from this book's own page timings.
    case personalized
    /// This book has no usable timings; the reader's cross-book pace was used.
    case crossBookBaseline
    /// Neither the book nor the library has usable timings; 120 s/page was used.
    case globalDefault

    var disclosure: String {
        switch self {
        case .personalized:
            return "Personalised from this book's page timings."
        case .crossBookBaseline:
            return "No page timings for this book yet — estimated from your cross-book reading pace."
        case .globalDefault:
            return "No reading history yet — estimated from the 2 min/page default."
        }
    }

    var isFallback: Bool { self != .personalized }
}

struct EstimationProvenance {
    let status: EstimationStatus
    let fallbackReason: String?
    let modelVersion: String
    let predictionTarget: String
    let measuredSecondsPerPage: Double

    static let modelVersion = "reading-time/page-speed-e4"
    static let predictionTarget = "active reading time, page-timing policy E2"
}

// MARK: - Book Estimation Result

struct BookEstimationResult {
    let remainingSeconds: TimeInterval
    let remainingHours: Double
    let formattedRemaining: String

    let estimatedCompletionDate: Date
    let estimatedDaysRemaining: Int

    let expectedSessionDuration: TimeInterval
    let expectedPagesPerSession: Double

    let probabilityFinishChapterInOneSession: Double

    let speedModel: SpeedModel
    let confidence: ConfidenceModel

    let chapterEstimates: [ChapterEstimation]

    /// E6: status, fallback disclosure, and model identity travel with the
    /// estimate instead of being inferred by the caller.
    let provenance: EstimationProvenance
}

// MARK: - EstimationEngine

enum EstimationEngine {
    // MARK: Public API

    /// E8 — the one pace every estimate surface uses.
    ///
    /// The measured per-book pace wins; the reader's cross-book pace is the
    /// only fallback. Difficulty is deliberately absent: it labels content,
    /// it does not re-scale a measured pace. Before E8, `AnalyticsEngine`
    /// multiplied this same pace by `difficultyMultiplier`, so the estimate
    /// screen and the prediction helpers disagreed by up to 1.77×.
    static func effectiveSecondsPerPage(for book: Book, allBooks: [Book]) -> Double {
        hasPersonalSpeed(for: book)
            ? AnalyticsEngine.readingSpeed(for: book)
            : AnalyticsEngine.crossBookReadingSpeed(allBooks: allBooks)
    }

    static func estimate(for book: Book, allBooks: [Book]) -> BookEstimationResult {
        let baseSpeed = AnalyticsEngine.readingSpeed(for: book)

        let genreSpeed = AnalyticsEngine.genreAdjustedReadingSpeed(
            for: book,
            books: allBooks
        )

        let trend = AnalyticsEngine.trendAnalysis(books: allBooks)
        let trendMultiplier = trendMultiplier(from: trend)

        let crossSpeed = AnalyticsEngine.crossBookReadingSpeed(allBooks: allBooks)

        let hasPersonalSpeed = hasPersonalSpeed(for: book)
        let effectiveSpeed = effectiveSecondsPerPage(for: book, allBooks: allBooks)

        let speedModel = buildSpeedModel(
            base: baseSpeed,
            genre: genreSpeed,
            trendMultiplier: trendMultiplier,
            cross: crossSpeed,
            effective: effectiveSpeed
        )

        let remainingPages = max(0, book.totalPages - 1 - book.currentPage)

        let remainingSeconds = Double(remainingPages) * effectiveSpeed
        let remainingHours = remainingSeconds / 3600.0

        let completionDate = Date().addingTimeInterval(remainingSeconds)

        let daysRemaining = max(
            0,
            Calendar.current.dateComponents([.day], from: Date(), to: completionDate).day ?? 0
        )

        let chapterEstimates = estimateChapters(
            book: book,
            speed: effectiveSpeed
        )

        let confidence = AnalyticsEngine.predictionConfidence(for: book, allBooks: allBooks)

        let confidenceModel = ConfidenceModel(
            score: confidence.value,
            level: confidence.level
        )

        let libraryHasEvidence = PageDurationPolicy.robustMeanSeconds(
            allBooks.flatMap(\.sessions).flatMap(\.pageTimes).map(\.duration)
        ) != nil || allBooks.contains { ($0.cachedSecondsPerPage ?? 0) > 0 }

        let status: EstimationStatus
        let fallbackReason: String?
        if hasPersonalSpeed {
            status = .personalized
            fallbackReason = nil
        } else if libraryHasEvidence {
            status = .crossBookBaseline
            fallbackReason = "no usable page timings for this book"
        } else {
            status = .globalDefault
            fallbackReason = "no usable page timings in the library"
        }

        return BookEstimationResult(
            remainingSeconds: remainingSeconds,
            remainingHours: remainingHours,
            formattedRemaining: formatTime(remainingSeconds),

            estimatedCompletionDate: completionDate,
            estimatedDaysRemaining: daysRemaining,

            expectedSessionDuration: estimateSessionDuration(book: book, speed: effectiveSpeed),
            expectedPagesPerSession: estimatePagesPerSession(book: book, speed: effectiveSpeed),

            probabilityFinishChapterInOneSession: estimateChapterCompletionProbability(book: book, speed: effectiveSpeed),

            speedModel: speedModel,
            confidence: confidenceModel,

            chapterEstimates: chapterEstimates,

            provenance: EstimationProvenance(
                status: status,
                fallbackReason: fallbackReason,
                modelVersion: EstimationProvenance.modelVersion,
                predictionTarget: EstimationProvenance.predictionTarget,
                measuredSecondsPerPage: effectiveSpeed
            )
        )
    }

    // MARK: Speed Model Builder

    /// E3 — the ablation rejected the 40/25/20/15 blend.
    ///
    /// With the measurement policy corrected (E2), the reader's own robust page
    /// speed is within 1–4% of the observed page-timing median on all eight
    /// personas, while the shipped blend lands 12–47% away. Genre contributed
    /// 25% of the estimate and measured the reader twice; trend contributed 20%
    /// and is a direction, not a speed. The estimate is therefore the reader's
    /// own speed, with the cross-book average used only as a cold start.
    ///
    /// `genreAdjustedSpeed` and `trendAdjustedSpeed` remain in the model as
    /// display/diagnostic values; they no longer move the effective speed.
    private static func buildSpeedModel(
        base: Double,
        genre: Double,
        trendMultiplier: Double,
        cross: Double,
        effective: Double
    ) -> SpeedModel {
        let volatility = computeVolatility(base: base, cross: cross)

        return SpeedModel(
            baseSpeed: base,
            genreAdjustedSpeed: genre,
            trendAdjustedSpeed: base * trendMultiplier,
            crossBookSpeed: cross,
            effectiveSpeed: effective,
            volatility: volatility
        )
    }

    // MARK: Trend

    private static func trendMultiplier(from trend: TrendAnalytics) -> Double {
        let raw = 1.0 + trend.dailyTrend
        return min(1.15, max(0.85, raw))
    }

    // MARK: Chapter Estimation (Part 2 continues this)

    private static func estimateChapters(book: Book, speed: Double) -> [ChapterEstimation] {
        book.chapters.map { chapter in
            let seconds = Double(chapter.pageCount) * speed
            let date = Date().addingTimeInterval(seconds)

            return ChapterEstimation(
                chapterID: chapter.id,
                estimatedSeconds: seconds,
                estimatedFormatted: formatTime(seconds),
                pages: chapter.pageCount,
                completionDate: date
            )
        }
    }

    // MARK: Session Estimation Helpers

    private static func estimateSessionDuration(book: Book, speed: Double) -> TimeInterval {
        let avgPages = max(1, book.totalPages / max(1, book.sessions.count + 1))
        return Double(avgPages) * speed
    }

    private static func estimatePagesPerSession(book: Book, speed: Double) -> Double {
        let avgSessionTime = book.sessions.map { $0.duration }.reduce(0, +) /
            Double(max(1, book.sessions.count))

        return avgSessionTime / max(speed, 1)
    }

    private static func estimateChapterCompletionProbability(book: Book, speed: Double) -> Double {
        let avgPages = Double(book.totalPages) / Double(max(1, book.chapters.count))
        let sessionCapacity = estimatePagesPerSession(book: book, speed: speed)

        let ratio = sessionCapacity / max(avgPages, 1)

        return min(1.0, max(0.0, ratio))
    }

    // MARK: Volatility

    private static func computeVolatility(base: Double, cross: Double) -> Double {
        let diff = abs(base - cross) / max(base, 1)
        return min(1.5, max(0.7, 1.0 + diff))
    }

    // MARK: Formatting

    private static func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds >= 60 else { return "<1m" }

        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}

// MARK: - PART 2: CONTEXT + PAGE + CHAPTER REFINEMENTS

extension EstimationEngine {
    // MARK: - Public Chapter APIs

    static func estimateAllChapters(for book: Book, allBooks: [Book]) -> [ChapterEstimation] {
        let baseSpeed = resolveEffectiveSpeed(book: book, allBooks: allBooks)

        return book.chapters.map { chapter in
            let seconds = Double(chapter.pageCount) * baseSpeed
            let date = Date().addingTimeInterval(seconds)

            return ChapterEstimation(
                chapterID: chapter.id,
                estimatedSeconds: seconds,
                estimatedFormatted: formatTime(seconds),
                pages: chapter.pageCount,
                completionDate: date
            )
        }
    }

    static func estimateChapter(
        for book: Book,
        chapterID: UUID,
        allBooks: [Book]
    ) -> ChapterEstimation? {
        guard let chapter = book.chapters.first(where: { $0.id == chapterID }) else {
            return nil
        }

        let baseSpeed = resolveEffectiveSpeed(book: book, allBooks: allBooks)

        let seconds = Double(chapter.pageCount) * baseSpeed
        let date = Date().addingTimeInterval(seconds)

        return ChapterEstimation(
            chapterID: chapter.id,
            estimatedSeconds: seconds,
            estimatedFormatted: formatTime(seconds),
            pages: chapter.pageCount,
            completionDate: date
        )
    }

    // MARK: - Page-Level Estimation

    static func estimatePageTime(
        for book: Book,
        page _: Int,
        context _: ReadingContext?,
        allBooks: [Book]
    ) -> TimeInterval {
        // Context and chapter-position effects are not calibrated against
        // observed reading outcomes. Use the same pace as the book estimate.
        resolveEffectiveSpeed(book: book, allBooks: allBooks)
    }

    // MARK: - Speed Resolution

    private static func hasPersonalSpeed(for book: Book) -> Bool {
        book.sessions.flatMap(\.pageTimes)
            .filter { $0.duration > PageDurationPolicy.minimumSeconds }
            .count >= AnalyticsConstants.minimumTimingsForPersonalSpeed
    }

    private static func resolveEffectiveSpeed(book: Book, allBooks: [Book]) -> Double {
        effectiveSecondsPerPage(for: book, allBooks: allBooks)
    }
}

// MARK: - PART 3: VALIDATION + UTILITIES

extension EstimationEngine {
    // MARK: - Final Validation Layer

    /// Ensures all outputs are deterministic and bounded.
    static func validate(result: BookEstimationResult) -> BookEstimationResult {
        let safeRemaining = max(0, result.remainingSeconds)
        let safeHours = max(0, result.remainingHours)

        let safeSessions = max(0, result.expectedSessionDuration)
        let safePages = max(0, result.expectedPagesPerSession)

        let safeProbability = min(1.0, max(0.0, result.probabilityFinishChapterInOneSession))

        let cleanedChapters = result.chapterEstimates.map {
            ChapterEstimation(
                chapterID: $0.chapterID,
                estimatedSeconds: max(0, $0.estimatedSeconds),
                estimatedFormatted: $0.estimatedFormatted,
                pages: max(0, $0.pages),
                completionDate: $0.completionDate
            )
        }

        return BookEstimationResult(
            remainingSeconds: safeRemaining,
            remainingHours: safeHours,
            formattedRemaining: result.formattedRemaining,

            estimatedCompletionDate: result.estimatedCompletionDate,
            estimatedDaysRemaining: result.estimatedDaysRemaining,

            expectedSessionDuration: safeSessions,
            expectedPagesPerSession: safePages,

            probabilityFinishChapterInOneSession: safeProbability,

            speedModel: result.speedModel,
            confidence: result.confidence,

            chapterEstimates: cleanedChapters,

            provenance: result.provenance
        )
    }

    // MARK: - Debug Snapshot (optional utility)

    static func debugSnapshot(for book: Book, allBooks: [Book]) -> String {
        let result = estimate(for: book, allBooks: allBooks)

        return """
        --- EstimationEngine Snapshot ---
        Book: \(book.title)
        Remaining Hours: \(result.remainingHours)
        Remaining Seconds: \(result.remainingSeconds)
        Finish Date: \(result.estimatedCompletionDate)
        Confidence: \(result.confidence.score) (\(result.confidence.level))
        Status: \(result.provenance.status.rawValue)
        Model: \(result.provenance.modelVersion)
        Speed: \(result.speedModel.effectiveSpeed)s/page
        Volatility: \(result.speedModel.volatility)
        Chapters: \(result.chapterEstimates.count)
        ----------------------------------
        """
    }
}
