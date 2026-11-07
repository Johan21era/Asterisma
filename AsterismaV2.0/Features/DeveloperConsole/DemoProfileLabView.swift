//  DemoProfileLabView.swift
//  AsterismaV2.0 — DEVELOPER CONSOLE ONLY
//
//  LIVE-TEST LT-8 v2 + celebration trigger request: the lab pane where Johan
//  picks one of sixteen synthetic reader personas, reviews exactly what it
//  contains, and installs it. Also hosts the New Year celebration trigger so
//  the full overlay can be reviewed on demand.
//
//  ISOLATION: this view lives inside the Developer Console's own window tree
//  (#if DEBUG at both ends of that tree) and only mutates state through
//  DemoProfileCatalog.install(into:) → DataStore.debug_replaceLibrary. There
//  is no path by which demo data reaches a Release build.

#if DEBUG

import SwiftUI

struct DemoProfileLabView: View {
    @EnvironmentObject private var dataStore: DataStore

    @State private var selectedPersonaID: String?
    @State private var installSummary: DemoInstallSummary?
    @State private var armInstall = false
    @State private var celebrationFiredNote = false

    /// P6-HOTFIX: installation is heavy work (hundreds of sessions,
    /// ~100k+ page-timings, full-library encode). It previously ran
    /// SYNCHRONOUSLY on the main actor inside this view's button handler,
    /// freezing the whole app for seconds-to-minutes and colliding with
    /// Sentinel/HUD timers mid-mutation. Now: async, guarded, with progress.
    @State private var isInstalling = false
    @State private var installStage: String = "" 

    private var selectedPersona: DemoPersona? {
        selectedPersonaID.flatMap { DemoProfileCatalog.persona(withID: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(ConsolePalette.border)

            HSplitView {
                personaList
                    .frame(minWidth: 320, maxWidth: 420)
                detailPane
                    .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(ConsolePalette.background)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "theatermasks")
                    .foregroundStyle(ConsolePalette.statusColor(.running))
                Text("Demo Profile Lab")
                    .font(.system(.title2, design: .monospaced).weight(.semibold))
                    .foregroundStyle(ConsolePalette.textPrimary)
                Spacer()
            }
            Text("Synthetic scenarios for exercising analytics, not evidence of real-reader accuracy. Installing REPLACES the entire library AND resets goals/achievements/collections — profiles are console-only and never ship.")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(ConsolePalette.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Persona list

    private var personaList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(DemoProfileCatalog.all) { persona in
                    PersonaRow(
                        persona: persona,
                        isSelected: persona.id == selectedPersonaID
                    ) {
                        selectedPersonaID = persona.id
                        armInstall = false
                        installSummary = nil
                    }
                }
            }
            .padding(12)
        }
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let persona = selectedPersona {
            PersonaDetail(
                persona: persona,
                armed: armInstall,
                summary: installSummary,
                isInstalling: isInstalling,
                installStage: installStage,
                onArmToggle: { armInstall.toggle() },
                onInstall: { install(persona) }
            )
        } else {
            VStack(spacing: 12) {
                Image(systemName: "person.crop.circle.dashed")
                    .font(.system(size: 44))
                    .foregroundStyle(ConsolePalette.textSecondary)
                Text("Select a reader profile")
                    .font(.system(.headline, design: .monospaced))
                    .foregroundStyle(ConsolePalette.textPrimary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ConsolePalette.background)
        }
    }

    /// HOTFIX: async pipeline. Generation + encode run detached; only the tiny
    /// store swap happens on main. Re-entrancy guard makes double-clicks and
    /// rapid persona-hopping safe (Johan's requirement: profile #1 → #2 → #4,
    /// repeatedly, must never skip a beat).
    private func install(_ persona: DemoPersona) {
        guard !isInstalling else { return }
        isInstalling = true
        armInstall = false
        installSummary = nil

        let personaID = persona.id
        let personaName = persona.name

        Task { @MainActor in
            SentinelDataBridge.shared.beginMutation()
            defer { SentinelDataBridge.shared.endMutation() }

            installStage = "Generating reading history…"

            // Heavy synthesis off-main. Deterministic per persona id (unchanged).
            let books: [Book] = await Task.detached(priority: .userInitiated) {
                let generated = DemoProfileCatalog.generateBooks(
                    for: persona, referenceDate: Date()
                )
                return generated
            }.value

            installStage = "Writing to library…"

            // Store swap is fast now (value assignment + debounced async save).
            await MainActor.run {
                dataStore.debug_replaceLibrary(with: books)
            }

            installStage = "Rebuilding collections…"
            _ = try? DemoProfileCatalog.installCollections(for: books, personaName: personaName, into: dataStore)

            let sessionTotal = books.reduce(0) { $0 + $1.sessions.count }
            installSummary = DemoInstallSummary(
                personaName: personaName,
                bookCount: books.count,
                sessionCount: sessionTotal,
                totalHours: books.reduce(0) { $0 + $1.totalReadingTime } / 3600
            )
            installStage = ""
            isInstalling = false
        }
    }
}

// MARK: - Row / Detail / Celebration subviews (file-private)

private struct PersonaRow: View {
    let persona: DemoPersona
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(persona.name)
                        .font(.system(.body, design: .monospaced).weight(.medium))
                        .foregroundStyle(isSelected ? ConsolePalette.textPrimary : ConsolePalette.textSecondary)
                    Text("\(persona.catalog.count) books · ~\(Int(persona.totalCatalogHours))h history sizing")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(ConsolePalette.textSecondary.opacity(0.8))
                }
                Spacer()
                if isSelected {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(ConsolePalette.statusColor(.running))
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? ConsolePalette.panel : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(isSelected ? ConsolePalette.border : .clear, lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PersonaDetail: View {
    let persona: DemoPersona
    let armed: Bool
    let summary: DemoInstallSummary?
    var isInstalling: Bool = false
    var installStage: String = ""
    let onArmToggle: () -> Void
    let onInstall: () -> Void

    @State private var celebrationNote = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                identityCard
                catalogPreview
                installControls
                if let summary {
                    summaryCard(summary)
                }
                celebrationCard
            }
            .padding(20)
        }
        .background(ConsolePalette.background)
    }

