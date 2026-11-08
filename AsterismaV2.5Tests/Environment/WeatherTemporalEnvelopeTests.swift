//  WeatherTemporalEnvelopeTests.swift
//  AsterismaV2.5Tests
//
//  Pins the 2026-11-08 precipitation envelope:
//    • a new event ramps in from the floor,
//    • a two-hour pass visibly weakens and strengthens,
//    • every value stays inside the documented bounds,
//    • only the drawn intensity changes — kind, wind, cloud, and provenance
//      are untouched.

import Foundation
import Testing
@testable import AsterismaV2_5

@Suite("Environment — precipitation envelope")
struct WeatherTemporalEnvelopeTests {

    private func multiplier(_ minutes: Double) -> Double {
        WeatherTemporalEnvelope.multiplier(elapsed: minutes * 60)
    }

    @Test("a precipitation event ramps in and then breathes")
    func eventRampsAndBreathes() {
        #expect(multiplier(0) < 0.6)
        #expect(multiplier(10) > multiplier(0) + 0.15)

        var samples: [Double] = []
        for minute in stride(from: 0.0, through: 120.0, by: 2.0) {
            samples.append(multiplier(minute))
        }
        let low = samples.min() ?? 0
        let high = samples.max() ?? 0

        #expect(low >= WeatherTemporalEnvelope.minimumMultiplier - 0.0001)
        #expect(high <= WeatherTemporalEnvelope.maximumMultiplier + 0.0001)
        #expect(high - low >= 0.25,
                "a two-hour pass should visibly weaken and strengthen")
    }

    @Test("the envelope only changes intensity")
    func envelopeOnlyChangesIntensity() {
        let base = WeatherVisual.forced(.rain, intensity: 0.8)
        let evolved = base.applyingIntensityMultiplier(0.6)

        #expect(abs(evolved.intensity - 0.48) < 0.0001)
        #expect(evolved.kind == base.kind)
        #expect(evolved.wind == base.wind)
        #expect(evolved.cloud == base.cloud)
        #expect(evolved.isLive == base.isLive)
    }
}
