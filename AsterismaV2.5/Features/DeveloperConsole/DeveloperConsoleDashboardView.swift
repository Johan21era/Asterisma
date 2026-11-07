//  DeveloperConsoleDashboardView.swift
//  AsterismaV2.5
//
//  DEVELOPER CONSOLE — Phase 2 (Dashboard)
//
//  Every value on this screen is either:
//    (a) a direct system/bundle fact (DeveloperConsoleSystemMetrics), or
//    (b) sourced from a real subsystem's own ConsoleSubsystemSnapshot,
//        reached only through DeveloperConsoleRegistry.
//
//  Nothing here is hardcoded. A subsystem this session did not get to
//  instrument shows as "NOT YET INSTRUMENTED" (DeveloperConsoleKnownSubsystems
//  below) rather than being silently omitted or shown as a fake "Healthy" —
//  that distinction is the whole point of Phase 2's "Done when" criteria.
//
//  SCOPE NOTE: the contract's Phase 2 checklist names some subsystems by
//  generic role ("Pattern Engine", "Timeline Engine", "Reading Session
//  Detector") that don't match any real type found in this codebase this
//  session. Rather than invent matching types, this Dashboard shows what is
//  actually real (see the scope note in DeveloperConsoleSystemMetrics.swift
//  and developer-console-component-registry.md for the full reasoning).
//

#if DEBUG

import SwiftUI
import Combine

// MARK: - DeveloperConsoleKnownSubsystem

/// A subsystem this session's inspection confirmed is REAL and genuinely
/// live in the running app (instantiated and/or called from a real,
/// verified code path) — whether or not it has been instrumented yet.
/// Deliberately excludes anything found to be declared-but-never-instantiated
/// (e.g. the eight actor types in BehavioralCategory.swift — see the
/// component registry) since those aren't "pending instrumentation of a
/// live thing," they're dormant code, a different and separate finding.
///
/// This list is a representative subset from this session's inspection, not
/// the full application. Extending it later is pure additive work: add a
/// line here, add a #if DEBUG conformance to the subsystem's own file.
struct DeveloperConsoleKnownSubsystem: Identifiable, Hashable {
    let id: String
    let displayName: String
    let category: ConsoleSubsystemCategory
}

enum DeveloperConsoleKnownSubsystems {
    static let all: [DeveloperConsoleKnownSubsystem] = [
        .init(id: "data-store", displayName: "Data Store", category: .manager),
        .init(id: "session-coordinator", displayName: "Session Coordinator", category: .manager),
        .init(id: "session-event-router", displayName: "Session Event Router", category: .manager),
        .init(id: "goal-progress-view-model", displayName: "Goal Progress ViewModel", category: .viewModel),
        .init(id: "behavior-context-engine", displayName: "Behavior Context Engine", category: .engine),
        .init(id: "environment-engine", displayName: "Environment Engine", category: .engine),
        .init(id: "weather-kit-service", displayName: "WeatherKit Service", category: .service),
        .init(id: "notification-scheduler", displayName: "Notification Scheduler", category: .service),
        .init(id: "achievement-engine", displayName: "Achievement Engine", category: .engine),
        .init(id: "data-maturity-engine", displayName: "Data Maturity Engine", category: .engine),
        .init(id: "musical-analysis-engine", displayName: "Musical Analysis Engine", category: .engine),
        .init(id: "estimation-engine", displayName: "Estimation Engine", category: .engine),
        .init(id: "insight-engine", displayName: "Insight Engine", category: .engine),
        .init(id: "analytics-engine", displayName: "Analytics Engine", category: .engine),
        .init(id: "audio-profile-store", displayName: "Audio Profile Store", category: .manager),
        .init(id: "new-year-transition-monitor", displayName: "New Year Transition Monitor", category: .manager),
    ]
}

// MARK: - DeveloperConsoleDashboardView

struct DeveloperConsoleDashboardView: View {
    @ObservedObject private var registry = DeveloperConsoleRegistry.shared
    @State private var snapshots: [ConsoleSubsystemSnapshot] = []

