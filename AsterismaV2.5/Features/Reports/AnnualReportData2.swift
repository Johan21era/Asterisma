//  AnnualReportData2.swift
//  AsterismaV2.5
//
//  Annual Reading Report — data model and generator.
//
//  ARCHITECTURE
//  This file is a PRESENTATION LAYER, not an analytics engine.
//  It gathers outputs from existing engines and packages them for display.
//  It does not reimplement any computation that already exists.
//
//  DATA SOURCES (all consumed, none reimplemented)
//    • AnalyticsEngine          — reading speed, time, pages, streak, trend,
//                                 time-of-day, improvement, genre, profile
//    • AchievementEngine        — earned achievements and milestone history
//    • InsightEngine            — narrative signals
//    • ReadingGoalManager       — goal completion status
//    • Book / ReadingSession    — raw session history, book metadata
//
//  REPORT GENERATION MODEL
//  Reports are generated once when opened and held in memory.
//  They are not persisted, cached to disk, or exported.
//  The archive stores only the list of years with sessions; report payloads
//  are always regenerated from live data.

import Foundation

// MARK: - Year Range Helpers

/// Returns a custom AnalyticsPeriod for a specific calendar year.
///
/// AUDIT F-01 (Phase 1): both `date(from:)` constructions here were force-unwrapped.
/// `Calendar.current` reflects the user's region calendar setting and these
/// constructors are documented-fallible — the same defect class as §5.1's thirteen
/// fixed sites, missed because that sweep enumerated only AnalyticsEngine and
/// ReadingGoalManager2. Degradation mirrors this file's own `daysInCalendarYear`
/// convention: never crash, fall back to sane bounds.
///
/// The `calendar` parameter is additive/defaulted so the regression suite can drive
/// Hebrew/Japanese/Islamic calendars deterministically instead of depending on the
/// test host's locale (TESTING_STRATEGY — Calendar/locale edge cases).
func analyticsPeriod(for year: Int, calendar: Calendar = .current) -> AnalyticsPeriod {
    var comps = DateComponents()
    comps.year = year
    comps.month = 1
    comps.day = 1

    // Degradation 1: unrepresentable year start → same-day range (never nil-crash).
    guard let start = calendar.date(from: comps) else {
        let fallback = calendar.startOfDay(for: Date())
        return .custom(start: fallback, end: fallback)
    }

    comps.year = year + 1

    // Degradation 2: unrepresentable next-year start → pure-arithmetic upper bound,
    // mirroring daysInCalendarYear's arithmetic fallback style.
    let nextStart = calendar.date(from: comps)
        ?? start.addingTimeInterval(366 * 86_400)
    return .custom(start: start, end: nextStart - 1)
}

/// Filters sessions to those that started within a calendar year.
func sessions(in books: [Book], year: Int) -> [ReadingSession] {
    let period = analyticsPeriod(for: year)
    let range = period.dateRange
    return books.flatMap(\.sessions).filter { s in
        guard let end = s.endTime else { return false }
        return s.startTime >= range.lowerBound && s.startTime <= range.upperBound
    }
}

/// Books that had at least one completed session in the given year.
func booksRead(in books: [Book], year: Int) -> [Book] {
    let yearSessions = sessions(in: books, year: year)
    let bookIDs = Set(yearSessions.map(\.bookID))
    return books.filter { bookIDs.contains($0.id) }
}

/// Books completed in the given year.
func booksCompleted(in books: [Book], year: Int) -> [Book] {
    let period = analyticsPeriod(for: year)
    let range = period.dateRange
    return books.filter { book in
        guard book.isCompleted else { return false }
        return book.lastReadDate.map { range.contains($0) } ?? false
    }
}

// MARK: - Annual Report Data

/// The complete data payload for a single year's annual reading report.
/// Generated once, held in @StateObject, passed read-only to slides.
struct AnnualReportData {
    let year: Int
    let generatedAt: Date

    // MARK: Slide 1 — Volume: How much did I read?

