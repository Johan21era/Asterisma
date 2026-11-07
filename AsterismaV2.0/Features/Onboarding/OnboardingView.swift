//  OnboardingView.swift
//  AsterismaV2.0
//
//  P5 / Feature 5 (First-Run Experience).
//
//  A brand-new user previously hit an empty sidebar with zero guidance.
//  This wizard shows automatically when the library is empty and the user
//  hasn't dismissed it, and walks the three steps that make every other
//  surface come alive:
//    1. Import your first book   (native open panel, existing importer)
//    2. Set a reading goal       (existing Settings APIs — roadmap 1.2b)
//    3. Done → points at Analytics
//
//  Dismissal persists via @AppStorage so it never nags twice.

import SwiftUI
import UniformTypeIdentifiers

struct OnboardingView: View {
    @EnvironmentObject private var dataStore: DataStore
    @Environment(\.dismiss) private var dismiss

    /// Whether to show. Library empty AND never dismissed.
    static func shouldShow(books: [Book], dismissed: Bool) -> Bool {
        books.isEmpty && !dismissed
    }

    @AppStorage("onboarding.completed") private var dismissed = false
    @State private var step = 0
    @State private var importSucceeded = false
    @State private var goalSet = false
    @State private var importError: String?

    // Goal editor state (mirrors SettingsRootView's editor contract)
    @State private var dailyPagesEnabled = true
    @State private var dailyPages = 20

    var body: some View {
        VStack(spacing: 0) {
            header

            Group {
                switch step {
                case 0: welcomeStep
                case 1: importStep
                default: goalStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
        }
        .frame(width: 520, height: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("Welcome to AsterismaV2.0")
                .font(.title2.weight(.semibold))
            Text("Three quick steps and your analytics come alive.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 32)
        .padding(.bottom, 12)
    }

    // MARK: - Step views

    private var welcomeStep: some View {
        VStack(spacing: 18) {
            featureRow("book", "Track real pages & sessions", "Every page turn is timed while you read EPUBs and PDFs.")
            featureRow("chart.line.uptrend.xyaxis", "See honest insights", "Speed, streaks, best reading hours — derived from evidence.")
            featureRow("target", "Goals that mean something", "Set a pace; watch projections update as you read.")
        }
        .padding(.horizontal, 44)
    }

    private func featureRow(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var importStep: some View {
        VStack(spacing: 16) {
            if importSucceeded || !dataStore.books.isEmpty {
                Label("Library started ✓", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
                Text("You can add more anytime with the + button.")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 36))
                    .foregroundStyle(.tint)
                Text("Add your first book")
                    .font(.headline)
                Text("EPUB, PDF, CBZ, or an image-folder comic. Covers are captured automatically, and reading time starts counting only once a book actually opens.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)

                Button {
                    importBook()
                } label: {
                    Label("Choose a Book…", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if let error = importError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .frame(maxWidth: 380)
                }

                Button("Skip for now") { advance() }
                    .buttonStyle(.link)
            }
        }
    }

    private var goalStep: some View {
        VStack(spacing: 16) {
            Image(systemName: "target")
                .font(.system(size: 36))
                .foregroundStyle(.tint)

            Toggle("Daily page target", isOn: $dailyPagesEnabled)
                .frame(width: 240)

            if dailyPagesEnabled {
                Stepper("\(dailyPages) pages per day", value: $dailyPages, in: 5 ... 500)
                    .frame(width: 280)
            }

            Button {
                commitGoal()
            } label: {
                Label(dailyPagesEnabled ? "Save My Goal" : "No Goals For Now", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Footer / progress

    private var footer: some View {
        HStack {
            ForEach(0..<3) { i in
                Circle()
                    .fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
            Spacer()
            if step > 0 {
                Button("Back") { step -= 1 }
            }
            if step < 2 {
                Button(step == 0 ? "Get Started" : "Next") { advance() }
            } else {
                Button("Finish") { finish() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    // MARK: - Actions

    private func advance() {
        withAnimation { step += 1 }
    }

    private func finish() {
        dismissed = true
        // The sheet is owned by ContentView's @State. Setting the AppStorage
        // flag alone left the sheet on screen forever — the last onboarding
        // step was a dead end (owner-test F2).
        dismiss()
    }

    private func importBook() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        // Folder-form EPUBs are directories/packages on macOS.
        BookImportPanel.configure(panel)

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    let book = try await BookImporter.importBook(from: url)

                    // G1 FIX: onboarding used to bypass the shared import path.
                    // Run the same import-intelligence report and duplicate
                    // rejection as the main window before accepting the book.
                    let fileSizeBytes = (try? url.resourceValues(
                        forKeys: [.fileSizeKey]).fileSize) ?? nil
                    let report = ImportIntelligenceFacade.analyze(
                        book: book,
                        fileName: url.lastPathComponent,
                        fileSizeBytes: fileSizeBytes,
                        fileType: book.fileType.displayName
                    )
                    let accepted = await MainActor.run {
                        dataStore.addBook(book)
                    }
                    await MainActor.run {
                        guard accepted else {
                            importError = "This book is already in your library."
                            return
                        }
                        if let critical = report.warnings.first(where: { $0.level == .critical }) {
                            importError = critical.message
                        }
                        importSucceeded = true
                        advance()
                    }
                } catch {
                    await MainActor.run { importError = error.localizedDescription }
                }
            }
        }
    }

    private func commitGoal() {
        // G1 FIX: preserve annual/weekly/deadline goals. The old code wrote a
        // fresh ReadingGoalSet and destroyed everything except the daily target.
        let merged = dataStore.libraryState.goalSet
            .withDailyPageTarget(dailyPagesEnabled ? dailyPages : nil)
        dataStore.updateGoalSet(merged)
        goalSet = dailyPagesEnabled
        advance()
    }
}
