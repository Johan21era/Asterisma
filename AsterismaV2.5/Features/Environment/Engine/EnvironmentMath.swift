//  EnvironmentMath.swift
//  AsterismaV2.5
//
//  Environment Engine — Phase B (Part 5 of the build spec)
//
//  Small numeric helpers shared across the Environment Engine, Star System,
//  and Shooting Star System. Namespaced under an enum (rather than global
//  functions or protocol extensions on Double/Comparable) specifically to
//  avoid any chance of colliding with a same-named helper elsewhere in this
//  56-file project. Phase A confirmed no existing "clamp"/"lerp"/"smoothstep"
//  helper exists anywhere in the codebase, so this is safe to introduce.
//

import Foundation

nonisolated enum EnvironmentMath {

    static func clampUnit(_ value: Double) -> Double {
        min(max(value, 0.0), 1.0)
    }

    static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    static func lerp(_ a: Double, _ b: Double, _ fraction: Double) -> Double {
        a + (b - a) * clampUnit(fraction)
    }

    /// Labeled convenience for the presentation layer. The original positional
    /// form is retained because the palette and weather math use it.
    static func lerp(_ a: Double, _ b: Double, fraction: Double) -> Double {
        lerp(a, b, fraction)
    }

    /// Classic cubic smoothstep: eases a raw 0...1 fraction so interpolation
    /// accelerates away from and decelerates into each keyframe. Part 5.3
    /// specifically asks for "a smoothstep-style ease," not a linear blend.
    static func smoothstep(_ rawFraction: Double) -> Double {
        let t = clampUnit(rawFraction)
        return t * t * (3.0 - 2.0 * t)
    }
}

/// A tiny deterministic PRNG (splitmix64) used by the Star System and
/// Shooting Star System so a field can optionally be regenerated identically
/// (e.g. for previews) instead of always reseeding from the wall clock.
/// Declared here rather than per-file since both systems need it.
nonisolated struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        // splitmix64 degenerates for a seed of exactly 0; nudge it off zero.
        self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
