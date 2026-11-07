//  WeatherEffectView.swift
//  AsterismaV2.5
//
//  The precipitation/atmosphere layer the environment background was missing.
//  Every frame is drawn from `WeatherVisual` — this view holds no weather state
//  and performs no I/O. Rain streaks, snow, fog banks, drifting cloud shadow,
//  wind streaks, and a rare storm flash are all procedural and deterministic,
//  so the same state produces the same frame and reduced motion can freeze it.
//
//  Intensity and wind come from the engine (a real WeatherSnapshot or a studio
//  override); a `.clear` visual draws nothing at all.

import SwiftUI

struct WeatherEffectView: View {
    let visual: WeatherVisual
    let reducedMotion: Bool

    var body: some View {
        Group {
            if visual.kind == .clear {
                EmptyView()
            } else if reducedMotion {
                Canvas { context, size in
                    draw(at: 0, into: &context, size: size)
                }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    Canvas { context, size in
                        draw(
                            at: timeline.date.timeIntervalSinceReferenceDate,
                            into: &context, size: size)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Drawing

    private func draw(at elapsed: Double, into context: inout GraphicsContext, size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        let intensity = visual.intensity
        guard intensity > 0.01 else { return }

        drawCloudField(at: elapsed, intensity: intensity, into: &context, size: size)
        drawFogBanks(at: elapsed, into: &context, size: size)

        switch visual.kind {
        case .clear, .cloudy, .fog:
            break
        case .rain, .heavyRain, .storm:
            drawRain(at: elapsed, into: &context, size: size)
            if visual.kind == .storm { drawStormFlash(at: elapsed, into: &context, size: size) }
        case .snow, .heavySnow:
            drawSnow(at: elapsed, into: &context, size: size)
        case .wind:
            drawWind(at: elapsed, into: &context, size: size)
        }
    }

    /// Soft overcast shadow: broad, slowly drifting radial patches. Kept weak
    /// so it darkens the scene without becoming a grey filter.
    private func drawCloudField(
        at elapsed: Double,
        intensity: Double,
        into context: inout GraphicsContext,
        size: CGSize
    ) {
        guard visual.cloud > 0.05 else { return }
        let count = 5
        let strength = min(0.22, visual.cloud * 0.26) * (0.55 + intensity * 0.45)
        for index in 0..<count {
            let seed = noise(index, 11)
            let speed = 0.0035 + seed * 0.003
            let x = wrapped(seed + elapsed * speed) * size.width * 1.3 - size.width * 0.15
            let y = (0.08 + noise(index, 29) * 0.55) * size.height
                + sin(elapsed * 0.01 + seed * 6) * size.height * 0.02
            let radius = size.width * (0.16 + noise(index, 47) * 0.15)
            let gradient = Gradient(colors: [
                Color(white: 0.18).opacity(strength),
                Color(white: 0.10).opacity(0),
            ])
            context.fill(
                Path(ellipseIn: CGRect(
                    x: x - radius, y: y - radius * 0.45,
                    width: radius * 2, height: radius * 0.9)),
                with: .radialGradient(
                    gradient, center: CGPoint(x: x, y: y),
                    startRadius: 0, endRadius: radius))
        }
    }

    private func drawFogBanks(
        at elapsed: Double,
        into context: inout GraphicsContext,
        size: CGSize
    ) {
        guard visual.kind == .fog || visual.kind == .storm else { return }
        let strength = visual.kind == .fog
            ? min(0.30, 0.10 + visual.intensity * 0.25)
            : 0.08
        for index in 0..<4 {
            let seed = noise(index, 71)
            let y = (0.30 + Double(index) * 0.17) * size.height
                + sin(elapsed * 0.02 + seed * 8) * 8
            let drift = wrapped(seed + elapsed * (0.0015 + seed * 0.002)) * size.width * 2
                - size.width * 0.5
            let rect = CGRect(
                x: drift, y: y,
                width: size.width * (0.8 + seed * 0.5),
                height: size.height * (0.10 + seed * 0.07))
            let gradient = Gradient(colors: [
                Color.white.opacity(0), Color.white.opacity(strength), Color.white.opacity(0),
            ])
            context.fill(
                Path(roundedRect: rect, cornerRadius: rect.height * 0.5),
                with: .linearGradient(
                    gradient, startPoint: CGPoint(x: rect.minX, y: rect.midY),
                    endPoint: CGPoint(x: rect.maxX, y: rect.midY)))
        }
    }

    private func drawRain(
        at elapsed: Double,
        into context: inout GraphicsContext,
        size: CGSize
    ) {
        let heavy = visual.kind == .heavyRain || visual.kind == .storm
        let count = heavy ? 150 : 80
        let tail = size.height * (heavy ? 0.10 : 0.07)
        let opacity = (heavy ? 0.30 : 0.20) * (0.55 + visual.intensity * 0.45)
        let slant = 12.0 + visual.wind * 28.0
        for index in 0..<count {
            let seed = noise(index, 3)
            let speed = (heavy ? 1.15 : 0.85) + seed * 0.5
            let x = wrapped(seed + elapsed * speed * 0.10) * size.width
            let y = wrapped(noise(index, 7) + elapsed * speed * 0.55) * size.height
            var path = Path()
            path.move(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x - slant, y: y + tail))
            context.stroke(
                path,
                with: .color(Color(red: 0.72, green: 0.82, blue: 0.94).opacity(opacity)),
                style: StrokeStyle(lineWidth: heavy ? 1.1 : 0.8, lineCap: .round))
        }
    }

    private func drawSnow(
        at elapsed: Double,
        into context: inout GraphicsContext,
        size: CGSize
    ) {
        let heavy = visual.kind == .heavySnow
        let count = heavy ? 120 : 70
        let opacity = (heavy ? 0.75 : 0.55) * (0.5 + visual.intensity * 0.5)
        for index in 0..<count {
            let seed = noise(index, 13)
            let speed = 0.012 + seed * 0.020
            let xBase = noise(index, 17) * size.width
            let drift = sin(elapsed * 0.35 + seed * 12) * (6 + visual.wind * 18)
            let y = wrapped(noise(index, 19) + elapsed * speed) * size.height
            let radius = 1.0 + seed * (heavy ? 2.4 : 1.8)
            let rect = CGRect(
                x: xBase + drift - radius, y: y - radius,
                width: radius * 2, height: radius * 2)
            context.fill(
                Path(ellipseIn: rect),
                with: .color(Color.white.opacity(opacity * (0.4 + seed * 0.6))))
        }
    }

    private func drawWind(
        at elapsed: Double,
        into context: inout GraphicsContext,
        size: CGSize
    ) {
        let count = 18
        let opacity = 0.10 + visual.intensity * 0.16
        for index in 0..<count {
            let seed = noise(index, 23)
            let y = (0.15 + seed * 0.7) * size.height
                + sin(elapsed * 0.20 + seed * 9) * 4
            let x = wrapped(seed + elapsed * (0.10 + seed * 0.08)) * size.width * 1.4
                - size.width * 0.2
            let length = size.width * (0.10 + seed * 0.16)
            var path = Path()
            path.move(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x + length, y: y - 3 - visual.wind * 4))
            context.stroke(
                path, with: .color(Color.white.opacity(opacity)),
                style: StrokeStyle(lineWidth: 1, lineCap: .round))
        }
    }

    private func drawStormFlash(
        at elapsed: Double,
        into context: inout GraphicsContext,
        size: CGSize
    ) {
        // One short flash every ~11 seconds; the cycle offset is fixed so the
        // flash is repeatable and testable, not random per launch.
        let cycle = 11.0
        let phase = elapsed.truncatingRemainder(dividingBy: cycle)
        guard phase < 0.16 else { return }
        let envelope = 1 - phase / 0.16
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .color(Color.white.opacity(0.22 * envelope * visual.intensity)))
    }

    // MARK: - Deterministic noise

    private func noise(_ index: Int, _ salt: Double) -> Double {
        let value = sin(Double(index) * 12.9898 + salt * 78.233) * 43758.5453
        return value - floor(value)
    }

    private func wrapped(_ value: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: 1)
        return remainder < 0 ? remainder + 1 : remainder
    }
}

