//  AchievementEngine2.swift
//  AsterismaV2.5
//
//  PURPOSE
//  Detects and awards reading achievements (badges/milestones) based on
//  reading history, goal completions, streaks, and page counts.
//
//  RATIONALE
//  Achievements serve two distinct purposes:
//    1. Motivational: visible progress markers that reward consistent behavior.
//    2. Diagnostic: the achievement log provides a timeline of reading activity
//       that DataIntegrityValidator and InsightEngine can cross-reference.
//
//  DESIGN
//  • Achievement definitions are declarative structs (AchievementDefinition).
//    Adding a new achievement requires only adding a new case to AchievementKind
//    and a threshold entry — no imperative code changes.
//  • Earned achievements are stored as [EarnedAchievement] in the GoalSet (persisted
//    by DataStore). The engine is pure: it detects but does not persist.
//  • Detection is idempotent: calling detectAll() multiple times produces the
//    same set — it never double-awards.
//  • Newly earned achievements (not in the existing earned set) are returned as
//    a separate array so the UI can animate them.
//
//  CALLERS
//    • DataStore — calls AchievementEngine.detectAll() after each save
//    • GoalProgressViewModel — subscribes to newly earned achievements
//    • InsightEngine — reads achievement history for narrative generation
//
//  INTERACTIONS
//    • Reads AnalyticsEngine for streak, profile, trend analysis
//    • Reads ReadingGoalManager for goal completion status
//    • Writes nothing (pure computation)

import Foundation

// MARK: - Achievement Models

/// The category taxonomy for achievements.
enum AchievementKind: String, Codable, CaseIterable {
    // Page milestones
    case pages100 = "First Hundred"
    case pages500 = "Five Hundred Pages"
    case pages1000 = "One Thousand Pages"
    case pages5000 = "Five Thousand Pages"
    case pages10000 = "Ten Thousand Pages"

    // Session milestones
    case sessions5 = "Regular Reader"
    case sessions25 = "Committed Reader"
    case sessions100 = "Dedicated Reader"
    case sessions365 = "Year of Reading"

    // Streak milestones
    case streak3 = "3-Day Streak"
    case streak7 = "One Week Streak"
    case streak14 = "Two Week Streak"
    case streak30 = "Monthly Streak"
    case streak100 = "Century Streak"

    // Completion milestones
    case firstBook = "First Book Finished"
    case books5 = "Bookworm"
    case books10 = "Bibliophile"
    case books25 = "Voracious Reader"
    case books52 = "Book a Week"

    // Speed milestones
    case speedReader = "Speed Reader" // avg < 45s/page
    case deepReader = "Deep Reader" // avg > 180s/page in a session
    case marathonSession = "Marathon Session" // single session > 2 hours

    // Goal milestones
    case firstDailyGoal = "First Daily Goal Met"
    case weekGoalStreak = "Goal Week" // 7 consecutive days of meeting daily goal
    case annualGoalMet = "Annual Goal Met"
}

/// Metadata associated with an achievement kind.
struct AchievementDefinition {
    let kind: AchievementKind
    let title: String
    let description: String
    let symbolName: String // SF Symbols name for the badge icon
    let tier: AchievementTier

    enum AchievementTier: String, Codable {
        case bronze, silver, gold, platinum
    }
}

/// An achievement that has been earned by the user.
struct EarnedAchievement: Identifiable, Codable, Hashable {
    var id: UUID
    var kind: AchievementKind
    var earnedAt: Date
    var relatedBookID: UUID? // optional: which book triggered it

    init(id: UUID = UUID(), kind: AchievementKind, earnedAt: Date = Date(), relatedBookID: UUID? = nil) {
        self.id = id
        self.kind = kind
        self.earnedAt = earnedAt
        self.relatedBookID = relatedBookID
    }
}

// MARK: - Achievement Definitions Registry

