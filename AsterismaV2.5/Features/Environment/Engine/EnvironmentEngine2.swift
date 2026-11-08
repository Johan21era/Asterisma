//  EnvironmentEngine2.swift
//  Environment Engine — Phase B (Parts 5.1, 5.3 of the build spec)
//
//  Computes and periodically republishes EnvironmentState.
//
//  Architecture note: Phase A confirmed every long-lived state object in
//  this codebase (DataStore, SessionCoordinator, GoalProgressViewModel,
//  SessionEventRouter, BehaviorContextAccessKit, BehaviorContextEngine in
//  AsterismaApp.swift, and WeatherKitService itself) uses the classic
//  `ObservableObject` + `@Published` + `@MainActor` pattern, not the newer
//  `@Observable` macro. EnvironmentEngine follows that same convention
//  deliberately, for consistency with the rest of the app — this also
//  matches Part 5.1's own parenthetical ("EnvironmentEngine as an
//  ObservableObject that publishes it").
//
//  Per Part 5.1/5.3: no view anywhere in this feature reads Date() or
//  accessibility settings directly (AnchorClock.swift's comment documents
//  the one exception: this file's own `now` closure), and interpolation is
//  keyframe-based, recomputed on a 10 s cadence. The background samples this
//  engine's previous/current targets on one 60 Hz TimelineView and interpolates
//  every visual property between them; stars, atmosphere, weather, and seasonal
//  particles share that clock rather than owning independent ones. The 10 s tick
//  replaced the original 45 s one on 2026-10-29.
//
//  2026-11-08 — live background pass:
//    • SolarDaylight maps the real sunrise/noon/sunset for the cached
//      coordinate onto the existing palette track. No coordinate means the
//      original fixed track, unchanged.
//    • SeasonalCalendar adds continuous spring/summer/autumn/winter weights
//      and a small tint, so the year changes the scene without replacing the
//      hour-of-day identity.
//    • An optional live ambient-weather loop reads current conditions from
//      WeatherKitService without writing a session row. It is off by default
//      for tests and explicitly enabled by the app shell and Environment
//      Studio.
//
//  The shared-consumer refcount is unchanged: start()/stop() are balanced per
//  consumer and the recompute loop lives while at least one reader remains.

import Combine
import AppKit
import SwiftUI

@MainActor
final class EnvironmentEngine: ObservableObject {

    @Published private(set) var state: EnvironmentState = .fallback

    /// The last published target. The background interpolates from this value
    /// to `state` across `transitionDuration`, so a 10 s recompute never lands
    /// as a visible jump. Kept in the engine (not the view) so every consumer
    /// sees the same transition and tests can assert it.
    @Published private(set) var previousState: EnvironmentState = .fallback

    /// When the current previous → state transition began. The rendering
    /// clock derives its eased progress from this instant.
    @Published private(set) var transitionStartedAt: Date = .distantPast

    /// Duration of the continuous presentation transition. Injectable for
    /// tests and the Studio; defaults to the production cross-fade.
    let transitionDuration: TimeInterval

    /// Duration of the transition currently on screen. Natural recomputes use
    /// `transitionDuration`; a manual Studio refresh can use the shorter Studio
    /// span. The renderer must keep using the value that started this fade.
    private(set) var activeTransitionDuration: TimeInterval

    #if DEBUG
    /// Studio-only geographic override. A manual coordinate recalibrates the
    /// solar day and the seasonal grade without moving the machine, so a
    /// latitude/longitude can be inspected before travelling to it.
    var previewCoordinateOverride: SolarCoordinate?

    /// Studio-only timezone override paired with the manual coordinate. The
    /// solar model needs the coordinate's own clock; using the machine's legal
    /// timezone would put a Tokyo sunrise at a San Francisco hour.
    var previewTimeZoneOverride: TimeZone?

    /// The coordinate the last recompute actually used, live or manual. Nil
    /// means the fixed equinox track is on screen.
    @Published private(set) var resolvedCoordinate: SolarCoordinate?

    /// Studio readout only: the recompute cadence in whole seconds.
    var recomputeIntervalSecondsForStudio: Int {
        Int(recomputeInterval.components.seconds)
    }

    /// Studio-only accessibility preview. Nil follows macOS, so the live app
    /// never diverges; a value lets the Studio exercise the reduced path
    /// without changing a system setting.
    var previewReducedMotionOverride: Bool?
    var previewReducedTransparencyOverride: Bool?

