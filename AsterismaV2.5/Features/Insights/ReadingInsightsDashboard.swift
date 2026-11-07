//  ReadingInsightsDashboard.swift
//  AsterismaV2.5
//
//  Surfaces the output of InsightEngine.generateAll() and key AnalyticsEngine
//  metrics in a single scrollable panel. Presented as a sheet from ContentView.
//
//  Engines called (read-only, all static, no side effects):
//    - InsightEngine.generateAll(books:goalSet:earnedAchievements:)
//    - AnalyticsEngine.readerProfile(books:)
//    - AnalyticsEngine.streak(books:)
//    - AnalyticsEngine.trendAnalysis(books:)
//    - AnalyticsEngine.timeOfDayAnalysis(books:)
//    - AnalyticsEngine.dailyActivity(books:days:)
//

import SwiftUI

struct ReadingInsightsDashboard: View {
    @EnvironmentObject private var dataStore: DataStore
    @Environment(\.dismiss) private var dismiss

    /// Embedded in the main window as a destination, rather than presented as
    /// a standalone window or sheet. The content is identical; only the close
    /// affordance and the standalone minimum size disappear.
    var embedded: Bool = false

    /// Computed lazily in the view body from DataStore state.
    /// No @State caching needed — these are pure functions on value types and
    /// SwiftUI's body diffing prevents unnecessary recomputation.
    private var profile: ReaderProfileAnalytics {
        AnalyticsEngine.readerProfile(books: dataStore.books, epoch: dataStore.analyticsEpoch)
    }

    private var streak: ReadingStreak {
        AnalyticsEngine.streak(books: dataStore.books, epoch: dataStore.analyticsEpoch)
    }

    private var trend: TrendAnalytics {
        AnalyticsEngine.trendAnalysis(books: dataStore.books, epoch: dataStore.analyticsEpoch)
    }

    private var timeOfDay: TimeOfDayAnalytics {
        AnalyticsEngine.timeOfDayAnalysis(books: dataStore.books, epoch: dataStore.analyticsEpoch)
    }

    private var activity: [DailyActivity] {
        AnalyticsEngine.dailyActivity(books: dataStore.books, days: 30)
    }

    private var insights: [ReadingInsight] {
        InsightEngine.generateAll(
            books: dataStore.books,
            goalSet: dataStore.libraryState.goalSet,
            earnedAchievements: dataStore.libraryState.earnedAchievements,
            epoch: dataStore.analyticsEpoch
        )
    }

