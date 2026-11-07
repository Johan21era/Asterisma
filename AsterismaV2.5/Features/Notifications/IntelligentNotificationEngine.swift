//  IntelligentNotificationEngine.swift
//  AsterismaV2.5
//  PART 1/3
//  Data Models
//  Behavioral Profiles
//  Confidence Modeling
//  Opportunity Detection
//

import Foundation

// MARK: - Notification Categories

enum NotificationCategory: String, CaseIterable, Codable {
    case readingOpportunity
    case streakProtection
    case completionEncouragement
    case momentumReinforcement
    case inactivityRecovery
    case chapterCompletion
    case sessionContinuation
    case achievementMilestone
}

// MARK: - Notification Score Breakdown

struct NotificationScoreBreakdown {
    let timeAffinity: Double
    let weekdayAffinity: Double

    let momentumScore: Double
    let streakScore: Double

    let sessionFitScore: Double
    let completionScore: Double

    let inactivityUrgency: Double
    let engagementLikelihood: Double

    var totalContribution: Double {
        timeAffinity +
            weekdayAffinity +
            momentumScore +
            streakScore +
            sessionFitScore +
            completionScore +
            inactivityUrgency +
            engagementLikelihood
    }
}

// MARK: - Notification Confidence

struct NotificationConfidence {
    let score: Double
    let sessionCount: Int
    let completedSessions: Int
    let activeDays: Int
}

// MARK: - Notification Candidate

struct NotificationCandidate {
    let category: NotificationCategory

    let title: String
    let message: String

    let triggerReason: String

    let recommendedDeliveryTime: Date

    let rankingScore: Double

    let confidence: NotificationConfidence

    let breakdown: NotificationScoreBreakdown

    let explanation: String
}

extension NotificationCandidate {
    init(
        category: NotificationCategory,
        title: String,
        message: String,
        triggerReason: String,
        recommendedDeliveryTime: Date,
        breakdown: NotificationScoreBreakdown,
        rankingScore: Double,
        confidence: NotificationConfidence = NotificationConfidence(
            score: 0.0,
            sessionCount: 0,
            completedSessions: 0,
            activeDays: 0
        ),
        explanation: String? = nil
    ) {
        self.category = category
        self.title = title
        self.message = message
        self.triggerReason = triggerReason
        self.recommendedDeliveryTime = recommendedDeliveryTime
        self.rankingScore = rankingScore
        self.confidence = confidence
        self.breakdown = breakdown
        self.explanation = explanation ?? triggerReason
    }
}

// MARK: - Notification Result

struct IntelligentNotificationResult {
    let generatedAt: Date

    let shouldNotify: Bool

    let selectedNotification: NotificationCandidate?

    let rankedNotifications: [NotificationCandidate]

    let confidence: NotificationConfidence

    let explanation: String
}

// MARK: - Behavioral Profile

struct NotificationBehaviorProfile {
    let preferredHours: [Int: Double]

    let preferredWeekdays: [Int: Double]

    let averageSessionDuration: TimeInterval

    let averagePagesPerSession: Double

    let activeReadingDays: Int

    let sessionConsistency: Double

    let momentum: Double

    let inactivityDays: Double

    let longestStreak: Int

    let readingFrequencyPerWeek: Double

    let totalSessions: Int
}

// MARK: - Opportunity Window

struct ReadingOpportunityWindow {
    let hour: Int

    let probability: Double

    let averageDuration: TimeInterval
}

// MARK: - Notification Analytics

struct NotificationAnalytics {
    let timeAffinity: Double
    let weekdayAffinity: Double
    let momentum: Double
    let sessionFit: Double
    let completionProbability: Double
    let inactivityUrgency: Double
    let engagementLikelihood: Double
    let sessionConsistency: Double
    let daysSinceLastSession: Int
    let recommendedDeliveryTime: Date
}

// MARK: - IntelligentNotificationEngine

enum IntelligentNotificationEngine {
    // MARK: Public API

