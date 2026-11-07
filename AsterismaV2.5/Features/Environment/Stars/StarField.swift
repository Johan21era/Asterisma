//  StarField.swift
//  AsterismaV2.5
//  Environment Engine — Phase C (Parts 6.1, 6.2 of the build spec)
//
//  Generates a star field for a given area, matching the density and color
//  distribution from Part 6.2. Pure data — knows nothing about rendering,
//  EnvironmentState, or the wall clock.
//

import CoreGraphics
import Foundation

struct StarField: Sendable {
    let stars: [Star]

    /// One star per ~4,000-6,000 sq pt (Part 6.2), clamped to a sane
    /// min/max regardless of window size — deliberately far sparser than
    /// the reference photo's literal star density, which Part 5.4/6.2 are
    /// both explicit is a color/mood reference only, not a density target.
    private static let squarePointsPerStar: Double = 5000
    private static let minimumStarCount = 40
    private static let maximumStarCount = 400

    /// Night's star color distribution from Part 5.4.
    private static let colorDistribution: [(weight: Double, hex: String)] = [
        (0.90, "#F5EFDD"), // warm white/cream
        (0.05, "#BFD7FF"), // pale blue-white
        (0.03, "#E8C77A"), // faint gold
        (0.02, "#E9AFDA"), // faint magenta/pink
    ]

    static func generate(for size: CGSize, seed: UInt64 = 0) -> StarField {
        guard size.width > 0, size.height > 0 else { return StarField(stars: []) }

        let area = Double(size.width) * Double(size.height)
        let targetCount = area / squarePointsPerStar
        let count = Int(EnvironmentMath.clamp(
            targetCount,
            to: Double(minimumStarCount)...Double(maximumStarCount)
        ))

        var generator = SeededGenerator(seed: seed == 0 ? UInt64(Date().timeIntervalSince1970) : seed)

        let stars: [Star] = (0..<count).map { _ in
            Star(
                id: UUID(),
                relativePosition: CGPoint(
                    x: Double.random(in: 0...1, using: &generator),
                    y: Double.random(in: 0...1, using: &generator)
                ),
                baseBrightness: Double.random(in: 0.55...1.0, using: &generator),
                radius: CGFloat.random(in: 0.6...1.8, using: &generator),
                color: weightedColor(using: &generator),
                twinklePeriod: Double.random(in: 3...9, using: &generator),
                twinklePhase: Double.random(in: 0...(2 * Double.pi), using: &generator),
                twinkleAmplitude: Double.random(in: 0.15...0.25, using: &generator)
            )
        }
        return StarField(stars: stars)
    }

    private static func weightedColor(using generator: inout SeededGenerator) -> EnvironmentColor {
        let roll = Double.random(in: 0...1, using: &generator)
        var cumulative = 0.0
        for entry in colorDistribution {
            cumulative += entry.weight
            if roll <= cumulative {
                return EnvironmentColor(hex: entry.hex)
            }
        }
        return EnvironmentColor(hex: colorDistribution[0].hex)
    }
}