extension AchievementDefinition {
    /// All achievement definitions. Authoritative list — add here to add an achievement.
    static let all: [AchievementKind: AchievementDefinition] = [
        .pages100: .init(kind: .pages100, title: "First Hundred",
                         description: "Read your first 100 pages.",
                         symbolName: "book.fill", tier: .bronze),
        .pages500: .init(kind: .pages500, title: "Five Hundred Pages",
                         description: "Read 500 pages total.",
                         symbolName: "books.vertical.fill", tier: .bronze),
        .pages1000: .init(kind: .pages1000, title: "One Thousand Pages",
                          description: "Read 1,000 pages. You're a reader now.",
                          symbolName: "books.vertical.fill", tier: .silver),
        .pages5000: .init(kind: .pages5000, title: "Five Thousand Pages",
                          description: "5,000 pages — a dedicated reader.",
                          symbolName: "text.book.closed.fill", tier: .gold),
        .pages10000: .init(kind: .pages10000, title: "Ten Thousand Pages",
                           description: "10,000 pages. Legendary.",
                           symbolName: "crown.fill", tier: .platinum),

        .sessions5: .init(kind: .sessions5, title: "Regular Reader",
                          description: "Complete 5 reading sessions.",
                          symbolName: "calendar.badge.clock", tier: .bronze),
        .sessions25: .init(kind: .sessions25, title: "Committed Reader",
                           description: "Complete 25 reading sessions.",
                           symbolName: "calendar.badge.clock", tier: .silver),
        .sessions100: .init(kind: .sessions100, title: "Dedicated Reader",
                            description: "Complete 100 reading sessions.",
                            symbolName: "calendar.badge.clock", tier: .gold),
        .sessions365: .init(kind: .sessions365, title: "Year of Reading",
                            description: "Complete 365 reading sessions.",
                            symbolName: "crown.fill", tier: .platinum),

        .streak3: .init(kind: .streak3, title: "3-Day Streak",
                        description: "Read for 3 consecutive days.",
                        symbolName: "flame.fill", tier: .bronze),
        .streak7: .init(kind: .streak7, title: "One Week Streak",
                        description: "Read every day for a week.",
                        symbolName: "flame.fill", tier: .silver),
        .streak14: .init(kind: .streak14, title: "Two Week Streak",
                         description: "Two consecutive weeks of reading.",
                         symbolName: "flame.fill", tier: .silver),
        .streak30: .init(kind: .streak30, title: "Monthly Streak",
                         description: "Read every day for a month.",
                         symbolName: "flame.fill", tier: .gold),
        .streak100: .init(kind: .streak100, title: "Century Streak",
                          description: "100 consecutive days. Exceptional.",
                          symbolName: "crown.fill", tier: .platinum),

        .firstBook: .init(kind: .firstBook, title: "First Book Finished",
                          description: "You finished your first book!",
                          symbolName: "checkmark.seal.fill", tier: .bronze),
        .books5: .init(kind: .books5, title: "Bookworm",
                       description: "Finish 5 books.",
                       symbolName: "bookmark.fill", tier: .silver),
        .books10: .init(kind: .books10, title: "Bibliophile",
                        description: "Finish 10 books.",
                        symbolName: "bookmark.fill", tier: .gold),
        .books25: .init(kind: .books25, title: "Voracious Reader",
                        description: "Finish 25 books.",
                        symbolName: "bookmark.fill", tier: .gold),
        .books52: .init(kind: .books52, title: "Book a Week",
                        description: "Finish 52 books — one per week for a year.",
                        symbolName: "crown.fill", tier: .platinum),

        .speedReader: .init(kind: .speedReader, title: "Speed Reader",
                            description: "Average under 45 seconds per page in a session.",
                            symbolName: "hare.fill", tier: .silver),
        .deepReader: .init(kind: .deepReader, title: "Deep Reader",
                           description: "Average over 3 minutes per page — really absorbing the text.",
                           symbolName: "tortoise.fill", tier: .bronze),
        .marathonSession: .init(kind: .marathonSession, title: "Marathon Session",
                                description: "Read for over 2 hours in a single session.",
                                symbolName: "figure.run", tier: .gold),

        .firstDailyGoal: .init(kind: .firstDailyGoal, title: "First Daily Goal Met",
                               description: "Meet your daily reading goal for the first time.",
                               symbolName: "target", tier: .bronze),
        .weekGoalStreak: .init(kind: .weekGoalStreak, title: "Goal Week",
                               description: "Meet your daily reading goal for 7 consecutive days.",
                               symbolName: "rosette", tier: .gold),
        .annualGoalMet: .init(kind: .annualGoalMet, title: "Annual Goal Met",
                              description: "Hit your annual book target.",
                              symbolName: "crown.fill", tier: .platinum),
    ]