    static func evaluate(
        books: [Book],
        notificationHistory _: [NotificationCandidate] = [],
        date: Date = Date()
    ) -> IntelligentNotificationResult {
        let profile = buildBehaviorProfile(
            books: books,
            date: date
        )

        let confidence = buildConfidence(
            books: books
        )

        let opportunities = detectReadingOpportunities(
            books: books,
            profile: profile
        )

        // Adapter: derive minimal NotificationAnalytics from existing data
        let analytics = NotificationAnalytics(
            timeAffinity: profile.preferredHours.max(by: { $0.value < $1.value })?.value ?? 0,
            weekdayAffinity: profile.preferredWeekdays.max(by: { $0.value < $1.value })?.value ?? 0,
            momentum: profile.momentum,
            sessionFit: 1.0, // placeholder until a precise computation exists
            completionProbability: 0.0,
            inactivityUrgency: min(1.0, profile.inactivityDays / 14.0),
            engagementLikelihood: min(1.0, max(profile.readingFrequencyPerWeek / 7.0, profile.sessionConsistency)),
            sessionConsistency: profile.sessionConsistency,
            daysSinceLastSession: Int(max(0, profile.inactivityDays.rounded())),
            recommendedDeliveryTime: date
        )

        // TODO: Thread real recommendation and estimation when available
        let recommendation: RecommendationResultV3? = nil
        let estimationResults: [UUID: BookEstimationResult] = [:]

        let candidates = buildCandidates(
            books: books,
            analytics: analytics,
            recommendation: recommendation,
            estimationResults: estimationResults
        )

        let ranked = candidates.sorted {
            $0.rankingScore > $1.rankingScore
        }

        let selected = ranked.first

        let shouldNotify =
            selected != nil &&
            (selected?.rankingScore ?? 0) > 0.55

        return IntelligentNotificationResult(
            generatedAt: date,
            shouldNotify: shouldNotify,
            selectedNotification: shouldNotify ? selected : nil,
            rankedNotifications: ranked,
            confidence: confidence,
            explanation: selected?.explanation ??
                "No notification opportunity detected."
        )
    }
}

// MARK: - Behavioral Profile Builder

extension IntelligentNotificationEngine {
    static func buildBehaviorProfile(
        books: [Book],
        date: Date
    ) -> NotificationBehaviorProfile {
        let sessions =
            books.flatMap { $0.sessions }
                .filter { $0.endTime != nil }

        guard !sessions.isEmpty else {
            return NotificationBehaviorProfile(
                preferredHours: [:],
                preferredWeekdays: [:],
                averageSessionDuration: 1800,
                averagePagesPerSession: 10,
                activeReadingDays: 0,
                sessionConsistency: 0,
                momentum: 0,
                inactivityDays: 999,
                longestStreak: 0,
                readingFrequencyPerWeek: 0,
                totalSessions: 0
            )
        }

        var hourCounts: [Int: Int] = [:]
        var weekdayCounts: [Int: Int] = [:]

        var activeDays = Set<Date>()

        let calendar = Calendar.current

        let durations = sessions.map {
            $0.duration
        }

        let pages = sessions.map {
            Double($0.pagesRead)
        }

        for session in sessions {
            let hour =
                calendar.component(
                    .hour,
                    from: session.startTime
                )

            let weekday =
                calendar.component(
                    .weekday,
                    from: session.startTime
                )

            hourCounts[hour, default: 0] += 1
            weekdayCounts[weekday, default: 0] += 1

            activeDays.insert(
                calendar.startOfDay(
                    for: session.startTime
                )
            )
        }

        let totalSessions = sessions.count

        let preferredHours =
            normalize(hourCounts)

        let preferredWeekdays =
            normalize(weekdayCounts)

        let avgDuration =
            durations.reduce(0,+) /
            Double(max(1, durations.count))

        let avgPages =
            pages.reduce(0,+) /
            Double(max(1, pages.count))

        let consistency =
            computeConsistency(
                sessions: sessions
            )

        let inactivity =
            computeInactivity(
                sessions: sessions,
                date: date
            )

        let longestStreak =
            computeLongestStreak(
                sessions: sessions
            )

        let momentum =
            computeMomentum(
                sessions: sessions,
                date: date
            )
        func computeLongestStreak(
            sessions: [ReadingSession]
        ) -> Int {
            let calendar = Calendar.current

            let days = Set(
                sessions.map {
                    calendar.startOfDay(for: $0.startTime)
                }
            )

            let sortedDays = days.sorted()

            guard !sortedDays.isEmpty else {
                return 0
            }

            var longest = 1
            var current = 1

            for index in 1 ..< sortedDays.count {
                let previous = sortedDays[index - 1]
                let currentDay = sortedDays[index]

                let difference =
                    calendar.dateComponents(
                        [.day],
                        from: previous,
                        to: currentDay
                    ).day ?? 0

                if difference == 1 {
                    current += 1
                    longest = max(longest, current)
                } else {
                    current = 1
                }
            }

            return longest
        }
        let frequency =
            computeWeeklyFrequency(
                sessions: sessions
            )

        return NotificationBehaviorProfile(
            preferredHours: preferredHours,
            preferredWeekdays: preferredWeekdays,
            averageSessionDuration: avgDuration,
            averagePagesPerSession: avgPages,
            activeReadingDays: activeDays.count,
            sessionConsistency: consistency,
            momentum: momentum,
            inactivityDays: inactivity,
            longestStreak: longestStreak,
            readingFrequencyPerWeek: frequency,
            totalSessions: totalSessions
        )
    }
}