// MARK: - LiveAtmosphereView

/// The continuous "flow" layer. The palette itself only changes on the engine's
/// recompute tick (now 10 s), so before this layer the background looked like a
/// still image between ticks. This draws two very slow, large ambient glows that
/// drift over tens of seconds, independent of the palette cadence.
struct LiveAtmosphereView: View {
    let ambientColor: Color
    let atmosphericOpacity: Double
    let reducedMotion: Bool

    var body: some View {
        Group {
            if reducedMotion {
                Canvas { context, size in draw(at: 0, into: &context, size: size) }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { timeline in
                    Canvas { context, size in
                        draw(
                            at: timeline.date.timeIntervalSinceReferenceDate,
                            into: &context, size: size)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .blendMode(.plusLighter)
    }

    private func draw(at elapsed: Double, into context: inout GraphicsContext, size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        let strength = 0.06 + atmosphericOpacity * 0.10
        for index in 0..<2 {
            let phase = elapsed * (0.010 + Double(index) * 0.004)
            let center = CGPoint(
                x: size.width * (0.30 + 0.42 * sin(phase + Double(index) * 2.1)),
                y: size.height * (0.32 + 0.36 * cos(phase * 0.8 + Double(index) * 1.7)))
            let radius = max(size.width, size.height) * (0.55 + Double(index) * 0.15)
            let gradient = Gradient(colors: [
                ambientColor.opacity(strength),
                ambientColor.opacity(0),
            ])
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .radialGradient(
                    gradient, center: center, startRadius: 0, endRadius: radius))
        }
    }
}
