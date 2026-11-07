//  InsightEngine.swift
//  AsterismaV2.5
//
//  PURPOSE
//  Generates human-readable, actionable insights from analytics data.
//  Transforms raw numbers into narrative cards the user can act on.
//
//  RATIONALE
//  AnalyticsEngine produces values. InsightEngine produces meaning.
//  A user seeing "avg 47s/page" doesn't know if that's fast or slow.
//  An insight saying "You read 20% faster in the morning — try scheduling
//  your sessions before noon" is immediately actionable.
//
//  Without InsightEngine, the analytics surface is data-dumping.
//  With it, the app becomes a reading coach.
//
//  DESIGN
//  • Insights are declarative ReadingInsight structs with a kind, title,
//    body, actionSuggestion, and confidence level.
//  • The engine generates insights from all available analytics dimensions:
//    time-of-day, trend, difficulty, streak, peer-comparison (same genre),
//    goal progress, improvement trajectory, and prediction reliability.
//  • Insights are filtered by confidence threshold before display so the UI
//    never shows low-confidence noise.
//  • All insight generation is pure (no state, no side effects).
//
//  CALLERS
//    • Stats/insights UI views — display insight cards
//    • ReadingGoalManager — augments with goal-specific insights
//    • AchievementEngine — cross-references for motivational messaging
//
//  INTERACTIONS
//    • Reads AnalyticsEngine (all subsystems)
//    • Reads ReadingGoalManager for goal context
//    • Reads SharedTextUtilities.ReadingComplexityHints for difficulty signals

import Foundation

// MARK: - Insight Models

/// A human-readable insight card derived from analytics.
struct ReadingInsight: Identifiable {
    var id: UUID = .init()
    let kind: InsightKind
    let title: String
    let body: String
    let actionSuggestion: String? // nil = purely informational
    let confidence: Double // 0–1; filter at 0.4 before display
    let priority: InsightPriority // determines display order

    enum InsightKind: String {
        case bestReadingTime = "Best Reading Time"
        case readingTrend = "Reading Trend"
        case difficultyMatch = "Difficulty Match"
        case streakRisk = "Streak at Risk"
        case speedImprovement = "Speed Improvement"
        case goalOnTrack = "Goal on Track"
        case goalBehind = "Goal Behind"
        case sessionLength = "Session Length"
        case predictionQuality = "Prediction Reliability"
        case genrePattern = "Genre Pattern"
        case milestoneNear = "Milestone Near"
        case consistencyReward = "Consistency"
        case drySpell = "Reading Dry Spell"
    }

    enum InsightPriority: Int, Comparable {
        case critical = 0 // streak at risk, goal overdue
        case high = 1 // goal behind, dry spell
        case medium = 2 // trend, improvement
        case low = 3 // informational patterns

        static func < (lhs: InsightPriority, rhs: InsightPriority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }
}

// MARK: - InsightEngine

/// Pure computation namespace. All methods return insights from analytics data.
enum InsightEngine {
    /// Minimum confidence threshold for an insight to be included in results.
    static let minimumConfidence: Double = 0.35

    // MARK: - Primary Entry Point