// MARK: - Confidence

extension IntelligentNotificationEngine {
    static func buildConfidence(
        books: [Book]
    ) -> NotificationConfidence {
        let sessions =
            books.flatMap { $0.sessions }

        let completed =
            sessions.filter {
                $0.endTime != nil
            }

        let activeDays =
            Set(
                completed.map {
                    Calendar.current.startOfDay(
                        for: $0.startTime
                    )
                }
            )

        let sessionFactor =
            min(
                1.0,
                Double(sessions.count) / 100.0
            )

        let dayFactor =
            min(
                1.0,
                Double(activeDays.count) / 60.0
            )

        let score =
            (sessionFactor * 0.6) +
            (dayFactor * 0.4)

        return NotificationConfidence(
            score: min(1, max(0, score)),
            sessionCount: sessions.count,
            completedSessions: completed.count,
            activeDays: activeDays.count
        )
    }
}

// MARK: - Reading Opportunity Detection

extension IntelligentNotificationEngine {
    static func detectReadingOpportunities(
        books _: [Book],
        profile: NotificationBehaviorProfile
    ) -> [ReadingOpportunityWindow] {
        profile.preferredHours
            .map { hour, score in
                ReadingOpportunityWindow(
                    hour: hour,
                    probability: score,
                    averageDuration:
                    profile.averageSessionDuration
                )
            }
            .sorted {
                $0.probability > $1.probability
            }
    }
}

// MARK: - Utilities

extension IntelligentNotificationEngine {
    static func normalize(
        _ values: [Int: Int]
    ) -> [Int: Double] {
        let total =
            Double(
                values.values.reduce(0,+)
            )

        guard total > 0 else {
            return [:]
        }

        return values.mapValues {
            Double($0) / total
        }
    }

    static func computeInactivity(
        sessions: [ReadingSession],
        date: Date
    ) -> Double {
        guard let last =
            sessions.map(\.startTime).max()
        else {
            return 999
        }

        return date.timeIntervalSince(last) / 86400
    }

    static func computeWeeklyFrequency(
        sessions: [ReadingSession]
    ) -> Double {
        guard
            let first = sessions.map(\.startTime).min(),
            let last = sessions.map(\.startTime).max()
        else {
            return 0
        }

        let weeks =
            max(
                1.0,
                last.timeIntervalSince(first)
                    / 604_800
            )

        return Double(
            sessions.count
        ) / weeks
    }

