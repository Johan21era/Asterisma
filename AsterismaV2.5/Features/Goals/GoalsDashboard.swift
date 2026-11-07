//  GoalsDashboard.swift
//  AsterismaV2.5
//
//  Displays live goal statuses from GoalProgressViewModel, which is already
//  bound to DataStore and refreshes automatically after every session.
//
//  Engines surfaced:
//    - GoalProgressViewModel  (statuses, deadlineStatuses, recommendedDailyTarget,
//                              projectedAnnualCompletions — all @Published)
//    - ReadingGoalManager     (called internally by GoalProgressViewModel)
//

import SwiftUI

struct GoalsDashboard: View {
    @EnvironmentObject private var goalVM: GoalProgressViewModel
    @EnvironmentObject private var dataStore: DataStore
    @Environment(\.dismiss) private var dismiss

    /// Embedded in the main window as a destination. The standalone sheet may
    /// still present itself with its own Done button.
    var embedded: Bool = false

    var body: some View {
        Group {
            if embedded {
                dashboardContent
            } else {
                NavigationStack {
                    dashboardContent
                        .navigationTitle("Goals")
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { dismiss() }
                            }
                        }
                }
            }
        }
        .frame(minWidth: embedded ? 0 : 480, minHeight: embedded ? 0 : 520)
    }

    /// The dashboard itself. Embedded mode deliberately has no NavigationStack:
    /// it already sits inside ContentView's reader stack, and a second stack
    /// makes SwiftUI collide the two paths when a book is opened from here
    /// (`AnyNavigationPath.Error.comparisonTypeMismatch`).
    private var dashboardContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // ── Projection banner ──────────────────────────────────
                projectionBanner

                // ── Daily / annual / streak goal cards ─────────────────
                if goalVM.statuses.isEmpty {
                    noGoalsState
                } else {
                    goalsSection
                }

                // ── Per-book deadlines ─────────────────────────────────
                if !goalVM.deadlineStatuses.isEmpty {
                    deadlinesSection
                }
            }
            .padding(24)
        }
    }

    // MARK: - Projection Banner

    private var projectionBanner: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Recommended today")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(goalVM.recommendedDailyTarget) pages")
                    .font(.title2)
                    .fontWeight(.bold)
            }

            Divider().frame(height: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text("On track for this year")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(goalVM.projectedAnnualCompletions) books")
                    .font(.title2)
                    .fontWeight(.bold)
            }

            Spacer()
        }
        .padding(16)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Goal Cards

    private var goalsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your Goals")
                .font(.title3)
                .fontWeight(.semibold)

            ForEach(goalVM.statuses, id: \.goal) { status in
                GoalStatusCard(status: status)
            }
        }
    }

    // MARK: - No Goals State

    private var noGoalsState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your Goals")
                .font(.title3)
                .fontWeight(.semibold)

            ContentUnavailableView(
                "No Goals Set",
                systemImage: "target",
                description: Text("Goals can be configured in the app settings.")
            )
            .frame(height: 160)
        }
    }

    // MARK: - Book Deadlines

    private var deadlinesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Book Deadlines")
                .font(.title3)
                .fontWeight(.semibold)

            ForEach(goalVM.deadlineStatuses.sorted { $0.daysRemaining < $1.daysRemaining },
                    id: \.deadline.id)
            { status in
                BookDeadlineRow(status: status)
            }
        }
    }
}

// MARK: - GoalStatusCard

private struct GoalStatusCard: View {
    let status: GoalStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Image(systemName: goalSymbol(status.goal))
                    .foregroundColor(status.isAchieved ? .green : .accentColor)
                Text(status.goal.rawValue)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                if status.isAchieved {
                    Label("Done", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                } else {
                    Text(status.period)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(status.isAchieved ? Color.green : Color.accentColor)
                        .frame(width: geo.size.width * CGFloat(status.percentComplete))
                }
            }
            .frame(height: 8)

            // Progress label
            HStack {
                Text("\(status.formattedCurrent) of \(status.formattedTarget)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.0f%%", status.percentComplete * 100))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(status.isAchieved ? .green : .primary)
            }
        }
        .padding(14)
        .background(
            (status.isAchieved ? Color.green : Color.accentColor).opacity(0.06),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    private func goalSymbol(_ kind: GoalStatus.GoalKind) -> String {
        switch kind {
        case .dailyPages: return "book.pages"
        case .dailyTime: return "clock"
        case .annualBooks: return "books.vertical"
        case .weeklyStreak: return "calendar.badge.checkmark"
        case .bookDeadline: return "calendar"
        }
    }
}

// MARK: - BookDeadlineRow

private struct BookDeadlineRow: View {
    let status: BookDeadlineStatus

    var body: some View {
        HStack(spacing: 12) {
            // Urgency indicator
            Circle()
                .fill(urgencyColor)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 3) {
                Text(status.book.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                if status.isOverdue {
                    Text("Overdue")
                        .font(.caption)
                        .foregroundColor(.red)
                } else {
                    Text("\(status.daysRemaining) days · \(status.pagesRemaining) pages left")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Required pace
            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.0f pg/day", status.requiredPagesPerDay))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(status.isAchievable ? .primary : .orange)
                Text(status.isAchievable ? "Achievable" : "Challenging")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(urgencyColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private var urgencyColor: Color {
        if status.isOverdue {
            return .red
        }
        if status.daysRemaining <= 3 {
            return .orange
        }
        if !status.isAchievable {
            return .yellow
        }
        return .green
    }
}

// MARK: - Preview

#Preview {
    GoalsDashboard()
        .environmentObject(GoalProgressViewModel())
        .environmentObject(DataStore())
}