    /// Generates all applicable insights for the given books and goal context.
    /// Returns insights sorted by priority (critical first) and filtered by confidence.
    ///
    /// - Parameters:
    ///   - books: Full library.
    ///   - goalSet: User's current reading goals.
    ///   - earnedAchievements: For milestone-near insights.
    /// - Returns: Array of insights sorted by priority descending.
    static func generateAll(
        books: [Book],
        goalSet: ReadingGoalSet,
        earnedAchievements: [EarnedAchievement] = [],
        epoch: UInt64 = 0
    ) -> [ReadingInsight] {
        var insights: [ReadingInsight] = []

        // Only generate meaningful insights if there's sufficient data.
        guard !books.isEmpty else { return [] }

        // G1: callers may pass the store epoch; 0 remains the uncached fallback.
        let profile = AnalyticsEngine.readerProfile(books: books, epoch: epoch)
        let streak = AnalyticsEngine.streak(books: books, epoch: epoch)
        let trend = AnalyticsEngine.trendAnalysis(books: books, epoch: epoch)
        let todOfDay = AnalyticsEngine.timeOfDayAnalysis(books: books, epoch: epoch)
        let improvement = AnalyticsEngine.improvementAnalysis(books: books)

        insights += bestReadingTimeInsight(todOfDay: todOfDay, profile: profile)
        insights += trendInsight(trend: trend, profile: profile)
        insights += streakInsight(streak: streak)
        insights += improvementInsight(improvement: improvement, profile: profile)
        insights += sessionLengthInsight(profile: profile)
        insights += predictionQualityInsight(books: books)
        insights += goalInsights(books: books, goalSet: goalSet, profile: profile)
        insights += milestoneNearInsight(books: books, earned: earnedAchievements)
        insights += drySpellInsight(streak: streak, activity: AnalyticsEngine.dailyActivity(books: books, days: 14))

        // Each of the nine builder functions above still computes its own
        // ad hoc confidence exactly as before — that math is untouched.
        // What used to happen here (`.filter { $0.confidence >= minimumConfidence }`)
        // was a single flat threshold applied identically to a streak-risk
        // read-of-today and a genre-speed comparison, which is the "scattered,
        // ad hoc confidence threshold" problem DataMaturityEngine exists to
        // replace. DataMaturityInsightAdapter.gate builds a real evidence
        // digest per insight kind (from `books`' actual session history),
        // asks DataMaturityEngine per kind, clamps confidence to whatever it
        // allows, and sorts by priority — see DataMaturityEngineAdapters.swift.
        return DataMaturityInsightAdapter.gate(insights, books: books)
    }

    // MARK: - Best Reading Time

    private static func bestReadingTimeInsight(
        todOfDay: TimeOfDayAnalytics,
        profile: ReaderProfileAnalytics
    ) -> [ReadingInsight] {
        // Require at least 5 sessions to have meaningful time-of-day data.
        let confidence = min(1.0, profile.totalPagesRead > 50 ? 0.8 : 0.3)
        guard confidence >= minimumConfidence else { return [] }

        let windowName = windowLabel(todOfDay.bestWindow)
        let worstName = windowLabel(todOfDay.worstWindow)

        let bestScore = todOfDay.scores[todOfDay.bestWindow] ?? 0
        let worstScore = todOfDay.scores[todOfDay.worstWindow] ?? 0
        let delta = worstScore > 0 ? ((bestScore - worstScore) / worstScore) * 100 : 0

        guard delta > 10 else { return [] } // Don't surface if times are nearly equal.

        return [ReadingInsight(
            kind: .bestReadingTime,
            title: "You Read Best in the \(windowName)",
            body: "Your reading output in the \(windowName.lowercased()) is " +
                "\(Int(delta))% higher than the \(worstName.lowercased()). " +
                "Your pace is most consistent when you read during that time.",
            actionSuggestion: "Try to schedule your sessions in the \(windowName.lowercased()).",
            confidence: confidence,
            priority: .medium
        )]
    }

    private static func windowLabel(_ window: ReadingWindow) -> String {
        switch window {
        case .morning: return "Morning"
        case .afternoon: return "Afternoon"
        case .evening: return "Evening"
        case .night: return "Night"
        }
    }

    // MARK: - Trend Insight

    private static func trendInsight(
        trend: TrendAnalytics,
        profile: ReaderProfileAnalytics
    ) -> [ReadingInsight] {
        let confidence = min(1.0, Double(Int(profile.totalReadingTime / 3600)) / 10.0)
        guard confidence >= minimumConfidence else { return [] }

        switch trend.direction {
        case .growth:
            let pct = Int(trend.dailyTrend * 100)
            return [ReadingInsight(
                kind: .readingTrend,
                title: "Your Reading is Growing 📈",
                body: "You've increased your reading pace by about \(pct)% over the past 30 days. " +
                    "Keep it up — sustained growth like this compounds quickly over a year.",
                actionSuggestion: nil,
                confidence: confidence,
                priority: .low
            )]

        case .decline:
            let pct = Int(abs(trend.dailyTrend) * 100)
            return [ReadingInsight(
                kind: .readingTrend,
                title: "Reading Pace Has Slowed",
                body: "Your reading activity is down about \(pct)% compared to a month ago. " +
                    "Even short sessions — 10 minutes a day — prevent momentum loss.",
                actionSuggestion: "Set a small daily target to rebuild the habit.",
                confidence: confidence,
                priority: .high
            )]

        case .plateau:
            return [] // Plateau is uninteresting; don't surface it.
        }
    }

