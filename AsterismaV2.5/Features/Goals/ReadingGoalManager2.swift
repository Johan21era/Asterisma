//  ReadingGoalManager2.swift
//  AsterismaV2.5
//
//  PURPOSE
//  Manages reading goals: daily page targets, weekly time targets, and
//  book-completion deadlines. Tracks progress in real time and emits
//  GoalStatus values consumed by the UI and AchievementEngine.
//
//  RATIONALE
//  Goals are one of the highest-impact motivational features in reading apps.
//  Without them, the analytics surface is purely descriptive — it tells users
//  what they did, not how they're doing relative to their intentions.
//  This file introduces the prescriptive layer.
//
//  DESIGN
//  • Goals are stored as Codable structs inside each Book (book-level goals)
//    or in a separate top-level GoalSet (library-level goals).
//  • All progress calculations delegate to AnalyticsEngine so there is a
//    single computation source of truth.
//  • ReadingGoalManager is a pure computation namespace (static functions).
//    Persistence is handled by DataStore (GoalSet is Codable).
//    UI binding is handled by a GoalProgressViewModel (defined below).
//
//  CALLERS
//    • DataStore — persists GoalSet alongside books array
//    • AchievementEngine — queries GoalStatus to award goal-completion badges
//    • InsightEngine — uses goal progress to generate motivational insights
//    • Library/stats UI views — bind to GoalProgressViewModel
//
//  INTERACTIONS
//    • Reads AnalyticsEngine for period-based reading time
//    • Reads Book.sessions for per-book progress
//    • Writes nothing (pure computation layer)

import Combine
import Foundation

// MARK: - Goal Models

/// A reading goal set by the user. All goals are optional and independently tracked.
struct ReadingGoalSet: Codable, Hashable {
    /// Target number of pages to read per day. nil = no daily goal.
    var dailyPageTarget: Int?
    /// Target reading duration (seconds) per day. nil = no daily time goal.
    var dailyTimeTarget: TimeInterval?
    /// Target number of books to complete per year. nil = no annual goal.
    var annualBookTarget: Int?
    /// Target number of reading days per week (streak goal). nil = no streak goal.
    var weeklyReadingDays: Int?

    static let empty = ReadingGoalSet()

    /// G1: merge semantics for callers that only own one field. Never replace
    /// the whole goal set just because one target was edited.
    func withDailyPageTarget(_ target: Int?) -> ReadingGoalSet {
        var copy = self
        copy.dailyPageTarget = target
        return copy
    }
}

/// A per-book deadline goal: finish this book by a given date.
struct BookDeadline: Identifiable, Codable, Hashable {
    var id: UUID
    var bookID: UUID
    var targetDate: Date
    var reminderEnabled: Bool

    init(id: UUID = UUID(), bookID: UUID, targetDate: Date, reminderEnabled: Bool = false) {
        self.id = id
        self.bookID = bookID
        self.targetDate = targetDate
        self.reminderEnabled = reminderEnabled
    }
}

/// The progress status of a single goal at a point in time.
struct GoalStatus {
    let goal: GoalKind
    let current: Double // what the user has achieved in the current period
    let target: Double // what the goal requires
    let period: String // human-readable period label (e.g. "Today", "This week")
    let isAchieved: Bool
    let percentComplete: Double // current/target, clamped [0,1]

    enum GoalKind: String {
        case dailyPages = "Daily Pages"
        case dailyTime = "Daily Reading Time"
        case annualBooks = "Books This Year"
        case weeklyStreak = "Reading Days This Week"
        case bookDeadline = "Book Deadline"
    }
}

/// Per-book deadline status.
struct BookDeadlineStatus {
    let deadline: BookDeadline
    let book: Book
    let daysRemaining: Int
    let pagesRemaining: Int
    let requiredPagesPerDay: Double // pages/day needed to hit the deadline
    let isAchievable: Bool // based on historical reading speed
    let isOverdue: Bool
}

// MARK: - ReadingGoalManager

/// Pure computation namespace. All methods are static.
/// The manager reads from the user's goals and the current books array,
/// and returns GoalStatus values that the UI and AchievementEngine consume.
enum ReadingGoalManager {
    // MARK: - Current Status