    static func computeMomentum(
        sessions: [ReadingSession],
        date: Date
    ) -> Double {
        let recent =
            sessions.filter {
                date.timeIntervalSince(
                    $0.startTime
                ) <= 86400 * 7
            }

        guard !recent.isEmpty else {
            return 0
        }

        let duration =
            recent.reduce(0) {
                $0 + $1.duration
            }

        return min(
            1,
            duration / 14400
        )
    }

    static func computeConsistency(
        sessions: [ReadingSession]
    ) -> Double {
        // Consistency is measured as how evenly sessions are distributed across days.
        // We compute sessions-per-day, then convert the normalized standard deviation
        // into a 0..1 score where 1 means very consistent (low variance) and 0 means inconsistent.
        guard !sessions.isEmpty else { return 0 }
        let calendar = Calendar.current
        let dayCounts = Dictionary(
            grouping: sessions
        ) { session in
            calendar.startOfDay(for: session.startTime)
        }.mapValues { $0.count }

        let counts = Array(dayCounts.values)
        guard !counts.isEmpty else { return 0 }

        // Mean sessions per active day
        let mean = Double(counts.reduce(0, +)) / Double(counts.count)
        if mean == 0 {
            return 0
        }

        // Population standard deviation
        let variance = counts.reduce(0.0) { partial, c in
            let d = Double(c) - mean
            return partial + d * d
        } / Double(counts.count)
        let stdDev = sqrt(variance)

        // Coefficient of variation (stdDev normalized by mean)
        let cv = stdDev / mean

        // Map CV to consistency score: higher CV -> lower consistency.
        // Use a soft mapping: score = 1 / (1 + k * cv) with k tuned.
        let k = 1.5
        let score = 1.0 / (1.0 + k * cv)

        // Clamp to [0,1]
        return max(0.0, min(1.0, score))
    }
}

//
//  IntelligentNotificationEngine.swift
//  AsterismaV2.5
//
//  PART 2 / 3
//  Notification Candidate Generation + Scoring + Ranking
//

import Foundation

// MARK: - Candidate Generation

extension IntelligentNotificationEngine {
    static func buildCandidates(
        books: [Book],
        analytics: NotificationAnalytics,
        recommendation _: RecommendationResultV3?,
        estimationResults: [UUID: BookEstimationResult]
    ) -> [NotificationCandidate] {
        var candidates: [NotificationCandidate] = []

        if let opportunity = buildReadingOpportunity(
            books: books,
            analytics: analytics
        ) {
            candidates.append(opportunity)
        }

        if let streak = buildStreakProtection(
            books: books,
            analytics: analytics
        ) {
            candidates.append(streak)
        }

        if let completion = buildCompletionEncouragement(
            books: books,
            analytics: analytics,
            estimationResults: estimationResults
        ) {
            candidates.append(completion)
        }

        if let momentum = buildMomentumReinforcement(
            books: books,
            analytics: analytics
        ) {
            candidates.append(momentum)
        }

        if let inactivity = buildInactivityRecovery(
            books: books,
            analytics: analytics
        ) {
            candidates.append(inactivity)
        }

        if let chapter = buildChapterOpportunity(
            books: books,
            analytics: analytics,
            estimationResults: estimationResults
        ) {
            candidates.append(chapter)
        }

        if let continuation = buildSessionContinuation(
            books: books,
            analytics: analytics
        ) {
            candidates.append(continuation)
        }

        if let achievement = buildAchievementMilestone(
            books: books,
            analytics: analytics
        ) {
            candidates.append(achievement)
        }

        return candidates
    }
}

// MARK: - Reading Opportunity

