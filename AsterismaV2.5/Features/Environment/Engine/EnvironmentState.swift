//  EnvironmentState.swift
//  AsterismaV2.5
//
//  Environment Engine — Phase B (Part 5.1 of the build spec)
//
//  The complete, centrally-computed visual state of the application at a
//  single instant. Every view in the Environment/Star/ShootingStar/Weather
//  systems reads its visual properties from an EnvironmentState value —
//  nothing computes its own color, opacity, or intensity independently
//  ("nothing renders its own opinion," Part 4).
//
//  This is a plain value type, not the engine itself. EnvironmentEngine
//  (ObservableObject) owns the *computation* of this value over time;
//  EnvironmentState is just the computed snapshot.
//

import Foundation

/// Whether the weather driving the scene came from a live fetch, a recent
/// persisted capture, an older capture, or a Debug-studio override.
nonisolated enum WeatherFreshness: String, CaseIterable, Sendable, Equatable {
    case live
    case recent
    case stale
    case unavailable
    case forced

    var displayName: String {
        switch self {
        case .live: return "Live"
        case .recent: return "Recent capture"
        case .stale: return "Stale capture"
        case .unavailable: return "Unavailable"
        case .forced: return "Forced"
        }
    }
}

struct EnvironmentState: Sendable, Equatable {

    /// Weights describing how much of each named anchor period is currently
    /// "in play." Outside blend zones, exactly one period has weight 1.0;
    /// inside a blend zone, two periods share nonzero weight (and, briefly,
    /// at the Midday crossing point's exact midpoint, Midday alone does).
    var currentAnchorBlend: [EnvironmentAnchorPeriod: Double]

    /// The current background gradient, as color+position pairs. Always the
    /// same stop count/positions across every possible state (see
    /// EnvironmentPalette's fixed 5-stop layout).
    var backgroundGradient: [EnvironmentGradientStop]

    /// A tint representing the ambient "color of light" in the current
    /// scene. Rendered by EnvironmentBackgroundView as a soft edge glow —
    /// most visible at night (see EnvironmentPalette.night's saturated navy
    /// value against a near-black background), negligible during bright
    /// daytime snapshots by construction, not by special-cased logic.
    var ambientLightColor: EnvironmentColor

    var shadowIntensity: Double
    var blurIntensity: Double
    var atmosphericOpacity: Double
    var starVisibility: Double

    /// The specific "Night Intensity" variable named in Appendix A's worked
    /// example. Ramps 0->1 specifically across the Afternoon-to-Night blend
    /// zone (19:30-19:45) — see EnvironmentPalette.afternoonEnd (0.0) and
    /// EnvironmentPalette.night (1.0). Tracks starVisibility's ramp here but
    /// is a conceptually separate signal, exposed for any future consumer
    /// that cares about "how far into night" rather than "how visible are stars."
    var nightIntensity: Double

    var weatherModifier: WeatherEnvironmentModifier

    /// The precipitation/atmosphere kind the background draws, derived from
    /// the same weather signal (or a studio override). `.clear` draws nothing.
    var weatherVisual: WeatherVisual

    /// Fractional minutes since local midnight that produced this snapshot.
    /// With a studio override this is the forced minute, not the wall clock.
    var minuteOfDay: Double

    /// A black veil above the gradient and below the content, sized from the
    /// palette's own luminance. Morning/midday were bright enough that white
    /// text and thin chrome disappeared; this keeps contrast without turning
    /// the scene into a flat night.
    var readabilityScrim: Double

    /// Sourced from real system accessibility settings by EnvironmentEngine,
    /// re-checked on the same periodic cadence as everything else — never
    /// read once and cached. No view in this feature should read
    /// NSWorkspace.shared.accessibilityDisplayShouldReduceMotion (or
    /// ...ReduceTransparency) directly; both flow through here.
    var reducedMotion: Bool
    var reducedTransparency: Bool

    // MARK: - Seasonal / solar layer

    /// The dominant season and the continuous weights behind the tint. The
    /// weights always sum to 1.0; two seasons share the scene near a boundary.
    var season: SeasonalPeriod
    var seasonalWeights: [SeasonalPeriod: Double]

    /// Seasonal tint and the opacity of the full-screen grade drawn by the
    /// background. The palette has already been lightly tinted; this overlay
    /// is the visible seasonal temperature.
    var seasonalTint: EnvironmentColor
    var seasonalTintStrength: Double
    var seasonalParticleIntensity: Double

    /// How deep into the dominant season this snapshot sits (0 at its edge,
    /// 1 at its peak) and the named third. The background renders the already
    /// scaled values; the Studio reads these to explain what it is showing.
    var seasonalMaturity: Double
    var seasonalPhase: SeasonalPhase

    /// Real sunrise/sunset/solar-noon for the cached coordinate, or `.fixed`
    /// when no coordinate is available.
    var solarDaylight: SolarDaylight

    /// The wall-clock minute that produced this snapshot. `minuteOfDay` is the
    /// palette minute: it equals this value when no coordinate is available,
    /// and is stretched onto the fixed day track when one is.
    var clockMinuteOfDay: Double

    /// Honest provenance for the weather layer: live fetch, recent persisted
    /// capture, older capture, no capture, or a studio override.
    var weatherFreshness: WeatherFreshness

    /// Moving celestial glow color/opacity. Position comes from
    /// `solarDaylight.glowX/glowY`.
    var celestialGlowColor: EnvironmentColor
    var celestialGlowOpacity: Double

    /// A safe default used only before the engine's first real computation
    /// completes (the engine's init computes a real value synchronously, so
    /// in practice this is visible for well under a frame).
    static let fallback = EnvironmentState(
        currentAnchorBlend: [.night: 1.0],
        backgroundGradient: EnvironmentPalette.night.gradientStops,
        ambientLightColor: EnvironmentPalette.night.ambientLightColor,
        shadowIntensity: EnvironmentPalette.night.shadowIntensity,
        blurIntensity: EnvironmentPalette.night.blurIntensity,
        atmosphericOpacity: EnvironmentPalette.night.atmosphericOpacity,
        starVisibility: EnvironmentPalette.night.starVisibility,
        nightIntensity: EnvironmentPalette.night.nightIntensity,
        weatherModifier: .neutral,
        weatherVisual: .clear,
        minuteOfDay: 0,
        readabilityScrim: 0,
        reducedMotion: false,
        reducedTransparency: false,
        season: .winter,
        seasonalWeights: [.winter: 1.0],
        seasonalTint: EnvironmentColor(hex: "#9CB6D9"),
        seasonalTintStrength: 0.0,
        seasonalParticleIntensity: 0.0,
        seasonalMaturity: 1.0,
        seasonalPhase: .prime,
        solarDaylight: .fixed,
        clockMinuteOfDay: 0.0,
        weatherFreshness: .unavailable,
        celestialGlowColor: EnvironmentPalette.night.ambientLightColor,
        celestialGlowOpacity: 0.55
    )

    /// Perceived luminance of the rendered gradient (0 = black, 1 = white).
    /// Used for the readability scrim and the studio readout.
    var gradientLuminance: Double {
        guard !backgroundGradient.isEmpty else { return 0 }
        let total = backgroundGradient.reduce(0.0) { partial, stop in
            let color = stop.color
            return partial + color.red * 0.2126 + color.green * 0.7152 + color.blue * 0.0722
        }
        return total / Double(backgroundGradient.count)
    }
}
