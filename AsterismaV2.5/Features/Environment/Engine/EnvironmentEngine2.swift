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
//  keyframe-based, recomputed on a 10 s cadence fully decoupled from
//  per-frame animation (stars, atmosphere, and weather tick on their own
//  TimelineView-driven cadence — see Stars/, Weather/WeatherEffectView.swift).
//  The 10 s tick replaced the original 45 s one on 2026-10-29: at 45 s the
//  background visibly jumped between palettes instead of flowing.
//

import Combine
import AppKit
import SwiftUI

@MainActor
final class EnvironmentEngine: ObservableObject {

    @Published private(set) var state: EnvironmentState = .fallback

    private var recomputeTask: Task<Void, Never>?
    private let recomputeInterval: Duration
    private let calendar: Calendar
    private let now: () -> Date
    private let overrideStore: EnvironmentOverrideStore
    private let weatherProvider: @MainActor (Date) -> WeatherEnvironmentModifier
    private let weatherCacheInterval: TimeInterval

    // Weather is read-only but still a SQLite query; the palette tick is 10 s
    // while a real capture only needs refreshing every few minutes.
    private var cachedWeather: WeatherEnvironmentModifier = .neutral
    private var weatherFetchedAt: Date?

    init(
        recomputeInterval: Duration = .seconds(10),
        calendar: Calendar = .current,
        now: @escaping () -> Date = { Date() },
        overrideStore: EnvironmentOverrideStore = .standard,
        weatherProvider: @escaping @MainActor (Date) -> WeatherEnvironmentModifier = { date in
            WeatherEnvironmentModifier.currentBestEffort(referenceDate: date)
        },
        weatherCacheInterval: TimeInterval = 5 * 60
    ) {
        self.recomputeInterval = recomputeInterval
        self.calendar = calendar
        self.now = now
        self.overrideStore = overrideStore
        self.weatherProvider = weatherProvider
        self.weatherCacheInterval = weatherCacheInterval
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
    /// moving its time/weather sliders; nothing else needs it.
    func refreshNow() {
        recompute()
    }

    private func recompute() {
        let reference = now()
        #if DEBUG
        // Studio overrides are a Debug-only affordance. A stale key left by a
        // crashed debug session must never repaint a Release launch.
        let minute = overrideStore.effectiveMinute(now: reference, calendar: calendar)
        let visual = overrideStore.weatherOverride
        #else
        let minute = AnchorClock.fractionalMinutesSinceMidnight(
            for: reference, calendar: calendar)
        let visual: WeatherVisual? = nil
        #endif
        let (paletteSnapshot, blend) = Self.interpolatedSnapshot(atMinute: minute)

        let weather = currentWeather(at: reference)
        let weatherModified = weather.apply(to: paletteSnapshot)

        // Part 11: "When reducedTransparency is true, reduce blurIntensity
        // and atmosphericOpacity accordingly." Re-read every tick (same 10 s
        // cadence as everything else in this function), never cached.
        let reducedTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let modified = Self.applyingReducedTransparency(reducedTransparency, to: weatherModified)

        state = EnvironmentState(
            currentAnchorBlend: blend,
            backgroundGradient: modified.gradientStops,
            ambientLightColor: modified.ambientLightColor,
            shadowIntensity: modified.shadowIntensity,
            blurIntensity: modified.blurIntensity,
            atmosphericOpacity: modified.atmosphericOpacity,
            starVisibility: modified.starVisibility,
            nightIntensity: modified.nightIntensity,
            weatherModifier: weather,
            weatherVisual: visual ?? weather.visual,
            minuteOfDay: minute,
            readabilityScrim: Self.readabilityScrim(for: modified),
            reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            reducedTransparency: reducedTransparency
        )

    }

    /// Cached read-only weather. The studio's forced visual is applied by the
    /// caller, not here — the modifier always describes the real capture so the
    /// provenance label can say which one is on screen.
    private func currentWeather(at date: Date) -> WeatherEnvironmentModifier {
        if let fetchedAt = weatherFetchedAt,
           date.timeIntervalSince(fetchedAt) < weatherCacheInterval {
            return cachedWeather
        }
        let fresh = weatherProvider(date)
        cachedWeather = fresh
        weatherFetchedAt = date
        return fresh
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
            purpose: "Computes the time-of-day + weather-blended visual theme (background gradient, star visibility, weather layer, readability scrim) on a 10 s recompute cadence; the effect layers animate at their own frame rate."
        )
    }

    var consoleSnapshot: ConsoleSubsystemSnapshot {
        ConsoleSubsystemSnapshot(
            identity: Self.consoleIdentity,
            status: recomputeTask != nil ? .running : .idle,
            currentActivity: recomputeTask != nil
                ? "Recomputing on a \(Int(recomputeInterval.components.seconds))s cadence"
                : "Instantiated, but start() has not been called — recompute loop is not running",
            lastUpdated: Date(),
            metrics: [
                "Clock": String(format: "%02d:%02d", Int(state.minuteOfDay) / 60, Int(state.minuteOfDay) % 60),
                "Weather": state.weatherVisual.kind.displayName
                    + (state.weatherVisual.isLive ? " (live)" : " (forced/none)"),
                "Gradient luminance": String(format: "%.2f", state.gradientLuminance),
                "Readability scrim": String(format: "%.2f", state.readabilityScrim),
                "Reduced motion": state.reducedMotion ? "Yes" : "No",
                "Reduced transparency": state.reducedTransparency ? "Yes" : "No",
            ]
        )
    }
}
#endif