    // MARK: - Streak Insight

    private static func streakInsight(streak: ReadingStreak) -> [ReadingInsight] {
        guard let lastRead = streak.lastReadDate else { return [] }

        let daysSinceLast = Calendar.current.dateComponents([.day], from: lastRead, to: Date()).day ?? 0

        // Streak at risk: haven't read today and current streak > 3.
        if daysSinceLast == 1, streak.currentStreak >= 3 {
            return [ReadingInsight(
                kind: .streakRisk,
                title: "Your \(streak.currentStreak)-Day Streak is at Risk",
                body: "You haven't read today yet. Read anything — even one page — " +
                    "to keep your \(streak.currentStreak)-day streak alive.",
                actionSuggestion: "Open a book and read at least one page today.",
                confidence: 0.95,
                priority: .critical
            )]
        }

        // Consistency reward: active streak worth celebrating.
        if streak.currentStreak >= 7 {
            return [ReadingInsight(
                kind: .consistencyReward,
                title: "\(streak.currentStreak)-Day Reading Streak 🔥",
                body: "You've read every day for \(streak.currentStreak) consecutive days. " +
                    "Consistency is the single most reliable predictor of reading progress.",
                actionSuggestion: nil,
                confidence: 0.9,
                priority: .low
            )]
        }

        return []
    }

    // MARK: - Improvement Insight

    private static func improvementInsight(
        improvement: ImprovementAnalytics,
        profile: ReaderProfileAnalytics
    ) -> [ReadingInsight] {
        // Need sufficient session history for this to be meaningful.
        let confidence = min(1.0, Double(profile.totalPagesRead) / 500.0)
        guard confidence >= minimumConfidence else { return [] }

        if improvement.speedImprovement > 0.1 {
            let pct = Int(improvement.speedImprovement * 100)
            return [ReadingInsight(
                kind: .speedImprovement,
                title: "You're Reading \(pct)% Faster",
                body: "Comparing your recent sessions to your earlier ones, " +
                    "your reading speed has improved by \(pct)%. " +
                    "This is a natural result of consistent practice.",
                actionSuggestion: nil,
                confidence: confidence * 0.8,
                priority: .low
            )]
        }

        if improvement.enduranceImprovement > 0.15 {
            let pct = Int(improvement.enduranceImprovement * 100)
            return [ReadingInsight(
                kind: .sessionLength,
                title: "Your Sessions are Getting Longer",
                body: "Your average session duration has grown by \(pct)%, " +
                    "meaning you're sustaining focus for longer. " +
                    "This typically means you're deepening your reading habit.",
                actionSuggestion: nil,
                confidence: confidence * 0.75,
                priority: .low
            )]
        }

        return []
    }

    // MARK: - Session Length Insight

    private static func sessionLengthInsight(profile: ReaderProfileAnalytics) -> [ReadingInsight] {
        guard profile.averageSessionDuration > 0 else { return [] }
        let minutes = Int(profile.averageSessionDuration / 60)

        // Very short sessions might indicate interrupted reading.
        if minutes < 10, profile.totalPagesRead > 50 {
            return [ReadingInsight(
                kind: .sessionLength,
                title: "Short Sessions Detected",
                body: "Your average reading session is only \(minutes) minutes. " +
                    "Research suggests 20–30 minute sessions lead to better retention " +
                    "by allowing deeper engagement with the text.",
                actionSuggestion: "Try setting aside 20 uninterrupted minutes per session.",
                confidence: 0.6,
                priority: .medium
            )]
        }

        return []
    }

    // MARK: - Prediction Quality