    static func definition(for kind: AchievementKind) -> AchievementDefinition? {
        all[kind]
    }
}

// MARK: - AchievementEngine

/// Pure computation namespace for achievement detection.
/// All detection functions are idempotent and side-effect free.
enum AchievementEngine {
    // MARK: - Primary Entry Point

    /// Detects all achievements the user qualifies for and returns:
    ///   - `allEarned`: the full set (existing + newly detected)
    ///   - `newlyEarned`: achievements not in the `existing` set (animate these)
    ///
    /// - Parameters:
    ///   - books: The full library.
    ///   - goalSet: The user's current goal configuration.
    ///   - existing: Achievements already recorded in persistent storage.
    /// - Returns: Full earned set and the newly-detected delta.
    static func detectAll(
        books: [Book],
        goalSet: ReadingGoalSet,
        existing: [EarnedAchievement]
    ) -> (allEarned: [EarnedAchievement], newlyEarned: [EarnedAchievement]) {
        #if DEBUG
        recordConsoleInvocation()
        #endif

        // G1 FIX: this used to be a `let`. The award closure checked it but
        // never inserted the kind it just awarded, so a loop over N qualifying
        // sessions appended N copies of the same badge. Keep it mutable and
        // insert on every award.
        var awardedKinds = Set(existing.map(\.kind))
        var earned = existing
        var newly: [EarnedAchievement] = []

        let profile = AnalyticsEngine.readerProfile(books: books)
        let streak = AnalyticsEngine.streak(books: books)
        let sessions = books.flatMap(\.sessions).filter { $0.endTime != nil }

        func award(_ kind: AchievementKind, bookID: UUID? = nil) {
            guard !awardedKinds.contains(kind) else { return }
            awardedKinds.insert(kind)
            let achievement = EarnedAchievement(kind: kind, relatedBookID: bookID)
            earned.append(achievement)
            newly.append(achievement)
        }

        // MARK: Page Milestones

        let totalPages = profile.totalPagesRead
        if totalPages >= 100 {
            award(.pages100)
        }
        if totalPages >= 500 {
            award(.pages500)
        }
        if totalPages >= 1000 {
            award(.pages1000)
        }
        if totalPages >= 5000 {
            award(.pages5000)
        }
        if totalPages >= 10000 {
            award(.pages10000)
        }

        // MARK: Session Milestones

        let sessionCount = sessions.count
        if sessionCount >= 5 {
            award(.sessions5)
        }
        if sessionCount >= 25 {
            award(.sessions25)
        }
        if sessionCount >= 100 {
            award(.sessions100)
        }
        if sessionCount >= 365 {
            award(.sessions365)
        }

        // MARK: Streak Milestones

        let currentStreak = streak.longestStreak // use all-time longest streak
        if currentStreak >= 3 {
            award(.streak3)
        }
        if currentStreak >= 7 {
            award(.streak7)
        }
        if currentStreak >= 14 {
            award(.streak14)
        }
        if currentStreak >= 30 {
            award(.streak30)
        }
        if currentStreak >= 100 {
            award(.streak100)
        }

        // MARK: Completion Milestones

        let completedBooks = books.filter(\.isCompleted)
        let completedCount = completedBooks.count
        if completedCount >= 1 {
            award(.firstBook, bookID: completedBooks.first?.id)
        }
        if completedCount >= 5 {
            award(.books5)
        }
        if completedCount >= 10 {
            award(.books10)
        }
        if completedCount >= 25 {
            award(.books25)
        }
        if completedCount >= 52 {
            award(.books52)
        }

        // MARK: Speed Milestones

        detectSpeedAchievements(sessions: sessions, award: award)

        // MARK: Goal Milestones

        detectGoalAchievements(
            books: books, goalSet: goalSet, award: award
        )

        return (earned, newly)
    }

    // MARK: - Speed Achievement Detection

    private static func detectSpeedAchievements(
        sessions: [ReadingSession],
        award: (AchievementKind, UUID?) -> Void
    ) {
        for session in sessions {
            let avg = session.averageSecondsPerPage
            if avg > 0, avg < 45 {
                award(.speedReader, nil)
            }
            if avg > 180 {
                award(.deepReader, nil)
            }
            if session.duration > 7200 {
                award(.marathonSession, nil)
            }
        }
    }

