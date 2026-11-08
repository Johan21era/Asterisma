//  SeasonalEnvironment.swift
//  AsterismaV2.5
//
//  Environment Engine — seasonal grading.
//
//  Season is a continuous field, not a switch that flips on the first of the
//  month. Four cosine lobes, one per season, peak at the solstices/equinoxes
//  and are normalized at every instant. Near a boundary two seasons each hold
//  roughly half the weight, so the tint and the seasonal particles cross-fade
//  exactly the way the time-of-day palette does.
//
//  The grade deliberately does not replace the time-of-day palette. It applies
//  a small tint to the ambient light and gradient, and exposes the tint for a
//  separate low-opacity overlay. The existing Morning/Midday/Afternoon/Night
//  identity stays intact; what changes is its temperature and air across the
//  year.
//
//  Hemisphere comes from the cached coordinate's latitude. Without a
//  coordinate the calendar still produces a northern-hemisphere season; the
//  fixed daylight track is a separate fallback in SolarDaylight.
//
//  Within the dominant season, maturity measures distance from that season's
//  own peak. Mid-December is prime winter at full seasonal air; late November
//  is early winter and late January is late winter, both at a fraction. The
//  phase is named, not just numeric, so the Studio can pin it directly.

import Foundation

nonisolated enum SeasonalPhase: String, CaseIterable, Identifiable, Sendable {
    case early
    case prime
    case late

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .early: return "Early"
        case .prime: return "Prime"
        case .late: return "Late"
        }
    }

    /// "Prime winter", "early autumn", and so on.
    func label(for season: SeasonalPeriod) -> String {
        "\(displayName) \(season.rawValue)"
    }
}

nonisolated struct SeasonalGrade: Sendable, Equatable {

    /// Normalized season weights. Keys always sum to 1.0.
    var weights: [SeasonalPeriod: Double]

    /// Weighted seasonal tint. Spring is new green, summer warm gold, autumn
    /// amber-rust, winter cool blue.
    var tint: EnvironmentColor

    /// Opacity of the separate tint overlay, and the amount blended into the
    /// ambient light. Kept small so the hour of day still leads.
    var tintStrength: Double

    /// Additive atmosphere and star adjustments. Winter clears the air and
    /// lifts the stars; autumn adds a little haze; spring/summer are nearly
    /// neutral.
    var atmosphericLift: Double
    var starLift: Double

    /// Multiplier for SeasonalAtmosphereView. 0...1.
    var particleIntensity: Double

    /// How deep into the dominant season the date sits: 0 at the season's
    /// edge, 1 at its peak. This is the "prime winter" scale.
    var maturity: Double

    /// Named third of the dominant season.
    var phase: SeasonalPhase

    /// Visual strength scale applied to seasonal air and particles. Seasons
    /// ramp in and out instead of switching on at full strength.
    var effectScale: Double {
        Self.effectScale(forMaturity: maturity)
    }

    static func effectScale(forMaturity maturity: Double) -> Double {
        0.5 + 0.5 * EnvironmentMath.clampUnit(maturity)
    }

    var dominantSeason: SeasonalPeriod {
        weights.max(by: { $0.value < $1.value })?.key ?? .spring
    }

    /// Applies the subtle palette half of the grade. The overlay half is drawn
    /// by EnvironmentBackgroundView from `tint` + `tintStrength`.
    func apply(to snapshot: EnvironmentPaletteSnapshot) -> EnvironmentPaletteSnapshot {
        guard tintStrength > 0.001 else { return snapshot }
        var result = snapshot
        result.ambientLightColor = snapshot.ambientLightColor.lerp(
            to: tint, fraction: tintStrength * 0.55)
        result.atmosphericOpacity = EnvironmentMath.clampUnit(
            snapshot.atmosphericOpacity + atmosphericLift)
        // Season is tertiary. Scale the lift against the already-composed
        // time + weather star field so winter cannot create stars in a
        // daylight palette or cancel a cloud cover's reduction outright.
        result.starVisibility = EnvironmentMath.clampUnit(
            snapshot.starVisibility + starLift * snapshot.starVisibility)
        result.gradientStops = snapshot.gradientStops.map { stop in
            EnvironmentGradientStop(
                color: stop.color.lerp(to: tint, fraction: tintStrength * 0.20),
                location: stop.location)
        }
        return result
    }
}