    /// Studio-only: pin a season phase so early, prime, and late winter can be
    /// inspected without waiting for the calendar.
    var previewSeasonPhaseOverride: SeasonalPhase?

    /// Studio-only: scrub an ongoing precipitation event's age, so a two-hour
    /// rain's waxing and waning can be judged in seconds.
    var previewWeatherEventAgeOverride: TimeInterval?

    /// The pulse the last recompute applied to a precipitation visual.
    @Published private(set) var weatherTemporalMultiplier: Double = 1.0
    #endif

    private var recomputeTask: Task<Void, Never>?
    private let recomputeInterval: Duration
    private let calendar: Calendar
    private let now: () -> Date
    private let overrideStore: EnvironmentOverrideStore
    private let weatherProvider: @MainActor (Date) -> WeatherEnvironmentModifier
    private let weatherCacheInterval: TimeInterval

    // Live ambient weather. Disabled by default so a bare EnvironmentEngine
    // (tests, previews, the console's isolated engines) cannot reach the
    // network or location services. The app shell and Environment Studio opt
    // in explicitly.
    private let liveWeatherEnabled: Bool
    private let liveWeatherProvider: @MainActor () async -> WeatherSnapshot?
    private let liveWeatherInterval: Duration
    private let coordinateProvider: @MainActor () -> SolarCoordinate?

    private var liveWeather: WeatherEnvironmentModifier?
    private var liveWeatherFetchedAt: Date?
    private var liveWeatherTask: Task<Void, Never>?

    /// When the current precipitation pass was first observed. A dry tick
    /// clears it, so the next shower gets its own onset ramp.
    private var precipitationStartedAt: Date?

    // Weather is read-only but still a SQLite query; the palette tick is 10 s
    // while a real capture only needs refreshing every few minutes.
    private var cachedWeather: WeatherEnvironmentModifier = .neutral
    private var weatherFetchedAt: Date?

    private var hasPublishedState = false
    private var lastCoordinate: SolarCoordinate?
    private var liveWeatherRefreshInFlight = false
    private var liveWeatherRefreshPending = false

    init(
        recomputeInterval: Duration = .seconds(10),
        calendar: Calendar = .autoupdatingCurrent,
        now: @escaping () -> Date = { Date() },
        overrideStore: EnvironmentOverrideStore = .standard,
        weatherProvider: @escaping @MainActor (Date) -> WeatherEnvironmentModifier = { date in
            WeatherEnvironmentModifier.currentBestEffort(referenceDate: date)
        },
        weatherCacheInterval: TimeInterval = 5 * 60,
        liveWeatherEnabled: Bool = false,
        liveWeatherProvider: @escaping @MainActor () async -> WeatherSnapshot? = {
            try? await WeatherKitService.shared.currentAmbientSnapshot()
        },
        liveWeatherInterval: Duration = .seconds(15 * 60),
        coordinateProvider: @escaping @MainActor () -> SolarCoordinate? = { nil },
        transitionDuration: TimeInterval = EnvironmentPresentation.transitionDuration
    ) {
        self.recomputeInterval = recomputeInterval
        self.calendar = calendar
        self.now = now
        self.overrideStore = overrideStore
        self.weatherProvider = weatherProvider
        self.weatherCacheInterval = weatherCacheInterval
        self.liveWeatherEnabled = liveWeatherEnabled
        self.liveWeatherProvider = liveWeatherProvider
        self.liveWeatherInterval = liveWeatherInterval
        self.coordinateProvider = coordinateProvider
        self.transitionDuration = transitionDuration
        self.activeTransitionDuration = transitionDuration
        recompute() // synchronous first value so the very first frame is already correct, not .fallback

        #if DEBUG
        DeveloperConsoleRegistry.shared.register(self)
        #endif
    }

    /// AUDIT §8.2 (Phase 2 gate 1): this engine is deliberately a SINGLE shared
    /// instance consumed by several views (EnvironmentBackgroundView today,
    /// LibraryExplorer/Spatial surfaces as they wire in). A bare boolean made any
    /// one consumer's `.onDisappear` cancel the loop out from under every other
    /// reader, freezing EnvironmentState app-wide until something happened to call
    /// start() again. Consumers are now counted; the loop lives while count > 0.
    private var activeConsumerCount = 0

