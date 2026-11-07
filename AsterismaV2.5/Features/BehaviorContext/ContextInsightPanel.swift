//  ContextInsightPanel.swift
//  AsterismaV2.5
//
//  Presents the output of BehaviorContextEngine.analyze() — behavioral routines,
//  context transitions, and narrative descriptions of reading patterns.
//
//  Engine surfaced:
//    - BehaviorContextEngine (@EnvironmentObject — owned by App struct as @StateObject)
//    - BehavioralContextSummary.narratives  (plain-English reading pattern descriptions)
//    - BehavioralContextSummary.routines    (detected timing + environment patterns)
//    - BehavioralContextSummary.confidence  (how much data the engine has processed)
//
//  Data accumulation: this panel shows "learning" state for the first several
//  weeks of use. That is correct — the engine requires behavioral history.
//

import SwiftUI

struct ContextInsightPanel: View {
    @EnvironmentObject private var contextEngine: BehaviorContextEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationStack {
            Group {
                if let summary = contextEngine.summary {
                    if summary.routines.isEmpty && summary.narratives.isEmpty {
                        buildingState(sessionCount: summary.contextRecords.count)
                    } else {
                        summaryContent(summary: summary)
                    }
                } else {
                    buildingState(sessionCount: 0)
                }
            }
            .navigationTitle("Your Context")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        openWindow(id: "reading-context-advanced")
                    } label: {
                        Label("Advanced Context", systemImage: "brain.head.profile")
                    }
                }
                // Confidence badge in the toolbar
                if let summary = contextEngine.summary {
                    ToolbarItem(placement: .secondaryAction) {
                        confidenceBadge(summary.confidence)
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 520)
    }

    // MARK: - Summary Content

    private func summaryContent(summary: BehavioralContextSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // ── Narratives ─────────────────────────────────────────────
                if !summary.narratives.isEmpty {
                    narrativesSection(summary.narratives)
                }

                // ── Detected Routines ──────────────────────────────────────
                if !summary.routines.isEmpty {
                    routinesSection(summary.routines)
                }

                // ── Context Records ─────────────────────────────────────────
                if !summary.contextRecords.isEmpty {
                    contextRecordsSection(summary.contextRecords)
                }

                // ── Data note ─────────────────────────────────────────────
                dataNote(
                    recordCount: summary.contextRecords.count,
                    confidence: summary.confidence
                )
            }
            .padding(24)
        }
    }

    // MARK: - Narratives

    private func narrativesSection(_ narratives: [ContextNarrative]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reading Patterns")
                .font(.title3)
                .fontWeight(.semibold)

            ForEach(narratives) { narrative in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "quote.opening")
                        .font(.subheadline)
                        .foregroundColor(.accentColor)
                        .padding(.top, 2)

                    Text(narrative.text)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .background(
                    Color.accentColor.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 12)
                )
            }
        }
    }

    // MARK: - Routines

    private func routinesSection(_ routines: [BehavioralRoutine]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Detected Routines")
                .font(.title3)
                .fontWeight(.semibold)

            ForEach(routines.prefix(5)) { routine in
                RoutineRow(routine: routine)
            }
        }
    }

    // MARK: - Context Records

    private func contextRecordsSection(_ records: [ReadingContextRecord]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sessions Analyzed")
                .font(.title3)
                .fontWeight(.semibold)

            Text("\(records.count) reading contexts have been observed and interpreted.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            // Top 3 most frequent pre-reading environments
            let envCounts = Dictionary(grouping: records) { $0.preReadingContext.type }
                .mapValues(\.count)
                .sorted { $0.value > $1.value }
                .prefix(3)

            if !envCounts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(envCounts, id: \.key) { env, count in
                        HStack {
                            Image(systemName: environmentSymbol(env))
                                .frame(width: 22)
                                .foregroundColor(.accentColor)
                            Text(env.rawValue.capitalized)
                                .font(.subheadline)
                            Spacer()
                            Text("\(count) sessions")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(12)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // MARK: - Building / Empty States

    private func buildingState(sessionCount: Int) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "brain")
                .font(.system(size: 52))
                .foregroundColor(.secondary.opacity(0.5))

            VStack(spacing: 8) {
                Text("Learning Your Patterns")
                    .font(.title3)
                    .fontWeight(.semibold)

                if sessionCount == 0 {
                    Text("The behavioral context engine is running and recording patterns around your reading sessions. Check back after a few reading sessions.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Text("The engine has observed \(sessionCount) reading contexts so far. Routines and patterns will appear as more data accumulates — typically after 2–3 weeks of regular use.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data Note

    private func dataNote(recordCount: Int, confidence: ContextConfidence) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundColor(.secondary)
                .font(.caption)

            Text("Based on \(recordCount) sessions · Confidence \(Int(confidence.score * 100))%")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Confidence Badge

    private func confidenceBadge(_ confidence: ContextConfidence) -> some View {
        let pct = Int(confidence.score * 100)
        let color: Color = confidence.score >= 0.6 ? .green
            : confidence.score >= 0.35 ? .orange
            : .secondary
        return Label("\(pct)% confidence", systemImage: "waveform")
            .font(.caption)
            .foregroundColor(color)
    }

    // MARK: - Helpers

    private func environmentSymbol(_ env: BehavioralEnvironmentType) -> String {
        switch env {
        case .work: return "briefcase"
        case .development: return "laptopcomputer"
        case .research: return "magnifyingglass"
        case .gaming: return "gamecontroller"
        case .entertainment: return "play.rectangle"
        case .learning: return "graduationcap"
        case .social: return "bubble.left.and.bubble.right"
        case .browsing: return "safari"
        case .creative: return "paintbrush"
        case .administrative: return "doc.text"
        case .idle: return "moon.zzz"
        case .recovery: return "heart"
        case .mixed: return "squares.leading.rectangle"
        case .unknown: return "questionmark.circle"
        }
    }
}

// MARK: - RoutineRow

private struct RoutineRow: View {
    let routine: BehavioralRoutine

    private var hourLabel: String {
        let hour = routine.averageHour
        if hour == 0 {
            return "Midnight"
        }
        if hour < 12 {
            return "\(hour) AM"
        }
        if hour == 12 {
            return "Noon"
        }
        return "\(hour - 12) PM"
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(routine.title)
                    .font(.subheadline)
                    .fontWeight(.medium)

                HStack(spacing: 8) {
                    Label(hourLabel, systemImage: "clock")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("·")
                        .foregroundColor(.secondary)

                    Text("\(routine.recurrenceCount)×")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("·")
                        .foregroundColor(.secondary)

                    Text(routine.dominantEnvironment.rawValue.capitalized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Confidence pip
            let score = routine.confidence.score
            HStack(spacing: 3) {
                ForEach(0 ..< 3, id: \.self) { i in
                    Circle()
                        .fill(Double(i + 1) <= score * 3
                            ? Color.accentColor
                            : Color.secondary.opacity(0.2))
                        .frame(width: 6, height: 6)
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Preview

#Preview {
    ContextInsightPanel()
        .environmentObject(BehaviorContextEngine())
}