    /// Returns the current status of all active library-level goals.
    static func allStatuses(
        for goalSet: ReadingGoalSet,
        books: [Book],
        epoch: UInt64 = 0
    ) -> [GoalStatus] {
        var statuses: [GoalStatus] = []

        if let target = goalSet.dailyPageTarget {
            statuses.append(dailyPageStatus(books: books, target: target))
        }
        if let target = goalSet.dailyTimeTarget {
            statuses.append(dailyTimeStatus(books: books, target: target))
        }
        if let target = goalSet.annualBookTarget {
            statuses.append(annualBookStatus(books: books, target: target))
        }
        if let target = goalSet.weeklyReadingDays {
            statuses.append(weeklyStreakStatus(books: books, target: target))
        }

        return statuses
    }

    /// Returns deadline status for every book deadline in the list.
    static func deadlineStatuses(
        deadlines: [BookDeadline],
        books: [Book]
    ) -> [BookDeadlineStatus] {
        deadlines.compactMap { deadline -> BookDeadlineStatus? in
            guard let book = books.first(where: { $0.id == deadline.bookID }) else { return nil }
            return deadlineStatus(deadline: deadline, book: book)
        }
    }

    // MARK: - Individual Goal Computations

    private static func dailyPageStatus(books: [Book], target: Int) -> GoalStatus {
        let today = AnalyticsPeriod.today
        let pages = Double(AnalyticsEngine.pagesRead(books: books, in: today))
        let tgt = Double(target)
        return GoalStatus(
            goal: .dailyPages,
            current: pages,
            target: tgt,
            period: "Today",
            isAchieved: pages >= tgt,
            percentComplete: (pages / tgt).clamped(to: 0 ... 1)
        )
    }

    private static func dailyTimeStatus(books: [Book], target: TimeInterval) -> GoalStatus {
        let today = AnalyticsPeriod.today
        let seconds = AnalyticsEngine.readingTime(books: books, in: today)
        return GoalStatus(
            goal: .dailyTime,
            current: seconds,
            target: target,
            period: "Today",
            isAchieved: seconds >= target,
            percentComplete: (seconds / max(1, target)).clamped(to: 0 ... 1)
        )
    }

    private static func annualBookStatus(books: [Book], target: Int) -> GoalStatus {
        let year = AnalyticsPeriod.thisYear
        let yearRange = year.dateRange
        let completed = books.filter { book in
            book.isCompleted &&
                (book.lastReadDate.map { yearRange.contains($0) } ?? false)
        }.count
        let tgt = Double(target)
        let cur = Double(completed)
        return GoalStatus(
            goal: .annualBooks,
            current: cur,
            target: tgt,
            period: "This Year",
            isAchieved: cur >= tgt,
            percentComplete: (cur / max(1, tgt)).clamped(to: 0 ... 1)
        )
    }

    private static func weeklyStreakStatus(books: [Book], target: Int) -> GoalStatus {
        let calendar = Calendar.current
        // AUDIT §5.1: failable Calendar constructors guarded. Degradation is a
        // neutral zero-progress status, never a crash of goal tracking.
        guard let weekStart = calendar.date(from: calendar.dateComponents(
            [.yearForWeekOfYear, .weekOfYear], from: Date()
        )) else {
            return GoalStatus(
                goal: .weeklyStreak,
                current: 0,
                target: Double(target),
                period: "This Week",
                isAchieved: false,
                percentComplete: 0
            )
        }
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)
            ?? weekStart.addingTimeInterval(7 * 86_400)

        // Count distinct calendar days within the current week that had any session activity.
        let activeDays: Set<Date> = Set(
            books.flatMap(\.sessions)
                .filter { session in
                    guard let end = session.endTime else { return false }
                    return session.startTime >= weekStart && end < weekEnd
                }
                .map { calendar.startOfDay(for: $0.startTime) }
        )