    /// Begins (or joins) the periodic recomputation loop. Balanced calls with
    /// stop() are required; redundant starts are counted, not deduplicated.
    func start() {
        activeConsumerCount += 1
        if activeConsumerCount == 1 {
            startLiveWeatherLoopIfNeeded()
        }
        guard recomputeTask == nil else { return }
        recomputeTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: self.recomputeInterval)
                guard !Task.isCancelled else { return }
                self.recompute()
            }
        }
    }

    /// Releases one consumer's claim on the loop. The loop stops only when the
    /// last consumer releases.
    func stop() {
        guard activeConsumerCount > 0 else { return }
        activeConsumerCount -= 1
        guard activeConsumerCount == 0 else { return }
        recomputeTask?.cancel()
        recomputeTask = nil
        liveWeatherTask?.cancel()
        liveWeatherTask = nil
    }

    // Deliberately no deinit-based cancellation here: cancelling
    // actor-isolated state from `deinit` is not guaranteed to run on the
    // MainActor in Swift's concurrency model, and isn't needed for
    // correctness — the `[weak self]` capture above already lets the loop
    // exit gracefully (via `guard let self else { return }`) once this
    // object is deallocated; it just may take up to one more sleep interval
    // to notice, which is harmless for a 10 s-cadence background loop.

    // MARK: - Core computation

    /// Recomputes immediately. The Debug Environment Studio calls this after
    /// moving its time/season/weather controls; the app shell also calls it
    /// for a persisted Studio override so the live window does not wait for
    /// the ambient 10 s tick. A caller can supply the shorter Studio fade.
    func refreshNow(transitionDuration: TimeInterval? = nil) {
        recompute(activeDuration: transitionDuration)
    }

    private func recompute(activeDuration requestedDuration: TimeInterval? = nil) {
        let reference = now()

        #if DEBUG
        // Studio overrides are a Debug-only affordance. A stale key left by a
        // crashed debug session must never repaint a Release launch.
        let minuteOverride = overrideStore.minuteOverride.map { Double($0) }
        let forcedSeason = overrideStore.seasonOverride
        let forcedVisual = overrideStore.weatherOverride
        let forcedPhase = previewSeasonPhaseOverride
        #else
        let minuteOverride: Double? = nil
        let forcedSeason: SeasonalPeriod? = nil
        let forcedVisual: WeatherVisual? = nil
        let forcedPhase: SeasonalPhase? = nil
        #endif

        // The Studio can pin a coordinate and its solar timezone. In Release
        // this is exactly the shared calendar the engine was built with.
        let activeCalendar: Calendar
        #if DEBUG
        activeCalendar = previewTimeZoneOverride.map { timezone in
            var adjusted = calendar
            adjusted.timeZone = timezone
            return adjusted
        } ?? calendar
        #else
        activeCalendar = calendar
        #endif

        let clockMinute = AnchorClock.fractionalMinutesSinceMidnight(
            for: reference, calendar: activeCalendar)

        #if DEBUG
        let coordinate = previewCoordinateOverride ?? coordinateProvider()
        resolvedCoordinate = coordinate
        #else
        let coordinate = coordinateProvider()
        #endif
        if Self.coordinateChanged(from: lastCoordinate, to: coordinate) {
            lastCoordinate = coordinate
            liveWeather = nil
            liveWeatherFetchedAt = nil
            cachedWeather = .neutral
            weatherFetchedAt = nil
            requestLiveWeatherRefresh()
        }
        // A forced palette minute is a simulated instant, not the wall clock.
        // The solar day must be simulated with it, otherwise the Studio could
        // draw a bright daytime celestial glow over a forced 22:48 night
        // palette. Without an override this is exactly `reference`.
        let solarReference: Date
        #if DEBUG
        if let minuteOverride {
            solarReference = Self.simulatedDate(
                atMinute: minuteOverride,
                on: reference,
                calendar: activeCalendar)
        } else {
            solarReference = reference
        }
        #else
        solarReference = reference
        #endif
        let solar = SolarDaylight.calculate(
            for: solarReference, calendar: activeCalendar, coordinate: coordinate)

        // The studio's forced minute is a palette minute by definition; the
        // real clock is remapped onto the fixed day track only when a cached
        // coordinate exists. Without one, this is exactly the old behaviour.
        let minute: Double
        if let minuteOverride {
            minute = minuteOverride
        } else if coordinate != nil {
            minute = solar.paletteMinute(for: clockMinute)
        } else {
            minute = clockMinute
        }

        let seasonal = SeasonalCalendar.grade(
            for: reference,
            calendar: activeCalendar,
            latitude: coordinate?.latitude ?? 45.0,
            forced: forcedSeason,
            forcedPhase: forcedPhase)

        let (paletteSnapshot, blend) = Self.interpolatedSnapshot(atMinute: minute)

        let weather = currentWeather(at: reference)
        let visual = evolvingWeatherVisual(forcedVisual ?? weather.visual, at: reference)
        let seasonalModified = EnvironmentAuthorityResolver.resolve(
            time: paletteSnapshot,
            weather: weather,
            season: seasonal)

        // Part 11: "When reducedTransparency is true, reduce blurIntensity
        // and atmosphericOpacity accordingly." Re-read every tick (same 10 s
        // cadence as everything else in this function), never cached.
        #if DEBUG
        let reducedMotion = previewReducedMotionOverride
            ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let reducedTransparency = previewReducedTransparencyOverride
            ?? NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        #else
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let reducedTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        #endif
        let modified = Self.applyingReducedTransparency(reducedTransparency, to: seasonalModified)

        let freshness = Self.weatherFreshness(
            forced: forcedVisual != nil,
            modifier: weather,
            reference: reference,
            liveFetchedAt: liveWeatherFetchedAt,
            liveIntervalSeconds: Double(liveWeatherInterval.components.seconds))
        let glow = Self.celestialGlow(for: solar, palette: modified)

        let nextState = EnvironmentState(
            currentAnchorBlend: blend,
            backgroundGradient: modified.gradientStops,
            ambientLightColor: modified.ambientLightColor,
            shadowIntensity: modified.shadowIntensity,
            blurIntensity: modified.blurIntensity,
            atmosphericOpacity: modified.atmosphericOpacity,
            starVisibility: modified.starVisibility,
            nightIntensity: modified.nightIntensity,
            weatherModifier: weather,
            weatherVisual: visual,
            minuteOfDay: minute,
            readabilityScrim: Self.readabilityScrim(for: modified),
            reducedMotion: reducedMotion,
            reducedTransparency: reducedTransparency,
            season: seasonal.dominantSeason,
            seasonalWeights: seasonal.weights,
            seasonalTint: seasonal.tint,
            seasonalTintStrength: seasonal.tintStrength,
            seasonalParticleIntensity: seasonal.particleIntensity,
            seasonalMaturity: seasonal.maturity,
            seasonalPhase: seasonal.phase,
            solarDaylight: solar,
            clockMinuteOfDay: clockMinute,
            weatherFreshness: freshness,
            celestialGlowColor: glow.color,
            celestialGlowOpacity: glow.opacity
        )

        let nextDuration = max(0, requestedDuration ?? transitionDuration)
        if hasPublishedState {
            // Capture what is currently on screen, not merely the last target.
            // If a location or weather update interrupts an in-flight fade,
            // the new fade starts from the interpolated frame rather than
            // snapping to the previous target first.
            let duration = state.reducedMotion
                ? EnvironmentPresentation.reducedMotionTransitionDuration
                : activeTransitionDuration
            let currentProgress = EnvironmentPresentation.progress(
                startedAt: transitionStartedAt,
                now: reference,
                duration: duration)
            previousState = EnvironmentPresentation.interpolate(
                from: previousState,
                to: state,
                progress: currentProgress)
            transitionStartedAt = reference
        } else {
            previousState = nextState
            transitionStartedAt = reference.addingTimeInterval(-nextDuration)
            hasPublishedState = true
        }
        activeTransitionDuration = nextDuration
        state = nextState
    }

    /// Cached read-only weather. Live ambient data wins while it is inside the
    /// refresh interval; otherwise the persisted capture is the fallback. The
    /// studio's forced visual is applied by the caller, not here — the modifier
    /// always describes the real capture so the provenance label can say which
    /// one is on screen.
    private func currentWeather(at date: Date) -> WeatherEnvironmentModifier {
        let liveSeconds = Double(liveWeatherInterval.components.seconds)
        if let liveWeather, let fetchedAt = liveWeatherFetchedAt,
           date.timeIntervalSince(fetchedAt) < liveSeconds {
            return liveWeather
        }

        if let fetchedAt = weatherFetchedAt,
           date.timeIntervalSince(fetchedAt) < weatherCacheInterval {
            return cachedWeather
        }

        let fresh = weatherProvider(date)
        cachedWeather = fresh
        weatherFetchedAt = date
        return fresh
    }

    /// Real precipitation rarely holds one intensity. The observed snapshot
    /// still sets the ceiling; this applies a slow, deterministic envelope so
    /// a long pass visibly thickens and thins instead of reading as a static
    /// particle curtain. Snow and storms share the same breathing curve.
    private func evolvingWeatherVisual(
        _ visual: WeatherVisual,
        at date: Date
    ) -> WeatherVisual {
        guard visual.kind.isPrecipitation else {
            precipitationStartedAt = nil
            #if DEBUG
            weatherTemporalMultiplier = 1.0
            #endif
            return visual
        }

        if precipitationStartedAt == nil {
            precipitationStartedAt = date
        }
        let start = precipitationStartedAt ?? date

        #if DEBUG
        let elapsed = previewWeatherEventAgeOverride
            ?? date.timeIntervalSince(start)
        #else
        let elapsed = date.timeIntervalSince(start)
        #endif

        let multiplier = WeatherTemporalEnvelope.multiplier(elapsed: elapsed)
        #if DEBUG
        weatherTemporalMultiplier = multiplier
        #endif
        return visual.applyingIntensityMultiplier(multiplier)
    }

    // MARK: - Live ambient weather

    private func startLiveWeatherLoopIfNeeded() {
        guard liveWeatherEnabled, liveWeatherTask == nil else { return }
        liveWeatherTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshLiveWeather()
            while !Task.isCancelled {
                try? await Task.sleep(for: self.liveWeatherInterval)
                guard !Task.isCancelled else { return }
                await self.refreshLiveWeather()
            }
        }
    }

    private func refreshLiveWeather() async {
        guard !liveWeatherRefreshInFlight else { return }
        liveWeatherRefreshInFlight = true
        defer {
            liveWeatherRefreshInFlight = false
            if liveWeatherRefreshPending {
                liveWeatherRefreshPending = false
                requestLiveWeatherRefresh()
            }
        }

        guard let snapshot = await liveWeatherProvider() else { return }
        let modifier = WeatherEnvironmentModifier(snapshot: snapshot)
        liveWeather = modifier
        liveWeatherFetchedAt = now()
        cachedWeather = modifier
        weatherFetchedAt = liveWeatherFetchedAt
        recompute()
    }

    /// Coalesces location-triggered refreshes with the periodic live loop.
    /// A location change must not stack network requests or leave the old
    /// location's weather on screen after the solar day has moved.
    private func requestLiveWeatherRefresh() {
        guard liveWeatherEnabled else { return }
        guard !liveWeatherRefreshInFlight else {
            liveWeatherRefreshPending = true
            return
        }
        Task { [weak self] in
            await self?.refreshLiveWeather()
        }
    }

    /// A GPS update can wiggle by metres. Only a materially different place
    /// invalidates the live-weather cache; solar recalibration still follows
    /// every coordinate update because it is cheap and local.
    private static func coordinateChanged(
        from old: SolarCoordinate?,
        to new: SolarCoordinate?
    ) -> Bool {
        switch (old, new) {
        case (nil, nil):
            return false
        case let (old?, new?):
            return abs(old.latitude - new.latitude) > 0.02
                || abs(old.longitude - new.longitude) > 0.02
        case (nil, _), (_, nil):
            return true
        }
    }

    // MARK: - Provenance and glow

    #if DEBUG
    /// Builds the instant at a forced palette minute on the reference day. Used
    /// only for the Studio's solar geometry, so a forced hour and its sun agree;
    /// the real clock is untouched everywhere else.
    private static func simulatedDate(
        atMinute minute: Double,
        on reference: Date,
        calendar: Calendar
    ) -> Date {
        let startOfDay = calendar.startOfDay(for: reference)
        return calendar.date(
            byAdding: .second,
            value: Int((minute * 60).rounded()),
            to: startOfDay) ?? reference
    }
    #endif

    private static func weatherFreshness(
        forced: Bool,
        modifier: WeatherEnvironmentModifier,
        reference: Date,
        liveFetchedAt: Date?,
        liveIntervalSeconds: Double
    ) -> WeatherFreshness {
        if forced { return .forced }
        guard let capturedAt = modifier.capturedAt else { return .unavailable }

        if let liveFetchedAt,
           reference.timeIntervalSince(liveFetchedAt) < max(1.0, liveIntervalSeconds) {
            return .live
        }

        let age = reference.timeIntervalSince(capturedAt)
        if age < 15 * 60 { return .live }
        if age < 2 * 60 * 60 { return .recent }
        return .stale
    }

    private static func celestialGlow(
        for solar: SolarDaylight,
        palette: EnvironmentPaletteSnapshot
    ) -> (color: EnvironmentColor, opacity: Double) {
        if solar.goldenHourFactor > 0.1 {
            return (EnvironmentColor(hex: "#F2C58A"),
                    0.55 + 0.35 * solar.goldenHourFactor)
        }

        if solar.hasLocation, !solar.isDaylight {
            return (palette.ambientLightColor.lerp(
                to: EnvironmentColor(hex: "#8FA9D6"), fraction: 0.35),
                    0.55)
        }

        // The fixed track has no solar elevation; use the palette's own night
        // signal rather than claiming it is daylight at 02:00.
        if !solar.hasLocation, palette.nightIntensity > 0.5 {
            return (palette.ambientLightColor.lerp(
                to: EnvironmentColor(hex: "#8FA9D6"), fraction: 0.35),
                    0.55)
        }

        return (palette.ambientLightColor, 0.45 + 0.15 * solar.daylightFactor)
    }

    /// Luminance-derived veil. Night sits at the 0.04 floor; the deepened
    /// morning arc lands around 0.25-0.30, which is enough for white text on
    /// thin chrome without flattening the sunrise.
    private static func readabilityScrim(for snapshot: EnvironmentPaletteSnapshot) -> Double {
        guard !snapshot.gradientStops.isEmpty else { return 0.04 }
        let luminance = snapshot.gradientStops.reduce(0.0) { partial, stop in
            partial + stop.color.red * 0.2126
                + stop.color.green * 0.7152
                + stop.color.blue * 0.0722
        } / Double(snapshot.gradientStops.count)
        return min(0.42, max(0.04, (luminance - 0.16) * 0.85))
    }

    /// Part 11's reduced-transparency reduction. Scales blurIntensity and
    /// atmosphericOpacity down to a quarter of their computed value rather
    /// than zeroing them — a small amount of atmosphere still reads as
    /// "this environment is alive," which is the point; reduced
    /// transparency asks for less translucency, not a flat, opaque scene.
    private static func applyingReducedTransparency(
        _ reducedTransparency: Bool,
        to snapshot: EnvironmentPaletteSnapshot
    ) -> EnvironmentPaletteSnapshot {
        guard reducedTransparency else { return snapshot }
        var result = snapshot
        result.blurIntensity = snapshot.blurIntensity * 0.25
        result.atmosphericOpacity = snapshot.atmosphericOpacity * 0.25
        return result
    }

    /// Walks EnvironmentPalette.keyframeTrack to find the two keyframes
    /// bracketing `minute`, eases the raw fraction between them, and blends
    /// every property using that eased fraction. This is the entire
    /// "which time-of-day state are we in" decision — no if/else time-range
    /// branching anywhere, per Part 5.3's explicit requirement.
    private static func interpolatedSnapshot(
        atMinute minute: Double
    ) -> (EnvironmentPaletteSnapshot, [EnvironmentAnchorPeriod: Double]) {
        let track = EnvironmentPalette.keyframeTrack

        var lowerIndex = 0
        for i in 0..<(track.count - 1) {
            if minute >= track[i].minute && minute <= track[i + 1].minute {
                lowerIndex = i
                break
            }
        }
        let lower = track[lowerIndex]
        let upper = track[lowerIndex + 1]

        let span = upper.minute - lower.minute
        let rawFraction = span > 0 ? (minute - lower.minute) / span : 0
        let eased = EnvironmentMath.smoothstep(rawFraction)

        let snapshot = EnvironmentPaletteSnapshot.blend(lower.snapshot, upper.snapshot, fraction: eased)
        let blend = anchorBlend(forSegmentStartingAt: lowerIndex, easedFraction: eased)
        return (snapshot, blend)
    }

    /// Maps a keyframe-track segment + eased fraction to named-period
    /// weights. The Midday crossing point (segment index 3, 12:00-13:00)
    /// gets a genuine brief peak — Morning fades to Midday across the first
    /// half of that hour, then Midday fades to Afternoon across the second
    /// half — rather than Midday never appearing with nonzero weight at all.
    private static func anchorBlend(
        forSegmentStartingAt lowerIndex: Int,
        easedFraction: Double
    ) -> [EnvironmentAnchorPeriod: Double] {
        switch lowerIndex {
        case 0, 6: // 00:00-05:45 and 19:45-24:00 — flat night
            return [.night: 1.0]
        case 1: // 05:45-06:00 — blend zone 1: night -> morning
            return [.night: 1 - easedFraction, .morning: easedFraction]
        case 2: // 06:00-12:00 — Morning's own window
            return [.morning: 1.0]
        case 3: // 12:00-13:00 — blend zone 2: the Midday crossing point
            if easedFraction < 0.5 {
                let local = EnvironmentMath.smoothstep(easedFraction * 2)
                return [.morning: 1 - local, .midday: local]
            } else {
                let local = EnvironmentMath.smoothstep((easedFraction - 0.5) * 2)
                return [.midday: 1 - local, .afternoon: local]
            }
        case 4: // 13:00-19:30 — Afternoon's own window
            return [.afternoon: 1.0]
        case 5: // 19:30-19:45 — blend zone 3: afternoon -> night
            return [.afternoon: 1 - easedFraction, .night: easedFraction]
        default:
            return [.night: 1.0]
        }
    }
}

