//  WeatherInsightPanel 2.swift
//  AsterismaV2.5
//  Fetches stored WeatherSnapshots, assembles EnvironmentalSessionRecord arrays
//  by joining them with DataStore reading sessions, then calls WeatherAnalysisEngine
//  to produce an EnvironmentalReadingProfile.
//
//  Engines called:
//    - WeatherKitService.shared.snapshots(from:to:)          (fetch stored snapshots)
//    - WeatherKitService.shared.coverageRatio(for:)          (real data-coverage input)
//    - WeatherAnalysisEngine.buildEnvironmentalProfile(from:) (produces profile)
//    - WeatherAnalysisEngine.analyzeCorrelations(from:)       (condition correlations)
//    - WeatherAnalysisEngine.generateTrendReport(from:)       (temporal trends)
//    - AnalyticsEngine.adjustedReadingSpeed(for:)            (per-book speed input)
//
//  Data guard: requires at least 5 sessions with attached weather snapshots
//  before showing results. Below that threshold shows ContentUnavailableView.
//
//  PRODUCTION PASS (P5 / W-01 wiring): load() now measures REAL data coverage
//  via coverageRatio(for:) over the session IDs actually analyzed and feeds it to
//  both report entry points, so ConfidenceReport.dataCoverageScore reflects how
//  much of the analyzed history genuinely has persisted weather — no more
//  hardcoded 1.0.

import CoreLocation
import SwiftUI

private let minimumSessionsForWeather = 5

struct WeatherInsightPanel: View {
    @EnvironmentObject private var dataStore: DataStore
    @Environment(\.dismiss) private var dismiss

    @State private var profile: EnvironmentalReadingProfile?
    @State private var correlations: [EnvironmentalCorrelation] = []
    @State private var trend: WeatherTrendReport?
    @State private var isLoading = true
    @State private var sessionCount = 0
    @State private var errorMessage: String?
    @State private var locationDenied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if locationDenied {
                    HStack(spacing: 8) {
                        Image(systemName: "location.slash.fill")
                        Text("Location is off, so new weather data is paused. Enable Location for AsterismaV2.5 in System Settings to resume.")
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .background(Color.orange.opacity(0.10))
                }

                Group {
                    if isLoading {
                        ProgressView("Loading weather data…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let error = errorMessage {
                        errorState(message: error)
                    } else if sessionCount < minimumSessionsForWeather {
                        tooLittleDataState
                    } else if let profile {
                        content(profile: profile)
                    } else {
                        tooLittleDataState
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("Environment")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button { Task { await load() } } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
        }
        .frame(minWidth: 500, minHeight: 580)
        .task { await load() }
    }

    // MARK: - Main Content

    private func content(profile: EnvironmentalReadingProfile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // ── Temperature profile ──────────────────────────────────
                if let temp = profile.temperatureProfile {
                    temperatureSection(temp)
                }

                // ── Seasonal patterns ──────────────────────────────────
                if !profile.seasonalProfiles.isEmpty {
                    seasonalSection(profile.seasonalProfiles)
                }

                // ── Weather correlations ──────────────────────────────
                if !correlations.isEmpty {
                    correlationsSection(correlations)
                }

                // ── Trend summary ─────────────────────────────────────
                if let trend {
                    trendSection(trend)
                }

                // ── Data note ─────────────────────────────────────────
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Based on \(sessionCount) reading sessions with captured weather data.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(24)
        }
    }

    // MARK: - Temperature Section

    private func temperatureSection(_ temp: TemperatureProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Temperature & Reading", systemImage: "thermometer.medium")
                .font(.title3)
                .fontWeight(.semibold)

            HStack(spacing: 16) {
                WeatherStatCard(
                    value: String(format: "%.0f–%.0f°", temp.optimalRange.lowerBound, temp.optimalRange.upperBound),
                    label: "Optimal temp range",
                    symbol: "thermometer"
                )
                WeatherStatCard(
                    value: String(format: "%.0f pg/h", temp.peakReadingSpeed * 3600 / 250),
                    label: "Peak reading speed",
                    symbol: "speedometer"
                )
                WeatherStatCard(
                    value: String(format: "%.0f%%", temp.influenceScore * 100),
                    label: "Temperature influence",
                    symbol: "chart.bar.fill"
                )
            }
        }
    }

    // MARK: - Seasonal Section