nonisolated enum SeasonalCalendar {

    private struct Profile {
        let tint: EnvironmentColor
        let tintStrength: Double
        let atmosphericLift: Double
        let starLift: Double
        let particleIntensity: Double
        let peakDay: Double
    }

    /// Peak days are the astronomical season boundaries: spring equinox
    /// (~day 80), summer solstice (~172), autumn equinox (~266), winter
    /// solstice (~355). The cosine lobes are widest at the equinoxes, which is
    /// why adjacent seasons overlap there.
    private static let profiles: [SeasonalPeriod: Profile] = [
        .spring: Profile(
            tint: EnvironmentColor(hex: "#7FB7A0"),
            tintStrength: 0.10,
            atmosphericLift: 0.02,
            starLift: -0.02,
            particleIntensity: 0.55,
            peakDay: 80),
        .summer: Profile(
            tint: EnvironmentColor(hex: "#E7B56A"),
            tintStrength: 0.12,
            atmosphericLift: 0.00,
            starLift: 0.00,
            particleIntensity: 0.45,
            peakDay: 172),
        .autumn: Profile(
            tint: EnvironmentColor(hex: "#C98A5E"),
            tintStrength: 0.14,
            atmosphericLift: 0.03,
            starLift: 0.02,
            particleIntensity: 0.80,
            peakDay: 266),
        .winter: Profile(
            tint: EnvironmentColor(hex: "#9CB6D9"),
            tintStrength: 0.12,
            atmosphericLift: 0.02,
            starLift: 0.08,
            particleIntensity: 0.65,
            peakDay: 355),
    ]

    /// Days either side of a season's peak that count as its prime window.
    /// Mid-December is prime winter; a month earlier is early winter.
    private static let primeWindowDays = 18.0

    /// Distance from the peak at which a season's visual scale reaches its
    /// floor. Early and late seasons keep a share of their effect air rather
    /// than dropping to nothing at the calendar boundary.
    private static let maturitySpanDays = 48.0

    private static let earlyMaturity = 0.30
    private static let primeMaturity = 1.0
    private static let lateMaturity = 0.50

    /// The continuous grade for a date. `forced` is the Debug studio's
    /// exclusive season: it returns one season at full weight so every state
    /// can be inspected without waiting for the calendar.
    static func grade(
        for date: Date,
        calendar: Calendar = .current,
        latitude: Double,
        forced: SeasonalPeriod? = nil,
        forcedPhase: SeasonalPhase? = nil
    ) -> SeasonalGrade {
        if let forced {
            let phase = forcedPhase ?? .prime
            return grade(
                for: [forced: 1.0],
                amplitude: 1.0,
                maturity: representativeMaturity(for: phase),
                phase: phase)
        }

        let day = Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 1)
        let southern = latitude < 0.0
        var raw: [SeasonalPeriod: Double] = [:]

        for (season, profile) in profiles {
            var peak = profile.peakDay
            if southern { peak += 182.5 }
            let delta = shortestDayDelta(day, peak)
            raw[season] = max(0.0, cos(delta / 365.25 * 2.0 * Double.pi))
        }

        let total = raw.values.reduce(0.0, +)
        let weights: [SeasonalPeriod: Double]
        if total > 0.0001 {
            weights = raw.mapValues { $0 / total }
        } else {
            weights = [.spring: 1.0]
        }

        // Seasonality is physically weaker near the equator. The grade still
        // exists there, but at about a third of its mid-latitude strength.
        let amplitude = min(1.0, max(0.35, abs(latitude) / 60.0))

        // Maturity belongs to the dominant season only. A boundary date still
        // has a season label and a weight blend; what it does not have is the
        // full air and particle strength of that season's peak.
        let dominant = weights.max(by: { $0.value < $1.value })?.key ?? .spring
        let peak = peakDay(for: dominant, southern: southern)
        let delta = shortestDayDelta(day, peak)
        let maturity = forcedPhase.map(representativeMaturity) ?? derivedMaturity(delta)
        let phase = forcedPhase ?? phase(forDelta: delta)

        return grade(
            for: weights,
            amplitude: amplitude,
            maturity: maturity,
            phase: phase)
    }

    private static func grade(
        for weights: [SeasonalPeriod: Double],
        amplitude: Double,
        maturity: Double,
        phase: SeasonalPhase
    ) -> SeasonalGrade {
        var tint = EnvironmentColor(red: 0.0, green: 0.0, blue: 0.0)
        var tintStrength = 0.0
        var atmosphericLift = 0.0
        var starLift = 0.0
        var particleIntensity = 0.0

        for (season, weight) in weights {
            guard let profile = profiles[season] else { continue }
            tint = EnvironmentColor(
                red: tint.red + profile.tint.red * weight,
                green: tint.green + profile.tint.green * weight,
                blue: tint.blue + profile.tint.blue * weight)
            tintStrength += profile.tintStrength * weight
            atmosphericLift += profile.atmosphericLift * weight
            starLift += profile.starLift * weight
            particleIntensity += profile.particleIntensity * weight
        }

        // Season is tertiary, so its air and particles scale with maturity
        // rather than with the calendar label alone. The tint stays at the
        // blended seasonal identity; only the effect strength breathes.
        let effectScale = SeasonalGrade.effectScale(forMaturity: maturity)
        return SeasonalGrade(
            weights: weights,
            tint: tint,
            tintStrength: tintStrength * amplitude,
            atmosphericLift: atmosphericLift * amplitude * effectScale,
            starLift: starLift * amplitude * effectScale,
            particleIntensity: particleIntensity * amplitude * effectScale,
            maturity: EnvironmentMath.clampUnit(maturity),
            phase: phase)
    }

    private static func peakDay(for season: SeasonalPeriod, southern: Bool) -> Double {
        let base = profiles[season]?.peakDay ?? 80.0
        return southern ? base + 182.5 : base
    }

    /// Maturity falls linearly from 1 at the peak to 0 at the edge of the
    /// effect window. It is deliberately independent of the weight blend: a
    /// date can be fully winter by weight while still early in its air.
    private static func derivedMaturity(_ delta: Double) -> Double {
        EnvironmentMath.clampUnit(1.0 - abs(delta) / maturitySpanDays)
    }

    private static func phase(forDelta delta: Double) -> SeasonalPhase {
        if delta < -primeWindowDays { return .early }
        if delta > primeWindowDays { return .late }
        return .prime
    }

    private static func representativeMaturity(for phase: SeasonalPhase) -> Double {
        switch phase {
        case .early: return earlyMaturity
        case .prime: return primeMaturity
        case .late: return lateMaturity
        }
    }

    /// Shortest signed distance between two day-of-year values, in days.
    private static func shortestDayDelta(_ day: Double, _ peak: Double) -> Double {
        var delta = (day - peak).truncatingRemainder(dividingBy: 365.25)
        if delta > 182.625 { delta -= 365.25 }
        if delta < -182.625 { delta += 365.25 }
        return delta
    }
}