        let cur = Double(activeDays.count)
        let tgt = Double(target)
        return GoalStatus(
            goal: .weeklyStreak,
            current: cur,
            target: tgt,
            period: "This Week",
            isAchieved: cur >= tgt,
            percentComplete: (cur / max(1, tgt)).clamped(to: 0 ... 1)
        )
    }

    // MARK: - Deadline Status

    static func deadlineStatus(deadline: BookDeadline, book: Book) -> BookDeadlineStatus {
        let now = Date()
        let calendar = Calendar.current
        let daysRemaining = calendar.dateComponents([.day], from: now, to: deadline.targetDate).day ?? 0
        let pagesRemaining = max(0, book.totalPages - 1 - book.currentPage)
        let isOverdue = daysRemaining < 0

        // Required pages per day to finish by the deadline.
        let required: Double
        if isOverdue || daysRemaining == 0 {
            required = isOverdue ? Double(pagesRemaining) : Double(pagesRemaining)
        } else {
            required = Double(pagesRemaining) / Double(daysRemaining)
        }

        // Achievability: compare required pace to historical pace.
        let historicalSpeed = AnalyticsEngine.readingSpeed(for: book) // seconds/page
        let secondsAvailablePerDay = 3600.0 // assume 1 hour/day available
        let achievablePagesPerDay = historicalSpeed > 0
            ? secondsAvailablePerDay / historicalSpeed
            : 10.0 // default if no history

        let isAchievable = required <= achievablePagesPerDay * 2.0 // 2x buffer

        return BookDeadlineStatus(
            deadline: deadline,
            book: book,
            daysRemaining: max(0, daysRemaining),
            pagesRemaining: pagesRemaining,
            requiredPagesPerDay: required,
            isAchievable: isAchievable && !isOverdue,
            isOverdue: isOverdue
        )
    }

    // MARK: - Pace Recommendation

    /// Returns a recommended daily page target based on the user's average reading history.
    /// This is shown in the goal setup UI as a smart default.
    static func recommendedDailyTarget(books: [Book], epoch: UInt64 = 0) -> Int {
        let profile = AnalyticsEngine.readerProfile(books: books, epoch: epoch)
        // Convert average daily reading time to pages using the most common reading speed.
        let speeds: [Double] = books.flatMap(\.sessions).map(\.averageSecondsPerPage).filter { $0 > 0 }
        guard !speeds.isEmpty else {
            return 20 // sensible default with no history
        }
        let sorted = speeds.sorted()
        let median = sorted[sorted.count / 2]
        let dailyPages = median > 0
            ? Int(profile.averageDailyReadingTime / median)
            : 20
        // Nudge slightly above average (10%) to make the goal a gentle stretch.
        return max(5, Int(Double(dailyPages) * 1.1))
    }

    // MARK: - Weekly Projection

    /// Projects how many books will be completed by year end at the current pace.
    static func projectedAnnualCompletions(books: [Book]) -> Int {
        let profile = AnalyticsEngine.readerProfile(books: books)
        let completionRate = profile.completionRate // fraction of books user finishes
        guard completionRate > 0, profile.averageWeeklyReadingTime > 0 else { return 0 }

        // Average pages across all books as a proxy for "books the user reads".
        let avgPages = books.isEmpty ? 300.0 :
            Double(books.reduce(0) { $0 + $1.totalPages }) / Double(books.count)

        // Average reading speed.
        let allTimings = books.flatMap(\.sessions).flatMap(\.pageTimes).map(\.duration).filter { $0 > 1 }
        let speed = allTimings.isEmpty ? AnalyticsConstants.defaultSecondsPerPage
            : allTimings.reduce(0, +) / Double(allTimings.count)

        // Pages per week at current pace.
        let pagesPerWeek = profile.averageWeeklyReadingTime / speed

        // Books per year = (pages/week × 52) / avgBookLength × completionRate
        let booksPerYear = (pagesPerWeek * 52.0) / max(1.0, avgPages) * completionRate
        return max(0, Int(booksPerYear.rounded()))
    }
}

// MARK: - GoalProgressViewModel

/// Observable ViewModel that wraps ReadingGoalManager computations for SwiftUI.
/// Refreshes automatically when books or goalSet change.
///
/// Usage:
///   @StateObject var goalVM = GoalProgressViewModel(dataStore: dataStore)
@MainActor
final class GoalProgressViewModel: ObservableObject {
    @Published private(set) var statuses: [GoalStatus] = []
    @Published private(set) var deadlineStatuses: [BookDeadlineStatus] = []
    @Published private(set) var recommendedDailyTarget: Int = 20
    @Published private(set) var projectedAnnualCompletions: Int = 0

    private var goalSet: ReadingGoalSet = .empty
    private var deadlines: [BookDeadline] = []
    private var cancellables = Set<AnyCancellable>()

    #if DEBUG
    private(set) var consoleIsBound: Bool = false
    #endif

    init() {
        #if DEBUG
        DeveloperConsoleRegistry.shared.register(self)
        #endif
    }

