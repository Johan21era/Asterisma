//  DeveloperConsoleRootView.swift
//  AsterismaV2.5
//
//  DEVELOPER CONSOLE — Phase 1 (Foundation)
//
//  The console's own separate navigation shell. This is intentionally NOT
//  content pushed into the existing ContentView (NewContentView.swift) — it
//  is the root view of its own separate SwiftUI `Window` scene, wired in
//  AsterismaApp.swift. That is what makes "opened and closed without
//  any change to existing view hierarchies or navigation state" true by
//  construction rather than by care: there is no shared state to accidentally
//  disturb, because there is no shared view tree at all.
//
//  Visual language is deliberately distinct from the app's consumer-facing
//  design (see NewContentView.swift's .regularMaterial / SF Symbols style):
//  dark background, monospaced numerics, dense layout — so it is always
//  obvious which "mode" is on screen, per the contract's requirement.
//

#if DEBUG

import SwiftUI

// MARK: - Window identity

/// Stable id for the console's Window scene. Kept as a single constant so
/// AsterismaApp.swift's Window(id:) declaration and the openWindow(id:)
/// call site can never drift apart from each other.
enum DeveloperConsoleWindowID {
    static let id = "developer-console"
}

// MARK: - DeveloperConsoleSection

/// Every section the console will eventually have, per the contract's 15
/// phases. Only `.dashboard` is live this session (Phase 2). The rest are
/// listed now, disabled, so the sidebar honestly previews the console's full
/// planned shape instead of hiding it — and so later phases only ever need
/// to flip `isAvailable`, never restructure this list or the views that
/// read it.
enum DeveloperConsoleSection: String, CaseIterable, Identifiable, Hashable {
    case dashboard
    case environment
    case sentinel
    case demoLab
    case subsystemExplorer
    case eventTimeline
    case stateInspector
    case dependencyGraph
    case architectureExplorer
    case performanceCenter
    case errorCenter
    case featureUsage
    case deadCode
    case internalSearch
    case learningMode
    case exportSnapshot

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .environment: return "Environment Studio"
        case .sentinel: return "Sentinel"
        case .demoLab: return "Demo Profile Lab"
        case .subsystemExplorer: return "Subsystem Explorer"
        case .eventTimeline: return "Live Event Timeline"
        case .stateInspector: return "Current State Inspector"
        case .dependencyGraph: return "Dependency Graph"
        case .architectureExplorer: return "Architecture Explorer"
        case .performanceCenter: return "Performance Center"
        case .errorCenter: return "Error Center"
        case .featureUsage: return "Feature Usage Explorer"
        case .deadCode: return "Dead Code Analysis"
        case .internalSearch: return "Internal Search"
        case .learningMode: return "Learning Mode"
        case .exportSnapshot: return "Export & Continuity"
        }
    }

    var symbolName: String {
        switch self {
        case .dashboard: return "gauge.medium"
        case .environment: return "sun.horizon"
        case .sentinel: return "shield.lefthalf.filled"
        case .demoLab: return "theatermasks"
        case .subsystemExplorer: return "square.stack.3d.up"
        case .eventTimeline: return "clock.arrow.circlepath"
        case .stateInspector: return "eye"
        case .dependencyGraph: return "point.3.connected.trianglepath.dotted"
        case .architectureExplorer: return "building.columns"
        case .performanceCenter: return "speedometer"
        case .errorCenter: return "exclamationmark.triangle"
        case .featureUsage: return "chart.bar"
        case .deadCode: return "trash"
        case .internalSearch: return "magnifyingglass"
        case .learningMode: return "book"
        case .exportSnapshot: return "square.and.arrow.up"
        }
    }

    /// Phase 2 only, this session. Every other section is a real, named
    /// destination on the roadmap — shown, not hidden — but disabled until
    /// its own phase is built, so the console never claims to show live
    /// data it does not actually have yet.
    var isAvailable: Bool {
        switch self {
        case .dashboard, .environment, .demoLab, .sentinel, .subsystemExplorer: return true
        default: return false
        }
    }

    var plannedPhaseLabel: String {
        switch self {
        case .dashboard: return "Phase 2"
        case .environment: return "Live"
        case .sentinel: return "Live"
        case .demoLab: return "Live QA"
        case .subsystemExplorer: return "Live"
        case .eventTimeline: return "Phase 5"
        case .stateInspector: return "Phase 6"
        case .dependencyGraph: return "Phase 7"
        case .architectureExplorer: return "Phase 8"
        case .performanceCenter: return "Phase 9"
        case .errorCenter: return "Phase 10"
        case .featureUsage: return "Phase 11"
        case .deadCode: return "Phase 12"
        case .internalSearch: return "Phase 13"
        case .learningMode: return "Phase 14"
        case .exportSnapshot: return "Phase 15"
        }
    }
}

// MARK: - ConsolePalette