    // MARK: - Goal Achievement Detection

    private static func detectGoalAchievements(
        books: [Book],
        goalSet: ReadingGoalSet,
        award: (AchievementKind, UUID?) -> Void
    ) {
        // AUDIT F-08 (roadmap 1.2c): weekGoalStreak was defined and registered in
        // AchievementDefinition.all but NO code path ever awarded it — users saw a
        // permanently locked "Goal Week" slot. Detection: any run of 7 consecutive
        // calendar days whose page count meets the daily page target. Requires a set
        // daily page target (reachable since roadmap 1.2b added the goal editor).
        if hasSevenConsecutiveGoalDays(books: books, goalSet: goalSet) {
            award(.weekGoalStreak, nil)
        }

        // Annual goal
        if let annualTarget = goalSet.annualBookTarget {
            let statuses = ReadingGoalManager.allStatuses(for: goalSet, books: books)
            if let annual = statuses.first(where: { $0.goal == .annualBooks }), annual.isAchieved {
                award(.annualGoalMet, nil)
            }
            // First daily goal: check if user has met the daily page target today.
            if let dailyTarget = goalSet.dailyPageTarget {
                let todayPages = AnalyticsEngine.pagesRead(books: books, in: .today)
                if todayPages >= dailyTarget {
                    award(.firstDailyGoal, nil)
                }
            }
        } else if let dailyTarget = goalSet.dailyPageTarget {
            let todayPages = AnalyticsEngine.pagesRead(books: books, in: .today)
            if todayPages >= dailyTarget {
                award(.firstDailyGoal, nil)
            }
        }
    }

    /// F-08 helper: true when some window of 7 consecutive calendar days each had
    /// page count ≥ the daily page target. Uses AnalyticsEngine's own period math
    /// (B7 clamped overlap) so the definition of "pages that day" matches what the
    /// dashboard shows. Bounded 90-day lookback keeps this O(sessions-in-window).
    static func hasSevenConsecutiveGoalDays(books: [Book], goalSet: ReadingGoalSet) -> Bool {
        guard let dailyTarget = goalSet.dailyPageTarget, dailyTarget > 0 else { return false }

        let activity = AnalyticsEngine.dailyActivity(books: books, days: 90)
        var longest = 0
        var run = 0
        for day in activity {
            if day.pagesRead >= dailyTarget {
                run += 1
                longest = max(longest, run)
            } else {
                run = 0
            }
        }
        return longest >= 7
    }

    // MARK: - Deduplication / migration

    /// G1: one badge per kind, keeping the earliest award. Idempotent.
    /// This is the migration path for libraries written by the old loop bug
    /// (the live store had 592 records for 10 unique kinds).
    static func deduplicated(
        _ achievements: [EarnedAchievement]
    ) -> (kept: [EarnedAchievement], removed: Int) {
        var earliest: [AchievementKind: EarnedAchievement] = [:]
        for achievement in achievements.sorted(by: { $0.earnedAt < $1.earnedAt }) {
            if earliest[achievement.kind] == nil {
                earliest[achievement.kind] = achievement
            }
        }
        let kept = achievements.filter { achievement in
            earliest[achievement.kind]?.id == achievement.id
        }
        return (kept, achievements.count - kept.count)
    }

    // MARK: - Summary

    /// Returns a summary of earned achievements grouped by tier.
    static func summary(
        earned: [EarnedAchievement]
    ) -> [AchievementDefinition.AchievementTier: [EarnedAchievement]] {
        Dictionary(grouping: earned) { achievement in
            AchievementDefinition.definition(for: achievement.kind)?.tier ?? .bronze
        }
    }

