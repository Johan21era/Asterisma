//  WeatherTests.swift
//  AsterismaV2.5Tests
//
//  AUDIT §6.1 / TECH_DEBT D3 remediation.
//
//  These three suites previously lived at the bottom of WeatherKitService2.swift
//  behind `#if canImport(XCTest) && DEBUG`, where they compiled into NO target:
//  the app target neither links XCTest nor should contain test code, and the
//  synchronized test folder never saw them. They are relocated here and
//  converted to the swift-testing framework this folder already uses, so they
//  actually execute under `AsterismaV2.5Tests`.
//
//  Conversion map:
//    XCTestCase subclass                  → @Suite struct/class
//    func testFoo()                       → @Test func foo()
//    XCTAssertEqual(a, b, accuracy: c)    → #expect(abs(a - b) <= c)
//    XCTAssertGreaterThan / LessThanOrEqual / Nil / NotNil / True / False
//                                         → #expect(...)
//    XCTUnwrap                            → try #require(...)
//
//  Every assertion message from the originals is preserved verbatim.

import Foundation
import WeatherKit
import Testing

@testable import AsterismaV2_5

// MARK: - WeatherSnapshotNormaliserTests
//
// Every assertion corresponds to a specific engine analysis branch.
// A failure here means that correlation branch produces no signal.

@Suite("WeatherSnapshotNormaliser")
struct WeatherSnapshotNormaliserTests {

    let normaliser = WeatherSnapshotNormaliser()

    // stormActivityIndex — analyzeStormCorrelations depends on this

    @Test("Clear calm conditions produce zero storm index")
    func stormIndex_clearCalm_isZero() {
        // True calm = zero wind: the formula's wind term is deliberately
        // unconditional (a labelled-.clear 90-kPH gale SHOULD score ~0.23),
        // so the zero invariant is defined at zero input.
        let index = normaliser.computeStormIndex(condition: .clear, windKPH: 0, precipMM: 0)
        // Clear calm conditions must produce 0 storm index; analyzeStormCorrelations returns no signal otherwise
        #expect(abs(index - 0.0) <= 0.01)
    }

    @Test("Severe storm conditions produce high storm index")
    func stormIndex_thunderstorm_highWind_heavyRain_isHigh() {
        let index = normaliser.computeStormIndex(condition: .thunderstorms, windKPH: 90, precipMM: 30)
        // Severe storm conditions must produce high index to enable storm correlation signal
        #expect(index > 0.7)
    }

    @Test("Storm index clamps to 1.0")
    func stormIndex_clamped_to_1() {
        let index = normaliser.computeStormIndex(condition: .thunderstorms, windKPH: 200, precipMM: 200)
        #expect(index <= 1.0)
    }

    // Season derivation — buildSeasonalProfiles depends on this

    @Test("Northern hemisphere June is summer")
    func season_northernHemisphere_june_isSummer() {
        #expect(normaliser.deriveSeason(from: makeDate(month: 6), latitude: 51.5) == .summer)
    }

    @Test("Southern hemisphere June is winter")
    func season_southernHemisphere_june_isWinter() {
        // Southern hemisphere June must be winter; SeasonalProfile grouping depends on this
        #expect(normaliser.deriveSeason(from: makeDate(month: 6), latitude: -33.9) == .winter)
    }

    @Test("All four northern seasons derive correctly")
    func season_allFourSeasons_northern() {
        let cases: [(Int, SeasonalPeriod)] = [(1, .winter), (4, .spring), (7, .summer), (10, .autumn)]
        for (month, expected) in cases {
            // Month \(month) should be \(expected)
            #expect(normaliser.deriveSeason(from: makeDate(month: month), latitude: 40.0) == expected)
        }
    }

    // DayPeriod derivation — EnvironmentalFactor.dayPeriod depends on this

    @Test("All day-period bands map correctly")
    func dayPeriod_allBands() {
        let cases: [(Int, DayPeriod)] = [
            (5, .dawn), (9, .morning), (14, .afternoon), (19, .evening), (23, .night), (2, .night),
        ]
        for (hour, expected) in cases {
            // Hour \(hour) should map to \(expected)
            #expect(normaliser.deriveDayPeriod(from: makeDate(hour: hour)) == expected)
        }
    }

    // Condition mapping — determineDominantCondition depends on this

    @Test("Every engine condition category stays reachable")
    func conditionMapping_allCategories_areReachable() {
        let allExpected: Set<WeatherConditionCategory> = [
            .clear, .partlyCloudy, .cloudy, .fog, .rain,
            .heavyRain, .snow, .heavySnow, .storm, .wind, .mixed, .unknown,
        ]
        let sampleConditions: [WeatherCondition] = [
            .clear, .partlyCloudy, .cloudy, .foggy, .rain,
            .heavyRain, .snow, .blizzard, .thunderstorms, .windy, .wintryMix,
        ]
        let mapped = Set(sampleConditions.map { normaliser.mapCondition($0) })
        #expect(mapped.isSubset(of: allExpected))
    }

