//  SeasonalAtmosphereView.swift
//  AsterismaV2.5
//
//  The seasonal companion to WeatherEffectView. Time-of-day gives the palette
//  its hour; weather gives it precipitation; season gives the air its small,
//  slow inhabitants:
//
//      spring  — petals / pollen drifting upward
//      summer  — fireflies at night, faint pollen by day
//      autumn  — leaves falling and drifting sideways
//      winter  — frost motes hanging in the cold
//
//  Every layer is weighted by the engine's continuous season weights, so the
//  seasons cross-fade instead of switching on a date. All motion is a pure
//  function of elapsed time and a fixed per-index seed: the same state renders
//  the same frame, and reduced motion freezes a single frame.
//
//  The layer stays deliberately faint. It sits above the stars and below the
//  weather, so rain/snow always read as foreground. Heavy precipitation scales
//  it down rather than piling two particle systems on top of each other.

import SwiftUI

struct SeasonalAtmosphereView: View {
    let weights: [SeasonalPeriod: Double]
    let intensity: Double
    let nightIntensity: Double
    let reducedMotion: Bool
    let elapsed: Double
    let weatherAttenuation: Double

    var body: some View {
        Canvas { context, size in
            draw(
                at: reducedMotion ? 0.0 : elapsed,
                into: &context, size: size)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(
        at elapsed: Double,
        into context: inout GraphicsContext,
        size: CGSize
    ) {
        guard size.width > 1.0, size.height > 1.0 else { return }
        let visible = min(1.0, max(0.0, intensity))
        guard visible > 0.01 else { return }

        let scale = visible * EnvironmentMath.clampUnit(weatherAttenuation)
        for (season, weight) in weights {
            guard weight > 0.01 else { continue }
            let opacity = weight * scale
            switch season {
            case .spring:
                drawSpring(at: elapsed, opacity: opacity, into: &context, size: size)
            case .summer:
                drawSummer(at: elapsed, opacity: opacity, into: &context, size: size)
            case .autumn:
                drawAutumn(at: elapsed, opacity: opacity, into: &context, size: size)
            case .winter:
                drawWinter(at: elapsed, opacity: opacity, into: &context, size: size)
            }
        }
    }

    // MARK: - Spring

    private func drawSpring(
        at elapsed: Double,
        opacity: Double,
        into context: inout GraphicsContext,
        size: CGSize
    ) {
        let count = 14
        for index in 0..<count {
            let seed = noise(index, 3.0)
            let speed = 0.006 + seed * 0.010
            let x = wrapped(noise(index, 7.0) + elapsed * speed * 0.6) * size.width
            let y = wrapped(noise(index, 11.0) - elapsed * speed) * size.height
            let width = 1.4 + seed * 2.4
            let height = width * 0.55
            let alpha = opacity * (0.18 + seed * 0.22)
            context.fill(
                Path(ellipseIn: CGRect(x: x, y: y, width: width, height: height)),
                with: .color(Color(red: 0.96, green: 0.82, blue: 0.86).opacity(alpha)))
        }
    }

    // MARK: - Summer

    private func drawSummer(
        at elapsed: Double,
        opacity: Double,
        into context: inout GraphicsContext,
        size: CGSize
    ) {
        let night = min(1.0, max(0.0, nightIntensity))

        // Fireflies, only after dark.
        if night > 0.01 {
            let count = 12
            for index in 0..<count {
                let seed = noise(index, 17.0)
                let x = wrapped(noise(index, 19.0)
                    + elapsed * (0.004 + seed * 0.005)) * size.width
                let baseY = noise(index, 23.0) * size.height
                let y = baseY + sin(elapsed * 0.35 + seed * 9.0) * 10.0
                let pulse = 0.35 + 0.65 * (0.5 + 0.5 * sin(elapsed * 0.8 + seed * 12.0))
                let radius = 1.0 + seed * 1.4
                let alpha = opacity * night * pulse * 0.55
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: x - radius, y: y - radius,
                        width: radius * 2.0, height: radius * 2.0)),
                    with: .color(Color(red: 1.0, green: 0.86, blue: 0.45).opacity(alpha)))
            }
        }

        // Faint daytime pollen.
        let pollen = 10
        for index in 0..<pollen {
            let seed = noise(index, 29.0)
            let x = wrapped(noise(index, 31.0)
                + elapsed * (0.003 + seed * 0.004)) * size.width
            let y = wrapped(noise(index, 37.0)
                - elapsed * (0.004 + seed * 0.005)) * size.height
            let radius = 0.7 + seed * 1.0
            let alpha = opacity * (1.0 - night) * (0.10 + seed * 0.10)
            context.fill(
                Path(ellipseIn: CGRect(
                    x: x - radius, y: y - radius,
                    width: radius * 2.0, height: radius * 2.0)),
                with: .color(Color.white.opacity(alpha)))
        }
    }

    // MARK: - Autumn

    private func drawAutumn(
        at elapsed: Double,
        opacity: Double,
        into context: inout GraphicsContext,
        size: CGSize
    ) {
        let count = 16
        for index in 0..<count {
            let seed = noise(index, 41.0)
            let fall = 0.018 + seed * 0.022
            let xBase = noise(index, 43.0) * size.width
            let sway = sin(elapsed * 0.30 + seed * 8.0) * (8.0 + seed * 14.0)
            let y = wrapped(noise(index, 47.0) + elapsed * fall) * size.height
            let width = 2.0 + seed * 2.2
            let height = width * 0.60
            let alpha = opacity * (0.18 + seed * 0.22)
            let warm = seed > 0.5
            let color = warm
                ? Color(red: 0.82, green: 0.46, blue: 0.20)
                : Color(red: 0.70, green: 0.36, blue: 0.16)
            context.fill(
                Path(ellipseIn: CGRect(
                    x: xBase + sway - width / 2.0, y: y,
                    width: width, height: height)),
                with: .color(color.opacity(alpha)))
        }
    }

    // MARK: - Winter

    private func drawWinter(
        at elapsed: Double,
        opacity: Double,
        into context: inout GraphicsContext,
        size: CGSize
    ) {
        let count = 18
        for index in 0..<count {
            let seed = noise(index, 53.0)
            let x = wrapped(noise(index, 59.0)
                + elapsed * (0.002 + seed * 0.003)) * size.width
            let y = wrapped(noise(index, 61.0)
                + elapsed * (0.004 + seed * 0.005)) * size.height
            let radius = 0.7 + seed * 1.1
            let alpha = opacity * (0.15 + seed * 0.20)
            context.fill(
                Path(ellipseIn: CGRect(
                    x: x - radius, y: y - radius,
                    width: radius * 2.0, height: radius * 2.0)),
                with: .color(Color(red: 0.82, green: 0.90, blue: 1.0).opacity(alpha)))
        }
    }

    // MARK: - Deterministic noise

    private func noise(_ index: Int, _ salt: Double) -> Double {
        let value = sin(Double(index) * 12.9898 + salt * 78.233) * 43758.5453
        return value - floor(value)
    }

    private func wrapped(_ value: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: 1.0)
        return remainder < 0.0 ? remainder + 1.0 : remainder
    }
}
