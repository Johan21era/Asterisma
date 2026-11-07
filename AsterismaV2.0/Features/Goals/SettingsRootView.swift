//  SettingsRootView.swift
//  AsterismaV2.0
//
//  ROADMAP 1.2a/1.2b (RA-002 / NA-2): the app previously had NO reachable way
//  to create goals or deadlines — DataStore.updateGoalSet/addDeadline had zero
//  callers and GoalsDashboard's empty state pointed at nonexistent "app settings."
//  This window is that missing creation surface.
//
//  DESIGN CONTRACT
//  • The shell is generic (tabs) so future settings panes (e.g. LT-9 symbol color)
//    drop in without restructuring.
//  • The goal editor binds ONLY to DataStore's existing, already-persisted API:
//      updateGoalSet(_:)      → library-state.json (immediate, non-debounced save)
//      addDeadline(_:)        → same file, replaces any deadline for the same book
//      removeDeadline(bookID:)
//    No new persistence path is introduced anywhere in this file.
//  • GoalProgressViewModel refreshes itself by observing $libraryState (see its
//    bind(to:) — roadmap 1.2b companion change), so the dashboard updates live
//    after saving here.

import AppKit
import SwiftUI

// MARK: - Settings Root

struct SettingsRootView: View {
    @EnvironmentObject private var dataStore: DataStore

    var body: some View {
        TabView {
            GoalEditorPane()
                .tabItem {
                    Label("Reading Goals", systemImage: "target")
                }

            DeadlineEditorPane()
                .tabItem {
                    Label("Deadlines", systemImage: "calendar.badge.clock")
                }

            RSVPSettingsPane()
                .tabItem {
                    Label("Speed Reading", systemImage: "hare")
                }

            WeatherSettingsPane()
                .tabItem {
                    Label("Weather", systemImage: "cloud.sun")
                }

            SentinelSettingsPane()
                .tabItem {
                    Label("Sentinel", systemImage: "shield.lefthalf.filled")
                }

            MirageSettingsPane()
                .tabItem {
                    Label("Mirage", systemImage: "sparkles.rectangle.stack")
                }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 430)
        .navigationTitle("Settings")
    }
}

// MARK: - Goal Editor Pane (roadmap 1.2b)

struct GoalEditorPane: View {
    @EnvironmentObject private var dataStore: DataStore

    // Local editing state — seeded from the persisted set, committed on Save.
    @State private var dailyPagesEnabled = false
    @State private var dailyPages = 20

    @State private var dailyMinutesEnabled = false
    @State private var dailyMinutes = 30

    @State private var annualBooksEnabled = false
    @State private var annualBooks = 12

    @State private var weeklyDaysEnabled = false
    @State private var weeklyDays = 5

    @State private var savedFlash = false

