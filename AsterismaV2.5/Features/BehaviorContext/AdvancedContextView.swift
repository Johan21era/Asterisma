//  AdvancedContextView.swift
//  Bedrock G6B — the V3 deep-dive surface.
//
//  The simple “Your Context” panel stays friendly. This window exposes the
//  evidence-gated V3 report: routines, significance, diversity, transitions,
//  and cited narratives.

import SwiftUI

struct AdvancedContextView: View {
    @EnvironmentObject private var engine: BehaviorContextEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let report = engine.intelligenceReport {
                    content(report)
                } else {
                    ContentUnavailableView(
                        "Not Enough Evidence Yet",
                        systemImage: "brain",
                        description: Text("Read a few sessions or import a library so the context engine can analyze your patterns."))
                }
            }
            .navigationTitle("Advanced Context")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 760, minHeight: 620)
    }

    private func content(_ report: FullContextIntelligenceReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header(report)
                if !report.narrativeResult.citedNarratives.isEmpty {
                    narratives(report.narrativeResult.citedNarratives)
                }
                routines(report)
                significance(report)
                diversity(report)
                provenance()
            }
            .padding(24)
        }
    }

    private func header(_ report: FullContextIntelligenceReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Your Reading Context")
                .font(.title2.bold())
            Text("Generated \(report.generatedAt.formatted(date: .abbreviated, time: .shortened)) · \(report.contextResult.contexts.count) sessions analyzed")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func narratives(_ narratives: [CitedContextNarrative]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Reading Patterns", icon: "quote.opening")
            ForEach(narratives.prefix(8)) { narrative in
                VStack(alignment: .leading, spacing: 4) {
                    Text(narrative.text)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(String(describing: narrative.category)) · confidence \(Int(narrative.confidence.score * 100))% · \(narrative.sessionIDs.count) session(s)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func routines(_ report: FullContextIntelligenceReport) -> some View {
        let detected = report.routineResult.advancedRoutines.detectedRoutines
        return VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Detected Routines", icon: "clock.arrow.circlepath")
            if detected.isEmpty {
                Text("No stable routine clears the evidence threshold yet.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                ForEach(detected.prefix(8)) { routine in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(routine.title).font(.subheadline.weight(.medium))
                            Text("\(routine.recurrenceCount)× · \(routine.dominantEnvironment.rawValue.capitalized)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Text("\(Int(routine.confidence.score * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func significance(_ report: FullContextIntelligenceReport) -> some View {
        let c = report.significanceResult.confidenceBreakdown
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Evidence Quality", icon: "checkmark.seal")
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                metricRow("Evidence volume", c.evidenceVolume)
                metricRow("Recency", c.evidenceRecency)
                metricRow("Consistency", c.evidenceConsistency)
                metricRow("Historical depth", c.historicalDepth)
                metricRow("Routine strength", c.routineStrength)
                metricRow("Overall", c.overallScore)
            }
            Text("\(report.significanceResult.evidenceChains.count) evidence chains · \(report.contextResult.chains.count) transitions · \(report.contextResult.trends.count) trends")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func diversity(_ report: FullContextIntelligenceReport) -> some View {
        let d = report.contextResult.diversity
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Environment Diversity", icon: "square.stack.3d.up")
            Text("\(d.uniquePreReadingEnvironments) pre-reading environments · \(d.uniquePostReadingEnvironments) post-reading environments")
                .font(.subheadline)
            Text("Classification: \(d.diversityClassification.rawValue.capitalized) · dominant share \(Int(d.dominanceRatio * 100))%")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func provenance() -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
            Text("This view is evidence-gated. Claims appear only when the maturity engine says the evidence is strong enough; absence means “not enough evidence,” not “no pattern.”")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func sectionTitle(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.headline)
    }

    private func metricRow(_ label: String, _ value: Double) -> some View {
        GridRow {
            Text(label).font(.caption).foregroundColor(.secondary)
            ProgressView(value: min(1, max(0, value)))
                .frame(width: 160)
            Text("\(Int(value * 100))%").font(.caption.monospacedDigit())
        }
    }
}
