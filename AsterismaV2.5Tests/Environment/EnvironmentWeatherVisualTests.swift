//  EnvironmentWeatherVisualTests.swift
//  AsterismaV2.5Tests
//
//  Pins the 2026-10-29 environment overhaul:
//    • snapshot → visual kind mapping (rain/snow/fog/storm/clear/cloudy),
//    • the persisted studio override store,
//    • forced time/weather reaching EnvironmentState,
//    • the readability scrim rising with palette luminance (the owner's
//      "morning and afternoon are far too bright" finding).

import Foundation
import Testing
@testable import AsterismaV2_5

@Suite("Environment — live weather + readability")
@MainActor
struct EnvironmentWeatherVisualTests {

    private func engine(
        minute: Int? = nil,
        kind: WeatherVisualKind? = nil,
        now: Date
    ) -> EnvironmentEngine {
        let suite = "environment-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = EnvironmentOverrideStore(defaults: defaults)
        if let minute { store.setMinuteOverride(minute) }
        if let kind { store.setWeatherOverride(kind, intensity: 0.8) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return EnvironmentEngine(
            calendar: calendar,
            now: { now },
            overrideStore: store,
            weatherProvider: { _ in .neutral },
            weatherCacheInterval: 0)
    }

    private func utcNoon() -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(
            year: 2026, month: 10, day: 29, hour: 12, minute: 0))!
    }

    @Test func precipitationConditionsProduceDrawableVisuals() {
        let storm = WeatherVisual.from(
            condition: .storm, cloudCover: 0.9, precipitationMM: 4,
            snowfallMM: 0, windKPH: 55, visibilityKM: 4, stormIndex: 0.8)
        #expect(storm.kind == .storm)
        #expect(storm.intensity >= 0.55)
        #expect(storm.isLive)

        let snow = WeatherVisual.from(
            condition: .snow, cloudCover: 0.8, precipitationMM: 0,
            snowfallMM: 3, windKPH: 10, visibilityKM: 6, stormIndex: 0)
        #expect(snow.kind == .snow)
        #expect(snow.intensity > 0.25)

        let fog = WeatherVisual.from(
            condition: .fog, cloudCover: 0.6, precipitationMM: 0,
            snowfallMM: 0, windKPH: 2, visibilityKM: 1, stormIndex: 0)
        #expect(fog.kind == .fog)
        #expect(fog.intensity >= 0.35)

        let clear = WeatherVisual.from(
            condition: .clear, cloudCover: 0.05, precipitationMM: 0,
            snowfallMM: 0, windKPH: 4, visibilityKM: 20, stormIndex: 0)
        #expect(clear.kind == .clear)
        #expect(clear.intensity == 0)

        // A "clear" label with near-total cloud cover is still drawn cloudy;
        // the label alone must not erase what the numbers say.
        let labelledClearButOvercast = WeatherVisual.from(
            condition: .clear, cloudCover: 0.92, precipitationMM: 0,
            snowfallMM: 0, windKPH: 4, visibilityKM: 20, stormIndex: 0)
        #expect(labelledClearButOvercast.kind == .cloudy)
    }

    @Test func overrideStoreRoundTripsAndClears() {
        let suite = "environment-override-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = EnvironmentOverrideStore(defaults: defaults)

        #expect(store.minuteOverride == nil)
        #expect(store.weatherOverride == nil)
        #expect(!store.hasOverrides)

        store.setMinuteOverride(725)
        store.setWeatherOverride(.snow, intensity: 0.5)
        #expect(store.minuteOverride == 725)
        #expect(store.weatherOverride?.kind == .snow)
        #expect(store.weatherOverride?.isLive == false)
        #expect(store.hasOverrides)

        let date = utcNoon()
        #expect(store.effectiveMinute(now: date, calendar: .current) == 725)

        store.clearAll()
        #expect(!store.hasOverrides)
        #expect(store.effectiveMinute(now: date, calendar: .current)
                == AnchorClock.fractionalMinutesSinceMidnight(for: date, calendar: .current))
    }

    @Test func forcedTimeAndWeatherReachTheState() {
        let forcedMorning = engine(minute: 480, kind: .rain, now: utcNoon())

        #expect(forcedMorning.state.minuteOfDay == 480)
        let blend = forcedMorning.state.currentAnchorBlend
        #expect((blend[.morning] ?? 0) > 0.99, "08:00 must resolve to the morning anchor")

        #expect(forcedMorning.state.weatherVisual.kind == .rain)
        #expect(forcedMorning.state.weatherVisual.isLive == false)
    }

    @Test func brightPalettesCarryMoreScrimThanNight() {
        let night = engine(minute: 60, now: utcNoon()).state
        let morning = engine(minute: 480, now: utcNoon()).state
        let afternoon = engine(minute: 1020, now: utcNoon()).state

        #expect(night.readabilityScrim >= 0.03)
        #expect(night.readabilityScrim <= 0.06,
                "the night scene must stay dark without a heavy veil")
        #expect(morning.readabilityScrim > 0.15,
                "the bright morning palette needs a real readability veil")
        #expect(afternoon.readabilityScrim > night.readabilityScrim)
        #expect(morning.gradientLuminance > night.gradientLuminance)
    }

    @Test func weatherOverrideDoesNotChangeThePinnedModifier() {
        let forced = engine(minute: 600, kind: .storm, now: utcNoon())
        // The environment state can force a VISUAL, but the modifier still
        // reports the truth of what was captured (nothing, in this harness).
        #expect(forced.state.weatherModifier == .neutral)
        #expect(forced.state.weatherVisual.kind == .storm)
    }
}