    var body: some View {
        Form {
            Section("Daily Targets") {
                Toggle("Daily page target", isOn: $dailyPagesEnabled)
                if dailyPagesEnabled {
                    Stepper("\(dailyPages) pages", value: $dailyPages, in: 1 ... 1000)
                }

                Toggle("Daily time target", isOn: $dailyMinutesEnabled)
                if dailyMinutesEnabled {
                    Stepper("\(dailyMinutes) minutes", value: $dailyMinutes, in: 5 ... 480)
                        .onChange(of: dailyMinutes) { _, newValue in
                            // Snap to friendly 5-minute increments while stepping.
                            dailyMinutes = max(5, newValue - (newValue % 5))
                        }
                }
            }

            Section("Longer Horizon") {
                Toggle("Annual book target", isOn: $annualBooksEnabled)
                if annualBooksEnabled {
                    Stepper("\(annualBooks) books this year", value: $annualBooks, in: 1 ... 365)
                }

                Toggle("Weekly reading days", isOn: $weeklyDaysEnabled)
                if weeklyDaysEnabled {
                    Stepper("\(weeklyDays) days per week", value: $weeklyDays, in: 1 ... 7)
                }
            }

            Section {
                HStack {
                    Button("Save Goals") { commit() }
                        .keyboardShortcut(.defaultAction)
                    if savedFlash {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                            .transition(.opacity)
                    }
                    Spacer()
                    Button("Clear All Goals", role: .destructive) {
                        clearAll()
                    }
                }
            } footer: {
                Text("Changes take effect immediately across Goals, Insights, and Achievements.")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: seedFromStore)
        // Re-seed when goals change underneath us (e.g. demo-profile reset wipes
        // LibraryState). ReadingGoalSet is Hashable, satisfying onChange's
        // Equatable requirement without widening LibraryState's conformance set.
        .onChange(of: dataStore.libraryState.goalSet) { _, _ in
            seedFromStore()
        }
    }

    private func seedFromStore() {
        let set = dataStore.libraryState.goalSet
        dailyPagesEnabled = set.dailyPageTarget != nil
        dailyPages = set.dailyPageTarget ?? 20
        dailyMinutesEnabled = set.dailyTimeTarget != nil
        dailyMinutes = Int((set.dailyTimeTarget ?? 1800) / 60)
        annualBooksEnabled = set.annualBookTarget != nil
        annualBooks = set.annualBookTarget ?? 12
        weeklyDaysEnabled = set.weeklyReadingDays != nil
        weeklyDays = set.weeklyReadingDays ?? 5
    }

    private func commit() {
        var set = ReadingGoalSet.empty
        set.dailyPageTarget = dailyPagesEnabled ? dailyPages : nil
        set.dailyTimeTarget = dailyMinutesEnabled ? TimeInterval(dailyMinutes * 60) : nil
        set.annualBookTarget = annualBooksEnabled ? annualBooks : nil
        set.weeklyReadingDays = weeklyDaysEnabled ? weeklyDays : nil
        dataStore.updateGoalSet(set)

        withAnimation(.easeOut(duration: 0.4)) { savedFlash = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation { savedFlash = false }
        }
    }

    private func clearAll() {
        dataStore.updateGoalSet(.empty)
        seedFromStore()
    }
}

// MARK: - Deadline Editor Pane (roadmap 1.2b — per-book finish-by dates)

struct DeadlineEditorPane: View {
    @EnvironmentObject private var dataStore: DataStore

    @State private var selectedBookID: UUID?
    @State private var targetDate = Date().addingTimeInterval(30 * 86_400)
    @State private var reminderEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Finish-by dates per book")
                .font(.headline)

