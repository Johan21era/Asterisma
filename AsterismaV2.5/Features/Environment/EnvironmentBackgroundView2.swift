//  EnvironmentBackgroundView2.swift
//  AsterismaV2.5
//
//  The rendering layer. It owns exactly one frame clock and reads the engine's
//  previous/current target states, interpolating every visual property at
//  60 Hz. The star field, shooting stars, live atmosphere, seasonal particles,
//  and weather all consume that same elapsed time instead of starting their
//  own TimelineViews.
//
//  Note on `blurIntensity`: Part 5.1 defines it as part of EnvironmentState
//  but the brief doesn't specify blurring the background/star art itself —
//  doing so would blur individual stars into fuzzy blobs, which reads as a
//  bug, not an effect. This view exposes `blurIntensity` for later
//  panel/material-level consumers (frosted UI chrome, Phase K+) to read
//  from `EnvironmentState` directly; it is intentionally NOT self-applied
//  here.
//

import SwiftUI

struct EnvironmentBackgroundView: View {
    @ObservedObject var engine: EnvironmentEngine
    @StateObject private var shootingStarManager = ShootingStarManager()
    @State private var starField = StarField(stars: [])
    @State private var lastStarFieldSize: CGSize = .zero

    #if DEBUG
    /// Studio-only frozen frame. Nil follows the engine's live transition, so
    /// production call sites are unchanged.
    var presentationOverride: EnvironmentPresentationOverride? = nil
    #endif

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                let frame = presentationFrame(at: timeline.date)
                let state = frame.state
                let progress = frame.progress
                let elapsed = timeline.date.timeIntervalSinceReferenceDate

