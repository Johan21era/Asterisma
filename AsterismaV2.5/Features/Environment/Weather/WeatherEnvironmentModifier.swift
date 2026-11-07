//  WeatherEnvironmentModifier.swift
//  Environment Engine — Phase E (Part 8 of the build spec)
//
//  The two, and only two, weather-driven adjustments Part 8 permits: a small
//  atmospheric-opacity/desaturation nudge from cloud cover, and a night-only
//  star-visibility reduction from cloud cover. No rain, lightning, or storm
//  visuals — this is two knobs on the existing Environment Engine, not a
//  second effect system, per Part 8's explicit warning.
//
//  VERIFIED (Phase A): WeatherKitService.shared.snapshots(from:to:) —
//    WeatherKitService.swift:159-164
//    `@MainActor public func snapshots(from startDate: Date, to endDate: Date) throws -> [WeatherSnapshot]`
//    Synchronous, throwing, queries only already-persisted local SQLite data
//    (WeatherSnapshotStore.fetchRange) — no network call, no session write.
//    Existing precedent: WeatherInsightPanel 2.swift:313, `try WeatherKitService.shared.snapshots(from:...)`.
//  Deliberately NOT using snapshotForCurrentConditions(sessionID:)
//    (WeatherKitService.swift:61-82): that method does a live WeatherKit
//    network fetch AND writes a row to the session-attached SQLite store —
//    wrong semantics (there is no reading session here) and unsafe to call
//    every 10 s from an ambient background system.
//  VERIFIED (Phase A): WeatherSnapshot's real fields, from its own
//    test-target constructor calls (WeatherKitService.swift:1220, 1342):
//    `timestamp: Date`, `cloudCover: Double`, plus fields this file doesn't need.
//

import Foundation

struct WeatherEnvironmentModifier: Sendable, Equatable {

    /// 0 (clear) ... 1 (fully overcast). `nil` when no recent weather
    /// snapshot is available — every effect below is then a no-op.
    var cloudCoverFraction: Double?

    /// The rest of the captured snapshot, carried verbatim so the background's
    /// precipitation layer can be derived from the SAME read that drives the
    /// cloud-cover nudge. Nil on `.neutral` (no recent capture).
    var condition: WeatherConditionCategory?
    var precipitationMillimeters: Double
    var snowfallMillimeters: Double
    var visibilityKilometers: Double
    var windSpeedKPH: Double
    var stormActivityIndex: Double
    var capturedAt: Date?

    init(
        cloudCoverFraction: Double? = nil,
        condition: WeatherConditionCategory? = nil,
        precipitationMillimeters: Double = 0,
        snowfallMillimeters: Double = 0,
        visibilityKilometers: Double = 12,
        windSpeedKPH: Double = 0,
        stormActivityIndex: Double = 0,
        capturedAt: Date? = nil
    ) {
        self.cloudCoverFraction = cloudCoverFraction
        self.condition = condition
        self.precipitationMillimeters = precipitationMillimeters
        self.snowfallMillimeters = snowfallMillimeters
        self.visibilityKilometers = visibilityKilometers
        self.windSpeedKPH = windSpeedKPH
        self.stormActivityIndex = stormActivityIndex
        self.capturedAt = capturedAt
    }

    /// The drawable weather layer. A missing condition stays `.clear` with
    /// `isLive == false` — absence of a capture is not a weather claim.
    var visual: WeatherVisual {
        guard let condition else { return .clear }
        return WeatherVisual.from(
            condition: condition,
            cloudCover: cloudCoverFraction ?? 0,
            precipitationMM: precipitationMillimeters,
            snowfallMM: snowfallMillimeters,
            windKPH: windSpeedKPH,
            visibilityKM: visibilityKilometers,
            stormIndex: stormActivityIndex)
    }

    static let neutral = WeatherEnvironmentModifier()

    /// Caps every modifier at a 15-20% maximum influence over the
    /// time-of-day-driven values, per Part 8.
    private static let maximumInfluence = 0.18

    /// How far back to look for a "current-enough" snapshot when querying
    /// the read-only store. Ambient weather here is necessarily "best
    /// available recent snapshot," not always-live — that's the accepted
    /// tradeoff of not calling the live/write-performing method.
    private static let lookbackWindow: TimeInterval = 6 * 60 * 60

    func apply(to snapshot: EnvironmentPaletteSnapshot) -> EnvironmentPaletteSnapshot {
        guard let cloudCoverFraction else { return snapshot }
        let influence = EnvironmentMath.clampUnit(cloudCoverFraction) * Self.maximumInfluence

        var result = snapshot
        result.atmosphericOpacity = EnvironmentMath.clampUnit(snapshot.atmosphericOpacity + influence)

        result.gradientStops = snapshot.gradientStops.map { stop in
            EnvironmentGradientStop(color: stop.color.desaturated(by: influence), location: stop.location)
        }

        // Night-only in effect: scaled by the snapshot's own starVisibility,
        // so this never *adds* stars during daytime snapshots where
        // starVisibility is already 0 — it only ever reduces.
        result.starVisibility = EnvironmentMath.clampUnit(snapshot.starVisibility * (1 - influence))

        return result
    }

    /// Reads the most recent already-captured weather snapshot via the
    /// verified read-only query path. Falls back to `.neutral` (no-op) if
    /// the query throws or nothing has been captured recently — a missing
    /// weather signal should never block the environment from rendering.
    @MainActor
    static func currentBestEffort(referenceDate: Date = Date()) -> WeatherEnvironmentModifier {
        let lookback = referenceDate.addingTimeInterval(-lookbackWindow)
        do {
            let recent = try WeatherKitService.shared.snapshots(from: lookback, to: referenceDate)
            guard let latest = recent.max(by: { $0.timestamp < $1.timestamp }) else {
                return .neutral
            }
            return WeatherEnvironmentModifier(
                cloudCoverFraction: latest.cloudCover,
                condition: latest.condition,
                precipitationMillimeters: latest.precipitationMillimeters,
                snowfallMillimeters: latest.snowfallMillimeters,
                visibilityKilometers: latest.visibilityKilometers,
                windSpeedKPH: latest.windSpeedKPH,
                stormActivityIndex: latest.stormActivityIndex,
                capturedAt: latest.timestamp)
        } catch {
            return .neutral
        }
    }
}
