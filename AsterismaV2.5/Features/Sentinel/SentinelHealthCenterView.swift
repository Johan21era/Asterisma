//  SentinelHealthCenterView.swift
//  AsterismaV2.5
//
//  SG4 — the product surface. Available in Release and Debug; it reads only
//  published state and never runs a probe from a view.
//
//  The five questions (§3.5) each have a home here:
//    Is anything wrong?        Overview band + headline
//    What exactly?             Issues list + issue detail
//    Why does it matter?       "Why this matters"
//    What can I do?            Fix / snooze / acknowledge / ignore / undo
//    Can I trust "all clear"?  Coverage line + Checks disclosure

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SentinelHealthCenterView: View {
    @StateObject private var model = SentinelViewModel()
    @EnvironmentObject private var dataStore: DataStore
    @State private var recovery: LibraryHealthCoordinator?
    @State private var tab: Tab = .overview
    @State private var configuration = SentinelConfiguration.default
    @State private var hasLoadedConfiguration = false
    @State private var issueQuery = ""
    @State private var severityFilter: SeverityFilter = .all
    @State private var checksQuery = ""
    @State private var historyQuery = ""

    enum Tab: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case issues = "Issues"
        case recovery = "Recovery"
        case history = "History"
        case checks = "Checks"
        case settings = "Settings"
        var id: String { rawValue }

        var symbolName: String {
            switch self {
            case .overview: return "shield"
            case .issues: return "list.bullet.rectangle"
            case .recovery: return "externaldrive.badge.exclamationmark"
            case .history: return "clock.arrow.circlepath"
            case .checks: return "checklist"
            case .settings: return "gearshape"
            }
        }

        var subtitle: String {
            switch self {
            case .overview: return "Health at a glance, coverage, and recent activity."
            case .issues: return "What needs a decision, with filters and a next-issue control."
            case .recovery: return "Verify, restore, or rebuild the library after damage."
            case .history: return "Every repair and journal entry, newest first."
            case .checks: return "Every probe, its budget, and what the last run found."
            case .settings: return "Autonomy, cadence, quiet hours, domains, and diagnostics."
            }
        }
    }

    enum SeverityFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case critical = "Critical"
        case warning = "Warning"
        case info = "Info"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailContainer
        }
        .frame(minWidth: 960, minHeight: 680)
        .task {
            await model.refresh()
            configuration = model.state.configuration
            hasLoadedConfiguration = true
            // The main window normally starts recovery before this window can
            // open. Starting here is idempotent and keeps the tab usable when
            // the Health Center is opened first.
            if recovery == nil {
                if let existing = LibraryHealthIntegration.existing() {
                    recovery = existing
                } else if let root = AppIdentity.dataRootURL() {
                    recovery = await LibraryHealthIntegration.start(
                        dataStore: dataStore, dataRoot: root)
                }
            }
        }
        .onChange(of: model.state.configuration) { _, newValue in
            if !hasLoadedConfiguration { configuration = newValue }
        }
        .sheet(isPresented: Binding(
            get: { model.preview != nil },
            set: { if !$0 { model.cancelFix() } }
        )) {
            if let preview = model.preview {
                repairPreview(preview)
            }
        }
    }

    // MARK: - Sidebar navigation

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: model.state.health.band.systemImage)
                        .font(.title3)
                        .foregroundStyle(model.bandColor)
                    Text("Sentinel")
                        .font(.headline)
                    Spacer()
                }
                Text(model.state.health.band.displayName)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(model.bandColor)
                Text(model.state.health.headline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.coverageLine)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)

            Divider()

            List(selection: $tab) {
                Section("Health") {
                    sidebarRow(.overview, badge: nil)
                    sidebarRow(.issues, badge: model.visibleIssues.isEmpty
                               ? nil : "\(model.visibleIssues.count)")
                }
                Section("Library") {
                    sidebarRow(.recovery, badge: nil)
                }
                Section("Records") {
                    sidebarRow(.history, badge: nil)
                    sidebarRow(.checks, badge: "\(model.registryCount)")
                }
                Section("Configure") {
                    sidebarRow(.settings, badge: nil)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    Task { await model.runCheck(scope: .fast) }
                } label: {
                    Label(model.isWorking ? "Checking…" : "Check now",
                          systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isWorking)
                .keyboardShortcut("r", modifiers: .command)

                if model.state.lastCycle.startedAt.timeIntervalSince1970 > 0 {
                    Text("Last check \(model.state.lastCycle.startedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(12)
        }
        .navigationSplitViewColumnWidth(min: 240, ideal: 265)
    }

    private func sidebarRow(_ item: Tab, badge: String?) -> some View {
        HStack(spacing: 8) {
            Label(item.rawValue, systemImage: item.symbolName)
            Spacer()
            if let badge {
                Text(badge)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.quaternary.opacity(0.5)))
            }
        }
        .tag(item)
    }

    private var detailContainer: some View {
        VStack(spacing: 0) {
            detailHeader
            if model.state.operationalMode.isSuspended {
                Divider()
                suspensionBanner
            }
            if let message = model.message {
                Divider()
                messageBar(message)
            }
            Divider()
            detailContent
                .padding(18)
        }
        .background(.background)
    }

    private var detailHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(tab.rawValue)
                    .font(.title2.weight(.semibold))
                Text(tab.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if tab != .issues && !model.visibleIssues.isEmpty {
                Button("Review \(model.visibleIssues.count) issue\(model.visibleIssues.count == 1 ? "" : "s")") {
                    tab = .issues
                }
                .buttonStyle(.bordered)
            }
            if tab != .settings {
                Button {
                    Task { await model.runCheck(scope: .deep) }
                } label: {
                    Label("Full check", systemImage: "checklist.checked")
                }
                .disabled(model.isWorking)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch tab {
        case .overview: overviewTab
        case .issues: issuesTab
        case .recovery: recoveryTab
        case .history: historyTab
        case .checks: checksTab
        case .settings: settingsTab
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: model.state.health.band.systemImage)
                .font(.system(size: 28))
                .foregroundStyle(model.bandColor)
                .accessibilityLabel(model.state.health.band.displayName)

            VStack(alignment: .leading, spacing: 3) {
                Text("Sentinel Health")
                    .font(.title2.weight(.semibold))
                Text(model.state.health.headline)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(model.coverageLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.state.lastCycle.startedAt.timeIntervalSince1970 > 0 {
                    Text("Last check \(model.state.lastCycle.startedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Button {
                Task { await model.runCheck(scope: .fast) }
            } label: {
                Label("Check now", systemImage: "arrow.clockwise")
            }
            .disabled(model.isWorking)
            .accessibilityHint("Runs the fast checks immediately")
        }
        .padding(18)
    }

    // MARK: - Recovery

    @ViewBuilder
    private var recoveryTab: some View {
        if let recovery {
            LibraryRecoveryView(coordinator: recovery)
                .environmentObject(dataStore)
        } else {
            ContentUnavailableView(
                "Recovery is unavailable",
                systemImage: "externaldrive.badge.xmark",
                description: Text("The recovery store could not be created, so no incident can be recorded. Your library file has not been touched."))
        }
    }

    private var suspensionBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.orange)
            Text("Sentinel is paused while the library is in recovery. No probes or repairs run.")
                .font(.callout)
            Spacer()
            Button("Open Recovery") { tab = .recovery }
                .buttonStyle(.link)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.10))
    }

    private func messageBar(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
            Text(message).font(.callout)
            Spacer()
            Button("Dismiss") { model.message = nil }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.4))
    }

    // MARK: - Overview

    private var overviewTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                bandCard
                HStack(spacing: 12) {
                    metric("Open issues", "\(model.visibleIssues.count)", systemImage: "exclamationmark.triangle")
                    metric("Repairs verified", "\(model.state.counters["repairsVerified"] ?? 0)", systemImage: "wrench.and.screwdriver")
                    metric("Checks run", "\(model.state.coverage.ran)", systemImage: "checkmark.circle")
                    metric("Checks available", "\(model.registryCount)", systemImage: "square.grid.2x2")
                }

                GroupBox("Coverage") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.coverageLine)
                            .font(.callout)
                        if !model.state.coverage.missingRequired.isEmpty {
                            Text("Did not run: \(model.state.coverage.missingRequired.joined(separator: ", "))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        ProgressView(value: model.state.coverage.completionFraction)
                            .tint(model.bandColor)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox("Recent activity") {
                    if model.state.history.isEmpty {
                        Text("Nothing recorded yet.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(model.state.history.prefix(6)), id: \.sequence) { entry in
                                historyRow(entry)
                            }
                        }
                        .padding(6)
                    }
                }

                GroupBox("What Sentinel is checking") {
                    HStack(spacing: 18) {
                        Text("\(model.registryCount) probes across \(model.domainCount) domains")
                        Text("\(model.repairCatalogCount) verified repair plans")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(6)
                }
            }
            .padding(.top, 8)
        }
    }

    private var bandCard: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: model.state.health.band.systemImage)
                .font(.system(size: 34))
                .foregroundStyle(model.bandColor)
            VStack(alignment: .leading, spacing: 5) {
                Text(model.state.health.band.displayName)
                    .font(.title3.weight(.semibold))
                Text(model.state.health.headline)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if model.state.health.band == .unknown {
                    Text("An incomplete check is not a clean bill of health. Run a full check to finish coverage.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(model.bandColor.opacity(0.08)))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(model.bandColor.opacity(0.25), lineWidth: 1))
    }

    private func metric(_ title: String, _ value: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.35)))
    }

    // MARK: - Issues

    private var issuesTab: some View {
        VSplitView {
            issueFilterBar
            HSplitView {
                List(selection: $model.selectedFingerprint) {
                    if filteredIssues.isEmpty {
                        ContentUnavailableView(
                            model.sortedIssues.isEmpty ? "Nothing needs you" : "No match",
                            systemImage: model.sortedIssues.isEmpty ? "checkmark.shield" : "line.3.horizontal.decrease.circle",
                            description: Text(model.sortedIssues.isEmpty
                                              ? (model.state.coverage.isComplete
                                                 ? "Every required check ran and found nothing to fix."
                                                 : "No issue is waiting, but coverage is incomplete — see Checks.")
                                              : "No issue matches the current search and severity filter."))
                    }
                    ForEach(filteredIssues) { issue in
                        issueRow(issue)
                            .tag(issue.fingerprint)
                    }
                }
                .frame(minWidth: 280, idealWidth: 330)

                Group {
                    if let issue = model.selectedIssue {
                        SentinelIssueDetailView(issue: issue, model: model)
                    } else {
                        ContentUnavailableView(
                            "Select an issue",
                            systemImage: "sidebar.left",
                            description: Text("Choose an item to see what it means and what can be done."))
                    }
                }
                .frame(minWidth: 420)
            }
        }
    }

    private var filteredIssues: [SentinelIssue] {
        model.sortedIssues.filter { issue in
            switch severityFilter {
            case .all: break
            case .critical: guard issue.severity == .critical else { return false }
            case .warning: guard issue.severity == .warning else { return false }
            case .info: guard issue.severity == .info else { return false }
            }
            let needle = issueQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else { return true }
            let haystack = [
                model.copy(for: issue)?.title ?? "",
                issue.safeSummary,
                issue.domain.displayName,
                issue.status.displayName,
                issue.ruleID.rawValue,
            ].joined(separator: "\n")
            return haystack.localizedCaseInsensitiveContains(needle)
        }
    }

    private var issueFilterBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search issues by title, domain, or rule…", text: $issueQuery)
                    .textFieldStyle(.plain)
                if !issueQuery.isEmpty {
                    Button { issueQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(7)
            .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.35)))

            Picker("Severity", selection: $severityFilter) {
                ForEach(SeverityFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)

            Button("Next issue") { selectNextIssue() }
                .disabled(filteredIssues.count < 2)
                .keyboardShortcut("]", modifiers: .command)

            Text("\(filteredIssues.count) of \(model.sortedIssues.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func selectNextIssue() {
        let issues = filteredIssues
        guard !issues.isEmpty else { return }
        guard let current = model.selectedFingerprint,
              let index = issues.firstIndex(where: { $0.fingerprint == current })
        else {
            model.selectedFingerprint = issues.first?.fingerprint
            return
        }
        model.selectedFingerprint = issues[(index + 1) % issues.count].fingerprint
    }

    private func issueRow(_ issue: SentinelIssue) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: issue.severity >= .critical ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(severityColor(issue.severity))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.copy(for: issue)?.title ?? issue.safeSummary)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(issue.domain.displayName)
                    Text("·")
                    Text(issue.status.displayName)
                    if issue.occurrenceCount > 1 {
                        Text("·")
                        Text("seen \(issue.occurrenceCount)×")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: - History

    private var filteredHistory: [SentinelJournalEntry] {
        let needle = historyQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return model.state.history }
        return model.state.history.filter { entry in
            [entry.event.rawValue, entry.ruleID ?? "", entry.note ?? "",
             entry.fingerprint ?? ""]
                .joined(separator: "\n")
                .localizedCaseInsensitiveContains(needle)
        }
    }

    private var filteredRepairs: [SentinelRepairRecord] {
        let needle = historyQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return model.state.repairs }
        return model.state.repairs.filter { record in
            [record.title, record.repairID, record.status.rawValue]
                .joined(separator: "\n")
                .localizedCaseInsensitiveContains(needle)
        }
    }

    private var historyTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter repairs and journal entries…", text: $historyQuery)
                    .textFieldStyle(.plain)
                if !historyQuery.isEmpty {
                    Button { historyQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(7)
            .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.35)))

            Text("Repairs")
                .font(.headline)
            if model.state.repairs.isEmpty {
                Text("No repair has been attempted yet.")
                    .foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(filteredRepairs.reversed()) { record in
                        HStack(spacing: 12) {
                            Image(systemName: repairStatusIcon(record.status))
                                .foregroundStyle(repairStatusColor(record.status))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.title).font(.body)
                                Text("\(record.repairID) · \(record.status.rawValue) · \(record.appliedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if record.isUndoable {
                                Button("Undo") {
                                    Task { await model.undo(record) }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(model.isWorking)
                                .accessibilityHint("Restores the values this repair changed")
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .frame(minHeight: 180)
            }

            Text("Journal")
                .font(.headline)
            List {
                ForEach(filteredHistory, id: \.sequence) { entry in
                    historyRow(entry)
                }
            }
        }
        .padding(.top, 4)
    }

    private func historyRow(_ entry: SentinelJournalEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(entry.at.formatted(date: .abbreviated, time: .shortened))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(entry.event.rawValue)
                .font(.caption.weight(.semibold))
                .frame(width: 110, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.ruleID ?? entry.note ?? "")
                    .font(.callout)
                if let fingerprint = entry.fingerprint {
                    Text(fingerprint)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
    }

    // MARK: - Checks

    private var filteredProbes: [SentinelProbeRunResult] {
        let needle = checksQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return model.probes }
        return model.probes.filter { result in
            let title = SentinelProbeCatalog.ruleMetadata[result.ruleID]?.title ?? result.ruleID.rawValue
            let haystack = [result.probeID, result.domain.code, title, result.ruleID.rawValue,
                            probeStatusWord(result.status)]
                .joined(separator: "\n")
            return haystack.localizedCaseInsensitiveContains(needle)
        }
    }

    private func probeStatusWord(_ status: SentinelProbeStatus) -> String {
        switch status {
        case .completed: return "completed"
        case .skipped: return "skipped"
        case .failed: return "failed"
        case .timedOut: return "timed out"
        }
    }

    private var checksTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.coverageLine).font(.callout)
                    Text("\(model.registryCount) probes registered across \(model.domainCount) domains")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Run fast checks") { Task { await model.runCheck(scope: .fast) } }
                    .disabled(model.isWorking)
                Button("Run full checks") { Task { await model.runCheck(scope: .deep) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isWorking)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter probes by id, domain, or outcome…", text: $checksQuery)
                    .textFieldStyle(.plain)
                if !checksQuery.isEmpty {
                    Button { checksQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(7)
            .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.35)))

            if model.probes.isEmpty {
                ContentUnavailableView(
                    "No results yet",
                    systemImage: "checklist",
                    description: Text("Run a check to see each probe, its budget, and what it found."))
            } else {
                List(filteredProbes, id: \.probeID) { result in
                    HStack(spacing: 10) {
                        Image(systemName: probeStatusIcon(result.status))
                            .foregroundStyle(probeStatusColor(result.status))
                            .frame(width: 16)
                        Text(result.probeID)
                            .font(.callout.monospaced())
                            .frame(width: 80, alignment: .leading)
                        Text(SentinelProbeCatalog.ruleMetadata[result.ruleID]?.title ?? result.ruleID.rawValue)
                            .font(.callout)
                            .lineLimit(1)
                        Spacer()
                        Text(result.domain.code)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        Text(result.tier.rawValue.uppercased())
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        Text("\(Int(result.duration * 1000)) ms")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text("\(result.findings.count)")
                            .font(.caption.monospacedDigit())
                            .frame(width: 24, alignment: .trailing)
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }

    // MARK: - Settings

    private var settingsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Autonomy") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Allow Sentinel to", selection: $configuration.autonomy) {
                            ForEach(SentinelAutonomy.allCases, id: \.self) { level in
                                Text(level.displayName).tag(level)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        Text(configuration.autonomy.explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox("Cadence") {
                    VStack(alignment: .leading, spacing: 10) {
                        Stepper("Fast checks every \(configuration.cadenceMinutes) minutes",
                                value: $configuration.cadenceMinutes, in: 5...240, step: 5)
                        Stepper("Deep checks every \(configuration.deepCadenceHours) hours",
                                value: $configuration.deepCadenceHours, in: 6...168, step: 6)
                        Stepper("Keep repairs undoable for \(configuration.undoWindowDays) days",
                                value: $configuration.undoWindowDays, in: 1...90)
                    }
                    .padding(6)
                }

                GroupBox("Quiet hours") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Pause notifications during quiet hours", isOn: $configuration.quietHours.isEnabled)
                        if configuration.quietHours.isEnabled {
                            Stepper("From \(String(format: "%02d:00", configuration.quietHours.startHour))",
                                    value: $configuration.quietHours.startHour, in: 0...23)
                            Stepper("Until \(String(format: "%02d:00", configuration.quietHours.endHour))",
                                    value: $configuration.quietHours.endHour, in: 0...23)
                        }
                    }
                    .padding(6)
                }

                GroupBox("Domains") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(SentinelDomain.allCases, id: \.self) { domain in
                            Toggle(domain.displayName, isOn: Binding(
                                get: { !configuration.disabledDomains.contains(domain) },
                                set: { isOn in
                                    if isOn { configuration.disabledDomains.remove(domain) }
                                    else { configuration.disabledDomains.insert(domain) }
                                }))
                            .toggleStyle(.checkbox)
                        }
                    }
                    .padding(6)
                }

                GroupBox("Library recovery") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("When the library database needs recovery, Sentinel pauses every probe and repair until the library reopens. After recovery it runs one full verification pass before resuming its schedule.")
                            .font(.callout)
                        Text("Recovery never runs automatically. Restores and rebuilds require a typed confirmation in the Recovery tab.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                GroupBox("Notifications") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Notify me about new issues that need a decision", isOn: $configuration.notificationsEnabled)
                        Text("Sentinel never includes book titles or reading content in a notification.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                HStack {
                    Button("Save changes") {
                        Task { await model.saveConfiguration(configuration) }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Open Sentinel folder") {
                        if let root = AppIdentity.dataRootURL() {
                            NSWorkspace.shared.open(root.appendingPathComponent("Sentinel", isDirectory: true))
                        }
                    }
                    Button("Export diagnostics…") { exportDiagnostics() }
                }
            }
            .padding(.top, 4)
        }
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "sentinel-diagnostics.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
                let data = try SentinelDiagnostics.export(
                    state: model.state,
                    appVersion: version)
                try data.write(to: url, options: .atomic)
                model.message = "Diagnostics exported without book titles, paths, or debug detail."
            } catch {
                model.message = "Could not export diagnostics."
            }
        }
    }

    // MARK: - Repair preview

    private func repairPreview(_ preview: SentinelRepairPlan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "wrench.and.screwdriver")
                    .foregroundStyle(.blue)
                Text(preview.title).font(.title3.weight(.semibold))
                Spacer()
                Text(preview.riskClass.label)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.quaternary))
            }

            Text(preview.summary)
                .font(.callout)

            VStack(alignment: .leading, spacing: 6) {
                Text("What will change").font(.headline)
                ForEach(preview.preview, id: \.self) { line in
                    Label(line, systemImage: "checkmark.circle")
                        .font(.callout)
                }
            }

            Text("Sentinel takes a safety snapshot first, re-reads the affected records, and verifies the result by re-running the check. You can undo it from History.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { model.cancelFix() }
                Button("Apply") {
                    Task { await model.confirmFix() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isWorking)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    // MARK: - Helpers

    private func severityColor(_ severity: SentinelSeverity) -> Color {
        switch severity {
        case .critical: return .red
        case .error: return .orange
        case .warning: return .yellow
        case .info: return .secondary
        }
    }

    private func probeStatusIcon(_ status: SentinelProbeStatus) -> String {
        switch status {
        case .completed: return "checkmark.circle.fill"
        case .skipped: return "minus.circle"
        case .failed: return "xmark.octagon"
        case .timedOut: return "clock.badge.exclamationmark"
        }
    }

    private func probeStatusColor(_ status: SentinelProbeStatus) -> Color {
        switch status {
        case .completed: return .green
        case .skipped: return .secondary
        case .failed, .timedOut: return .red
        }
    }

    private func repairStatusIcon(_ status: SentinelRepairRecord.Status) -> String {
        switch status {
        case .verified: return "checkmark.seal.fill"
        case .unverified: return "questionmark.seal"
        case .failed, .rolledBack: return "arrow.uturn.backward.circle"
        case .undone: return "arrow.uturn.backward.circle.fill"
        }
    }

    private func repairStatusColor(_ status: SentinelRepairRecord.Status) -> Color {
        switch status {
        case .verified: return .green
        case .unverified: return .orange
        case .failed, .rolledBack: return .orange
        case .undone: return .secondary
        }
    }
}

// MARK: - Issue detail

struct SentinelIssueDetailView: View {
    let issue: SentinelIssue
    @ObservedObject var model: SentinelViewModel
    @State private var showEvidence = false

    private var copy: SentinelCopy? { model.copy(for: issue) }
    private var metadata: SentinelRuleMetadata? { model.metadata(for: issue) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(copy?.title ?? issue.safeSummary)
                            .font(.title3.weight(.semibold))
                        HStack(spacing: 8) {
                            Text(issue.severity.label)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(issue.severity >= .error ? .orange : .secondary)
                            Text(issue.status.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(issue.ruleID.rawValue)
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                }

                section("What Sentinel found", copy?.what ?? issue.safeSummary)
                section("Why this matters", copy?.why ?? metadata?.domain.whyItMatters ?? "")

                if let now = copy?.now {
                    section("Right now", now)
                }
                if let whatIf = copy?.whatIf {
                    section("If left alone", whatIf)
                }

                DisclosureGroup(isExpanded: $showEvidence) {
                    VStack(alignment: .leading, spacing: 6) {
                        if issue.evidence.isEmpty {
                            Text("No evidence recorded.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(issue.evidence.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: 8) {
                                Text(item.labelKey)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(item.safeValue)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                        Text("Evidence contains identifiers and counts, never book titles or reading content.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.top, 6)
                } label: {
                    Text("Evidence (\(issue.evidence.count))")
                        .font(.headline)
                }

                #if DEBUG
                if let debug = issue.debugDetail {
                    Text(debug)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                #endif

                Divider()

                HStack(spacing: 10) {
                    if model.canShowRepair, metadata?.repairID != nil {
                        Button {
                            Task { await model.requestFix(issue) }
                        } label: {
                            Label("Fix safely…", systemImage: "wrench.and.screwdriver")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isWorking)
                        .accessibilityHint("Shows exactly what will change before applying")
                    }

                    if issue.status == .open {
                        Button("Acknowledge") {
                            Task { await model.acknowledge(issue) }
                        }
                    }
                    Button("Snooze 24h") {
                        Task { await model.snooze(issue) }
                    }
                    Button("Ignore") {
                        Task { await model.ignore(issue) }
                    }
                    Spacer()
                }

                if model.canShowRepair == false {
                    Text("Sentinel is in observe-only mode. Change autonomy in Settings to allow fixes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("First seen \(issue.firstSeen.formatted(date: .abbreviated, time: .shortened)) · last seen \(issue.lastSeen.formatted(date: .abbreviated, time: .shortened)) · seen \(issue.occurrenceCount)×")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(18)
        }
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
