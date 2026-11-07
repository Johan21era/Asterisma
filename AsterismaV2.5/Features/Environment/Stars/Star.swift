//  Star.swift
//  AsterismaV2.5
//
//  Environment Engine — Phase C (Part 6.1 of the build spec)
//
//  A single star's identity and animation parameters. Position is
//  resolution-independent (fractional 0...1 within the visible star-field
//  area) so the field regenerates cleanly at any window size.
//

import CoreGraphics
import Foundation

struct Star: Identifiable, Sendable {
    let id: UUID

    /// Fractional position within the star field's bounds, 0...1 on each axis.
    let relativePosition: CGPoint

    /// Base brightness before twinkle oscillation is applied, 0...1.
    let baseBrightness: Double

    let radius: CGFloat
    let color: EnvironmentColor

    /// Seconds per full twinkle cycle — randomized 3-9s per Part 6.1.
    let twinklePeriod: Double

    /// Radians, randomized 0...2π so no two stars are ever synchronized.
    let twinklePhase: Double

    /// Oscillation amplitude around baseBrightness — randomized ±15-25%,
    /// per Part 6.1 ("not 0-100%; this is what keeps it calm").
    let twinkleAmplitude: Double

    /// Brightness at a given elapsed time (seconds since the star field's
    /// own reference epoch), before `starVisibility` is applied by the
    /// rendering layer. A pure time-based function of `elapsedSeconds` —
    /// no discrete state mutation, no per-star Timer — per Part 6.3.
    func brightness(at elapsedSeconds: Double) -> Double {
        let angle = (2 * Double.pi / twinklePeriod) * elapsedSeconds + twinklePhase
        let oscillation = sin(angle) * twinkleAmplitude
        return EnvironmentMath.clampUnit(baseBrightness + oscillation)
    }
}