    func bind(to dataStore: DataStore, goalSet: ReadingGoalSet, deadlines: [BookDeadline]) {
        // AUDIT F-12 (roadmap 2.3): re-binding used to append another sink set on
        // every call (the root .task re-runs when windows close/reopen), so
        // subscriptions accumulated for process lifetime. Clearing first makes
        // re-bind idempotent — one active subscription pair, always.
        cancellables.removeAll()

        self.goalSet = goalSet
        self.deadlines = deadlines
        self.dataStoreRef = dataStore
        #if DEBUG
        consoleIsBound = true
        #endif

        // Refresh whenever books change.
        dataStore.$books
            .receive(on: RunLoop.main)
            .sink { [weak self] books in
                self?.refresh(books: books)
            }
            .store(in: &cancellables)

        // ROADMAP 1.2b (NA-2 companion): goals and deadlines live in libraryState
        // and are mutated by the Settings window via updateGoalSet/addDeadline.
        // Without observing $libraryState this VM kept only the values seeded at
        // launch, so saved goal changes never reached the dashboard until relaunch.
        dataStore.$libraryState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                self.goalSet = state.goalSet
                self.deadlines = state.deadlines
                self.refresh(books: dataStore.books)
            }
            .store(in: &cancellables)
    }

    func updateGoalSet(_ newSet: ReadingGoalSet, books: [Book]) {
        goalSet = newSet
        refresh(books: books)
    }

    private func refresh(books: [Book]) {
        // FINAL TRACES #5: pass the store's epoch so heavy analytics hit the
        // cache instead of walking every timing on each $books emission.
        let epoch = dataStore?.analyticsEpoch ?? 0
        statuses = ReadingGoalManager.allStatuses(for: goalSet, books: books, epoch: epoch)
        deadlineStatuses = ReadingGoalManager.deadlineStatuses(deadlines: deadlines, books: books)
        recommendedDailyTarget = ReadingGoalManager.recommendedDailyTarget(books: books, epoch: epoch)
        projectedAnnualCompletions = ReadingGoalManager.projectedAnnualCompletions(books: books)
    }

    /// Set by bind(to:) so refresh can read the live epoch. Weak not needed:
    /// DataStore outlives the VM in every ownership path here.
    private weak var dataStoreRef: DataStore?
    var dataStore: DataStore? { dataStoreRef }
}

// MARK: - Developer Console

#if DEBUG
extension GoalProgressViewModel: DeveloperConsoleObservable {
    static var consoleIdentity: ConsoleSubsystemIdentity {
        ConsoleSubsystemIdentity(
            id: "goal-progress-view-model",
            displayName: "Goal Progress ViewModel",
            category: .viewModel,
            purpose: "Wraps ReadingGoalManager's pure calculations for SwiftUI, refreshing automatically whenever the book library changes."
        )
    }

    var consoleSnapshot: ConsoleSubsystemSnapshot {
        ConsoleSubsystemSnapshot(
            identity: Self.consoleIdentity,
            status: consoleIsBound ? .healthy : .initializing,
            currentActivity: consoleIsBound
                ? "Tracking \(statuses.count) goal(s), \(deadlineStatuses.count) deadline(s)"
                : "Not bound yet — bind(to:goalSet:deadlines:) has not been called",
            lastUpdated: Date(),
            metrics: [
                "Recommended daily pages": "\(recommendedDailyTarget)",
                "Projected annual completions": "\(projectedAnnualCompletions)",
            ]
        )
    }
}
#endif

// MARK: - Formatting Helpers

extension GoalStatus {
    /// Human-readable representation of `current` appropriate to the goal kind.
    var formattedCurrent: String {
        switch goal {
        case .dailyPages, .annualBooks, .weeklyStreak:
            return "\(Int(current))"
        case .dailyTime:
            return formatDuration(current)
        case .bookDeadline:
            return "\(Int(current)) days"
        }
    }

    /// Human-readable representation of `target` appropriate to the goal kind.
    var formattedTarget: String {
        switch goal {
        case .dailyPages: return "\(Int(target)) pages"
        case .annualBooks: return "\(Int(target)) books"
        case .weeklyStreak: return "\(Int(target)) days"
        case .dailyTime: return formatDuration(target)
        case .bookDeadline: return "\(Int(target)) days"
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

extension BookDeadlineStatus {
    var formattedRequiredPace: String {
        let pages = Int(requiredPagesPerDay.rounded(.up))
        return "\(pages) pages/day"
    }

    var urgencyLabel: String {
        if isOverdue {
            return "Overdue"
        }
        if daysRemaining <= 3 {
            return "Urgent"
        }
        if daysRemaining <= 7 {
            return "This Week"
        }
        return "\(daysRemaining) days left"
    }
}
