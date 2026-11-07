//  EnvironmentPalette.swift
//  AsterismaV2.5
//
//  Environment Engine — Phase B (Parts 5.3, 5.4, 5.5 of the build spec)
//
//  Palette source mapping (see the ambiguity note in this session's chat
//  response for the reasoning — this is the resolved, current mapping):
//    Night     ← starfield reference photo
//    Morning   ← sunrise gradient reference photo (START-STATE only)
//    Midday    ← synthesized, no reference photo (Part 5.4 is explicit
//                about this) — also doubles as Afternoon's START-STATE
//    Afternoon ← blue-hour lake reference photo (END-STATE only, reached
//                by 19:30, never the 13:00 starting condition)
//
//  Every snapshot below uses exactly 5 gradient stops at the same fixed
//  positions (0, 0.25, 0.5, 0.75, 1.0). That's a deliberate, load-bearing
//  design choice: it's what makes EnvironmentPaletteSnapshot.blend()
//  well-defined between any two snapshots — stop N always blends with
//  stop N, never a different count/order to reconcile.
//
//  Owner feedback 2026-10-29: the morning, midday, and afternoon-reference
//  snapshots were pale enough that white text and thin chrome vanished over
//  them. Those three snapshots are now the SAME reference hues, deepened into
//  their shadow range; the engine also adds a luminance-derived readability
//  scrim on top, so contrast no longer depends on the wallpaper being dark.
//

import Foundation

// MARK: - EnvironmentPaletteSnapshot

/// A single named palette snapshot — one "keyframe" the Environment Engine
/// interpolates from or toward.
struct EnvironmentPaletteSnapshot: Sendable, Equatable {
    var gradientStops: [EnvironmentGradientStop]
    var ambientLightColor: EnvironmentColor
    var shadowIntensity: Double
    var blurIntensity: Double
    var atmosphericOpacity: Double
    var starVisibility: Double
    var nightIntensity: Double

    /// Component-wise eased blend between two snapshots. `fraction` must
    /// already be eased by the caller (see `EnvironmentMath.smoothstep`) —
    /// this performs a plain linear blend using whatever fraction it's given.
    static func blend(_ a: EnvironmentPaletteSnapshot, _ b: EnvironmentPaletteSnapshot, fraction: Double) -> EnvironmentPaletteSnapshot {
        precondition(
            a.gradientStops.count == b.gradientStops.count,
            "EnvironmentPaletteSnapshot.blend requires matching stop counts — every named snapshot in EnvironmentPalette must use the same fixed 5-stop layout."
        )
        let t = EnvironmentMath.clampUnit(fraction)
        let stops = zip(a.gradientStops, b.gradientStops).map { sa, sb in
            EnvironmentGradientStop(
                color: sa.color.lerp(to: sb.color, fraction: t),
                location: EnvironmentMath.lerp(sa.location, sb.location, t)
            )
        }
        return EnvironmentPaletteSnapshot(
            gradientStops: stops,
            ambientLightColor: a.ambientLightColor.lerp(to: b.ambientLightColor, fraction: t),
            shadowIntensity: EnvironmentMath.lerp(a.shadowIntensity, b.shadowIntensity, t),
            blurIntensity: EnvironmentMath.lerp(a.blurIntensity, b.blurIntensity, t),
            atmosphericOpacity: EnvironmentMath.lerp(a.atmosphericOpacity, b.atmosphericOpacity, t),
            starVisibility: EnvironmentMath.lerp(a.starVisibility, b.starVisibility, t),
            nightIntensity: EnvironmentMath.lerp(a.nightIntensity, b.nightIntensity, t)
        )
    }
}

// MARK: - EnvironmentPalette

enum EnvironmentPalette {

    // MARK: Named snapshots (Part 5.4)

    /// Night — from the starfield reference photo. Held flat across its
    /// whole window (see `keyframeTrack`) since Appendix A describes stars
    /// as "remaining largely static," not evolving the way Morning/Afternoon do.
    /// ambientLightColor is Part 5.4's explicit edge/border glow value,
    /// rendered by EnvironmentBackgroundView as a soft radial overlay —
    /// not baked into these linear stops.
    static let night = EnvironmentPaletteSnapshot(
        gradientStops: [
            EnvironmentGradientStop(color: EnvironmentColor(hex: "#0B0E18"), location: 0.0),
            EnvironmentGradientStop(color: EnvironmentColor(hex: "#06060B"), location: 0.25),
            EnvironmentGradientStop(color: EnvironmentColor(hex: "#06060B"), location: 0.5),
            EnvironmentGradientStop(color: EnvironmentColor(hex: "#06060B"), location: 0.75),
            EnvironmentGradientStop(color: EnvironmentColor(hex: "#0B0E18"), location: 1.0),
        ],
        ambientLightColor: EnvironmentColor(hex: "#131B33"),
        shadowIntensity: 0.85,
        blurIntensity: 0.6,
        atmosphericOpacity: 0.5,
        starVisibility: 1.0,
        nightIntensity: 1.0
    )

    /// Morning START-STATE — from the sunrise gradient reference photo.
    /// Part 5.4 is explicit this is only the beginning of the Morning
    /// window, never held flat across 06:00-12:00.
    /// ambientLightColor reuses this snapshot's own pale-gold stop rather
    /// than inventing a new, untraceable hex value.
    static let morningStart = EnvironmentPaletteSnapshot(
        gradientStops: [
            EnvironmentGradientStop(color: EnvironmentColor(hex: "#6F93AC"), location: 0.0),
            EnvironmentGradientStop(color: EnvironmentColor(hex: "#C7A472"), location: 0.25),
            EnvironmentGradientStop(color: EnvironmentColor(hex: "#B87C5A"), location: 0.5),
            EnvironmentGradientStop(color: EnvironmentColor(hex: "#9E645C"), location: 0.75),
            EnvironmentGradientStop(color: EnvironmentColor(hex: "#74505F"), location: 1.0),
        ],
        ambientLightColor: EnvironmentColor(hex: "#C7A472"),
        shadowIntensity: 0.15,
        blurIntensity: 0.2,
        atmosphericOpacity: 0.15,
        starVisibility: 0.0,
        nightIntensity: 0.0
    )

