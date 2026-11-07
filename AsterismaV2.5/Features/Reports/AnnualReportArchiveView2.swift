//  AnnualReportArchiveView2.swift
//  AsterismaV2.5
//
//  Feature B: Annual Report Archive — browse past years
//
//  ARCHITECTURE
//  The archive stores only the list of years that have sessions.
//  It does NOT store report payloads, snapshots, or cached data.
//  When a year is selected, the report is generated dynamically from live data.
//
//  ROADMAP 3.3 (RA-002 / NA-3): report generation previously spawned an
//  UNTRACKED Task.detached per selection. Rapid year switching let an older
//  task finish last and overwrite the newer selection's pane ("last-finished-
//  wins"). Generation now carries a monotonically increasing token; a stale
//  task's result is discarded on landing. LT-5 made Prev/Next clicks much
//  faster, which is what made this race practically reachable.
//
//  ROADMAP 4.1 (RA-002): JanuaryFirstBannerView deleted. It was defined here
//  (~200 LOC incl. a speculative AppDelegate advice block) but never instantiated
//  anywhere in the app — verified by reference search during RA-002. Recoverable
//  from project history if the January-banner feature is ever prioritized.
//
import SwiftUI

// MARK: - Annual Report Archive View

/// Presents the list of years with reading data, each opening its annual report.
struct AnnualReportArchiveView: View {
    @EnvironmentObject var dataStore: DataStore

    @State private var selectedYear: Int?
    @State private var reportData: AnnualReportData?
    @State private var isGenerating: Bool = false

    /// ROADMAP 3.3 (NA-3): incremented on every generation request; detached
    /// tasks capture the value they were created for and are discarded if a
    /// newer request has superseded them by the time their work completes.
    @State private var generationToken = 0

    var body: some View {
        NavigationSplitView {
            archiveSidebar
        } detail: {
            if isGenerating {
                generatingView
            } else if let report = reportData {
                AnnualReportView(data: report) {
                    selectedYear = nil
                    reportData = nil
                }
            } else {
                archiveEmptyDetail
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    // MARK: - Sidebar

    private var archiveSidebar: some View {
        let years = availableReportYears(books: dataStore.books)

        return Group {
            if years.isEmpty {
                emptyArchiveView
            } else {
                List(years, id: \.self, selection: $selectedYear) { year in
                    archiveYearRow(year: year)
                }
                .listStyle(.sidebar)
                .onChange(of: selectedYear) { _, newYear in
                    guard let year = newYear else { return }
                    generateReport(for: year)
                }
            }
        }
        .navigationTitle("Reading Reports")
        .frame(minWidth: 200)
    }

    private func archiveYearRow(year: Int) -> some View {
        let yearBooks = booksRead(in: dataStore.books, year: year)
        let yearCompleted = booksCompleted(in: dataStore.books, year: year)
        let period = analyticsPeriod(for: year)
        let yearTime = AnalyticsEngine.readingTime(books: dataStore.books, in: period)

        return VStack(alignment: .leading, spacing: 4) {
            Text(String(year))
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.primary)

            HStack(spacing: 12) {
                Label("\(yearCompleted.count) finished", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                Label(formatDuration(yearTime), systemImage: "clock")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
        .tag(year)
    }

    private var emptyArchiveView: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text("No reading data yet.")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Your annual reports will appear here once you've completed reading sessions.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var archiveEmptyDetail: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("Select a year to view your reading report.")
                .font(.title3)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var generatingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.4)
            Text("Generating your report…")
                .font(.body)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Report Generation

    private func generateReport(for year: Int) {
        generationToken += 1
        let token = generationToken

        isGenerating = true
        reportData = nil

        // Run on background thread; generation is synchronous but can be slow for large libraries.
        // ROADMAP 3.3 (NA-3): the token travels with the task. If the user has
        // clicked a different year since this task started, its result is stale
        // and must NOT land — the newer task owns the pane now.
        Task.detached(priority: .userInitiated) {
            let books = await dataStore.books
            let goalSet = await dataStore.libraryState.goalSet
            let achievements = await dataStore.libraryState.earnedAchievements
            // Load persisted audio profiles so MusicalAnalysisEngine can populate Slide 10.
            let audioProfiles = await dataStore.allAudioProfiles()

            let generated = AnnualReportGenerator.generate(
                year: year,
                books: books,
                goalSet: goalSet,
                earnedAchievements: achievements,
                audioProfiles: audioProfiles
            )

            await MainActor.run {
                guard token == generationToken else { return } // superseded — discard
                reportData = generated
                isGenerating = false
            }
        }
    }
}
