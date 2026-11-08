//  EnvironmentAuthorityInterpolationTests.swift
//  AsterismaV2.5Tests
//
//  Pins the 2026-11-08 continuous-environment pass:
//    • definitive Time → Weather → Season authority,
//    • minute interpolation across midnight,
//    • normalized season weights and state endpoint behavior,
//    • honest WeatherKit provider scaffolding (no fabricated snapshots).

import CoreLocation
import Foundation
import Testing
@testable import AsterismaV2_5

@Suite("Environment — authority, interpolation, and provider scaffold")
@MainActor
struct EnvironmentAuthorityInterpolationTests {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test("authority is ordered Time, then Weather, then Season")
    func authorityOrder() {
        #expect(EnvironmentAuthority.allCases == [.time, .weather, .season])
        #expect(EnvironmentAuthority.time.rawValue < EnvironmentAuthority.weather.rawValue)
        #expect(EnvironmentAuthority.weather.rawValue < EnvironmentAuthority.season.rawValue)
        #expect(EnvironmentAuthorityResolver.weatherInfluenceCeiling == 0.18)
        #expect(EnvironmentAuthorityResolver.seasonInfluenceCeiling == 0.14)
    }

    @Test("minute interpolation takes the short path across midnight")
    func minuteInterpolationCrossesMidnight() {
        let halfway = EnvironmentPresentation.interpolateMinute(
            1439, 1, fraction: 0.5)
        #expect(abs(halfway - 0.0) < 0.001 || abs(halfway - 1440.0) < 0.001)

        let quarter = EnvironmentPresentation.interpolateMinute(
            100, 200, fraction: 0.25)
        #expect(abs(quarter - 125) < 0.001)

        #expect(EnvironmentPresentation.interpolateMinute(10, 20, fraction: 0) == 10)
        #expect(EnvironmentPresentation.interpolateMinute(10, 20, fraction: 1) == 20)
    }

