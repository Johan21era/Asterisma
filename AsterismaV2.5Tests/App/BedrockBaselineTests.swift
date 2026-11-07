//  BedrockBaselineTests.swift
//  Opt-in baseline/performance receipt. Never part of the default census.
//
//  Run via scripts/benchmark.sh. The app is pointed at a COPY of the real
//  library, never the live store.

import Foundation
import Testing
@testable import AsterismaV2_5

private func benchmarkEnv(_ key: String) -> String? {
    let env = ProcessInfo.processInfo.environment
    return env[key] ?? env["TEST_RUNNER_\(key)"]
}

@Suite(
    "Bedrock Baseline (opt-in)",
    .enabled(if: benchmarkEnv("RT_BENCH_LIBRARY") != nil)
)
@MainActor
final class BedrockBaselineTests {

    @Test("Measure load + core analytics on a copy of the real library")
    func baselineMetrics() throws {
        let libraryPath = try #require(benchmarkEnv("RT_BENCH_LIBRARY"))
        let libraryURL = URL(fileURLWithPath: libraryPath)
        let size = (try? FileManager.default.attributesOfItem(atPath: libraryPath)[.size] as? NSNumber)?.intValue ?? 0

        let loadStart = CFAbsoluteTimeGetCurrent()
        let store = DataStore(fileURL: libraryURL)
        let loadMS = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000

        let books = store.books
        let sessions = books.reduce(0) { $0 + $1.sessions.count }
        let pageTimes = books.reduce(0) { partial, book in
            partial + book.sessions.reduce(0) { $0 + $1.pageTimes.count }
        }

        func ms(_ body: () -> Void) -> Double {
            let start = CFAbsoluteTimeGetCurrent()
            body()
            return (CFAbsoluteTimeGetCurrent() - start) * 1000
        }

        var profile = 0.0
        var streak = 0.0
        var trend = 0.0
        var timeOfDay = 0.0
        var genre = 0.0
        var estimate = 0.0

        profile = ms { _ = AnalyticsEngine.readerProfile(books: books) }
        streak = ms { _ = AnalyticsEngine.streak(books: books) }
        trend = ms { _ = AnalyticsEngine.trendAnalysis(books: books) }
        timeOfDay = ms { _ = AnalyticsEngine.timeOfDayAnalysis(books: books) }
        genre = ms { _ = AnalyticsEngine.genreProfiles(from: books) }
        if let first = books.first {
            estimate = ms {
                _ = EstimationEngine.validate(
                    result: EstimationEngine.estimate(for: first, allBooks: books))
            }
        }

        let receipt: [String: Any] = [
            "library_bytes": size,
            "books": books.count,
            "sessions": sessions,
            "page_times": pageTimes,
            "load_ms": loadMS,
            "reader_profile_ms": profile,
            "streak_ms": streak,
            "trend_ms": trend,
            "time_of_day_ms": timeOfDay,
            "genre_profiles_ms": genre,
            "estimation_ms": estimate,
            "captured_at": ISO8601DateFormatter().string(from: Date()),
        ]

        let data = try JSONSerialization.data(
            withJSONObject: receipt, options: [.sortedKeys])
        let json = String(data: data, encoding: .utf8) ?? "{}"

        #expect(books.count > 0)
        #expect(sessions >= 0)
        #expect(pageTimes >= 0)
        print("BEDROCK_BASELINE_JSON \(json)")
    }
}
