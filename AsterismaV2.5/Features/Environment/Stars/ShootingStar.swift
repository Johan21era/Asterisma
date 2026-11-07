//  ShootingStar.swift
//  Environment Engine — Phase D (Part 7 of the build spec)
//
//  A single shooting star's fully-randomized trajectory. Every value below
//  is independently randomized per spawn: edge spawn position, direction,
//  trajectory length, velocity (expressed via duration + length), brightness,
//  fade rate, and total duration.
//

import CoreGraphics
import Foundation

struct ShootingStar: Identifiable, Sendable {
    let id: UUID

    /// Wall-clock moment this star was spawned — lets the rendering layer
    /// compute real elapsed-time progress rather than faking a static streak.
    let spawnDate: Date

    /// Fractional start point, 0...1, always along an upper edge.
    let start: CGPoint

    /// Fractional end point, 0...1 — derived from start + direction + length
    /// at spawn time, then stored explicitly so rendering never repeats trig.
    let end: CGPoint

    let brightness: Double

    /// Total transit duration, seconds. A natural feel is usually 0.6-1.4s
    /// (Part 7), tunable via this random range.
    let duration: Double

    /// How much of the back portion of the transit is spent fading out,
    /// 0...1 — higher values mean a longer fade tail.
    let fadeRate: Double

    static func randomized(fieldSize: CGSize, using generator: inout SeededGenerator, spawnDate: Date = Date()) -> ShootingStar {
        // Spawn from the top edge (most common) or the upper portion of a
        // side edge — a shooting star climbing up from the bottom edge
        // would read as visually wrong.
        let edgeRoll = Int.random(in: 0...9, using: &generator)
        let start: CGPoint
        switch edgeRoll {
        case 0...5: // top edge
            start = CGPoint(x: Double.random(in: 0...1, using: &generator), y: 0)
        case 6...7: // left edge, upper half
            start = CGPoint(x: 0, y: Double.random(in: 0...0.5, using: &generator))
        default: // right edge, upper half
            start = CGPoint(x: 1, y: Double.random(in: 0...0.5, using: &generator))
        }

        // Direction: generally downward and inward (toward center), so
        // trails read as falling rather than as random noise.
        let angleDegrees = Double.random(in: 20...55, using: &generator)
        let angle = angleDegrees * Double.pi / 180
        let horizontalSign: Double = start.x < 0.5 ? 1 : -1
        let length = Double.random(in: 0.18...0.38, using: &generator) // fraction of field diagonal

        let dx = cos(angle) * length * horizontalSign
        let dy = sin(angle) * length

        let end = CGPoint(
            x: EnvironmentMath.clamp(start.x + dx, to: -0.1...1.1),
            y: EnvironmentMath.clamp(start.y + dy, to: -0.1...1.1)
        )

        return ShootingStar(
            id: UUID(),
            spawnDate: spawnDate,
            start: start,
            end: end,
            brightness: Double.random(in: 0.7...1.0, using: &generator),
            duration: Double.random(in: 0.6...1.4, using: &generator),
            fadeRate: Double.random(in: 0.4...0.75, using: &generator)
        )
    }
}