    let totalReadingTime: TimeInterval // Source: AnalyticsEngine.readingTime
    let totalPagesRead: Int // Source: AnalyticsEngine.pagesRead
    let totalBooksStarted: Int // Source: booksRead(year:)
    let totalBooksCompleted: Int // Source: booksCompleted(year:)
    let totalReadingDays: Int // Source: distinct calendar days with sessions
    let totalSessions: Int // Source: sessions(year:).count

    // MARK: Slide 2 — Rhythm: When did I read?

    let timeOfDayAnalysis: TimeOfDayAnalytics // Source: AnalyticsEngine.timeOfDayAnalysis
    let bestReadingWindow: ReadingWindow // Source: timeOfDayAnalysis.bestWindow
    let dailyActivityForYear: [DailyActivity] // Source: AnalyticsEngine.dailyActivity (year-filtered)
    let mostActiveDayOfWeek: Int // Source: computed from sessions
    let longestSingleSession: TimeInterval // Source: max session duration in year
    let averageSessionLength: TimeInterval // Source: mean session duration

    // MARK: Slide 3 — Library: What did I read?

    let booksReadThisYear: [Book] // Source: booksRead(year:)
    let booksCompletedThisYear: [Book] // Source: booksCompleted(year:)
    let genreSummary: GenreAnalyticsSummary // Source: AnalyticsEngine.genreSummary (year subset)
    let dominantGenre: ReadingGenre? // Source: genreSummary.dominantGenre
    let formatBreakdown: (epub: Int, pdf: Int, comic: Int) // Source: booksReadThisYear partition by fileType

    // MARK: Slide 4 — Pace: How did I read?

    let averageSecondsPerPage: Double // Source: AnalyticsEngine.crossBookReadingSpeed
    let speedTrend: TrendAnalytics // Source: AnalyticsEngine.trendAnalysis (year subset)
    let improvementAnalysis: ImprovementAnalytics // Source: AnalyticsEngine.improvementAnalysis
    let averagePagesPerHour: Double // Source: readerProfile.averagePagesPerHour

    // MARK: Slide 5 — Highlights: Which books mattered most?

    let mostReadBook: Book? // Source: most total time in year
    let longestBook: Book? // Source: most pages among completed
    let fastestBook: Book? // Source: fastest avg seconds/page
    let deepestBook: Book? // Source: slowest avg seconds/page (most deliberate)

    // MARK: Slide 6 — Streak & Consistency

    let streak: ReadingStreak // Source: AnalyticsEngine.streak
    let longestYearStreak: Int // Source: computed from year sessions only
    let readingDaysPercentage: Double // Source: totalReadingDays / daysInYear
    let weeklyPatternScores: [Int: Double] // Source: weekday → avg session duration

    // MARK: Slide 7 — Achievements

    let achievementsEarnedThisYear: [EarnedAchievement] // Source: EarnedAchievements filtered to year
    let totalAchievementsEarned: Int // Source: achievementsEarnedThisYear.count
    let highestTierEarned: AchievementDefinition.AchievementTier? // Source: max tier in year

    // MARK: Slide 8 — Goals

    let annualGoalStatus: GoalStatus? // Source: ReadingGoalManager.annualBookStatus
    let goalMetCount: Int // Source: statuses where isAchieved
    let hadAnnualGoal: Bool // Source: goalSet.annualBookTarget != nil
    let annualBookTarget: Int? // Source: goalSet.annualBookTarget

    // MARK: Slide 9 — Narrative: Who did I become as a reader?

    let narrativeProfile: ReaderNarrativeProfile // Source: deterministic from all metrics

    // MARK: Slide 10 — Audio Environment: What was the soundtrack to your reading?

    /// nil when audioProfiles were not passed to generate() or fewer than 3 audio-linked
    /// sessions exist for the year. MusicalAnalysisEngine is the authoritative source.
    let audioReport: AudioAnnualReport? // Source: MusicalAnalysisEngine.generateAnnualReport
}

// MARK: - Reader Narrative Profile

