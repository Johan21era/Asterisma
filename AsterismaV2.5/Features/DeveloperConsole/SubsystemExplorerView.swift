//  SubsystemExplorerView.swift
//  AsterismaV2.5 — DEVELOPER CONSOLE
//
//  Phase 3's searchable view over everything the console registry knows.
//  The Dashboard answers "is anything wrong?" in tiles; this pane answers
//  "where is that subsystem and what is it doing?" with a filterable list,
//  a category filter, and a full detail pane (purpose, activity, status
//  meaning, metrics, warnings/errors, last update).
//
//  Search covers the stable id, display name, category, purpose, and every
//  metric key/value already in the snapshot — no extra instrumentation and
//  no new console-side knowledge of specific subsystems.

#if DEBUG

import Combine
import SwiftUI

struct SubsystemExplorerView: View {
    @ObservedObject private var registry = DeveloperConsoleRegistry.shared

    @State private var snapshots: [ConsoleSubsystemSnapshot] = []
    @State private var query = ""
    @State private var category: ConsoleSubsystemCategory?
    @State private var selectedID: String?

    private let refreshTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private var filtered: [ConsoleSubsystemSnapshot] {
        snapshots.filter { snapshot in
            if let category, snapshot.identity.category != category { return false }
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else { return true }
            let haystack = [
                snapshot.identity.id,
                snapshot.identity.displayName,
                snapshot.identity.category.displayName,
                snapshot.identity.purpose ?? "",
                snapshot.currentActivity,
                snapshot.status.displayName,
                snapshot.warnings.joined(separator: " "),
                snapshot.errors.joined(separator: " "),
                snapshot.metrics.map { "\($0.key) \($0.value)" }.joined(separator: " "),
            ].joined(separator: "\n")
            return haystack.localizedCaseInsensitiveContains(needle)
        }
    }

    private var selected: ConsoleSubsystemSnapshot? {
        guard let selectedID else { return filtered.first }
        return filtered.first { $0.id == selectedID } ?? filtered.first
    }

    var body: some View {
        HSplitView {
            listPane
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
            detailPane
                .frame(minWidth: 400)
        }
        .background(ConsolePalette.background)
        .onAppear(perform: refresh)
        .onReceive(refreshTimer) { _ in refresh() }
    }

    // MARK: - List

    private var listPane: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("SUBSYSTEM EXPLORER")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(ConsolePalette.textSecondary)

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(ConsolePalette.textSecondary)
                    TextField("Filter by name, purpose, metric…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(ConsolePalette.textPrimary)
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(ConsolePalette.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(7)
                .background(ConsolePalette.panel)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(ConsolePalette.border, lineWidth: 1))

                Picker("Category", selection: $category) {
                    Text("All categories").tag(ConsoleSubsystemCategory?.none)
                    ForEach(ConsoleSubsystemCategory.allCases, id: \.self) { category in
                        Text(category.displayName).tag(ConsoleSubsystemCategory?.some(category))
                    }
                }
                .labelsHidden()
                .font(.system(.caption, design: .monospaced))

                Text("\(filtered.count) of \(snapshots.count) registered")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(ConsolePalette.textSecondary)
            }
            .padding(12)

            Divider().overlay(ConsolePalette.border)

            List(selection: $selectedID) {
                ForEach(filtered) { snapshot in
                    row(snapshot)
                        .tag(snapshot.id)
                }
                if filtered.isEmpty {
                    Text("No subsystem matches this filter.")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(ConsolePalette.textSecondary)
                        .padding(.vertical, 8)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(ConsolePalette.panel.opacity(0.55))
    }

    private func row(_ snapshot: ConsoleSubsystemSnapshot) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(ConsolePalette.statusColor(snapshot.status))
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.identity.displayName)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(ConsolePalette.textPrimary)
                Text("\(snapshot.identity.category.displayName) · \(snapshot.status.displayName)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(ConsolePalette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if !snapshot.errors.isEmpty {
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(.caption2))
                    .foregroundStyle(ConsolePalette.statusColor(.error))
            } else if !snapshot.warnings.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(.caption2))
                    .foregroundStyle(ConsolePalette.statusColor(.warning))
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailPane: some View {
        if let snapshot = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    detailHeader(snapshot)
                    if let purpose = snapshot.identity.purpose {
                        section("PURPOSE") {
                            Text(purpose)
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(ConsolePalette.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    section("WHAT IT IS DOING") {
                        Text(snapshot.currentActivity)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(ConsolePalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(snapshot.status.plainEnglishMeaning)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(ConsolePalette.textSecondary)
                    }
                    if !snapshot.metrics.isEmpty {
                        section("METRICS") {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 170), spacing: 8)],
                                alignment: .leading, spacing: 8
                            ) {
                                ForEach(snapshot.metrics.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(key.uppercased())
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundStyle(ConsolePalette.textSecondary)
                                        Text(value)
                                            .font(.system(.callout, design: .monospaced))
                                            .foregroundStyle(ConsolePalette.textPrimary)
                                            .textSelection(.enabled)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                                    .background(ConsolePalette.panel)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                            }
                        }
                    }
                    if !snapshot.warnings.isEmpty || !snapshot.errors.isEmpty {
                        section("WARNINGS & ERRORS") {
                            ForEach(Array(snapshot.errors.enumerated()), id: \.offset) { _, message in
                                flagRow(message, isError: true)
                            }
                            ForEach(Array(snapshot.warnings.enumerated()), id: \.offset) { _, message in
                                flagRow(message, isError: false)
                            }
                        }
                    }
                    if let updated = snapshot.lastUpdated {
                        Text("Last updated \(updated.formatted(date: .abbreviated, time: .standard))")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(ConsolePalette.textSecondary)
                    }
                }
                .padding(20)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 34))
                    .foregroundStyle(ConsolePalette.textSecondary)
                Text(snapshots.isEmpty
                     ? "No subsystem has registered yet."
                     : "Select a subsystem to inspect it.")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(ConsolePalette.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailHeader(_ snapshot: ConsoleSubsystemSnapshot) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(ConsolePalette.statusColor(snapshot.status))
                .frame(width: 12, height: 12)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.identity.displayName)
                    .font(.system(.title2, design: .monospaced).weight(.semibold))
                    .foregroundStyle(ConsolePalette.textPrimary)
                Text("\(snapshot.identity.category.displayName) · \(snapshot.identity.id)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(ConsolePalette.textSecondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Text(snapshot.status.displayName.uppercased())
                .font(.system(.caption2, design: .monospaced).weight(.bold))
                .foregroundStyle(ConsolePalette.statusColor(snapshot.status))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(ConsolePalette.statusColor(snapshot.status).opacity(0.12)))
        }
    }

    private func flagRow(_ message: String, isError: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(
                    ConsolePalette.statusColor(isError ? .error : .warning))
            Text(message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(ConsolePalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(ConsolePalette.panel)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(ConsolePalette.textSecondary)
            content()
        }
    }

    private func refresh() {
        snapshots = registry.currentSnapshots()
    }
}

#endif