    private func seasonalSection(_ seasons: [SeasonalProfile]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Reading by Season", systemImage: "leaf")
                .font(.title3)
                .fontWeight(.semibold)

            let maxPages = seasons.map(\.averagePagesRead).max() ?? 1

            ForEach(seasons, id: \.season) { season in
                HStack(spacing: 10) {
                    Image(systemName: seasonSymbol(season.season))
                        .frame(width: 22)
                        .foregroundColor(seasonColor(season.season))

                    Text(season.season.rawValue.capitalized)
                        .font(.subheadline)
                        .frame(width: 90, alignment: .leading)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.secondary.opacity(0.12))
                            RoundedRectangle(cornerRadius: 4)
                                .fill(seasonColor(season.season).opacity(0.7))
                                .frame(width: geo.size.width * CGFloat(
                                    maxPages > 0 ? season.averagePagesRead / maxPages : 0
                                ))
                        }
                    }
                    .frame(height: 8)

                    Text(String(format: "%.0f pg", season.averagePagesRead))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
    }

    // MARK: - Correlations Section

    private func correlationsSection(_ correlations: [EnvironmentalCorrelation]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Condition Correlations", systemImage: "cloud.sun")
                .font(.title3)
                .fontWeight(.semibold)

            Text("How different weather conditions affect your reading.")
                .font(.caption)
                .foregroundColor(.secondary)

            ForEach(correlations.prefix(5)) { correlation in
                CorrelationRow(correlation: correlation)
            }
        }
    }

    // MARK: - Trend Section

    private func trendSection(_ trend: WeatherTrendReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Environmental Sensitivity", systemImage: "chart.line.uptrend.xyaxis")
                .font(.title3)
                .fontWeight(.semibold)

            HStack(spacing: 16) {
                WeatherStatCard(
                    value: String(format: "%.0f%%", trend.environmentalSensitivityScore * 100),
                    label: "Weather sensitivity",
                    symbol: "antenna.radiowaves.left.and.right"
                )

                if let strongest = trend.strongestInfluences.first {
                    WeatherStatCard(
                        value: strongest.factor.rawValue.capitalized,
                        label: "Strongest influence",
                        symbol: "star.fill"
                    )
                }
            }

            if !trend.strongestInfluences.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Top influences on your reading")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ForEach(trend.strongestInfluences.prefix(3)) { corr in
                        CorrelationRow(correlation: corr)
                    }
                }
            }
        }
    }

    // MARK: - Empty / Error States

    private var tooLittleDataState: some View {
        ContentUnavailableView(
            "Not Enough Data Yet",
            systemImage: "cloud.sun",
            description: Text("Weather patterns appear here after \(minimumSessionsForWeather) reading sessions with location access enabled. Currently at \(sessionCount).")
        )
    }

    private func errorState(message: String) -> some View {
        ContentUnavailableView(
            "Weather Data Unavailable",
            systemImage: "exclamationmark.icloud",
            description: Text(message)
        )
    }

    // MARK: - Data Loading

    @MainActor
    private func load() async {
        isLoading = true
        errorMessage = nil
        let status = WeatherKitService.shared.locationAuthorizationStatus
        locationDenied = (status == .denied || status == .restricted)

        do {
            let records = try buildEnvironmentalRecords()
            sessionCount = records.count

            guard records.count >= minimumSessionsForWeather else {
                isLoading = false
                return
            }

            // W-01 WIRING: real coverage over exactly the session IDs being
            // analyzed. Failure here degrades to nil (engine falls back to its
            // sample-size proxy) rather than blocking the panel.
            let coverage = try? WeatherKitService.shared
                .coverageRatio(for: records.map(\.sessionID))

            let engine = WeatherAnalysisEngine()
            profile = engine.buildEnvironmentalProfile(
                from: records,
                dataCoverageRatio: coverage
            )
            // analyzeCorrelations() itself is completely untouched — this
            // only decides which of its results have earned the right to
            // be shown (DataMaturityWeatherAdapter asks per-correlation).
            correlations = DataMaturityWeatherAdapter
                .gate(engine.analyzeCorrelations(
                    from: records,
                    dataCoverageRatio: coverage))
                .map(\.correlation)
            trend = engine.generateTrendReport(
                sessions: records,
                dataCoverageRatio: coverage
            )
        } catch {
            errorMessage = "Could not load weather data: \(error.localizedDescription)"
        }

        isLoading = false
    }

    /// Joins completed reading sessions with their stored WeatherSnapshots to build
    /// [EnvironmentalSessionRecord] for WeatherAnalysisEngine.
    ///
    /// Sessions without a matching WeatherSnapshot are skipped — the engine
    /// requires at least one weather data point per record.
    private func buildEnvironmentalRecords() throws -> [WeatherAnalysisEngine.EnvironmentalSessionRecord] {
        let allSessions: [(session: ReadingSession, book: Book)] = dataStore.books.flatMap { book in
            book.sessions
                .filter { $0.endTime != nil }
                .map { (session: $0, book: book) }
        }

        guard !allSessions.isEmpty else { return [] }

        // Fetch all snapshots in the span of the recorded sessions
        guard let earliest = allSessions.map(\.session.startTime).min(),
              let latest = allSessions.compactMap(\.session.endTime).max()
        else { return [] }

        let snapshots = try WeatherKitService.shared.snapshots(
            from: earliest.addingTimeInterval(-3600),
            to: latest.addingTimeInterval(3600)
        )

        var records: [WeatherAnalysisEngine.EnvironmentalSessionRecord] = []

        for pair in allSessions {
            let session = pair.session
            let book = pair.book
            guard let end = session.endTime else { continue }

            // WeatherSnapshot is timestamp-keyed (the normaliser discards any
            // session linkage), so the join is closest-snapshot-to-session-start.
            let snapshot = snapshots.min {
                abs($0.timestamp.timeIntervalSince(session.startTime))
                    < abs($1.timestamp.timeIntervalSince(session.startTime))
            }

            // G4: a snapshot more than an hour from the session is not evidence
            // about that session. Do not bind sparse weather to old sessions.
            guard let snap = snapshot,
                  abs(snap.timestamp.timeIntervalSince(session.startTime)) <= 3600
            else { continue }

            // AnalyticsEngine.adjustedReadingSpeed returns seconds/page
            let secsPerPage = AnalyticsEngine.adjustedReadingSpeed(for: book)
            let pagesPerHour = secsPerPage > 0 ? 3600 / secsPerPage : 0

            records.append(
                WeatherAnalysisEngine.EnvironmentalSessionRecord(
                    sessionID: session.id,
                    bookID: book.id,
                    timestamp: session.startTime,
                    weather: snap,
                    readingDurationMinutes: end.timeIntervalSince(session.startTime) / 60,
                    pagesRead: Double(session.pagesRead),
                    chaptersCompleted: 0,
                    booksCompleted: 0,
                    readingSpeed: pagesPerHour,
                    consistencyScore: 0.5, // approximation
                    readingFrequencyScore: 0.5, // approximation
                    engagementScore: min(1.0, Double(session.pagesRead) / 30.0),
                    sessionQualityScore: 0.5, // approximation
                    momentumScore: 0.5, // approximation
                    completionProbability: 0.5, // approximation
                    abandonmentProbability: 0.5,
                    difficultyScore: max(0, min(1, secsPerPage / 300)),
                    complexityScore: 0.5,
                    bookLength: Double(book.totalPages),
                    genre: book.genre.rawValue,
                    seriesIdentifier: nil,
                    reread: false
                )
            )
        }

        return records
    }

    // MARK: - Helpers

    private func seasonSymbol(_ season: SeasonalPeriod) -> String {
        switch season {
        case .spring: return "leaf"
        case .summer: return "sun.max"
        case .autumn: return "wind"
        case .winter: return "snowflake"
        }
    }

    private func seasonColor(_ season: SeasonalPeriod) -> Color {
        switch season {
        case .spring: return .green
        case .summer: return .yellow
        case .autumn: return .orange
        case .winter: return .blue
        }
    }
}

// MARK: - WeatherStatCard

private struct WeatherStatCard: View {
    let value: String
    let label: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .font(.subheadline)
                .foregroundColor(.accentColor)
            Text(value)
                .font(.title3)
                .fontWeight(.bold)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - CorrelationRow

private struct CorrelationRow: View {
    let correlation: EnvironmentalCorrelation

    private var label: String {
        "\(correlation.factor.rawValue.capitalized) → \(correlation.metric.rawValue.capitalized)"
    }

    private var isPositive: Bool {
        correlation.coefficient >= 0
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isPositive ? "arrow.up.right" : "arrow.down.right")
                .foregroundColor(isPositive ? .green : .orange)
                .frame(width: 20)

            Text(label)
                .font(.subheadline)

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%+.2f", correlation.coefficient))
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(isPositive ? .green : .orange)
                Text(String(format: "%.0f%% influence", correlation.influenceScore * 100))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Preview

#Preview {
    WeatherInsightPanel()
        .environmentObject(DataStore())
}