    /// Returns the next un-earned achievements the user is closest to achieving.
    /// Useful for the "What's next?" section in the UI.
    static func upcoming(
        books: [Book],
        earned: [EarnedAchievement],
        limit: Int = 3
    ) -> [AchievementKind] {
        let earnedKinds = Set(earned.map(\.kind))
        let profile = AnalyticsEngine.readerProfile(books: books)
        let streak = AnalyticsEngine.streak(books: books)

        // Score each un-earned achievement by closeness (0..1).
        var scores: [(AchievementKind, Double)] = []

        func addIfNeeded(_ kind: AchievementKind, progress: Double) {
            guard !earnedKinds.contains(kind) else { return }
            scores.append((kind, progress.clamped(to: 0 ... 1)))
        }

        // Pages
        addIfNeeded(.pages100, progress: Double(profile.totalPagesRead) / 100)
        addIfNeeded(.pages500, progress: Double(profile.totalPagesRead) / 500)
        addIfNeeded(.pages1000, progress: Double(profile.totalPagesRead) / 1000)
        addIfNeeded(.pages5000, progress: Double(profile.totalPagesRead) / 5000)
        addIfNeeded(.pages10000, progress: Double(profile.totalPagesRead) / 10000)

        // Sessions
        let sessionCount = books.flatMap(\.sessions).filter { $0.endTime != nil }.count
        addIfNeeded(.sessions5, progress: Double(sessionCount) / 5)
        addIfNeeded(.sessions25, progress: Double(sessionCount) / 25)
        addIfNeeded(.sessions100, progress: Double(sessionCount) / 100)
        addIfNeeded(.sessions365, progress: Double(sessionCount) / 365)

        // Streaks
        addIfNeeded(.streak3, progress: Double(streak.currentStreak) / 3)
        addIfNeeded(.streak7, progress: Double(streak.currentStreak) / 7)
        addIfNeeded(.streak14, progress: Double(streak.currentStreak) / 14)
        addIfNeeded(.streak30, progress: Double(streak.currentStreak) / 30)
        addIfNeeded(.streak100, progress: Double(streak.currentStreak) / 100)

        // Books completed
        let completed = books.filter(\.isCompleted).count
        addIfNeeded(.firstBook, progress: Double(completed) / 1)
        addIfNeeded(.books5, progress: Double(completed) / 5)
        addIfNeeded(.books10, progress: Double(completed) / 10)
        addIfNeeded(.books25, progress: Double(completed) / 25)
        addIfNeeded(.books52, progress: Double(completed) / 52)

        // Sort by closest (descending progress score) and return top `limit`.
        return scores
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }
}

// MARK: - Developer Console
//
// AchievementEngine is a stateless enum namespace (static func only, no
// instance) — the example this codebase uses to prove the console's
// registration pattern covers BOTH subsystem shapes found here, not just
// @MainActor classes. See the honest-limitation note in
// DeveloperConsoleObservable.swift for why this needs one line in
// DeveloperConsoleRegistry.swift's static engine manifest, unlike the
// fully self-registering class-based subsystems elsewhere in this app.

#if DEBUG
extension AchievementEngine: DeveloperConsoleStaticObservable {
    // nonisolated(unsafe): this is a simple call counter for a DEBUG-only
    // diagnostic display, not correctness-critical state. Using
    // nonisolated(unsafe) here — rather than making detectAll() @MainActor
    // — avoids forcing an isolation requirement onto every existing call
    // site of detectAll() (DataStore, AchievementPanel), which this session
    // could not verify are all MainActor-isolated without reading
    // substantially more of the codebase than the instrumentation itself
    // warrants.
    nonisolated(unsafe) private static var consoleInvocationCount: Int = 0
    nonisolated(unsafe) private static var consoleLastInvokedAt: Date?

    /// Called once at the top of detectAll(). Never reads or affects
    /// detectAll's return value — purely a call counter for the console.
    fileprivate static func recordConsoleInvocation() {
        consoleInvocationCount += 1
        consoleLastInvokedAt = Date()
    }

    static var consoleIdentity: ConsoleSubsystemIdentity {
        ConsoleSubsystemIdentity(
            id: "achievement-engine",
            displayName: "Achievement Engine",
            category: .engine,
            purpose: "Pure, side-effect-free achievement detection. Called by DataStore after each save and by AchievementPanel for display."
        )
    }

    static var consoleSnapshot: ConsoleSubsystemSnapshot {
        ConsoleSubsystemSnapshot(
            identity: consoleIdentity,
            status: consoleInvocationCount > 0 ? .healthy : .idle,
            currentActivity: consoleInvocationCount > 0
                ? "Called detectAll() \(consoleInvocationCount) time(s) this session"
                : "Not called yet this session",
            lastUpdated: consoleLastInvokedAt,
            metrics: [
                "Calls to detectAll() this session": "\(consoleInvocationCount)",
            ]
        )
    }
}
#endif