private extension IntelligentNotificationEngine {
    static func buildReadingOpportunity(
        books _: [Book],
        analytics: NotificationAnalytics
    ) -> NotificationCandidate? {
        guard analytics.timeAffinity > 0.55 else {
            return nil
        }

        guard analytics.sessionConsistency > 0.30 else {
            return nil
        }

        let breakdown = NotificationScoreBreakdown(
            timeAffinity: analytics.timeAffinity,
            weekdayAffinity: analytics.weekdayAffinity,
            momentumScore: analytics.momentum,
            streakScore: 0.20,
            sessionFitScore: analytics.sessionFit,
            completionScore: analytics.completionProbability,
            inactivityUrgency: analytics.inactivityUrgency,
            engagementLikelihood: analytics.engagementLikelihood
        )

        let score = weightedScore(from: breakdown)

        return NotificationCandidate(
            category: .readingOpportunity,
            title: "Good Time To Read",
            message: "This aligns with one of your strongest historical reading windows.",
            triggerReason: "High time-of-day affinity and session consistency.",
            recommendedDeliveryTime: analytics.recommendedDeliveryTime,
            breakdown: breakdown,
            rankingScore: score
        )
    }
}

// MARK: - Streak Protection

private extension IntelligentNotificationEngine {
    static func buildStreakProtection(
        books: [Book],
        analytics: NotificationAnalytics
    ) -> NotificationCandidate? {
        let streak = AnalyticsEngine.streak(books: books)

        guard streak.currentStreak > 0 else {
            return nil
        }

        let daysSinceRead = analytics.daysSinceLastSession

        guard daysSinceRead >= 1 else {
            return nil
        }

        let urgency =
            min(
                1.0,
                Double(daysSinceRead) /
                    Double(max(streak.currentStreak, 1))
            )

        let breakdown = NotificationScoreBreakdown(
            timeAffinity: analytics.timeAffinity,
            weekdayAffinity: analytics.weekdayAffinity,
            momentumScore: analytics.momentum,
            streakScore: urgency,
            sessionFitScore: analytics.sessionFit,
            completionScore: analytics.completionProbability,
            inactivityUrgency: urgency,
            engagementLikelihood: analytics.engagementLikelihood
        )

        let score = weightedScore(from: breakdown)

        return NotificationCandidate(
            category: .streakProtection,
            title: "Protect Your Reading Streak",
            message: "A short reading session today helps maintain your consistency.",
            triggerReason: "Active streak with increasing lapse risk.",
            recommendedDeliveryTime: analytics.recommendedDeliveryTime,
            breakdown: breakdown,
            rankingScore: score
        )
    }
}

// MARK: - Completion Encouragement

private extension IntelligentNotificationEngine {
    static func buildCompletionEncouragement(
        books: [Book],
        analytics: NotificationAnalytics,
        estimationResults _: [UUID: BookEstimationResult]
    ) -> NotificationCandidate? {
        let activeBooks = books.filter {
            !$0.isCompleted
        }

        guard !activeBooks.isEmpty else {
            return nil
        }

        guard
            let target = activeBooks.max(
                by: { $0.progressFraction < $1.progressFraction }
            )
        else {
            return nil
        }

        guard target.progressFraction >= 0.75 else {
            return nil
        }

        let completionProbability =
            min(
                1.0,
                target.progressFraction +
                    analytics.completionProbability * 0.25
            )

        let breakdown = NotificationScoreBreakdown(
            timeAffinity: analytics.timeAffinity,
            weekdayAffinity: analytics.weekdayAffinity,
            momentumScore: analytics.momentum,
            streakScore: 0.25,
            sessionFitScore: analytics.sessionFit,
            completionScore: completionProbability,
            inactivityUrgency: analytics.inactivityUrgency,
            engagementLikelihood: analytics.engagementLikelihood
        )

        let score = weightedScore(from: breakdown)

        return NotificationCandidate(
            category: .completionEncouragement,
            title: "You're Almost Finished",
            message: "\(target.title) is close to completion.",
            triggerReason: "Book progress exceeded 75%.",
            recommendedDeliveryTime: analytics.recommendedDeliveryTime,
            breakdown: breakdown,
            rankingScore: score
        )
    }
}

// MARK: - Momentum Reinforcement