    var body: some View {
        Group {
            if embedded {
                dashboardContent
            } else {
                NavigationStack {
                    dashboardContent
                        .navigationTitle("Insights")
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { dismiss() }
                            }
                        }
                }
            }
        }
        .frame(minWidth: embedded ? 0 : 540, minHeight: embedded ? 0 : 600)
    }

    /// Embedded mode is already inside ContentView's reader stack. Wrapping it
    /// in a second NavigationStack made the two stacks collide on a reader push
    /// (`AnyNavigationPath.Error.comparisonTypeMismatch`).
    private var dashboardContent: some View {
        Group {
            if dataStore.books.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        statsHeader
                        if !insights.isEmpty {
                            insightsSection
                        }
                        activitySection
                        timeOfDaySection
                    }
                    .padding(24)
                }
            }
        }
    }

    // MARK: - Stats Header

    private var statsHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your Reading at a Glance")
                .font(.title2)
                .fontWeight(.bold)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                spacing: 12
            ) {
                StatCard(
                    value: "\(profile.totalPagesRead)",
                    label: "Pages Read",
                    symbol: "book.pages"
                )
                StatCard(
                    value: formatDuration(profile.totalReadingTime),
                    label: "Total Time",
                    symbol: "clock"
                )
                StatCard(
                    value: "\(profile.totalBooksCompleted)",
                    label: "Books Finished",
                    symbol: "checkmark.seal"
                )
                StatCard(
                    value: "\(streak.currentStreak)",
                    label: "Day Streak",
                    symbol: "flame"
                )
                StatCard(
                    value: String(format: "%.0f", profile.averagePagesPerHour),
                    label: "Pages / Hour",
                    symbol: "speedometer"
                )
                StatCard(
                    value: formatDuration(profile.averageSessionDuration),
                    label: "Avg Session",
                    symbol: "timer"
                )
            }

            // Trend banner
            trendBanner
        }
    }

    private var trendBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: trend.direction == .growth ? "arrow.up.right"
                : trend.direction == .decline ? "arrow.down.right"
                : "minus")
                .foregroundColor(trend.direction == .growth ? .green
                    : trend.direction == .decline ? .red
                    : .secondary)

            Text(trendLabel)
                .font(.subheadline)
                .foregroundColor(.secondary)

            Spacer()

            Text("vs. prior 30 days")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var trendLabel: String {
        let pct = Int(abs(trend.dailyTrend) * 100)
        switch trend.direction {
        case .growth: return "Up \(pct)% — you're reading more than usual"
        case .decline: return "Down \(pct)% — reading pace has slowed"
        case .plateau: return "Steady pace — consistent reading this month"
        }
    }

    // MARK: - Insights Section

    private var insightsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Insights")
                .font(.title3)
                .fontWeight(.semibold)

            ForEach(insights.prefix(6)) { insight in
                InsightCard(insight: insight)
            }
        }
    }

    // MARK: - 30-Day Activity

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Last 30 Days")
                .font(.title3)
                .fontWeight(.semibold)

            let maxDuration = activity.map(\.totalDuration).max() ?? 1

            HStack(alignment: .bottom, spacing: 3) {
                ForEach(activity) { day in
                    let fraction = maxDuration > 0
                        ? day.totalDuration / maxDuration
                        : 0
                    RoundedRectangle(cornerRadius: 2)
                        .fill(fraction > 0 ? Color.accentColor : Color.secondary.opacity(0.15))
                        .frame(maxWidth: .infinity)
                        .frame(height: max(3, CGFloat(fraction) * 80))
                        .help(activityTooltip(for: day))
                }
            }
            .frame(height: 80)
            .padding(.horizontal, 2)

            HStack {
                Text(activity.first.map { shortDate($0.date) } ?? "")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Text(activity.last.map { shortDate($0.date) } ?? "")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Time of Day

    private var timeOfDaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Best Reading Times")
                .font(.title3)
                .fontWeight(.semibold)

            let windows: [ReadingWindow] = [.morning, .afternoon, .evening, .night]
            let maxScore = timeOfDay.scores.values.max() ?? 1

            ForEach(windows, id: \.self) { window in
                let score = timeOfDay.scores[window] ?? 0
                let fraction = maxScore > 0 ? score / maxScore : 0
                let isBest = window == timeOfDay.bestWindow

                HStack(spacing: 10) {
                    Image(systemName: windowSymbol(window))
                        .frame(width: 20)
                        .foregroundColor(isBest ? .accentColor : .secondary)

                    Text(windowName(window))
                        .font(.subheadline)
                        .fontWeight(isBest ? .semibold : .regular)
                        .frame(width: 90, alignment: .leading)

                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isBest ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: geo.size.width * CGFloat(fraction))
                    }
                    .frame(height: 8)

                    if isBest {
                        Text("Best")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15))
                            .foregroundColor(.accentColor)
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView(
            "No Reading Data Yet",
            systemImage: "chart.line.flattrend.xyaxis",
            description: Text("Import a book and start a reading session to see insights here.")
        )
    }

    // MARK: - Helpers

    private func windowName(_ w: ReadingWindow) -> String {
        switch w {
        case .morning: return "Morning"
        case .afternoon: return "Afternoon"
        case .evening: return "Evening"
        case .night: return "Night"
        }
    }

    private func windowSymbol(_ w: ReadingWindow) -> String {
        switch w {
        case .morning: return "sunrise"
        case .afternoon: return "sun.max"
        case .evening: return "sunset"
        case .night: return "moon.stars"
        }
    }

    private func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }

    private func activityTooltip(for day: DailyActivity) -> String {
        let pages = day.pagesRead
        let time = formatDuration(day.totalDuration)
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return "\(f.string(from: day.date)): \(pages) pages · \(time)"
    }
}

// MARK: - StatCard

private struct StatCard: View {
    let value: String
    let label: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .font(.subheadline)
                .foregroundColor(.accentColor)
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - InsightCard

private struct InsightCard: View {
    let insight: ReadingInsight

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: insightSymbol(insight.kind))
                    .foregroundColor(insightColor(insight.priority))
                Text(insight.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                ConfidencePip(confidence: insight.confidence)
            }

            Text(insight.body)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let action = insight.actionSuggestion {
                Text(action)
                    .font(.caption)
                    .foregroundColor(.accentColor)
                    .italic()
            }
        }
        .padding(12)
        .background(insightColor(insight.priority).opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(insightColor(insight.priority).opacity(0.2), lineWidth: 1)
        )
    }

    private func insightSymbol(_ kind: ReadingInsight.InsightKind) -> String {
        switch kind {
        case .bestReadingTime: return "clock.badge.checkmark"
        case .readingTrend: return "chart.line.uptrend.xyaxis"
        case .difficultyMatch: return "brain.head.profile"
        case .streakRisk: return "flame.fill"
        case .speedImprovement: return "hare"
        case .goalOnTrack: return "checkmark.circle"
        case .goalBehind: return "exclamationmark.circle"
        case .sessionLength: return "timer"
        case .predictionQuality: return "chart.bar.xaxis"
        case .genrePattern: return "books.vertical"
        case .milestoneNear: return "flag.checkered"
        case .consistencyReward: return "calendar.badge.checkmark"
        case .drySpell: return "cloud.rain"
        }
    }

    private func insightColor(_ priority: ReadingInsight.InsightPriority) -> Color {
        switch priority {
        case .critical: return .red
        case .high: return .orange
        case .medium: return .accentColor
        case .low: return .secondary
        }
    }
}

// MARK: - ConfidencePip

private struct ConfidencePip: View {
    let confidence: Double

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0 ..< 3, id: \.self) { i in
                Circle()
                    .fill(Double(i + 1) <= confidence * 3
                        ? Color.accentColor
                        : Color.secondary.opacity(0.3))
                    .frame(width: 5, height: 5)
            }
        }
        .help("Confidence: \(Int(confidence * 100))%")
    }
}

// MARK: - Preview

#Preview {
    ReadingInsightsDashboard()
        .environmentObject(DataStore())
}