    /// Midday — synthesized (Part 5.4: "no reference photo covers this
    /// state"), derived from Appendix A's "balanced slate blues, warm gray
    /// tones, soft beige colors." The 3 named colors are mapped across the
    /// fixed 5-stop layout by lerping the *given* colors at the midpoints —
    /// no new, invented hex values, just interpolations of the three Part
    /// 5.4 gives. Also serves as Afternoon's START-STATE (see
    /// `afternoonStart` below) since Part 5.5 defines Afternoon's start as
    /// exactly this meeting point, with no independent hex set of its own.
    static let midday: EnvironmentPaletteSnapshot = {
        let slateBlue = EnvironmentColor(hex: "#4C6076")
        let warmGray = EnvironmentColor(hex: "#6E726C")
        let softBeige = EnvironmentColor(hex: "#9C907C")
        return EnvironmentPaletteSnapshot(
            gradientStops: [
                EnvironmentGradientStop(color: slateBlue, location: 0.0),
                EnvironmentGradientStop(color: slateBlue.lerp(to: warmGray, fraction: 0.5), location: 0.25),
                EnvironmentGradientStop(color: warmGray, location: 0.5),
                EnvironmentGradientStop(color: warmGray.lerp(to: softBeige, fraction: 0.5), location: 0.75),
                EnvironmentGradientStop(color: softBeige, location: 1.0),
            ],
            ambientLightColor: softBeige,
            shadowIntensity: 0.35,
            blurIntensity: 0.3,
            atmosphericOpacity: 0.25,
            starVisibility: 0.0,
            nightIntensity: 0.0
        )
    }()

    /// Afternoon's START-STATE is, by Part 5.5's own definition, the Midday
    /// meeting point — there is no independent hex set for it in Part 5.4.
    static var afternoonStart: EnvironmentPaletteSnapshot { midday }

    /// Afternoon END-STATE — from the blue-hour lake reference photo. Part
    /// 5.4 is explicit this is where the Afternoon window *arrives* by
    /// 19:30, never its starting condition at 13:00.
    static let afternoonEnd = EnvironmentPaletteSnapshot(
        gradientStops: [
            EnvironmentGradientStop(color: EnvironmentColor(hex: "#2C343C"), location: 0.0),
            EnvironmentGradientStop(color: EnvironmentColor(hex: "#56697F"), location: 0.25),
            EnvironmentGradientStop(color: EnvironmentColor(hex: "#B9B4AC"), location: 0.5),
            EnvironmentGradientStop(color: EnvironmentColor(hex: "#C79C97"), location: 0.75),
            EnvironmentGradientStop(color: EnvironmentColor(hex: "#8E6C6B"), location: 1.0),
        ],
        ambientLightColor: EnvironmentColor(hex: "#C79C97"),
        shadowIntensity: 0.7,
        blurIntensity: 0.5,
        atmosphericOpacity: 0.45,
        starVisibility: 0.15,
        nightIntensity: 0.0
    )

    // MARK: Keyframe track (Part 5.5's six keyframe pairs)

    struct TimedKeyframe {
        /// Minutes since local midnight, 0...1440. 1440 duplicates the
        /// minute-0 snapshot so the wraparound needs no special-cased branch.
        let minute: Double
        let snapshot: EnvironmentPaletteSnapshot
    }

    /// Sorted ascending, spanning the full 24h cycle inclusive of both
    /// endpoints. Every minute of the day falls between exactly two of
    /// these (cyclically), and every gap is walked with the *same* eased-
    /// interpolation code in EnvironmentEngine — including the two "flat"
    /// gaps (Night holding overnight, and the 12:00-13:00 Midday crossing
    /// point), which are flat only because their two endpoints happen to
    /// hold equal snapshot values, not because of any special-cased branch.
    /// This directly satisfies Part 5.3's "not if/else time-range branching"
    /// requirement, and Part 5.2's "no hour of the day is undefined."
    ///
    /// Segment → Part 5.5 keyframe pair mapping:
    ///   0    →345  (00:00–05:45)  Night held flat
    ///   345  →360  (05:45–06:00)  blend zone 1: Night end → Morning start
    ///   360  →720  (06:00–12:00)  Morning's own arc → Midday
    ///   720  →780  (12:00–13:00)  blend zone 2: Midday crossing point (flat — both ends equal `midday`)
    ///   780  →1170 (13:00–19:30)  Afternoon's own arc: Midday → Afternoon end
    ///   1170→1185  (19:30–19:45)  blend zone 3: Afternoon end → Night
    ///   1185→1440  (19:45–24:00)  Night held flat (closes the loop)
    static let keyframeTrack: [TimedKeyframe] = [
        TimedKeyframe(minute: 0, snapshot: night),
        TimedKeyframe(minute: 345, snapshot: night),
        TimedKeyframe(minute: 360, snapshot: morningStart),
        TimedKeyframe(minute: 720, snapshot: midday),
        TimedKeyframe(minute: 780, snapshot: afternoonStart),
        TimedKeyframe(minute: 1170, snapshot: afternoonEnd),
        TimedKeyframe(minute: 1185, snapshot: night),
        TimedKeyframe(minute: 1440, snapshot: night),
    ]
}
