//  SeasonalEnvironmentTests.swift
//  AsterismaV2.5Tests
//
//  Pins the 2026-11-08 live-background pass:
//    • continuous, normalized seasonal weights and hemisphere inversion,
//    • the solar day at the equator and at mid-latitude,
//    • the sunrise/noon/sunset mapping onto the existing palette track,
//    • the fixed-track fallback when no coordinate is available,
//    • the Debug season override,
//    • honest weather provenance (live / recent / stale / unavailable / forced).

import Foundation
import Testing
@testable import AsterismaV2_5

@Suite("Environment — season, solar day, and weather provenance")
@MainActor
struct SeasonalEnvironmentTests {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 12,
        _ minute: Int = 0
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day,
            hour: hour, minute: minute))!
    }

    private func engine(
        at reference: Date,
        coordinate: SolarCoordinate? = nil,
        weather: WeatherEnvironmentModifier = .neutral,
        store: EnvironmentOverrideStore? = nil
    ) -> EnvironmentEngine {
        EnvironmentEngine(
            calendar: calendar,
            now: { reference },
            overrideStore: store ?? .standard,
            weatherProvider: { _ in weather },
            weatherCacheInterval: 0,
            coordinateProvider: { coordinate })
    }

    // MARK: - Season

    @Test("seasonal weights peak at the astronomical seasons and invert south of the equator")
    func seasonalWeightsPeakAtTheRightTime() {
        let june = date(2026, 6, 21)
        let december = date(2026, 12, 21)

        let northernJune = SeasonalCalendar.grade(
            for: june, calendar: calendar, latitude: 51.5)
        #expect(northernJune.dominantSeason == .summer)
        #expect((northernJune.weights[.summer] ?? 0) > 0.9)

        let northernDecember = SeasonalCalendar.grade(
            for: december, calendar: calendar, latitude: 51.5)
        #expect(northernDecember.dominantSeason == .winter)
        #expect((northernDecember.weights[.winter] ?? 0) > 0.9)

        let southernJune = SeasonalCalendar.grade(
            for: june, calendar: calendar, latitude: -33.9)
        #expect(southernJune.dominantSeason == .winter)
        #expect((southernJune.weights[.winter] ?? 0) > 0.9)
    }

    @Test("seasonal weights are non-negative and normalized every day of the year")
    func seasonalWeightsAreNormalized() {
        for month in 1...12 {
            let grade = SeasonalCalendar.grade(
                for: date(2026, month, 15),
                calendar: calendar,
                latitude: 51.5)
            let total = grade.weights.values.reduce(0.0, +)
            #expect(abs(total - 1.0) < 0.0001,
                    "month \(month) weights summed to \(total)")
            #expect(grade.weights.values.allSatisfy { $0 >= 0.0 })
        }
    }

    @Test("a forced season is exclusive and bypasses the calendar")
    func forcedSeasonIsExclusive() {
        let grade = SeasonalCalendar.grade(
            for: date(2026, 3, 20),
            calendar: calendar,
            latitude: 51.5,
            forced: .autumn)
        #expect(grade.weights == [.autumn: 1.0])
        #expect(grade.dominantSeason == .autumn)
    }

    // MARK: - Solar day

    @Test("the equator's equinox day is about twelve hours")
    func equinoxAtTheEquatorIsAboutTwelveHours() {
        let solar = SolarDaylight.calculate(
            for: date(2026, 3, 20),
            calendar: calendar,
            coordinate: SolarCoordinate(latitude: 0.0, longitude: 0.0))

        #expect(solar.hasLocation)
        #expect(abs(solar.daylightDurationMinutes - 720.0) < 30.0)
        #expect(abs(solar.sunriseMinute - 360.0) < 30.0)
        #expect(abs(solar.sunsetMinute - 1080.0) < 30.0)
    }

    @Test("a mid-latitude summer day is materially longer than its winter day")
    func summerDayIsLongerThanWinter() {
        let coordinate = SolarCoordinate(latitude: 51.5, longitude: -0.1)
        let summer = SolarDaylight.calculate(
            for: date(2026, 6, 21), calendar: calendar, coordinate: coordinate)
        let winter = SolarDaylight.calculate(
            for: date(2026, 12, 21), calendar: calendar, coordinate: coordinate)

        #expect(summer.hasLocation && winter.hasLocation)
        #expect(summer.daylightDurationMinutes > winter.daylightDurationMinutes + 240.0)
        #expect(summer.sunriseMinute < winter.sunriseMinute)
        #expect(summer.sunsetMinute > winter.sunsetMinute)
    }

    @Test("the palette maps real sunrise to 06:00 and real sunset to 19:45")
    func paletteMinuteMapsSunriseAndSunset() {
        let solar = SolarDaylight.calculate(
            for: date(2026, 6, 21),
            calendar: calendar,
            coordinate: SolarCoordinate(latitude: 51.5, longitude: -0.1))

        #expect(abs(solar.paletteMinute(for: solar.sunriseMinute) - 360.0) < 1.0)
        #expect(abs(solar.paletteMinute(for: solar.sunsetMinute) - 1185.0) < 1.0)
    }

    // MARK: - Engine integration

    @Test("the fixed track leaves the wall clock untouched when no coordinate is cached")
    func fixedTrackKeepsTheWallClock() {
        let noon = date(2026, 6, 15, 12, 0)
        let engine = engine(at: noon)

        #expect(!engine.state.solarDaylight.hasLocation)
        #expect(abs(engine.state.minuteOfDay - 720.0) < 0.01)
        #expect(abs(engine.state.clockMinuteOfDay - 720.0) < 0.01)
        #expect(engine.state.season == .summer)
    }

    @Test("a cached coordinate shifts the palette onto the real solar day")
    func coordinateShiftsThePalette() {
        let morning = date(2026, 1, 15, 10, 0)
        let engine = engine(
            at: morning,
            coordinate: SolarCoordinate(latitude: 51.5, longitude: -0.1))

        #expect(engine.state.solarDaylight.hasLocation)
        #expect(engine.state.minuteOfDay < engine.state.clockMinuteOfDay,
                "winter 10:00 should sit earlier on the solar palette than on the wall clock")
    }

    @Test("a forced season reaches EnvironmentState")
    func forcedSeasonReachesTheState() {
        let suite = "environment-season-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = EnvironmentOverrideStore(defaults: defaults)
        store.setSeasonOverride(.summer)

        let engine = engine(at: date(2026, 1, 15, 12, 0), store: store)
        #expect(engine.state.season == .summer)
        #expect(engine.state.seasonalWeights == [.summer: 1.0])
    }

    // MARK: - Seasonal maturity

    @Test("season maturity distinguishes early, prime, and late winter")
    func seasonMaturityDistinguishesWinterPhases() {
        let early = SeasonalCalendar.grade(
            for: date(2026, 11, 15), calendar: calendar, latitude: 51.5)
        let prime = SeasonalCalendar.grade(
            for: date(2026, 12, 15), calendar: calendar, latitude: 51.5)
        let late = SeasonalCalendar.grade(
            for: date(2027, 1, 15), calendar: calendar, latitude: 51.5)

        #expect(early.dominantSeason == .winter)
        #expect(early.phase == .early)
        #expect(prime.dominantSeason == .winter)
        #expect(prime.phase == .prime)
        #expect(late.dominantSeason == .winter)
        #expect(late.phase == .late)

        #expect(early.maturity < prime.maturity)
        #expect(late.maturity < prime.maturity)
        #expect(early.effectScale < prime.effectScale)
        #expect(late.effectScale < prime.effectScale)

        // The effect air follows the phase, not just the calendar label.
        #expect(early.particleIntensity < prime.particleIntensity)
        #expect(late.particleIntensity < prime.particleIntensity)
    }

    @Test("a forced phase scales the season without changing its identity")
    func forcedPhaseScalesTheSeason() {
        let early = SeasonalCalendar.grade(
            for: date(2026, 7, 1), calendar: calendar, latitude: 51.5,
            forced: .winter, forcedPhase: .early)
        let prime = SeasonalCalendar.grade(
            for: date(2026, 7, 1), calendar: calendar, latitude: 51.5,
            forced: .winter, forcedPhase: .prime)
        let late = SeasonalCalendar.grade(
            for: date(2026, 7, 1), calendar: calendar, latitude: 51.5,
            forced: .winter, forcedPhase: .late)

        #expect(early.weights == [.winter: 1.0])
        #expect(early.phase == .early)
        #expect(prime.phase == .prime)
        #expect(late.phase == .late)
        #expect(early.maturity < prime.maturity)
        #expect(late.maturity < prime.maturity)
        #expect(early.particleIntensity < prime.particleIntensity)
        #expect(late.particleIntensity < prime.particleIntensity)
    }

    @Test("EnvironmentState carries the seasonal phase and maturity")
    func stateCarriesSeasonPhase() {
        let engine = engine(at: date(2026, 12, 15))
        #expect(engine.state.season == .winter)
        #expect(engine.state.seasonalPhase == .prime)
        // Mid-December is inside the prime window, six days before the peak:
        // 1 - 6/48, not a perfect 1.0.
        #expect(engine.state.seasonalMaturity > 0.85)
    }

    @Test("a forced precipitation visual starts at the envelope floor and scrubs upward")
    func forcedPrecipitationEnvelopeReachesState() {
        let suite = "environment-envelope-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = EnvironmentOverrideStore(defaults: defaults)
        store.setWeatherOverride(.rain, intensity: 0.8)

        let engine = engine(at: date(2026, 12, 15), store: store)
        #expect(abs(engine.state.weatherVisual.intensity - 0.44) < 0.02)

        engine.previewWeatherEventAgeOverride = 15 * 60
        engine.refreshNow()
        #expect(engine.state.weatherVisual.kind == .rain)
        #expect(engine.state.weatherVisual.intensity > 0.5)
    }

    // MARK: - Weather provenance

    @Test("weather provenance distinguishes live, recent, stale, missing, and forced")
    func weatherProvenanceIsHonest() {
        let now = date(2026, 10, 29, 12, 0)

        let live = engine(
            at: now,
            weather: WeatherEnvironmentModifier(
                cloudCoverFraction: 0.4,
                condition: .cloudy,
                capturedAt: now.addingTimeInterval(-10 * 60)))
        #expect(live.state.weatherFreshness == .live)

        let recent = engine(
            at: now,
            weather: WeatherEnvironmentModifier(
                cloudCoverFraction: 0.4,
                condition: .cloudy,
                capturedAt: now.addingTimeInterval(-45 * 60)))
        #expect(recent.state.weatherFreshness == .recent)

        let stale = engine(
            at: now,
            weather: WeatherEnvironmentModifier(
                cloudCoverFraction: 0.4,
                condition: .cloudy,
                capturedAt: now.addingTimeInterval(-3 * 60 * 60)))
        #expect(stale.state.weatherFreshness == .stale)

        let missing = engine(at: now)
        #expect(missing.state.weatherFreshness == .unavailable)

        let suite = "environment-weather-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = EnvironmentOverrideStore(defaults: defaults)
        store.setWeatherOverride(.rain, intensity: 0.6)
        let forced = engine(at: now, store: store)
        #expect(forced.state.weatherFreshness == .forced)
        #expect(forced.state.weatherVisual.kind == .rain)
    }
}