    // Helpers

    private func makeDate(month: Int = 6, hour: Int = 12) -> Date {
        var c = DateComponents()
        c.year = 2025; c.month = month; c.day = 15; c.hour = hour
        // AUDIT §5.1 note: fixed components in a fixed proleptic Gregorian context;
        // construction failure here would be a test-authoring bug, not user input.
        return Calendar(identifier: .gregorian).date(from: c)!
    }
}

// MARK: - WeatherSnapshotStoreTests
//
// Integration tests against a real (temporary) SQLite database.
// No network calls; validates that WeatherSnapshot survives a round-trip
// through the persistence layer with all 16 engine-consumed fields intact.

@Suite("WeatherSnapshotStore")
final class WeatherSnapshotStoreTests {

    var store: WeatherSnapshotStore
    var tempDir: URL

    /// Replaces XCTest setUp(): swift-testing builds a fresh instance per test.
    init() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = WeatherSnapshotStore(directory: tempDir)
    }

    /// Replaces XCTest tearDown().
    deinit {
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test("Round-trip save/fetch preserves all engine-consumed fields")
    func saveAndFetch_roundTrip_preservesAllFields() throws {
        let original = makeSnapshot()
        let sessionID = UUID()
        try store.save(original, sessionID: sessionID)

        let fetched = try #require(try store.fetch(sessionID: sessionID))

        #expect(fetched.temperatureCelsius == original.temperatureCelsius)
        #expect(fetched.feelsLikeTemperatureCelsius == original.feelsLikeTemperatureCelsius)
        #expect(fetched.humidity == original.humidity)
        #expect(fetched.pressure == original.pressure)
        #expect(fetched.cloudCover == original.cloudCover)
        #expect(fetched.visibilityKilometers == original.visibilityKilometers)
        #expect(fetched.windSpeedKPH == original.windSpeedKPH)
        #expect(fetched.precipitationMillimeters == original.precipitationMillimeters)
        #expect(fetched.snowfallMillimeters == original.snowfallMillimeters)
        #expect(fetched.stormActivityIndex == original.stormActivityIndex)
        #expect(fetched.condition == original.condition)
        #expect(fetched.season == original.season)
        #expect(fetched.month == original.month)
        #expect(fetched.weekday == original.weekday)
        #expect(fetched.dayPeriod == original.dayPeriod)
    }

    @Test("Range query returns exactly the sessions in window")
    func fetchRange_returnsCorrectWindow() throws {
        let base = Date(timeIntervalSinceReferenceDate: 0)
        for i in 0 ..< 10 {
            let snap = makeSnapshot(timestamp: base.addingTimeInterval(Double(i) * 3600))
            try store.save(snap, sessionID: UUID())
        }
        let results = try store.fetchRange(
            from: base.addingTimeInterval(3600 * 2),
            to: base.addingTimeInterval(3600 * 5)
        )
        // Range query must return exactly the sessions in window
        #expect(results.count == 4)
    }

    @Test("coverageRatio reports partial coverage accurately")
    func coverageRatio_partialCoverage() throws {
        let covered = (0 ..< 7).map { _ in UUID() }
        let uncovered = (0 ..< 3).map { _ in UUID() }
        for id in covered {
            try store.save(makeSnapshot(), sessionID: id)
        }

        let ratio = try store.coverageRatio(for: covered + uncovered)
        // coverageRatio feeds ConfidenceReport.dataCoverageScore; must be accurate
        #expect(abs(ratio - 0.7) <= 0.01)
    }

    @Test("Save is idempotent — INSERT OR REPLACE updates, never duplicates")
    func save_idempotent_replacesExisting() throws {
        let sessionID = UUID()
        try store.save(makeSnapshot(temperature: 20), sessionID: sessionID)
        try store.save(makeSnapshot(temperature: 25), sessionID: sessionID)

        let fetched = try #require(try store.fetch(sessionID: sessionID))
        // INSERT OR REPLACE must update, not duplicate, on retry
        #expect(fetched.temperatureCelsius == 25)
    }

    // Helpers

    private func makeSnapshot(timestamp: Date = Date(), temperature: Double = 18.0) -> WeatherSnapshot {
        WeatherSnapshot(
            timestamp: timestamp,
            temperatureCelsius: temperature,
            feelsLikeTemperatureCelsius: temperature - 2,
            humidity: 0.65,
            pressure: 1013.0,
            cloudCover: 0.4,
            visibilityKilometers: 15.0,
            windSpeedKPH: 12.0,
            precipitationMillimeters: 0.0,
            snowfallMillimeters: 0.0,
            stormActivityIndex: 0.05,
            condition: .clear,
            season: .summer,
            month: 7,
            weekday: 3,
            dayPeriod: .afternoon
        )
    }
}