private extension IntelligentNotificationEngine {
    static func buildMomentumReinforcement(
        books _: [Book],
        analytics: NotificationAnalytics
    ) -> NotificationCandidate? {
        guard analytics.momentum >= 0.65 else {
            return nil
        }

        let breakdown = NotificationScoreBreakdown(
            timeAffinity: analytics.timeAffinity,
            weekdayAffinity: analytics.weekdayAffinity,
            momentumScore: analytics.momentum,
            streakScore: 0.30,
            sessionFitScore: analytics.sessionFit,
            completionScore: analytics.completionProbability,
            inactivityUrgency: 0.0,
            engagementLikelihood: analytics.engagementLikelihood
        )

        let score = weightedScore(from: breakdown)

        return NotificationCandidate(
            category: .momentumReinforcement,
            title: "Keep The Momentum Going",
            message: "Your recent reading activity is trending upward.",
            triggerReason: "High momentum score detected.",
            recommendedDeliveryTime: analytics.recommendedDeliveryTime,
            breakdown: breakdown,
            rankingScore: score
        )
    }
}

// MARK: - Inactivity Recovery

private extension IntelligentNotificationEngine {
    static func buildInactivityRecovery(
        books _: [Book],
        analytics: NotificationAnalytics
    ) -> NotificationCandidate? {
        guard analytics.daysSinceLastSession >= 3 else {
            return nil
        }

        let urgency =
            min(
                1.0,
                Double(analytics.daysSinceLastSession) / 14.0
            )

        let breakdown = NotificationScoreBreakdown(
            timeAffinity: analytics.timeAffinity,
            weekdayAffinity: analytics.weekdayAffinity,
            momentumScore: analytics.momentum,
            streakScore: 0.0,
            sessionFitScore: analytics.sessionFit,
            completionScore: analytics.completionProbability,
            inactivityUrgency: urgency,
            engagementLikelihood: analytics.engagementLikelihood
        )

        let score = weightedScore(from: breakdown)

        return NotificationCandidate(
            category: .inactivityRecovery,
            title: "Time To Reconnect With Reading",
            message: "Your reading activity has slowed recently.",
            triggerReason: "Inactivity threshold exceeded.",
            recommendedDeliveryTime: analytics.recommendedDeliveryTime,
            breakdown: breakdown,
            rankingScore: score
        )
    }
}

// MARK: - Chapter Opportunity

private extension IntelligentNotificationEngine {
    static func buildChapterOpportunity(
        books: [Book],
        analytics: NotificationAnalytics,
        estimationResults: [UUID: BookEstimationResult]
    ) -> NotificationCandidate? {
        for book in books {
            guard let estimate = estimationResults[book.id] else {
                continue
            }

            let chapter = estimate.chapterEstimates.first

            guard let chapter else {
                continue
            }

            let estimatedMinutes =
                chapter.estimatedSeconds / 60.0

            if estimatedMinutes <= 20 {
                let breakdown = NotificationScoreBreakdown(
                    timeAffinity: analytics.timeAffinity,
                    weekdayAffinity: analytics.weekdayAffinity,
                    momentumScore: analytics.momentum,
                    streakScore: 0.15,
                    sessionFitScore: analytics.sessionFit,
                    completionScore: analytics.completionProbability,
                    inactivityUrgency: analytics.inactivityUrgency,
                    engagementLikelihood: analytics.engagementLikelihood
                )

                let score = weightedScore(from: breakdown)

                return NotificationCandidate(
                    category: .chapterCompletion,
                    title: "Quick Chapter Opportunity",
                    message: "You likely have enough time to finish a chapter.",
                    triggerReason: "Chapter forecast fits typical session duration.",
                    recommendedDeliveryTime: analytics.recommendedDeliveryTime,
                    breakdown: breakdown,
                    rankingScore: score
                )
            }
        }

        return nil
    }
}

// MARK: - Session Continuation