    private var identityCard: some View {
        consolePanel {
            VStack(alignment: .leading, spacing: 8) {
                Text(persona.name)
                    .font(.system(.title2, design: .monospaced).weight(.semibold))
                    .foregroundStyle(ConsolePalette.textPrimary)
                Text(persona.blurb)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(ConsolePalette.textSecondary)

                Divider().overlay(ConsolePalette.border)

                HStack(spacing: 24) {
                    metric("BOOKS", "\(persona.catalog.count)")
                    metric("HISTORY SIZING", "~\(Int(persona.totalCatalogHours))h")
                    metric("GENRES", "\(Set(persona.catalog.map(\.genre)).count)")
                    metric("PACE", "\(Int(persona.secondsPerPage.lowerBound))–\(Int(persona.secondsPerPage.upperBound))s/pg")
                }
            }
        }
    }

    private var catalogPreview: some View {
        consolePanel {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("CATALOG")
                ForEach(persona.catalog, id: \.title) { book in
                    HStack {
                        Circle()
                            .fill(ConsolePalette.statusColor(.running))
                            .frame(width: 6, height: 6)
                        Text(book.title)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(ConsolePalette.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        Text("\(book.genre.displayName) · \(Int(book.totalHours))h catalog input")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(ConsolePalette.textSecondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var installControls: some View {
        consolePanel {
            VStack(alignment: .leading, spacing: 12) {
                sectionLabel("INSTALL")
                Text("Installing wipes the current library and installs this persona's full history. The app's analytics surfaces update immediately.")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(ConsolePalette.textSecondary)

                HStack {
                    if armed {
                        if isInstalling {
                            ProgressView()
                                .controlSize(.small)
                            Text(installStage)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(ConsolePalette.textSecondary)
                        } else {
                            Button(role: .destructive) {
                                onInstall()
                            } label: {
                                Label("Confirm — Replace Library", systemImage: "bolt.trianglebadge.exclamationmark")
                                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                            }
                            Button("Cancel") { onArmToggle() }
                        }
                    } else {
                        Button {
                            onArmToggle()
                        } label: {
                            Label("Install This Profile…", systemImage: "person.badge.key")
                                .font(.system(.callout, design: .monospaced).weight(.medium))
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private func summaryCard(_ summary: DemoInstallSummary) -> some View {
        consolePanel {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("LAST INSTALL")
                Text("\(summary.personaName): \(summary.bookCount) books · \(summary.sessionCount) sessions · ~\(Int(summary.totalHours))h reading time")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(ConsolePalette.statusColor(.healthy))
            }
        }
    }

    private var celebrationCard: some View {
        consolePanel {
            VStack(alignment: .leading, spacing: 12) {
                sectionLabel("CELEBRATION LAB")
                Text("Fires the full New Year overlay over the main app window — toast → expansion → fullscreen with particles. Requires the main app window to be open.")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(ConsolePalette.textSecondary)

                HStack {
                    Button {
                        DebugCelebrationBus.fire()
                        celebrationNote = true
                    } label: {
                        Label("Trigger New Year Celebration", systemImage: "sparkles")
                            .font(.system(.callout, design: .monospaced).weight(.medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(DebugCelebrationBus.monitor == nil)

                    if DebugCelebrationBus.monitor == nil {
                        Text("Main window not active yet — open it first.")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(ConsolePalette.textSecondary)
                    }

                    if celebrationNote {
                        Text("Fired ✓ — check the main window.")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(ConsolePalette.statusColor(.healthy))
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: - Panel chrome helpers

    private func consolePanel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(ConsolePalette.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(ConsolePalette.border, lineWidth: 1)
            )
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption2, design: .monospaced).weight(.bold))
            .tracking(1.5)
            .foregroundStyle(ConsolePalette.textSecondary)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.body, design: .monospaced).weight(.bold))
                .foregroundStyle(ConsolePalette.textPrimary)
            Text(label)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(ConsolePalette.textSecondary)
        }
    }
}
#endif
