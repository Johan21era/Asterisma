//  EnvironmentBackgroundView2.swift
//  Environment Engine — Phase B-D composition (Part 12 of the build spec)
//
//  Composes the environment layers Part 12 describes, in order: gradient →
//  atmospheric effects → stars → shooting stars. Depth layers, the spatial
//  library, UI components, overlays, and the interaction layer come after
//  this in Part 12's pipeline, and belong to Phase F onward.
//
//  WIRING STATUS (Phase 2): WIRED. ContentView owns the single
//  EnvironmentEngine via @StateObject and composes this view as the ZStack
//  root behind NavigationSplitView (with .scrollContentBackground(.hidden) on
//  the sidebar so ambience reads through). History: an early revision falsely
//  claimed wiring was complete; a later session corrected it to UNWIRED
//  (Audit §1.1 / D4); Phase 2 performed the actual wiring.
//  `engine` is injected rather than owned here, because Phase K's own
//  requirement is a SINGLE centralized EnvironmentState ("nothing renders
//  its own opinion," Part 4) — LibraryExplorerView/SpatialLibraryView also
//  need to read `reducedMotion` off the same instance this view renders
//  from. Two independently-owned engines would each run their own 10 s
//  recompute loop against the same real clock/accessibility settings —
//  not incorrect, but a silent duplicate-timer waste and a violation of
//  "computed once by a centralized system." ContentView owns the single
//  instance via @StateObject (the wrapper that survives re-renders); this
//  view and LibraryExplorerView both just read it.
//
//  Deliberately NOT given a default value (e.g. `= EnvironmentEngine()`):
//  a default argument is re-evaluated on every call site that omits it,
//  and SwiftUI reconstructs view values on most parent body re-evaluations
//  — an inline default here would silently build a fresh engine (new
//  10 s timer, reset interpolation) on some unpredictable subset of
//  re-renders. @ObservedObject (unlike @StateObject) has no protection
//  against that, so the caller must own and pass the same instance every
//  time. See NewContentView.swift's `environmentEngine`.
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

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    stops: engine.state.backgroundGradient.map {
                        Gradient.Stop(color: $0.color.swiftUIColor, location: $0.location)
                    },
                    startPoint: .top,
                    endPoint: .bottom
                )

                // Ambient glow — UI REVIEW §3/§4 (P7): the previous
                // treatment (0.35 opacity, 0.35–0.75 radii) read as a distinct
                // curved SURFACE floating behind the chrome, misaligned with
                // sidebar/content geometry. Per the review's own option B,
                // it's now anchored to the WINDOW geometry via DesignGrid and
                // diffused past the corners so its boundary is imperceptible:
                // atmosphere, not a competing surface.
                // Readability veil (owner feedback 2026-10-29): the bright
                // morning/midday palettes swallowed white text and thin chrome.
                // The engine sizes this from the palette's own luminance, so
                // night stays untouched and no view computes its own opinion.
                Color.black.opacity(engine.state.readabilityScrim)

                // Continuous ambience: two large, slow glows that drift over
                // tens of seconds. Without this the background only moved when
                // the 10 s palette tick landed, which read as a still image.
                LiveAtmosphereView(
                    ambientColor: engine.state.ambientLightColor.swiftUIColor,
                    atmosphericOpacity: engine.state.atmosphericOpacity,
                    reducedMotion: engine.state.reducedMotion
                )

                RadialGradient(
                    colors: [engine.state.ambientLightColor.swiftUIColor.opacity(DesignGrid.glowPeakOpacity), .clear],
                    center: .center,
                    startRadius: min(proxy.size.width, proxy.size.height) * DesignGrid.glowStartFraction,
                    endRadius: max(proxy.size.width, proxy.size.height) * DesignGrid.glowEndFraction
                )
                .blendMode(.plusLighter)

                // Atmospheric effects layer — a soft haze whose strength
                // tracks atmosphericOpacity. Weather's cloud-cover nudge
                // (Part 8) flows into this same value, so heavier cloud
                // cover reads as slightly hazier with no separate weather-
                // specific view.
                atmosphericHaze

                StarFieldView(
                    starField: starField,
                    starVisibility: engine.state.starVisibility,
                    reducedMotion: engine.state.reducedMotion
                )

                ShootingStarView(shootingStar: shootingStarManager.active)

                // Precipitation/atmosphere sits in front of the stars: a rainy
                // night still shows its stars through the streaks, but the
                // rain itself is unmistakably foreground.
                WeatherEffectView(
                    visual: engine.state.weatherVisual,
                    reducedMotion: engine.state.reducedMotion
                )
            }
            // Part 11: ambient/atmospheric motion belongs "on the scale of
            // many seconds to minutes" — without this, each 10 s recompute
            // tick would snap to its new values instead of drifting into
            // them, which is exactly the abrupt transition Appendix A says
            // should never be observable. Ambient drift is also explicitly
            // named in Part 11 as something to minimize under reduced
            // motion, so it collapses to a near-instant fade there instead.
            .animation(ambientAnimation, value: engine.state)
            .onAppear {
                regenerateStarFieldIfNeeded(for: proxy.size)
                engine.start()
                shootingStarManager.start(
                    starVisibility: { [weak engine] in engine?.state.starVisibility ?? 0 },
                    reducedMotion: { [weak engine] in engine?.state.reducedMotion ?? false }
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
        .ignoresSafeArea()
    }

    private var atmosphericHaze: some View {
        engine.state.ambientLightColor.swiftUIColor
            .opacity(engine.state.atmosphericOpacity * 0.15) // UI REVIEW §6: softer support
            .blendMode(.softLight)
            .allowsHitTesting(false)
    }

    private var ambientAnimation: Animation {
        engine.state.reducedMotion ? .easeInOut(duration: 0.4) : .easeInOut(duration: 10)
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