                ZStack {
                    LinearGradient(
                        stops: state.backgroundGradient.map {
                            Gradient.Stop(
                                color: $0.color.swiftUIColor,
                                location: $0.location)
                        },
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    // Ambient glow — UI REVIEW §3/§4 (P7): anchored to the
                    // WINDOW geometry via DesignGrid and diffused past the
                    // corners so its boundary is imperceptible: atmosphere,
                    // not a competing surface.
                    // Readability veil (owner feedback 2026-10-29): the bright
                    // morning/midday palettes swallowed white text and thin
                    // chrome. The engine sizes this from the palette's own
                    // luminance, so night stays untouched.
                    Color.black.opacity(state.readabilityScrim)

                    // Seasonal grade. This is intentionally a low-opacity
                    // overlay instead of a second palette: the hour of day
                    // still owns the scene, while the year shifts its
                    // temperature.
                    state.seasonalTint.swiftUIColor
                        .opacity(state.seasonalTintStrength)
                        .blendMode(.softLight)
                        .allowsHitTesting(false)

                    // Continuous ambience: two large, slow glows that drift
                    // over tens of seconds. They are driven by the shared
                    // 60 Hz clock, so the background moves between engine
                    // ticks instead of reading as a still image.
                    LiveAtmosphereView(
                        ambientColor: state.ambientLightColor.swiftUIColor,
                        atmosphericOpacity: state.atmosphericOpacity,
                        reducedMotion: engine.state.reducedMotion,
                        elapsed: elapsed
                    )

                    // The celestial glow follows the real solar arc when a
                    // cached coordinate exists; without one it stays centered
                    // and reads the palette's own night signal.
                    RadialGradient(
                        colors: [
                            state.celestialGlowColor.swiftUIColor.opacity(
                                DesignGrid.glowPeakOpacity * state.celestialGlowOpacity),
                            .clear,
                        ],
                        center: UnitPoint(
                            x: state.solarDaylight.glowX,
                            y: state.solarDaylight.glowY),
                        startRadius: min(proxy.size.width, proxy.size.height)
                            * DesignGrid.glowStartFraction,
                        endRadius: max(proxy.size.width, proxy.size.height)
                            * DesignGrid.glowEndFraction
                    )
                    .blendMode(.plusLighter)

                    atmosphericHaze(state)

                    StarFieldView(
                        starField: starField,
                        starVisibility: state.starVisibility,
                        reducedMotion: engine.state.reducedMotion,
                        elapsed: elapsed
                    )

                    ShootingStarView(
                        shootingStar: shootingStarManager.active,
                        now: timeline.date
                    )

                    // Seasonal air: petals, fireflies, leaves, frost. Weighted
                    // by the continuous season mix, so boundaries cross-fade.
                    // Heavy weather scales it down continuously rather than
                    // snapping when the weather kind changes.
                    SeasonalAtmosphereView(
                        weights: state.seasonalWeights,
                        intensity: state.seasonalParticleIntensity,
                        nightIntensity: state.nightIntensity,
                        reducedMotion: engine.state.reducedMotion,
                        elapsed: elapsed,
                        weatherAttenuation: weatherAttenuation(
                            from: frame.from.weatherVisual,
                            to: frame.to.weatherVisual,
                            progress: progress)
                    )

                    // Precipitation/atmosphere sits in front of the stars: a
                    // rainy night still shows its stars through the streaks,
                    // but the rain itself is unmistakably foreground. The
                    // outgoing and incoming kinds cross-fade over the same
                    // transition, so weather changes are never a hard cut.
                    WeatherEffectView(
                        from: frame.from.weatherVisual,
                        to: frame.to.weatherVisual,
                        progress: progress,
                        elapsed: elapsed,
                        reducedMotion: engine.state.reducedMotion
                    )
                }
                .onAppear {
                    regenerateStarFieldIfNeeded(for: proxy.size)
                    engine.start()
                    shootingStarManager.start(
                        starVisibility: { [weak engine] in
                            engine?.state.starVisibility ?? 0
                        },
                        reducedMotion: { [weak engine] in
                            engine?.state.reducedMotion ?? false
                        }
                    )
                }
                .onChange(of: proxy.size) { _, newSize in
                    regenerateStarFieldIfNeeded(for: newSize)
                }
                .onDisappear {
                    engine.stop()
                    shootingStarManager.stop()
                }
            }
        }
        .ignoresSafeArea()
    }

    private struct PresentationFrame {
        var state: EnvironmentState
        var from: EnvironmentState
        var to: EnvironmentState
        var progress: Double
    }

    /// The single place that decides which frame to draw. The Studio's scrub
    /// override wins when present; otherwise this is the engine's live
    /// previous → current transition.
    private func presentationFrame(at date: Date) -> PresentationFrame {
        #if DEBUG
        if let presentationOverride {
            let progress = EnvironmentMath.clampUnit(presentationOverride.progress)
            return PresentationFrame(
                state: EnvironmentPresentation.interpolate(
                    from: presentationOverride.from,
                    to: presentationOverride.to,
                    progress: progress),
                from: presentationOverride.from,
                to: presentationOverride.to,
                progress: progress)
        }
        #endif
        let progress = transitionProgress(at: date)
        return PresentationFrame(
            state: EnvironmentPresentation.interpolate(
                from: engine.previousState,
                to: engine.state,
                progress: progress),
            from: engine.previousState,
            to: engine.state,
            progress: progress)
    }

    private func transitionProgress(at date: Date) -> Double {
        let duration = engine.state.reducedMotion
            ? EnvironmentPresentation.reducedMotionTransitionDuration
            : engine.activeTransitionDuration
        return EnvironmentPresentation.progress(
            startedAt: engine.transitionStartedAt,
            now: date,
            duration: duration)
    }

    private func weatherAttenuation(
        from: WeatherVisual,
        to: WeatherVisual,
        progress: Double
    ) -> Double {
        EnvironmentMath.lerp(
            EnvironmentPresentation.weatherAttenuation(for: from.kind),
            EnvironmentPresentation.weatherAttenuation(for: to.kind),
            fraction: progress)
    }

    private func atmosphericHaze(_ state: EnvironmentState) -> some View {
        state.ambientLightColor.swiftUIColor
            .opacity(state.atmosphericOpacity * 0.15) // UI REVIEW §6: softer support
            .blendMode(.softLight)
            .allowsHitTesting(false)
    }

    private func regenerateStarFieldIfNeeded(for size: CGSize) {
        // Regenerate only on meaningful size changes, not every layout pass
        // — star positions are resolution-independent (fractional), so a
        // small resize doesn't need a new field, only a genuinely different
        // aspect/area does. This also keeps StarField.generate off the hot
        // path during ordinary window interaction.
        let widthDelta = abs(size.width - lastStarFieldSize.width)
        let heightDelta = abs(size.height - lastStarFieldSize.height)
        guard widthDelta > 40 || heightDelta > 40 || lastStarFieldSize == .zero else { return }
        starField = StarField.generate(for: size)
        lastStarFieldSize = size
        shootingStarManager.updateFieldSize(size)
    }
}