/// Coverage-ratio convenience shim for tests (calls through to the store).
/// Moved here together with its only callers — production code uses
/// `WeatherKitService.coverageRatio(for:)`, which reads `countPresent` directly.
extension WeatherSnapshotStore {
    func coverageRatio(for sessionIDs: [UUID]) throws -> Double {
        let covered = try countPresent(sessionIDs: sessionIDs)
        guard !sessionIDs.isEmpty else { return 0 }
        return Double(covered) / Double(sessionIDs.count)
    }
}

// MARK: - WeatherAnalysisEngineIntegrationTests
//
// Validates the full pipeline from WeatherKitService output through to engine correlations.
// Uses synthetic EnvironmentalSessionRecord arrays — no WeatherKit network calls.

@Suite("WeatherAnalysisEngine Integration")
struct WeatherAnalysisEngineIntegrationTests {

    let engine = WeatherAnalysisEngine()

    @Test("20 correlated sessions produce at least one strong temperature correlation")
    func fullCorrelationPipeline_withMinimumSessions_returnsResults() {
        // Break up complex expression to help the type-checker
        var sessions: [WeatherAnalysisEngine.EnvironmentalSessionRecord] = []
        sessions.reserveCapacity(20)
        for i in 0 ..< 20 {
            let temp = Double(10 + i)
            let speed = Double(200 + i * 5)
            let s = makeSession(temperature: temp, readingSpeed: speed)
            sessions.append(s)
        }
        let correlations = engine.analyzeCorrelations(from: sessions)

        // 20 sessions with correlated temperature/speed must produce at least one correlation
        #expect(!correlations.isEmpty)

        let tempCorrelation = correlations.first { $0.factor == .temperature }
        #expect(tempCorrelation != nil)
        #expect((tempCorrelation?.coefficient ?? 0) > 0.8)
    }

    @Test("Zero storm index yields no signal; non-zero yields correlation")
    func stormCorrelation_requiresNonZeroStormIndex() {
        let sessionsNoStorm = (0 ..< 20).map { _ in makeSession(stormIndex: 0.0) }
        let sessionsWithStorm = (0 ..< 20).enumerated().map { i, _ in makeSession(stormIndex: Double(i) / 20.0) }

        let noCorr = engine.analyzeCorrelations(from: sessionsNoStorm).filter { $0.factor == .stormActivity }
        let withCorr = engine.analyzeCorrelations(from: sessionsWithStorm).filter { $0.factor == .stormActivity }

        // Zero storm index must produce no storm signal — validates stormActivityIndex computation
        #expect(noCorr.isEmpty || (noCorr.first?.coefficient ?? 1) == 0)
        // Non-zero storm index must produce storm correlation
        #expect(!withCorr.isEmpty)
    }

    @Test("Seasonal profiles require all four seasons")
    func seasonalProfiles_requireAllFourSeasons() {
        let sessions = SeasonalPeriod.allCases.flatMap { season in
            (0 ..< 10).map { _ in makeSession(season: season) }
        }
        let profile = engine.buildEnvironmentalProfile(from: sessions)
        let profiledSeasons = Set(profile.seasonalProfiles.map(\.season))

        // All four seasons must appear — requires deriveSeason() to be correct for all months
        #expect(profiledSeasons == Set(SeasonalPeriod.allCases))
    }

    // Helpers

    private func makeSession(
        temperature: Double = 18.0,
        stormIndex: Double = 0.1,
        season: SeasonalPeriod = .summer,
        readingSpeed: Double = 250.0
    ) -> WeatherAnalysisEngine.EnvironmentalSessionRecord {
        WeatherAnalysisEngine.EnvironmentalSessionRecord(
            sessionID: UUID(),
            bookID: UUID(),
            timestamp: Date(),
            weather: makeWeatherSnapshot(temperature: temperature, stormIndex: stormIndex, season: season),
            readingDurationMinutes: 45,
            pagesRead: 30,
            chaptersCompleted: 1,
            booksCompleted: 0,
            readingSpeed: readingSpeed,
            consistencyScore: 0.8,
            readingFrequencyScore: 0.7,
            engagementScore: 0.75,
            sessionQualityScore: 0.8,
            momentumScore: 0.7,
            completionProbability: 0.6,
            abandonmentProbability: 0.2,
            difficultyScore: 0.5,
            complexityScore: 0.5,
            bookLength: 350,
            genre: "Fiction",
            seriesIdentifier: nil,
            reread: false
        )
    }

    private func makeWeatherSnapshot(
        temperature: Double = 18.0,
        stormIndex: Double = 0.1,
        season: SeasonalPeriod = .summer
    ) -> WeatherSnapshot {
        WeatherSnapshot(
            timestamp: Date(),
            temperatureCelsius: temperature,
            feelsLikeTemperatureCelsius: temperature - 2,
            humidity: 0.6,
            pressure: 1013.0,
            cloudCover: 0.3,
            visibilityKilometers: 20.0,
            windSpeedKPH: 10.0,
            precipitationMillimeters: 0,
            snowfallMillimeters: 0,
            stormActivityIndex: stormIndex,
            condition: .clear,
            season: season,
            month: 7,
            weekday: 2,
            dayPeriod: .afternoon
        )
    }
}