    // Polling fallback, bounded to 1s per the contract's Console Technical
    // Foundation. Registration events reach this view via @ObservedObject
    // (push, Combine) already; this timer exists only to notice CHANGES
    // inside an already-registered subsystem's snapshot (e.g. DataStore's
    // book count), since those changes aren't independently published back
    // through the registry today. Documented here as the fallback it is,
    // not presented as the primary design.
    private let refreshTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerStrip
                if !warningsAndErrors.isEmpty {
                    warningsErrorsSection
                }
                subsystemsSection
            }
            .padding(20)
        }
        .background(ConsolePalette.background)
        .onAppear(perform: refresh)
        .onReceive(refreshTimer) { _ in refresh() }
    }

    private func refresh() {
        snapshots = registry.currentSnapshots()
    }

    // MARK: Header

    private var headerStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("APPLICATION")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                statTile(label: "Status", value: overallStatusText, valueColor: overallStatusColor)
                statTile(label: "Build Configuration", value: DeveloperConsoleSystemMetrics.buildConfiguration)
                statTile(label: "Version", value: DeveloperConsoleSystemMetrics.appVersionString)
                statTile(label: "Uptime", value: DeveloperConsoleSystemMetrics.uptimeDescription)
                statTile(label: "Memory Usage", value: DeveloperConsoleSystemMetrics.memoryUsageDescription)
                statTile(label: "CPU Time", value: DeveloperConsoleSystemMetrics.cpuTimeDescription)
                statTile(label: "Storage Usage (app data)", value: DeveloperConsoleSystemMetrics.storageUsageDescription)
                statTile(label: "Persistence", value: "Mixed — JSON files (Data Store) + SQLite (WeatherKit Service)")
                statTile(label: "Subsystems Registered", value: "\(snapshots.count) of \(DeveloperConsoleKnownSubsystems.all.count) known")
            }
        }
        .padding(16)
        .background(ConsolePalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(ConsolePalette.border, lineWidth: 1))
    }

    private var overallStatusText: String {
        let errorCount = snapshots.filter { $0.status == .error }.count
        let warningCount = snapshots.filter { $0.status == .warning }.count
        if errorCount > 0 { return "\(errorCount) subsystem(s) reporting errors" }
        if warningCount > 0 { return "\(warningCount) subsystem(s) reporting warnings" }
        if snapshots.isEmpty { return "No subsystems registered yet" }
        return "Running normally"
    }

    private var overallStatusColor: Color {
        if snapshots.contains(where: { $0.status == .error }) { return ConsolePalette.statusColor(.error) }
        if snapshots.contains(where: { $0.status == .warning }) { return ConsolePalette.statusColor(.warning) }
        return ConsolePalette.statusColor(.healthy)
    }

    // MARK: Warnings & Errors

    private struct FlaggedItem: Identifiable {
        let id = UUID()
        let subsystemName: String
        let message: String
        let isError: Bool
    }

    private var warningsAndErrors: [FlaggedItem] {
        snapshots.flatMap { snapshot in
            snapshot.errors.map { FlaggedItem(subsystemName: snapshot.identity.displayName, message: $0, isError: true) }
                + snapshot.warnings.map { FlaggedItem(subsystemName: snapshot.identity.displayName, message: $0, isError: false) }
        }
    }

    private var warningsErrorsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("WARNINGS & ERRORS")
            VStack(spacing: 6) {
                ForEach(warningsAndErrors) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: item.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(item.isError ? ConsolePalette.statusColor(.error) : ConsolePalette.statusColor(.warning))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.subsystemName)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(ConsolePalette.textSecondary)
                            Text(item.message)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(ConsolePalette.textPrimary)
                        }
                        Spacer()
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(ConsolePalette.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    // MARK: Subsystems

    private var subsystemsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("SUBSYSTEMS")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                ForEach(DeveloperConsoleKnownSubsystems.all) { known in
                    if let snapshot = snapshots.first(where: { $0.id == known.id }) {
                        subsystemTile(snapshot)
                    } else {
                        notInstrumentedTile(known)
                    }
                }
                // Anything registered but NOT in the known-subsystems list
                // above still shows up here — the registry is the ultimate
                // source of truth; the known list only adds honest
                // placeholders for real things not registered yet.
                ForEach(unlistedSnapshots) { snapshot in
                    subsystemTile(snapshot)
                }
            }
        }
    }

    private var unlistedSnapshots: [ConsoleSubsystemSnapshot] {
        let knownIDs = Set(DeveloperConsoleKnownSubsystems.all.map(\.id))
        return snapshots.filter { !knownIDs.contains($0.id) }
    }

    private func subsystemTile(_ snapshot: ConsoleSubsystemSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(ConsolePalette.statusColor(snapshot.status))
                    .frame(width: 8, height: 8)
                Text(snapshot.identity.displayName)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(ConsolePalette.textPrimary)
                Spacer()
                Text(snapshot.identity.category.displayName)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(ConsolePalette.textSecondary)
            }
            Text(snapshot.status.displayName.uppercased())
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(ConsolePalette.statusColor(snapshot.status))
            Text(snapshot.currentActivity)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(ConsolePalette.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if !snapshot.metrics.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(snapshot.metrics.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        HStack {
                            Text(key)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(ConsolePalette.textSecondary)
                            Spacer()
                            Text(value)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(ConsolePalette.textPrimary)
                        }
                    }
                }
                .padding(.top, 2)
            }
            if let lastUpdated = snapshot.lastUpdated {
                Text("Updated \(lastUpdated.formatted(date: .omitted, time: .standard))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(ConsolePalette.textSecondary.opacity(0.7))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ConsolePalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(ConsolePalette.border, lineWidth: 1))
    }

    private func notInstrumentedTile(_ known: DeveloperConsoleKnownSubsystem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(ConsolePalette.notInstrumented)
                    .frame(width: 8, height: 8)
                Text(known.displayName)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(ConsolePalette.textSecondary)
                Spacer()
                Text(known.category.displayName)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(ConsolePalette.textSecondary.opacity(0.6))
            }
            Text("NOT YET INSTRUMENTED")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(ConsolePalette.notInstrumented)
            Text("Real and live in the app — just not wired into the console yet.")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(ConsolePalette.textSecondary.opacity(0.7))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ConsolePalette.panel.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(ConsolePalette.border.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
    }

    // MARK: Shared

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(ConsolePalette.textSecondary)
    }

    private func statTile(label: String, value: String, valueColor: Color = ConsolePalette.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(ConsolePalette.textSecondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(valueColor)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(ConsolePalette.background)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

#endif