/// A fully deterministic narrative derived from measurable evidence.
/// No AI, no language models, no generated prose, no random observations.
/// Every field has an identifiable source in the analytics engines.
struct ReaderNarrativeProfile {
    // Reading Identity
    let identityLabel: String // e.g. "Consistent Evening Reader"
    let identitySubtitle: String // supporting evidence phrase

    // Key stats that define the year
    let standoutStat: String // the single most impressive measurement
    let standoutContext: String // what that measurement means

    // Trajectory
    let trajectoryLabel: String // "Growing", "Consistent", "Rebuilding"
    let trajectoryDetail: String // one-sentence evidence

    // Character observation (from data)
    let characterObservation: String // e.g. "You finish what you start." based on completion rate
    let characterEvidence: String // backing statistic

    // Growth signal
    let growthSignal: String? // nil if insufficient data for year-over-year
    let growthDetail: String?
}

// MARK: - AnnualReportGenerator

enum AnnualReportGenerator {
    /// Generates the complete report data for the given year from live DataStore state.
    /// This is the only entry point. Call once; store result in @StateObject.
    ///
    /// - Parameters:
    ///   - year: Calendar year (e.g. 2025)
    ///   - books: All books in the library (from DataStore.books)
    ///   - goalSet: The user's reading goal configuration
    ///   - earnedAchievements: All earned achievements from LibraryState
    static func generate(
        year: Int,
        books: [Book],
        goalSet: ReadingGoalSet,
        earnedAchievements: [EarnedAchievement],
        audioProfiles: [AudioContextProfile] = []
    ) -> AnnualReportData {
        let calendar = Calendar.current
        let period = analyticsPeriod(for: year)
        let yearRange = period.dateRange

        // ── Filter to year ────────────────────────────────────────────────
        let yearBooks = booksRead(in: books, year: year)
        let yearCompleted = booksCompleted(in: books, year: year)
        let yearSessions = sessions(in: books, year: year).filter { $0.endTime != nil }

        // ── Slide 1: Volume ───────────────────────────────────────────────
        let totalTime = AnalyticsEngine.readingTime(books: books, in: period)
        let totalPages = AnalyticsEngine.pagesRead(books: books, in: period)
        let totalDays = distinctReadingDays(sessions: yearSessions, calendar: calendar)
        let totalSessions = yearSessions.count

        // ── Slide 2: Rhythm ───────────────────────────────────────────────
        // Build a year-subset books array so time-of-day analysis uses only year data.
        let yearSubsetBooks = booksWithYearSessions(books: yearBooks, yearSessions: yearSessions)
        let todAnalysis = AnalyticsEngine.timeOfDayAnalysis(books: yearSubsetBooks)
        let dailyActivity = dailyActivityForYear(yearSessions: yearSessions, year: year, calendar: calendar)
        let mostActiveDay = mostActiveDayOfWeek(sessions: yearSessions, calendar: calendar)
        let longestSession = yearSessions.map(\.duration).max() ?? 0
        let avgSession = yearSessions.isEmpty ? 0 :
            yearSessions.map(\.duration).reduce(0, +) / Double(yearSessions.count)

        // ── Slide 3: Library ──────────────────────────────────────────────
        let yearGenreBooks = yearSubsetBooks
        let genreSummary = AnalyticsEngine.genreSummary(from: yearGenreBooks)
        let epubCount = yearBooks.filter { $0.fileType == .epub }.count
        let pdfCount = yearBooks.filter { $0.fileType == .pdf }.count

        // ── Slide 4: Pace ─────────────────────────────────────────────────
        let crossSpeed = AnalyticsEngine.crossBookReadingSpeed(allBooks: yearSubsetBooks)
        let trendAnalysis = AnalyticsEngine.trendAnalysis(books: yearSubsetBooks)
        let improvement = AnalyticsEngine.improvementAnalysis(books: yearSubsetBooks)
        let profile = AnalyticsEngine.readerProfile(books: yearSubsetBooks)

        // ── Slide 5: Highlights ───────────────────────────────────────────
        let mostRead = mostReadBook(yearBooks: yearBooks, yearSessions: yearSessions)
        let longest = yearCompleted.max(by: { $0.totalPages < $1.totalPages })
        let fastest = fastestBook(yearBooks: yearBooks, yearSessions: yearSessions)
        let deepest = deepestBook(yearBooks: yearBooks, yearSessions: yearSessions)

        // ── Slide 6: Streak & Consistency ────────────────────────────────
        let overallStreak = AnalyticsEngine.streak(books: books)
        let yearStreakLen = longestStreakInYear(sessions: yearSessions, calendar: calendar)
        let daysInYear = daysInCalendarYear(year)
        let readingDaysPct = daysInYear > 0 ? Double(totalDays) / Double(daysInYear) : 0
        let weeklyPattern = weeklyPatternScores(sessions: yearSessions, calendar: calendar)

        // ── Slide 7: Achievements ─────────────────────────────────────────
        let yearAchievements = earnedAchievements.filter { a in
            yearRange.contains(a.earnedAt)
        }
        let highestTier = highestAchievementTier(achievements: yearAchievements)

        // ── Slide 8: Goals ────────────────────────────────────────────────
        // Build a goal status for this year specifically.
        let annualStatus = goalSet.annualBookTarget.map { target -> GoalStatus in
            let cur = Double(yearCompleted.count)
            let tgt = Double(target)
            return GoalStatus(
                goal: .annualBooks,
                current: cur,
                target: tgt,
                period: String(year),
                isAchieved: cur >= tgt,
                percentComplete: (cur / max(1, tgt)).clamped(to: 0 ... 1)
            )
        }
        let allGoalStatuses = ReadingGoalManager.allStatuses(for: goalSet, books: yearSubsetBooks)
        let metCount = allGoalStatuses.filter(\.isAchieved).count

        // ── Slide 10: Audio Environment ───────────────────────────────────
        // Builds only when AudioContextProfile data is available for this year.
        // Requires at least 3 audio-linked sessions to produce a meaningful report.
        let audioReport: AudioAnnualReport? = {
            guard !audioProfiles.isEmpty else { return nil }
            let yearProfiles = audioProfiles.filter { profile in
                Calendar.current.component(.year, from: profile.createdAt) == year
            }
            guard !yearProfiles.isEmpty else { return nil }
            let audioRecords = MusicalAnalysisEngine.buildSessionRecords(
                books: yearBooks,
                audioProfiles: yearProfiles,
                allBooks: books
            )
            guard audioRecords.count >= 3 else { return nil }
            return MusicalAnalysisEngine().generateAnnualReport(year: year, records: audioRecords)
        }()

        // ── Slide 9: Narrative ────────────────────────────────────────────
        let narrative = buildNarrative(
            year: year,
            totalTime: totalTime,
            totalPages: totalPages,
            totalBooksCompleted: yearCompleted.count,
            totalDays: totalDays,
            avgSession: avgSession,
            bestWindow: todAnalysis.bestWindow,
            readingDaysPct: readingDaysPct,
            trend: trendAnalysis,
            improvement: improvement,
            longestStreak: yearStreakLen,
            profile: profile,
            crossSpeed: crossSpeed,
            completionRate: yearBooks.isEmpty ? 0 : Double(yearCompleted.count) / Double(yearBooks.count)
        )

        return AnnualReportData(
            year: year,
            generatedAt: Date(),
            totalReadingTime: totalTime,
            totalPagesRead: totalPages,
            totalBooksStarted: yearBooks.count,
            totalBooksCompleted: yearCompleted.count,
            totalReadingDays: totalDays,
            totalSessions: totalSessions,
            timeOfDayAnalysis: todAnalysis,
            bestReadingWindow: todAnalysis.bestWindow,
            dailyActivityForYear: dailyActivity,
            mostActiveDayOfWeek: mostActiveDay,
            longestSingleSession: longestSession,
            averageSessionLength: avgSession,
            booksReadThisYear: yearBooks,
            booksCompletedThisYear: yearCompleted,
            genreSummary: genreSummary,
            dominantGenre: genreSummary.dominantGenre,
            formatBreakdown: (epubCount, pdfCount, yearBooks.filter { $0.fileType.isComic }.count),
            averageSecondsPerPage: crossSpeed,
            speedTrend: trendAnalysis,
            improvementAnalysis: improvement,
            averagePagesPerHour: profile.averagePagesPerHour,
            mostReadBook: mostRead,
            longestBook: longest,
            fastestBook: fastest,
            deepestBook: deepest,
            streak: overallStreak,
            longestYearStreak: yearStreakLen,
            readingDaysPercentage: readingDaysPct,
            weeklyPatternScores: weeklyPattern,
            achievementsEarnedThisYear: yearAchievements,
            totalAchievementsEarned: yearAchievements.count,
            highestTierEarned: highestTier,
            annualGoalStatus: annualStatus,
            goalMetCount: metCount,
            hadAnnualGoal: goalSet.annualBookTarget != nil,
            annualBookTarget: goalSet.annualBookTarget,
            narrativeProfile: narrative,
            audioReport: audioReport
        )
    }