            if dataStore.books.isEmpty {
                ContentUnavailableView(
                    "No Books",
                    systemImage: "books.vertical",
                    description: Text("Import a book first — deadlines track individual titles.")
                )
            } else {
                addForm
                deadlineList
            }
        }
        .padding(4)
    }

    private var addForm: some View {
        HStack(alignment: .bottom, spacing: 12) {
            Picker("Book", selection: $selectedBookID) {
                Text("Choose a book…").tag(UUID?.none)
                ForEach(dataStore.books.sorted { $0.title < $1.title }) { book in
                    Text(book.title).tag(UUID?.some(book.id))
                }
            }
            .frame(minWidth: 240)

            DatePicker("Finish by", selection: $targetDate, displayedComponents: .date)

            Toggle("Remind", isOn: $reminderEnabled)
                .toggleStyle(.checkbox)

            Button("Add Deadline") { addDeadline() }
                .disabled(selectedBookID == nil)
        }
    }

    private var deadlineList: some View {
        let deadlines = dataStore.libraryState.deadlines
            .sorted { $0.targetDate < $1.targetDate }

        return List {
            ForEach(deadlines) { deadline in
                HStack {
                    Image(systemName: "calendar")
                        .foregroundColor(color(for: deadline))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(bookTitle(for: deadline.bookID))
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(formatted(deadline.targetDate))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if deadline.reminderEnabled {
                        Image(systemName: "bell.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Button {
                        dataStore.removeDeadline(bookID: deadline.bookID)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help("Remove deadline")
                }
                .padding(.vertical, 2)
            }
        }
        .frame(minHeight: 200)
        .overlay {
            if deadlines.isEmpty {
                Text("No deadlines yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func addDeadline() {
        guard let bookID = selectedBookID else { return }
        // Normalize to end-of-day so "finish by Jun 30" includes June 30 itself.
        let endOfDay = Calendar.current.startOfDay(for: targetDate).addingTimeInterval(86_399)
        dataStore.addDeadline(BookDeadline(
            bookID: bookID,
            targetDate: endOfDay,
            reminderEnabled: reminderEnabled
        ))
    }

    // MARK: Helpers

    private func bookTitle(for id: UUID) -> String {
        dataStore.book(id: id)?.title ?? "Unknown book"
    }

    private func formatted(_ date: Date) -> String {
        date.formatted(date: .long, time: .omitted)
    }

    private func color(for deadline: BookDeadline) -> Color {
        let days = Calendar.current.dateComponents([.day], from: Date(), to: deadline.targetDate).day ?? 0
        if days < 0 { return .red }
        if days <= 7 { return .orange }
        return .accentColor
    }
}


// MARK: - RSVP Settings (P5 Feature 3 — plan §4: single toggle + WPM)

struct RSVPSettingsPane: View {
    @AppStorage("rsvp.enabled") private var isEnabled = true
    @AppStorage("rsvp.wpm") private var wordsPerMinute: Double = 300

    var body: some View {
        Form {
            Section {
                Toggle("Show Speed Read controls in readers", isOn: $isEnabled)
            } footer: {
                Text("RSVP streams one word at a time at a fixed point, removing eye travel. Great for articles and re-reading; comprehension research suggests treating it as a complement to normal reading, not a replacement.")
            }

            if isEnabled {
                Section("Default Speed") {
                    Slider(value: $wordsPerMinute, in: 150 ... 800, step: 25) {
                        Text("Words per minute")
                    } minimumValueLabel: {
                        Text("150")
                    } maximumValueLabel: {
                        Text("800")
                    }
                    Text("\(Int(wordsPerMinute)) WPM")
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                }
            }
        }
        .formStyle(.grouped)
    }
}


// MARK: - Mirage Settings (ADR-13 control center)

/// The Mirage control center: one switch, one warm engine, one library-wide
/// scan, and one explicit batch. Nothing here starts engine work on appear —
/// the runtime availability probe is passive, and every process/request begins
/// from a labeled gesture.
struct MirageSettingsPane: View {
    @EnvironmentObject private var dataStore: DataStore
    @AppStorage(MirageSettings.enabledKey) private var isEnabled = true
    @ObservedObject private var engine = MirageEngineService.shared
    @StateObject private var batch = MirageBatchAnalyzer()

    @State private var index: MirageLibraryIndexFile = .empty
    @State private var indexUnreadable: String?
    @State private var linkedBookIDs: Set<UUID> = []
    @State private var mapUnreadable: String?
    @State private var identityMap: MirageIdentityMapFile?
    @State private var scanning = false
    @State private var scanNote: String?

    /// EPUB books and comic containers (CBZ/image folders) are the two
    /// analyzable source families; PDFs stay out of Mirage entirely.
    private var analyzableBooks: [Book] {
        dataStore.books.filter { $0.fileType == .epub || $0.fileType.isComic }
    }

    private var unlinkedBooks: [Book] {
        analyzableBooks.filter { !linkedBookIDs.contains($0.id) }
    }

    /// 2.7: derived coverage/density from engine-attested inventory counts and
    /// RT's own link records. No engine call and no analysis content is read.
    private var analysisReport: MirageAnalysisReport {
        MirageAnalysisReport(
            analyzableBookIDs: Set(analyzableBooks.map(\.id)),
            identityMap: identityMap,
            index: index)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable Mirage analysis", isOn: $isEnabled)
                    .onChange(of: isEnabled) { _, enabled in
                        if enabled {
                            engine.refreshRuntimeAvailability()
                        } else {
                            Task { await engine.stop() }
                        }
                    }
            } footer: {
                Text("Mirage reads an EPUB's text — or recognizes a comic's text on this Mac — and keeps its own spoiler-safe analysis locally. RT's library, goals, and progress are never touched. Analysis starts only when you ask for it.")
            }

            Section("Engine") {
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(engineColor)
                        .frame(width: 9, height: 9)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(engineTitle)
                            .font(.body.weight(.medium))
                        Text(engineDetail)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if engine.state.isWarm || engine.stopPending {
                        Button(engine.stopPending ? "Stopping…" : "Stop") {
                            Task { await engine.stop() }
                        }
                        .disabled(engine.stopPending)
                    } else {
                        Button("Start") {
                            Task { await engine.start() }
                        }
                        .disabled(!isEnabled || engine.runtimeChannel == nil)
                    }
                }

                if case .failed(let reason) = engine.state {
                    Text(reason)
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(3)
                    Button("Retry engine") {
                        Task { await engine.retry() }
                    }
                }

                Text(engineProvenance)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Stopping Mirage deletes nothing: stored analyses, RT's link records, and the library index stay exactly as they are.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Section("Analysis report") {
                let report = analysisReport
                Text(report.summaryLine)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                LabeledContent("Coverage") {
                    Text("\(report.linkedCount) of \(report.analyzableCount) analyzable (\(report.coveragePercent)%)")
                }
                LabeledContent("Indexed editions") {
                    Text("\(report.indexedEditionCount)")
                }
                LabeledContent("Mirage ledger") {
                    Text("\(report.totalUnits) units · \(report.totalClaims) claims")
                }
                if let units = report.averageUnitsPerEdition,
                   let claims = report.averageClaimsPerEdition {
                    LabeledContent("Per indexed edition") {
                        Text("\(Self.oneDecimal(units)) units · \(Self.oneDecimal(claims)) claims")
                    }
                }
                if report.pausedBookCount > 0 {
                    LabeledContent("Paused links") {
                        Text("\(report.pausedBookCount) book\(report.pausedBookCount == 1 ? "" : "s")")
                    }
                }
                if let seconds = engine.lastAnalysisSeconds {
                    LabeledContent("Last analysis") {
                        Text("\(Self.oneDecimal(seconds)) s")
                    }
                }
                LabeledContent("Last scan") {
                    Text(lastScanText)
                }

                if report.unindexedLinkedCount > 0 {
                    Text("\(report.unindexedLinkedCount) linked book\(report.unindexedLinkedCount == 1 ? "" : "s") \(report.unindexedLinkedCount == 1 ? "is" : "are") not in the last scan. Scan library to reconcile.")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if report.zeroClaimEditionCount > 0 {
                    Text("\(report.zeroClaimEditionCount) indexed edition\(report.zeroClaimEditionCount == 1 ? " has" : "s have") zero claims. That is an engine count, not a quality judgment.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let mapUnreadable {
                    Text(mapUnreadable)
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                if let indexUnreadable {
                    Text(indexUnreadable)
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                HStack(spacing: 12) {
                    Button("Scan library") {
                        Task { await scanLibrary() }
                    }
                    .disabled(!isEnabled || scanning)
                    if scanning {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                if let scanNote {
                    Text(scanNote)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Counts are engine-attested inventory facts from the read-only scan. RT never promotes them into its library, and no claim text, evidence, entity, or graph appears here — ADR-7 keeps those behind the spoiler gate.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Batch analysis") {
                if unlinkedBooks.isEmpty {
                    Text(linkedBookIDs.isEmpty
                         ? "No analyzable books in this library yet."
                         : "Every analyzable book in this library has a Mirage link.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                } else {
                    Text("\(unlinkedBooks.count) book\(unlinkedBooks.count == 1 ? "" : "s") not linked yet.")
                        .font(.callout)
                    Button("Analyze \(unlinkedBooks.count) book\(unlinkedBooks.count == 1 ? "" : "s")") {
                        batch.prepare(books: unlinkedBooks, linkedBookIDs: linkedBookIDs)
                        Task { await batch.run() }
                    }
                    .disabled(!isEnabled || batch.isRunning)
                }

                if batch.isRunning {
                    ProgressView(value: batch.fractionComplete)
                    HStack {
                        Text(batch.summaryLine)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Cancel") { batch.cancel() }
                    }
                } else if !batch.jobs.isEmpty {
                    Text(batch.summaryLine)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if !batch.jobs.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(batch.jobs.prefix(20)) { job in
                            batchRow(job)
                        }
                        if batch.jobs.count > 20 {
                            Text("…and \(batch.jobs.count - 20) more")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    HStack {
                        if batch.failedCount > 0 && !batch.isRunning && batch.finishedAt != nil {
                            Button("Retry failed") {
                                Task { await batch.retryFailed() }
                            }
                        }
                        if !batch.isRunning && batch.finishedAt != nil {
                            Button("Clear list") { batch.reset() }
                        }
                    }
                }
            }

            Section("Storage") {
                Text("Mirage writes only inside the app's mirage folder. Your library, goals, and reading progress stay in Asterisma's own files.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Button("Show Mirage folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([mirageDirectory])
                }
                .disabled(!FileManager.default.fileExists(atPath: mirageDirectory.path))
            }
        }
        .formStyle(.grouped)
        .task {
            engine.refreshRuntimeAvailability()
            reload()
        }
        .onChange(of: dataStore.books.count) { _, _ in reload() }
        .onChange(of: batch.finishedAt) { _, _ in reload() }
    }

    // MARK: - Rows and copy

    private func batchRow(_ job: MirageBatchAnalyzer.Job) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: batchIcon(job.state))
                .foregroundColor(batchColor(job.state))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(job.title)
                    .font(.callout)
                    .lineLimit(1)
                Text(batchDetail(job))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }

    private var engineTitle: String {
        switch engine.state {
        case .stopped: return "Engine idle"
        case .disabled: return "Mirage is off"
        case .unavailable: return "Engine not available"
        case .starting: return "Engine starting…"
        case .ready: return "Engine warm"
        case .failed: return "Engine needs attention"
        }
    }

    private var engineDetail: String {
        switch engine.state {
        case .stopped:
            return "Starts only on an explicit request; stops automatically when idle."
        case .disabled:
            return "No engine will start while the switch is off."
        case .unavailable(let reason):
            return reason
        case .starting:
            return "Handshaking with the local sidecar…"
        case .ready:
            let started = engine.startedAt?.formatted(date: .omitted, time: .shortened) ?? "just now"
            return "Warm since \(started) · \(engine.requestCount) request\(engine.requestCount == 1 ? "" : "s") this session."
        case .failed(let reason):
            return reason
        }
    }

    private var engineProvenance: String {
        switch engine.runtimeChannel {
        case .bundled: return "Runtime: bundled with this build."
        case .dev: return "Runtime: development checkout (MIRAGE_REAL_ENGINE_DIR)."
        case nil: return "Runtime: not resolved on this Mac yet."
        }
    }

    private var engineColor: Color {
        switch engine.state {
        case .ready: return .green
        case .starting: return .yellow
        case .failed: return .red
        case .unavailable: return .orange
        case .stopped, .disabled: return .secondary
        }
    }

    private var lastScanText: String {
        guard let generated = index.generatedAt else { return "Never scanned" }
        return generated.formatted(date: .abbreviated, time: .shortened)
    }

    private static func oneDecimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    private var mirageDirectory: URL {
        MirageSupportPaths.mirageDirectory()
    }

    private func batchIcon(_ state: MirageBatchAnalyzer.Job.State) -> String {
        switch state {
        case .pending: return "circle"
        case .running: return "arrow.triangle.2.circlepath"
        case .linked: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "minus.circle"
        }
    }

    private func batchColor(_ state: MirageBatchAnalyzer.Job.State) -> Color {
        switch state {
        case .linked: return .green
        case .failed: return .yellow
        case .cancelled: return .secondary
        case .pending, .running: return .secondary
        }
    }

    private func batchDetail(_ job: MirageBatchAnalyzer.Job) -> String {
        switch job.state {
        case .pending: return "Waiting"
        case .running: return "Analyzing…"
        case .linked(let reused): return reused ? "Linked · reused stored analysis" : "Linked"
        case .failed(let reason): return reason
        case .cancelled: return "Cancelled"
        }
    }

    // MARK: - Data + actions

    private func reload() {
        let identityURL = mirageDirectory.appendingPathComponent("identity-map.json")
        switch MirageIdentityMapStore(fileURL: identityURL).load() {
        case .loaded(let map):
            identityMap = map
            linkedBookIDs = Set(map.entries.filter { $0.status == .active }.map(\.rtBookID))
            mapUnreadable = nil
        case .unreadable(let reason):
            identityMap = nil
            linkedBookIDs = []
            mapUnreadable = reason
        }

        let indexURL = mirageDirectory.appendingPathComponent("library-index.json")
        switch MirageLibraryIndexStore(fileURL: indexURL).load() {
        case .missing:
            index = .empty
            indexUnreadable = nil
        case .loaded(let file):
            index = file
            indexUnreadable = nil
        case .unreadable(let reason):
            index = .empty
            indexUnreadable = reason
        }
    }

    private func scanLibrary() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        switch await engine.scanLibrary() {
        case .success(let report):
            index = report.index
            indexUnreadable = nil
            scanNote = report.orphanedCount == 0
                ? "Scanned \(report.index.entries.count) edition\(report.index.entries.count == 1 ? "" : "s") · \(report.index.totalUnits) units · \(report.index.totalClaims) claims."
                : "Scanned \(report.index.entries.count) editions; \(report.orphanedCount) RT link\(report.orphanedCount == 1 ? "" : "s") paused because its edition is gone."
            reload()
        case .failure(let reason):
            scanNote = reason
        }
    }
}

// MARK: - Weather Settings (G4)

struct WeatherSettingsPane: View {
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                Text("Weather uses your approximate location to capture conditions during reading sessions. If Location is off, set a manual latitude/longitude here.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                TextField("Latitude (e.g. 40.7128)", text: $latitude)
                TextField("Longitude (e.g. -74.0060)", text: $longitude)
                HStack {
                    Button("Save Location") { save() }
                        .keyboardShortcut(.defaultAction)
                    Button("Clear") { clear() }
                    if saved {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                    }
                }
            } header: {
                Text("Location")
            } footer: {
                Text("Leave both fields empty to use macOS Location Services.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
    }

    private func load() {
        let defaults = UserDefaults.standard
        let lat = defaults.double(forKey: "wks_manual_lat")
        let lon = defaults.double(forKey: "wks_manual_lon")
        if lat != 0 || lon != 0 {
            latitude = String(lat)
            longitude = String(lon)
        }
    }

    private func save() {
        guard let lat = Double(latitude), let lon = Double(longitude),
              (-90 ... 90).contains(lat), (-180 ... 180).contains(lon)
        else {
            saved = false
            return
        }
        let defaults = UserDefaults.standard
        defaults.set(lat, forKey: "wks_manual_lat")
        defaults.set(lon, forKey: "wks_manual_lon")
        saved = true
    }

    private func clear() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "wks_manual_lat")
        defaults.removeObject(forKey: "wks_manual_lon")
        latitude = ""
        longitude = ""
        saved = true
    }
}

// MARK: - Sentinel Settings (SG4)

struct SentinelSettingsPane: View {
    @Environment(\.openWindow) private var openWindow
    @State private var configuration = SentinelConfiguration.default
    @State private var loaded = false

    private var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    var body: some View {
        Form {
            Section(
                header: Text("Autonomy"),
                footer: Text(configuration.autonomy.explanation)
            ) {
                Picker("Sentinel", selection: $configuration.autonomy) {
                    ForEach(SentinelAutonomy.allCases, id: \.self) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            if configuration.autonomy.isMonitoring {
                Section("Cadence") {
                    Stepper("Fast checks every \(configuration.cadenceMinutes) minutes",
                            value: $configuration.cadenceMinutes, in: 5...240, step: 5)
                    Stepper("Deep checks every \(configuration.deepCadenceHours) hours",
                            value: $configuration.deepCadenceHours, in: 6...168, step: 6)
                }
            }

            Section {
                Button {
                    openWindow(id: SentinelHealthCenterWindowID.id)
                } label: {
                    Label("Open Sentinel Health", systemImage: "shield.lefthalf.filled")
                }
            } footer: {
                Text("See every check, every issue, and every repair — including what changed and whether it verified.")
            }

            Section("Privacy") {
                Label("No reading data ever leaves this Mac", systemImage: "lock.shield")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Sentinel writes only inside its own folder. Explanations are local and deterministic; nothing is generated by a remote service.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            guard !loaded else { return }
            configuration = SentinelConfiguration.load(from: .standard, isDebug: isDebugBuild)
            loaded = true
        }
        .onChange(of: configuration) { _, newValue in
            guard loaded else { return }
            Task { await SentinelRuntime.shared.updateConfiguration(newValue) }
        }
    }
}
