//  EnvironmentPresentation.swift
//  AsterismaV2.5
//
//  The authoritative composition and interpolation layer for the background.
//
//  Authority order (definitive):
//      1. Time    — the base palette and solar day
//      2. Weather — a capped secondary modulation of that palette
//      3. Season  — a capped tertiary modulation of the result
//
//  EnvironmentEngine publishes discrete target states on its 10 s cadence.
//  EnvironmentBackgroundView samples this type every frame and interpolates
//  the previous target toward the current target, so no visual property jumps
//  when a weather kind, season, solar day, or location changes. Weather kinds
//  cannot be linearly blended as a single value, so the rendering layer
//  cross-fades the outgoing and incoming WeatherVisual explicitly.
//
//  Booleans choose their destination at the halfway point; all continuous
//  properties — colors, opacities, weights, solar geometry, minutes — are
//  linearly blended from an already-eased progress value.

import Foundation

// MARK: - Authority

nonisolated enum EnvironmentAuthority: Int, CaseIterable, Sendable {
    case time = 0
    case weather = 1
    case season = 2

    var displayName: String {
        switch self {
        case .time: return "Time"
        case .weather: return "Weather"
        case .season: return "Season"
        }
    }

    var influenceDescription: String {
        switch self {
        case .time: return "Base palette and solar day"
        case .weather: return "Capped 18% modulation"
        case .season: return "Capped tint, atmosphere, and particle modulation"
        }
    }
}

nonisolated enum EnvironmentAuthorityResolver {

    /// The existing weather modifier enforces this same ceiling. Keeping it
    /// named here makes the authority budget testable and visible at the
    /// composition point instead of being an implementation detail.
    static let weatherInfluenceCeiling = 0.18

    /// The strongest season tint profile is 0.14. Season is allowed to shift
    /// temperature and air, never to replace the hour or the weather.
    static let seasonInfluenceCeiling = 0.14

    /// Composes in the definitive order. Time is the unmodified base; weather
    /// is applied second; season is applied last but only through its bounded
    /// tint/lift/particle contributions.
    static func resolve(
        time: EnvironmentPaletteSnapshot,
        weather: WeatherEnvironmentModifier,
        season: SeasonalGrade
    ) -> EnvironmentPaletteSnapshot {
        let weatherApplied = weather.apply(to: time)
        return season.apply(to: weatherApplied)
    }
}

// MARK: - Presentation interpolation