    @Test("state interpolation blends colors, opacities, weights, and minutes")
    func stateInterpolationIsContinuous() {
        var from = EnvironmentState.fallback
        from.minuteOfDay = 710
        from.starVisibility = 0.2
        from.seasonalWeights = [.autumn: 1.0]
        from.season = .autumn

        var to = from
        to.minuteOfDay = 730
        to.starVisibility = 0.8
        to.seasonalWeights = [.winter: 1.0]
        to.season = .winter

        let halfway = EnvironmentPresentation.interpolate(
            from: from, to: to, progress: 0.5)

        #expect(abs(halfway.minuteOfDay - 720) < 0.001)
        #expect(abs(halfway.starVisibility - 0.5) < 0.0001)
        #expect(abs((halfway.seasonalWeights[.autumn] ?? 0) - 0.5) < 0.0001)
        #expect(abs((halfway.seasonalWeights[.winter] ?? 0) - 0.5) < 0.0001)
        #expect(abs(halfway.seasonalWeights.values.reduce(0, +) - 1.0) < 0.0001)
        #expect(halfway.weatherVisual.kind == from.weatherVisual.kind,
                "weather kinds cross-fade in the renderer, not through this scalar state")
    }

    @Test("weather and season compose in authority order and season cannot erase cloud cover")
    func weatherDominatesSeasonForStars() {
        let time = EnvironmentPalette.night
        let weather = WeatherEnvironmentModifier(
            cloudCoverFraction: 1.0,
            condition: .storm,
            precipitationMillimeters: 6,
            windSpeedKPH: 60,
            stormActivityIndex: 0.8,
            capturedAt: Date(timeIntervalSince1970: 0))
        let winter = SeasonalCalendar.grade(
            for: calendar.date(from: DateComponents(
                year: 2026, month: 12, day: 21))!,
            calendar: calendar,
            latitude: 51.5,
            forced: .winter)

        let resolved = EnvironmentAuthorityResolver.resolve(
            time: time, weather: weather, season: winter)
        let weatherOnly = weather.apply(to: time)

        #expect(resolved.starVisibility < time.starVisibility,
                "cloud cover must reduce the night stars")
        #expect(resolved.starVisibility > weatherOnly.starVisibility,
                "winter may make a bounded seasonal star contribution")
        #expect(resolved.starVisibility - weatherOnly.starVisibility <= 0.08,
                "season's star lift is tertiary and cannot outweigh the weather reduction")
        #expect(resolved.starVisibility < time.starVisibility,
                "the overcast weather reduction is still visible after the seasonal lift")
        #expect(resolved.starVisibility <= 1.0)
        #expect(resolved.atmosphericOpacity > time.atmosphericOpacity)
    }

    @Test("winter season lift cannot create stars in a daylight palette")
    func seasonCannotInventDaylightStars() {
        let winter = SeasonalCalendar.grade(
            for: calendar.date(from: DateComponents(
                year: 2026, month: 12, day: 21))!,
            calendar: calendar,
            latitude: 51.5,
            forced: .winter)
        let resolved = winter.apply(to: EnvironmentPalette.midday)

        #expect(EnvironmentPalette.midday.starVisibility == 0)
        #expect(resolved.starVisibility == 0)
    }

    @Test("weather provider scaffolding is honest")
    func weatherKitScaffoldDoesNotInventData() async {
        #expect(WeatherProviderKind.openMeteo.isConfigured)
        #expect(!WeatherProviderKind.weatherKit.isConfigured)
        #expect(WeatherProviderFactory.make(kind: .openMeteo) is OpenMeteoProvider)

        let provider = WeatherProviderFactory.make(kind: .weatherKit)
        let location = CLLocation(latitude: 51.5, longitude: -0.1)

        do {
            _ = try await provider.snapshot(at: Date(), location: location)
            Issue.record("WeatherKit scaffold returned fabricated weather data")
        } catch let error as WeatherProviderError {
            #expect(error == .notConfigured(.weatherKit))
        } catch {
            Issue.record("Unexpected WeatherKit scaffold error: \(error)")
        }
    }

    @Test("engine retains the previous target and starts a transition")
    func enginePublishesTransitionPair() {
        let noon = calendar.date(from: DateComponents(
            year: 2026, month: 6, day: 15, hour: 12))!
        let engine = EnvironmentEngine(
            calendar: calendar,
            now: { noon },
            weatherProvider: { _ in .neutral },
            weatherCacheInterval: 0,
            transitionDuration: 6)

        #expect(engine.previousState == engine.state)
        #expect(engine.transitionStartedAt <= noon)
        #expect(engine.transitionDuration == 6)
        #expect(engine.activeTransitionDuration == 6)
    }

    @Test("a Studio override can refresh with the short fade without changing the natural default")
    func studioOverrideUsesShortTransition() {
        let suite = "environment-engine-transition-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = EnvironmentOverrideStore(defaults: defaults)
        let noon = calendar.date(from: DateComponents(
            year: 2026, month: 6, day: 15, hour: 12))!
        let engine = EnvironmentEngine(
            calendar: calendar,
            now: { noon },
            overrideStore: store,
            weatherProvider: { _ in .neutral },
            weatherCacheInterval: 0,
            transitionDuration: 6)

        store.setMinuteOverride(60)
        #expect(abs(engine.state.minuteOfDay - 720) < 0.001,
                "the engine should still be on its previous target before the refresh")

        engine.refreshNow(transitionDuration: EnvironmentPresentation.studioOverrideTransitionDuration)
        #expect(abs(engine.state.minuteOfDay - 60) < 0.001)
        #expect(engine.activeTransitionDuration == EnvironmentPresentation.studioOverrideTransitionDuration)
        #expect(engine.transitionDuration == 6, "the natural production fade must remain unchanged")

        engine.refreshNow()
        #expect(engine.activeTransitionDuration == 6)
    }

    @Test("The short Studio fade leads the ambient curve")
    func studioFadeIsSharperThanAmbient() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let studio = EnvironmentPresentation.progress(
            startedAt: start,
            now: start.addingTimeInterval(0.625),
            duration: EnvironmentPresentation.studioOverrideTransitionDuration)
        let ambient = EnvironmentPresentation.progress(
            startedAt: start,
            now: start.addingTimeInterval(2.5),
            duration: EnvironmentPresentation.transitionDuration)

        #expect(studio > 0.5)
        #expect(studio > ambient)
    }
}