    // MARK: - Private Helpers

    /// Reconstructs a minimal [Book] array where each book has only year-period sessions.
    /// This lets us pass "year-only" data into AnalyticsEngine functions that expect [Book].
    private static func booksWithYearSessions(
        books: [Book],
        yearSessions: [ReadingSession]
    ) -> [Book] {
        let sessionsByBook = Dictionary(grouping: yearSessions, by: \.bookID)
        return books.compactMap { book -> Book? in
            guard let bookSessions = sessionsByBook[book.id], !bookSessions.isEmpty else {
                return nil
            }
            var copy = book
            copy.sessions = bookSessions
            return copy
        }
    }

    /// Count of distinct calendar days that had at least one completed session.
    private static func distinctReadingDays(
        sessions: [ReadingSession],
        calendar: Calendar
    ) -> Int {
        Set(sessions.compactMap { s -> Date? in
            guard s.endTime != nil else { return nil }
            return calendar.startOfDay(for: s.startTime)
        }).count
    }

    /// Builds DailyActivity array for the full calendar year (365/366 entries).
    private static func dailyActivityForYear(
        yearSessions: [ReadingSession],
        year: Int,
        calendar: Calendar
    ) -> [DailyActivity] {
        var comps = DateComponents()
        comps.year = year; comps.month = 1; comps.day = 1
        guard let yearStart = calendar.date(from: comps) else { return [] }

        let days = daysInCalendarYear(year)
        var buckets: [Date: (duration: TimeInterval, pages: Int, bookIDs: Set<UUID>)] = [:]

        for session in yearSessions {
            guard session.endTime != nil else { continue }
            let day = calendar.startOfDay(for: session.startTime)
            var entry = buckets[day] ?? (0, 0, [])
            entry.duration += session.duration
            entry.pages += session.pagesRead
            entry.bookIDs.insert(session.bookID)
            buckets[day] = entry
        }

        return (0 ..< days).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: yearStart) else { return nil }
            let entry = buckets[date] ?? (0, 0, [])
            return DailyActivity(
                date: date,
                totalDuration: entry.duration,
                pagesRead: entry.pages,
                booksRead: entry.bookIDs
            )
        }
    }

    private static func mostActiveDayOfWeek(
        sessions: [ReadingSession],
        calendar: Calendar
    ) -> Int {
        var daySums: [Int: Double] = [:]
        for session in sessions {
            let weekday = calendar.component(.weekday, from: session.startTime)
            daySums[weekday, default: 0] += session.duration
        }
        return daySums.max(by: { $0.value < $1.value })?.key ?? 1
    }

    private static func weeklyPatternScores(
        sessions: [ReadingSession],
        calendar: Calendar
    ) -> [Int: Double] {
        var dayTotals: [Int: (sum: Double, count: Int)] = [:]
        for session in sessions {
            let weekday = calendar.component(.weekday, from: session.startTime)
            var entry = dayTotals[weekday] ?? (0, 0)
            entry.sum += session.duration
            entry.count += 1
            dayTotals[weekday] = entry
        }
        var result: [Int: Double] = [:]
        for (day, data) in dayTotals {
            result[day] = data.count > 0 ? data.sum / Double(data.count) : 0
        }
        return result
    }

    private static func mostReadBook(
        yearBooks: [Book],
        yearSessions: [ReadingSession]
    ) -> Book? {
        let sessionsByBook = Dictionary(grouping: yearSessions, by: \.bookID)
        return yearBooks.max { a, b in
            let aTime = (sessionsByBook[a.id] ?? []).reduce(0) { $0 + $1.duration }
            let bTime = (sessionsByBook[b.id] ?? []).reduce(0) { $0 + $1.duration }
            return aTime < bTime
        }
    }

    private static func fastestBook(
        yearBooks: [Book],
        yearSessions: [ReadingSession]
    ) -> Book? {
        let sessionsByBook = Dictionary(grouping: yearSessions, by: \.bookID)
        return yearBooks
            .filter { book in
                guard let s = sessionsByBook[book.id] else { return false }
                return s.reduce(0) { $0 + $1.pagesRead } > 10
            }
            .min { a, b in
                let aSpeed = averageSpeed(book: a, sessions: sessionsByBook[a.id] ?? [])
                let bSpeed = averageSpeed(book: b, sessions: sessionsByBook[b.id] ?? [])
                return aSpeed < bSpeed
            }
    }

    private static func deepestBook(
        yearBooks: [Book],
        yearSessions: [ReadingSession]
    ) -> Book? {
        let sessionsByBook = Dictionary(grouping: yearSessions, by: \.bookID)
        return yearBooks
            .filter { book in
                guard let s = sessionsByBook[book.id] else { return false }
                return s.reduce(0) { $0 + $1.pagesRead } > 10
            }
            .max { a, b in
                let aSpeed = averageSpeed(book: a, sessions: sessionsByBook[a.id] ?? [])
                let bSpeed = averageSpeed(book: b, sessions: sessionsByBook[b.id] ?? [])
                return aSpeed < bSpeed
            }
    }

    private static func averageSpeed(book _: Book, sessions: [ReadingSession]) -> Double {
        // E2: the same documented policy as every other speed consumer — a
        // reader is never slower than the policy allows merely because of a
        // universal one-minute ceiling.
        PageDurationPolicy.robustMeanSeconds(sessions.flatMap(\.pageTimes).map(\.duration))
            ?? AnalyticsConstants.defaultSecondsPerPage
    }

    private static func longestStreakInYear(
        sessions: [ReadingSession],
        calendar: Calendar
    ) -> Int {
        let days = Set(sessions.compactMap { s -> Date? in
            guard s.endTime != nil else { return nil }
            return calendar.startOfDay(for: s.startTime)
        }).sorted()

        guard !days.isEmpty else { return 0 }

        var longest = 1
        var current = 1
        for i in 1 ..< days.count {
            let diff = calendar.dateComponents([.day], from: days[i - 1], to: days[i]).day ?? 0
            if diff == 1 {
                current += 1
                longest = max(longest, current)
            } else {
                current = 1
            }
        }
        return longest
    }

    private static func daysInCalendarYear(_ year: Int) -> Int {
        var comps = DateComponents()
        comps.year = year; comps.month = 1; comps.day = 1
        let calendar = Calendar.current
        guard let start = calendar.date(from: comps) else { return 365 }
        comps.year = year + 1
        guard let end = calendar.date(from: comps) else { return 365 }
        return calendar.dateComponents([.day], from: start, to: end).day ?? 365
    }

    private static func highestAchievementTier(
        achievements: [EarnedAchievement]
    ) -> AchievementDefinition.AchievementTier? {
        let tiers = achievements.compactMap { a in
            AchievementDefinition.definition(for: a.kind)?.tier
        }
        // Platinum > Gold > Silver > Bronze
        if tiers.contains(.platinum) {
            return .platinum
        }
        if tiers.contains(.gold) {
            return .gold
        }
        if tiers.contains(.silver) {
            return .silver
        }
        if tiers.contains(.bronze) {
            return .bronze
        }
        return nil
    }

    // MARK: - Narrative Builder

    /// Builds a deterministic narrative profile from measured evidence.
    /// Every claim maps to a specific metric. No fabrication.
    private static func buildNarrative(
        year: Int,
        totalTime: TimeInterval,
        totalPages: Int,
        totalBooksCompleted: Int,
        totalDays _: Int,
        avgSession: TimeInterval,
        bestWindow: ReadingWindow,
        readingDaysPct: Double,
        trend: TrendAnalytics,
        improvement: ImprovementAnalytics,
        longestStreak: Int,
        profile _: ReaderProfileAnalytics,
        crossSpeed _: Double,
        completionRate: Double
    ) -> ReaderNarrativeProfile {
        // ── Identity ──────────────────────────────────────────────────────
        let windowName = windowDisplayName(bestWindow)

        let identityLabel: String
        let identitySubtitle: String

        switch (readingDaysPct, avgSession, bestWindow) {
        case let (pct, _, _) where pct >= 0.80:
            identityLabel = "The Daily Reader"
            identitySubtitle = "You read on \(Int(readingDaysPct * 100))% of all days in \(year)."
        case let (_, avg, _) where avg >= 3600:
            identityLabel = "The Deep Diver"
            identitySubtitle = "Your average session ran over an hour — you read in long, immersive blocks."
        case (_, _, .morning):
            identityLabel = "The Morning Reader"
            identitySubtitle = "Your most productive sessions consistently happened in the morning."
        case (_, _, .night):
            identityLabel = "The Night Owl"
            identitySubtitle = "You did most of your reading after dark, when the world was quiet."
        case (_, _, .evening):
            identityLabel = "The Evening Reader"
            identitySubtitle = "You settled into your reading habit in the evenings."
        case let (pct, _, _) where pct >= 0.40:
            identityLabel = "The Steady Reader"
            identitySubtitle = "You read consistently across the year, making it a real habit."
        default:
            identityLabel = "The Intentional Reader"
            identitySubtitle = "When you picked up a book, you made it count."
        }

        // ── Standout Stat ─────────────────────────────────────────────────
        let standoutStat: String
        let standoutContext: String

        let hours = Int(totalTime / 3600)
        let minutes = Int((totalTime.truncatingRemainder(dividingBy: 3600)) / 60)

        if longestStreak >= 30 {
            standoutStat = "\(longestStreak)-day streak"
            standoutContext = "You read every single day for \(longestStreak) consecutive days in \(year). That kind of momentum is rare."
        } else if totalBooksCompleted >= 20 {
            standoutStat = "\(totalBooksCompleted) books finished"
            standoutContext = "Completing \(totalBooksCompleted) books in a year puts you well ahead of most readers."
        } else if totalPages >= 5000 {
            standoutStat = "\(totalPages.formatted()) pages"
            standoutContext = "You turned more than \(totalPages.formatted()) pages in \(year). That's a serious body of reading."
        } else if hours >= 100 {
            let formatted = hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
            standoutStat = formatted + " reading"
            standoutContext = "You spent over \(hours) hours reading in \(year) — more than four full days of your life."
        } else {
            let formatted = hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
            standoutStat = formatted + " reading"
            standoutContext = "Every minute counted: \(formatted) of focused reading added up across your year."
        }

        // ── Trajectory ────────────────────────────────────────────────────
        let trajectoryLabel: String
        let trajectoryDetail: String

        switch trend.direction {
        case .growth:
            let pct = Int(trend.dailyTrend * 100)
            trajectoryLabel = "Growing"
            trajectoryDetail = "Your reading pace increased by about \(pct)% over the course of the year."
        case .decline:
            let pct = Int(abs(trend.dailyTrend) * 100)
            trajectoryLabel = "Ebbing"
            trajectoryDetail = "Your reading pace slowed by about \(pct)% through the year — a natural rhythm, not a failure."
        case .plateau:
            trajectoryLabel = "Consistent"
            trajectoryDetail = "Your reading pace was remarkably steady all year — a sign of a well-anchored habit."
        }

        // ── Character Observation ─────────────────────────────────────────
        let characterObservation: String
        let characterEvidence: String

        switch completionRate {
        case 0.8...:
            characterObservation = "You finish what you start."
            characterEvidence = "\(Int(completionRate * 100))% of the books you picked up this year, you finished."
        case 0.5 ..< 0.8:
            characterObservation = "You're selective about what holds your attention."
            characterEvidence = "You completed \(totalBooksCompleted) books and left others behind when they weren't the right fit."
        case 0 ..< 0.5 where totalBooksCompleted >= 3:
            characterObservation = "You read widely and move on."
            characterEvidence = "You explored many books and finished the ones that truly grabbed you."
        default:
            if avgSession >= 1800 {
                characterObservation = "When you read, you commit."
                characterEvidence = "Your sessions averaged \(Int(avgSession / 60)) minutes — substantial, focused blocks."
            } else {
                characterObservation = "You fit reading into the margins of life."
                characterEvidence = "Shorter sessions still accumulated into real reading time across the year."
            }
        }

        // ── Growth Signal (only if meaningful improvement exists) ─────────
        let growthSignal: String?
        let growthDetail: String?

        if improvement.speedImprovement > 0.10 {
            let pct = Int(improvement.speedImprovement * 100)
            growthSignal = "You got faster."
            growthDetail = "Your reading speed improved by \(pct)% over the year — the result of consistent practice."
        } else if improvement.enduranceImprovement > 0.15 {
            let pct = Int(improvement.enduranceImprovement * 100)
            growthSignal = "Your endurance grew."
            growthDetail = "Your sessions got \(pct)% longer on average — you're sustaining focus better than you did at the start of the year."
        } else if longestStreak >= 7 {
            growthSignal = "You built a real habit."
            growthDetail = "A \(longestStreak)-day streak doesn't happen by accident. You made reading a consistent part of your life."
        } else {
            growthSignal = nil
            growthDetail = nil
        }

        return ReaderNarrativeProfile(
            identityLabel: identityLabel,
            identitySubtitle: identitySubtitle,
            standoutStat: standoutStat,
            standoutContext: standoutContext,
            trajectoryLabel: trajectoryLabel,
            trajectoryDetail: trajectoryDetail,
            characterObservation: characterObservation,
            characterEvidence: characterEvidence,
            growthSignal: growthSignal,
            growthDetail: growthDetail
        )
    }

    private static func windowDisplayName(_ window: ReadingWindow) -> String {
        switch window {
        case .morning: return "Morning"
        case .afternoon: return "Afternoon"
        case .evening: return "Evening"
        case .night: return "Night"
        }
    }
}