nonisolated enum EnvironmentPresentation {

    /// The production cross-fade spans the engine's full 10 s recompute period,
    /// so time-of-day color is continuously moving rather than settling for the
    /// last four seconds of each tick. At 60 Hz that is 600 interpolated frames.
    static let transitionDuration: TimeInterval = 10.0

    /// A manual Studio override is an inspection action, not ambient drift.
    /// It starts immediately and settles in the same span as the mini preview,
    /// while natural day/night changes keep the ten-second production fade.
    static let studioOverrideTransitionDuration: TimeInterval = 2.5

    /// Reduced motion still permits a short color settle; all drifting,
    /// precipitation, and particle layers are frozen by their own views.
    static let reducedMotionTransitionDuration: TimeInterval = 0.4

    static func progress(
        startedAt: Date,
        now: Date,
        duration: TimeInterval
    ) -> Double {
        guard duration > 0 else { return 1.0 }
        let raw = EnvironmentMath.clampUnit(
            now.timeIntervalSince(startedAt) / duration)

        // A manual Studio change is an inspection action: lead with motion,
        // then settle. The ambient ten-second fade keeps the gentler
        // smoothstep so day/night drift never reads as a jump.
        if duration <= studioOverrideTransitionDuration {
            let remaining = 1.0 - raw
            return 1.0 - remaining * remaining * remaining
        }
        return EnvironmentMath.smoothstep(raw)
    }

    static func weatherAttenuation(for kind: WeatherVisualKind) -> Double {
        switch kind {
        case .heavyRain, .storm, .heavySnow:
            return 0.15
        case .rain, .snow, .fog:
            return 0.45
        case .clear, .cloudy, .wind:
            return 1.0
        }
    }

    static func interpolate(
        from: EnvironmentState,
        to: EnvironmentState,
        progress: Double
    ) -> EnvironmentState {
        let t = EnvironmentMath.clampUnit(progress)

        return EnvironmentState(
            currentAnchorBlend: interpolateWeights(
                from.currentAnchorBlend, to.currentAnchorBlend, fraction: t),
            backgroundGradient: interpolateGradient(
                from.backgroundGradient, to.backgroundGradient, fraction: t),
            ambientLightColor: from.ambientLightColor.lerp(
                to: to.ambientLightColor, fraction: t),
            shadowIntensity: EnvironmentMath.lerp(
                from.shadowIntensity, to.shadowIntensity, fraction: t),
            blurIntensity: EnvironmentMath.lerp(
                from.blurIntensity, to.blurIntensity, fraction: t),
            atmosphericOpacity: EnvironmentMath.lerp(
                from.atmosphericOpacity, to.atmosphericOpacity, fraction: t),
            starVisibility: EnvironmentMath.lerp(
                from.starVisibility, to.starVisibility, fraction: t),
            nightIntensity: EnvironmentMath.lerp(
                from.nightIntensity, to.nightIntensity, fraction: t),
            weatherModifier: t < 0.5 ? from.weatherModifier : to.weatherModifier,
            weatherVisual: t < 0.5 ? from.weatherVisual : to.weatherVisual,
            minuteOfDay: interpolateMinute(
                from.minuteOfDay, to.minuteOfDay, fraction: t),
            readabilityScrim: EnvironmentMath.lerp(
                from.readabilityScrim, to.readabilityScrim, fraction: t),
            // Accessibility switches are owned by the engine's target state at
            // the view boundary. The value stored here still follows the
            // transition so a state snapshot is internally consistent.
            reducedMotion: t < 1 ? from.reducedMotion : to.reducedMotion,
            reducedTransparency: t < 1 ? from.reducedTransparency : to.reducedTransparency,
            season: t < 0.5 ? from.season : to.season,
            seasonalWeights: interpolateWeights(
                from.seasonalWeights, to.seasonalWeights, fraction: t),
            seasonalTint: from.seasonalTint.lerp(
                to: to.seasonalTint, fraction: t),
            seasonalTintStrength: EnvironmentMath.lerp(
                from.seasonalTintStrength, to.seasonalTintStrength, fraction: t),
            seasonalParticleIntensity: EnvironmentMath.lerp(
                from.seasonalParticleIntensity, to.seasonalParticleIntensity,
                fraction: t),
            seasonalMaturity: EnvironmentMath.lerp(
                from.seasonalMaturity, to.seasonalMaturity, fraction: t),
            seasonalPhase: t < 0.5 ? from.seasonalPhase : to.seasonalPhase,
            solarDaylight: interpolateSolar(
                from.solarDaylight, to.solarDaylight, fraction: t),
            clockMinuteOfDay: interpolateMinute(
                from.clockMinuteOfDay, to.clockMinuteOfDay, fraction: t),
            weatherFreshness: t < 0.5 ? from.weatherFreshness : to.weatherFreshness,
            celestialGlowColor: from.celestialGlowColor.lerp(
                to: to.celestialGlowColor, fraction: t),
            celestialGlowOpacity: EnvironmentMath.lerp(
                from.celestialGlowOpacity, to.celestialGlowOpacity, fraction: t)
        )
    }

    /// Interpolates a minute-of-day without sweeping the long way around
    /// midnight. A transition from 23:59 to 00:01 passes through midnight,
    /// not through noon.
    static func interpolateMinute(
        _ from: Double,
        _ to: Double,
        fraction: Double
    ) -> Double {
        let t = EnvironmentMath.clampUnit(fraction)
        var delta = (to - from).truncatingRemainder(dividingBy: 1440.0)
        if delta > 720.0 { delta -= 1440.0 }
        if delta < -720.0 { delta += 1440.0 }

        var value = (from + delta * t).truncatingRemainder(dividingBy: 1440.0)
        if value < 0 { value += 1440.0 }
        return value
    }

    private static func interpolateWeights<Key: Hashable>(
        _ from: [Key: Double],
        _ to: [Key: Double],
        fraction: Double
    ) -> [Key: Double] {
        let keys = Set(from.keys).union(to.keys)
        var result: [Key: Double] = [:]
        result.reserveCapacity(keys.count)

        var total = 0.0
        for key in keys {
            let value = EnvironmentMath.lerp(
                from[key] ?? 0, to[key] ?? 0, fraction: fraction)
            result[key] = value
            total += value
        }

        // The source weights are normalized. A linear blend of two
        // normalized weight maps is also normalized, but renormalizing
        // protects callers from accumulated rounding at display precision.
        guard total > 0.000_001 else { return result }
        return result.mapValues { $0 / total }
    }

    private static func interpolateGradient(
        _ from: [EnvironmentGradientStop],
        _ to: [EnvironmentGradientStop],
        fraction: Double
    ) -> [EnvironmentGradientStop] {
        guard from.count == to.count else {
            return fraction < 0.5 ? from : to
        }

        return zip(from, to).map { a, b in
            EnvironmentGradientStop(
                color: a.color.lerp(to: b.color, fraction: fraction),
                location: EnvironmentMath.lerp(a.location, b.location, fraction: fraction))
        }
    }

    private static func interpolateSolar(
        _ from: SolarDaylight,
        _ to: SolarDaylight,
        fraction: Double
    ) -> SolarDaylight {
        SolarDaylight(
            sunriseMinute: interpolateMinute(
                from.sunriseMinute, to.sunriseMinute, fraction: fraction),
            sunsetMinute: interpolateMinute(
                from.sunsetMinute, to.sunsetMinute, fraction: fraction),
            solarNoonMinute: interpolateMinute(
                from.solarNoonMinute, to.solarNoonMinute, fraction: fraction),
            daylightDurationMinutes: EnvironmentMath.lerp(
                from.daylightDurationMinutes, to.daylightDurationMinutes,
                fraction: fraction),
            solarElevationDegrees: EnvironmentMath.lerp(
                from.solarElevationDegrees, to.solarElevationDegrees,
                fraction: fraction),
            daylightFactor: EnvironmentMath.lerp(
                from.daylightFactor, to.daylightFactor, fraction: fraction),
            goldenHourFactor: EnvironmentMath.lerp(
                from.goldenHourFactor, to.goldenHourFactor, fraction: fraction),
            isDaylight: fraction < 0.5 ? from.isDaylight : to.isDaylight,
            solarProgress: EnvironmentMath.lerp(
                from.solarProgress, to.solarProgress, fraction: fraction),
            nightProgress: EnvironmentMath.lerp(
                from.nightProgress, to.nightProgress, fraction: fraction),
            glowX: EnvironmentMath.lerp(from.glowX, to.glowX, fraction: fraction),
            glowY: EnvironmentMath.lerp(from.glowY, to.glowY, fraction: fraction),
            hasLocation: fraction < 0.5 ? from.hasLocation : to.hasLocation)
    }
}

#if DEBUG
// MARK: - Studio frame override

/// A frozen A→B frame for the Environment Studio's transition scrubber.
///
/// The background normally derives its interpolation from the engine's live
/// previous/current targets. The Studio captures two states and renders this
/// value instead, so a cross-fade can be inspected at any point without
/// waiting for a real weather, season, or location change to happen.
nonisolated struct EnvironmentPresentationOverride: Equatable, Sendable {
    var from: EnvironmentState
    var to: EnvironmentState
    var progress: Double
}
#endif