// MARK: - Developer Console

#if DEBUG
extension EnvironmentEngine: DeveloperConsoleObservable {
    static var consoleIdentity: ConsoleSubsystemIdentity {
        ConsoleSubsystemIdentity(
            id: "environment-engine",
            displayName: "Environment Engine",
            category: .engine,
            purpose: "Computes the time-of-day + season + weather-blended visual theme on a 10 s cadence; maps the real solar day onto the palette when a coordinate is cached; optionally refreshes live ambient weather without writing a session row. The effect layers animate at their own frame rate."
        )
    }

    var consoleSnapshot: ConsoleSubsystemSnapshot {
        let solar = state.solarDaylight
        let sunText: String
        if solar.hasLocation {
            sunText = "\(Self.formatMinute(solar.sunriseMinute))–\(Self.formatMinute(solar.sunsetMinute))"
        } else {
            sunText = "fixed track"
        }

        return ConsoleSubsystemSnapshot(
            identity: Self.consoleIdentity,
            status: recomputeTask != nil ? .running : .idle,
            currentActivity: recomputeTask != nil
                ? "Recomputing on a \(Int(recomputeInterval.components.seconds))s cadence"
                    + (liveWeatherEnabled ? "; live weather on" : "")
                : "Instantiated, but start() has not been called — recompute loop is not running",
            lastUpdated: Date(),
            metrics: [
                "Clock": Self.formatMinute(state.minuteOfDay),
                "Wall clock": Self.formatMinute(state.clockMinuteOfDay),
                "Season": state.season.rawValue.capitalized,
                "Season phase": "\(state.seasonalPhase.displayName) "
                    + "\(state.season.rawValue)"
                    + " (\(String(format: "%.2f", state.seasonalMaturity)))",
                "Weather pulse": String(format: "%.2f", weatherTemporalMultiplier),
                "Sun": sunText,
                "Weather": state.weatherVisual.kind.displayName
                    + " (\(state.weatherFreshness.displayName.lowercased()))",
                "Gradient luminance": String(format: "%.2f", state.gradientLuminance),
                "Readability scrim": String(format: "%.2f", state.readabilityScrim),
                "Seasonal tint": String(format: "%.2f", state.seasonalTintStrength),
                "Season particles": String(format: "%.2f", state.seasonalParticleIntensity),
                "Reduced motion": state.reducedMotion ? "Yes" : "No",
                "Reduced transparency": state.reducedTransparency ? "Yes" : "No",
            ]
        )
    }

    private static func formatMinute(_ minute: Double) -> String {
        let total = Int(minute.rounded())
        return String(format: "%02d:%02d", (total / 60) % 24, total % 60)
    }
}
#endif