private extension IntelligentNotificationEngine {
    static func buildSessionContinuation(
        books: [Book],
        analytics: NotificationAnalytics
    ) -> NotificationCandidate? {
        guard
            let recentBook = books
            .filter({ !$0.isCompleted })
            .sorted(by: {
                ($0.lastReadDate ?? .distantPast) >
                    ($1.lastReadDate ?? .distantPast)
            })
            .first
        else {
            return nil
        }

        guard let lastRead = recentBook.lastReadDate else {
            return nil
        }

        let hours =
            Date().timeIntervalSince(lastRead) / 3600

        guard hours >= 6, hours <= 48 else {
            return nil
        }

        let breakdown = NotificationScoreBreakdown(
            timeAffinity: analytics.timeAffinity,
            weekdayAffinity: analytics.weekdayAffinity,
            momentumScore: analytics.momentum,
            streakScore: 0.10,
            sessionFitScore: analytics.sessionFit,
            completionScore: analytics.completionProbability,
            inactivityUrgency: analytics.inactivityUrgency,
            engagementLikelihood: analytics.engagementLikelihood
        )

        let score = weightedScore(from: breakdown)

        return NotificationCandidate(
            category: .sessionContinuation,
            title: "Continue Where You Left Off",
            message: recentBook.title,
            triggerReason: "Recently active unfinished book.",
            recommendedDeliveryTime: analytics.recommendedDeliveryTime,
            breakdown: breakdown,
            rankingScore: score
        )
    }
}

// MARK: - Achievement Milestone

private extension IntelligentNotificationEngine {
    static func buildAchievementMilestone(
        books: [Book],
        analytics: NotificationAnalytics
    ) -> NotificationCandidate? {
        let completed =
            books.filter(\.isCompleted).count

        guard completed > 0 else {
            return nil
        }

        let milestone =
            completed % 5 == 0

        guard milestone else {
            return nil
        }

        let breakdown = NotificationScoreBreakdown(
            timeAffinity: analytics.timeAffinity,
            weekdayAffinity: analytics.weekdayAffinity,
            momentumScore: analytics.momentum,
            streakScore: 0.20,
            sessionFitScore: analytics.sessionFit,
            completionScore: analytics.completionProbability,
            inactivityUrgency: 0.0,
            engagementLikelihood: analytics.engagementLikelihood
        )

        let score = weightedScore(from: breakdown)

        return NotificationCandidate(
            category: .achievementMilestone,
            title: "Reading Milestone Reached",
            message: "You've completed \(completed) books.",
            triggerReason: "Completion milestone detected.",
            recommendedDeliveryTime: analytics.recommendedDeliveryTime,
            breakdown: breakdown,
            rankingScore: score
        )
    }
}

func clamp(_ value: Double) -> Double {
    max(0.0, min(1.0, value))
}

// MARK: - Ranking Engine

extension IntelligentNotificationEngine {
    /// Ensures candidate scores are valid and returns a sanitized candidate
    static func validateCandidate(_ candidate: NotificationCandidate) -> NotificationCandidate {
        // Clamp rankingScore to [0,1] to keep ordering stable
        let clampedScore = max(0.0, min(1.0, candidate.rankingScore))
        if clampedScore == candidate.rankingScore {
            return candidate
        }
        // Rebuild candidate with clamped score, preserving all other fields
        return NotificationCandidate(
            category: candidate.category,
            title: candidate.title,
            message: candidate.message,
            triggerReason: candidate.triggerReason,
            recommendedDeliveryTime: candidate.recommendedDeliveryTime,
            breakdown: candidate.breakdown,
            rankingScore: clampedScore,
            confidence: candidate.confidence,
            explanation: candidate.explanation
        )
    }

    static func rankCandidates(
        _ candidates: [NotificationCandidate]
    ) -> [NotificationCandidate] {
        candidates
            .map { validateCandidate($0) }
            .sorted {
                $0.rankingScore >
                    $1.rankingScore
            }
    }

    static func weightedScore(
        from breakdown: NotificationScoreBreakdown
    ) -> Double {
        let score =
            breakdown.timeAffinity * 0.18 +
            breakdown.weekdayAffinity * 0.10 +
            breakdown.momentumScore * 0.12 +
            breakdown.streakScore * 0.18 +
            breakdown.sessionFitScore * 0.12 +
            breakdown.completionScore * 0.12 +
            breakdown.inactivityUrgency * 0.10 +
            breakdown.engagementLikelihood * 0.08

        return clamp(score)
    }
}