// MARK: - Available Report Years

/// Returns the set of calendar years that have at least one completed reading session.
/// This is what the archive displays.
func availableReportYears(books: [Book]) -> [Int] {
    let calendar = Calendar.current
    let years = Set(
        books.flatMap(\.sessions)
            .compactMap(\.endTime)
            .map { calendar.component(.year, from: $0) }
    )
    return years.sorted(by: >) // Most recent first
}

// MARK: - Format Helpers (shared across report slides)

func formatDuration(_ seconds: TimeInterval) -> String {
    let totalMinutes = Int(seconds / 60)
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if hours > 0 {
        return "\(hours)h \(minutes)m"
    }
    return "\(minutes)m"
}

func formatDurationVerbose(_ seconds: TimeInterval) -> String {
    let hours = Int(seconds / 3600)
    let minutes = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
    if hours > 0 {
        return "\(hours) hours, \(minutes) minutes"
    }
    return "\(minutes) minutes"
}

func weekdayName(_ weekday: Int) -> String {
    // Calendar.weekday is 1=Sunday…7=Saturday
    switch weekday {
    case 1: return "Sunday"
    case 2: return "Monday"
    case 3: return "Tuesday"
    case 4: return "Wednesday"
    case 5: return "Thursday"
    case 6: return "Friday"
    case 7: return "Saturday"
    default: return "—"
    }
}
