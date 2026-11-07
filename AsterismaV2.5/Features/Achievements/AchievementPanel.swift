//  AchievementPanel.swift
//  AsterismaV2.5
//
//  Displays all earned achievements (grouped by tier) and the next un-earned
//  achievements the user is closest to unlocking.
//
//  Engines called (read-only, static, no side effects):
//    - AchievementEngine.summary(earned:)
//    - AchievementEngine.upcoming(books:earned:limit:)
//    - AchievementDefinition.definition(for:)
//

import SwiftUI

struct AchievementPanel: View {
    @EnvironmentObject private var dataStore: DataStore
    @Environment(\.dismiss) private var dismiss

    private var earned: [EarnedAchievement] {
        dataStore.libraryState.earnedAchievements
    }

    private var summary: [AchievementDefinition.AchievementTier: [EarnedAchievement]] {
        AchievementEngine.summary(earned: earned)
    }

    private var upcoming: [AchievementKind] {
        AchievementEngine.upcoming(
            books: dataStore.books,
            earned: earned,
            limit: 5
        )
    }

    /// Tier display order: platinum → gold → silver → bronze
    private let tierOrder: [AchievementDefinition.AchievementTier] = [
        .platinum, .gold, .silver, .bronze,
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    // Summary counts
                    headerRow

                    // Upcoming milestones
                    if !upcoming.isEmpty {
                        upcomingSection
                    }

                    // Earned by tier
                    if earned.isEmpty {
                        emptyState
                    } else {
                        earnedSection
                    }
                }
                .padding(24)
            }
            .navigationTitle("Achievements")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 560)
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 0) {
            ForEach(tierOrder, id: \.self) { tier in
                let count = summary[tier]?.count ?? 0
                VStack(spacing: 4) {
                    Text("\(count)")
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundColor(tierColor(tier))
                    Text(tierName(tier))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(16)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Upcoming Milestones

    private var upcomingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Coming Up")
                .font(.title3)
                .fontWeight(.semibold)

            ForEach(upcoming, id: \.self) { kind in
                if let def = AchievementDefinition.definition(for: kind) {
                    UpcomingAchievementRow(definition: def)
                }
            }
        }
    }

    // MARK: - Earned by Tier

    private var earnedSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(tierOrder, id: \.self) { tier in
                if let group = summary[tier], !group.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: tierSymbol(tier))
                                .foregroundColor(tierColor(tier))
                            Text(tierName(tier))
                                .font(.title3)
                                .fontWeight(.semibold)
                            Text("(\(group.count))")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }

                        LazyVGrid(
                            columns: Array(
                                repeating: GridItem(.flexible(), spacing: 12),
                                count: 3
                            ),
                            spacing: 12
                        ) {
                            ForEach(group) { achievement in
                                if let def = AchievementDefinition.definition(for: achievement.kind) {
                                    AchievementBadge(
                                        definition: def,
                                        earnedAt: achievement.earnedAt
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView(
            "No Achievements Yet",
            systemImage: "medal",
            description: Text("Keep reading to unlock your first achievement. You're closer than you think.")
        )
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    // MARK: - Helpers

    private func tierName(_ tier: AchievementDefinition.AchievementTier) -> String {
        switch tier {
        case .bronze: return "Bronze"
        case .silver: return "Silver"
        case .gold: return "Gold"
        case .platinum: return "Platinum"
        }
    }

    private func tierColor(_ tier: AchievementDefinition.AchievementTier) -> Color {
        switch tier {
        case .bronze: return Color(red: 0.80, green: 0.50, blue: 0.20)
        case .silver: return Color(red: 0.70, green: 0.70, blue: 0.75)
        case .gold: return Color(red: 0.90, green: 0.75, blue: 0.10)
        case .platinum: return Color(red: 0.60, green: 0.85, blue: 0.90)
        }
    }

    private func tierSymbol(_ tier: AchievementDefinition.AchievementTier) -> String {
        switch tier {
        case .bronze: return "medal"
        case .silver: return "medal.fill"
        case .gold: return "trophy"
        case .platinum: return "crown.fill"
        }
    }
}

// MARK: - AchievementBadge

private struct AchievementBadge: View {
    let definition: AchievementDefinition
    let earnedAt: Date

    @State private var showingDetail = false

    var body: some View {
        Button {
            showingDetail = true
        } label: {
            VStack(spacing: 8) {
                Image(systemName: definition.symbolName)
                    .font(.system(size: 28))
                    .foregroundColor(tierColor(definition.tier))

                Text(definition.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(
                tierColor(definition.tier).opacity(0.08),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(tierColor(definition.tier).opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingDetail) {
            AchievementDetailPopover(definition: definition, earnedAt: earnedAt)
        }
    }

    private func tierColor(_ tier: AchievementDefinition.AchievementTier) -> Color {
        switch tier {
        case .bronze: return Color(red: 0.80, green: 0.50, blue: 0.20)
        case .silver: return Color(red: 0.70, green: 0.70, blue: 0.75)
        case .gold: return Color(red: 0.90, green: 0.75, blue: 0.10)
        case .platinum: return Color(red: 0.60, green: 0.85, blue: 0.90)
        }
    }
}

// MARK: - AchievementDetailPopover

private struct AchievementDetailPopover: View {
    let definition: AchievementDefinition
    let earnedAt: Date

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: definition.symbolName)
                    .font(.title2)
                Text(definition.title)
                    .font(.headline)
            }
            Text(definition.description)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text("Earned \(Self.dateFormatter.string(from: earnedAt))")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(16)
        .frame(minWidth: 220)
    }
}

// MARK: - UpcomingAchievementRow

private struct UpcomingAchievementRow: View {
    let definition: AchievementDefinition

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: definition.symbolName)
                .font(.title3)
                .foregroundColor(.secondary)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(definition.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(definition.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text("Soon")
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.12))
                .foregroundColor(.accentColor)
                .clipShape(Capsule())
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Preview

#Preview {
    AchievementPanel()
        .environmentObject(DataStore())
}