    private static func predictionQualityInsight(books: [Book]) -> [ReadingInsight] {
        let activeBooks = books.filter { !$0.isCompleted && $0.sessions.count > 0 }
        guard let book = activeBooks.first else { return [] }

        let conf = AnalyticsEngine.predictionConfidence(for: book)
        if conf.level == .low {
            return [ReadingInsight(
                kind: .predictionQuality,
                title: "Predictions Will Improve",
                body: "Time-to-finish predictions for \"\(book.title)\" are estimates " +
                    "because you've only read a few pages so far. " +
                    "Predictions become accurate after about 30 pages of tracking.",
                actionSuggestion: nil,
                confidence: 0.5,
                priority: .low
            )]
        }
        return []
    }

    // MARK: - Goal Insights

    private static func goalInsights(
        books: [Book],
        goalSet: ReadingGoalSet,
        profile _: ReaderProfileAnalytics
    ) -> [ReadingInsight] {
        var insights: [ReadingInsight] = []
        let statuses = ReadingGoalManager.allStatuses(for: goalSet, books: books)

        for status in statuses {
            if status.isAchieved {
                insights.append(ReadingInsight(
                    kind: .goalOnTrack,
                    title: "\(status.goal.rawValue) Achieved! ✅",
                    body: "You've hit your \(status.goal.rawValue.lowercased()) goal for \(status.period).",
                    actionSuggestion: nil,
                    confidence: 0.95,
                    priority: .low
                ))
            } else if status.percentComplete < 0.3 {
                // Less than 30% through the day and below 30% of goal — worth surfacing.
                let needed = status.target - status.current
                insights.append(ReadingInsight(
                    kind: .goalBehind,
                    title: "\(status.goal.rawValue) Goal Behind",
                    body: "You need \(status.formattedTarget) \(status.period.lowercased()) " +
                        "and you're at \(status.formattedCurrent). " +
                        "A focused session now would make a big difference.",
                    actionSuggestion: "Read for the next 20 minutes.",
                    confidence: 0.75,
                    priority: .high
                ))
            }
        }

        return insights
    }

    // MARK: - Milestone Near

    private static func milestoneNearInsight(
        books: [Book],
        earned: [EarnedAchievement]
    ) -> [ReadingInsight] {
        let upcoming = AchievementEngine.upcoming(books: books, earned: earned, limit: 1)
        guard let nextKind = upcoming.first,
              let def = AchievementDefinition.definition(for: nextKind) else { return [] }

        return [ReadingInsight(
            kind: .milestoneNear,
            title: "Achievement Close: \(def.title)",
            body: "You're approaching the \"\(def.title)\" milestone. \(def.description)",
            actionSuggestion: "Keep reading to unlock it.",
            confidence: 0.7,
            priority: .medium
        )]
    }

    // MARK: - Dry Spell

    private static func drySpellInsight(
        streak: ReadingStreak,
        activity: [DailyActivity]
    ) -> [ReadingInsight] {
        guard let lastRead = streak.lastReadDate else { return [] }
        let daysSince = Calendar.current.dateComponents([.day], from: lastRead, to: Date()).day ?? 0

        // Dry spell: no reading in 3+ days.
        guard daysSince >= 3 else { return [] }

        let recentActive = activity.suffix(14).filter { $0.totalDuration > 0 }.count
        let confidence = min(0.95, Double(recentActive) / 7.0 * 0.5 + 0.4)

        return [ReadingInsight(
            kind: .drySpell,
            title: "It's Been \(daysSince) Days Since Your Last Session",
            body: "Reading habits are fragile — the longer the break, the harder " +
                "it is to restart. Even 5 minutes today will re-anchor the habit.",
            actionSuggestion: "Open your current book and read one page.",
            confidence: confidence,
            priority: daysSince >= 7 ? .critical : .high
        )]
    }
}

// MARK: - Insight Filtering Utilities

extension Array where Element == ReadingInsight {
    /// Returns only insights above the given confidence threshold.
    func filtered(minConfidence: Double = InsightEngine.minimumConfidence) -> [ReadingInsight] {
        filter { $0.confidence >= minConfidence }
    }

    /// Returns insights of a specific kind.
    func of(kind: ReadingInsight.InsightKind) -> [ReadingInsight] {
        filter { $0.kind == kind }
    }
}