/// Deliberately separate from the app's own color system (EnvironmentColor,
/// EnvironmentPalette, etc.) — the console must never depend on, or be
/// affected by, anything in the consumer-facing app's visual state (e.g.
/// the current time-of-day Environment Engine theme). A diagnostic tool
/// that itself depends on the thing it diagnoses is a design smell.
enum ConsolePalette {
    static let background = Color(red: 0.07, green: 0.08, blue: 0.09)
    static let panel = Color(red: 0.11, green: 0.12, blue: 0.135)
    static let border = Color(red: 0.22, green: 0.24, blue: 0.26)
    static let textPrimary = Color(red: 0.90, green: 0.92, blue: 0.93)
    static let textSecondary = Color(red: 0.58, green: 0.62, blue: 0.65)

    static func statusColor(_ status: ConsoleSubsystemStatus) -> Color {
        switch status {
        case .healthy: return Color(red: 0.30, green: 0.78, blue: 0.45)
        case .running: return Color(red: 0.35, green: 0.60, blue: 0.95)
        case .idle: return Color(red: 0.55, green: 0.58, blue: 0.62)
        case .initializing: return Color(red: 0.65, green: 0.55, blue: 0.95)
        case .warning: return Color(red: 0.95, green: 0.70, blue: 0.20)
        case .error: return Color(red: 0.92, green: 0.35, blue: 0.35)
        case .unavailable: return Color(red: 0.40, green: 0.42, blue: 0.45)
        }
    }

    /// For the "not yet instrumented" empty-slot state, which is distinct
    /// from all seven real statuses (see DeveloperConsoleTypes.swift) —
    /// deliberately a flat, muted dot so it never reads as "fine".
    static let notInstrumented = Color(red: 0.35, green: 0.36, blue: 0.38)
}

// MARK: - DeveloperConsoleRootView

struct DeveloperConsoleRootView: View {
    @State private var selectedSection: DeveloperConsoleSection? = .dashboard
    @State private var query = ""

    private var visibleSections: [DeveloperConsoleSection] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return DeveloperConsoleSection.allCases }
        return DeveloperConsoleSection.allCases.filter {
            $0.displayName.localizedCaseInsensitiveContains(needle)
                || $0.plannedPhaseLabel.localizedCaseInsensitiveContains(needle)
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .background(ConsolePalette.background)
        .preferredColorScheme(.dark)
        .navigationTitle("Developer Console")
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(ConsolePalette.textSecondary)
                TextField("Find a pane…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(ConsolePalette.textPrimary)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(ConsolePalette.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(ConsolePalette.panel)
            .overlay(Rectangle().fill(ConsolePalette.border).frame(height: 1), alignment: .bottom)

            List(selection: $selectedSection) {
                let live = visibleSections.filter { $0.isAvailable }
                let planned = visibleSections.filter { !$0.isAvailable }
                if !live.isEmpty {
                    Section {
                        ForEach(live) { section in
                            sidebarRow(section)
                                .tag(section)
                        }
                    } header: {
                        Text("LIVE")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(ConsolePalette.textSecondary)
                    }
                }
                if !planned.isEmpty {
                    Section {
                        ForEach(planned) { section in
                            sidebarRow(section)
                                .tag(section)
                        }
                    } header: {
                        Text("PLANNED")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(ConsolePalette.textSecondary)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(ConsolePalette.panel)
        }
        .navigationSplitViewColumnWidth(min: 230, ideal: 250)
    }

    private func sidebarRow(_ section: DeveloperConsoleSection) -> some View {
        HStack {
            Image(systemName: section.symbolName)
                .frame(width: 18)
            Text(section.displayName)
                .font(.system(.body, design: .monospaced))
            Spacer()
            if section.isAvailable {
                Circle()
                    .fill(ConsolePalette.statusColor(.healthy))
                    .frame(width: 5, height: 5)
            } else {
                Text(section.plannedPhaseLabel)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(ConsolePalette.textSecondary)
            }
        }
        .foregroundStyle(
            section.isAvailable
                ? ConsolePalette.textPrimary
                : ConsolePalette.textSecondary.opacity(0.7)
        )
    }

    @ViewBuilder
    private var detail: some View {
        switch selectedSection {
        case .none, .some(.dashboard):
            DeveloperConsoleDashboardView()
        case .some(.environment):
            EnvironmentStudioView()
        case .some(.subsystemExplorer):
            SubsystemExplorerView()
        case .some(.demoLab):
            DemoProfileLabView()
        case .some(.sentinel):
            SentinelPaneView()
        case .some(let section):
            comingSoon(section)
        }
    }

    private func comingSoon(_ section: DeveloperConsoleSection) -> some View {
        VStack(spacing: 12) {
            Image(systemName: section.symbolName)
                .font(.system(size: 40))
                .foregroundStyle(ConsolePalette.textSecondary)
            Text(section.displayName)
                .font(.system(.title2, design: .monospaced))
                .foregroundStyle(ConsolePalette.textPrimary)
            Text("Not built yet — planned for \(section.plannedPhaseLabel) of the Developer Console contract.")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(ConsolePalette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ConsolePalette.background)
    }
}

#endif
