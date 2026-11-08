//  AsterismaMotion.swift
//  AsterismaV2.5
//
//  One motion language for the app. UI state changes settle quickly and
//  decisively; larger surfaces get a longer, more deliberate reveal; tactile
//  state changes get a small spring. Ambient environment motion stays in the
//  procedural renderer, where it belongs.
//
//  The old ad-hoc ease curves made unrelated surfaces feel like they belonged
//  to different apps. These tokens are the single source of timing truth.

import SwiftUI

enum AsterismaMotion {
    /// Per-word and per-glyph updates where anything slower reads as lag.
    static let instant = Animation.timingCurve(0.2, 0.9, 0.1, 1.0, duration: 0.08)

    /// Hover, selection, and tiny state flips.
    static let snap = Animation.timingCurve(0.2, 0.9, 0.1, 1.0, duration: 0.14)

    /// Controls, rows, and compact panels.
    static let quick = Animation.timingCurve(0.16, 1.0, 0.3, 1.0, duration: 0.20)

    /// Standard chrome and surface transitions.
    static let standard = Animation.timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.28)

    /// Page slides, sheet-sized changes, and other large entrances.
    static let emphasized = Animation.timingCurve(0.16, 1.0, 0.3, 1.0, duration: 0.40)

    /// Dismissals leave faster than entrances and never bounce.
    static let exit = Animation.timingCurve(0.4, 0.0, 1.0, 1.0, duration: 0.18)

    /// A tactile button, zoom, or selection spring.
    static let press = Animation.spring(response: 0.28, dampingFraction: 0.72)

    /// Achievement and banner arrivals.
    static let toast = Animation.spring(response: 0.44, dampingFraction: 0.80)

    /// Keyboard-driven scroll-to-selection.
    static let scroll = Animation.timingCurve(0.2, 0.9, 0.1, 1.0, duration: 0.22)

    /// Deliberate library settles and other ambient reveals.
    static let settle = Animation.timingCurve(0.16, 1.0, 0.3, 1.0, duration: 0.70)

    /// Full-screen narrative transitions, not ordinary UI.
    static let cinematic = Animation.timingCurve(0.4, 0.0, 0.2, 1.0, duration: 0.80)
    static let cinematicMist = Animation.timingCurve(0.16, 1.0, 0.3, 1.0, duration: 1.20)
    static let cinematicExit = Animation.timingCurve(0.4, 0.0, 1.0, 1.0, duration: 1.00)

    /// Accessibility-aware wrapper for decorative motion.
    static func reduced(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

enum AsterismaTransition {
    /// Floating surfaces: a slightly firmer pop than a bare opacity fade.
    static let overlay: AnyTransition = .opacity.combined(with: .scale(scale: 0.985))

    /// Chrome and toasts entering from the top edge.
    static let topPanel: AnyTransition = .opacity.combined(with: .move(edge: .top))

    /// Controls and actions entering from the bottom edge.
    static let bottomPanel: AnyTransition = .opacity.combined(with: .move(edge: .bottom))

    /// Small inline confirmations such as “Saved”.
    static let inlineNotice: AnyTransition = .opacity.combined(with: .scale(scale: 0.96))
}

// MARK: - Cinematic choreography

/// The “blockbuster” layer: camera moves, letterboxing, depth-of-field
/// scrims, and staggered reveals for the app's narrative moments. These are
/// deliberately reserved for full-screen or hero surfaces — ordinary chrome
/// stays on the crisp UI tokens above.
extension AsterismaMotion {
    /// A camera push: long deceleration with no overshoot.
    static let cameraPush = Animation.timingCurve(0.16, 1.0, 0.3, 1.0, duration: 1.10)

    /// Hero titles and full-screen statements. Settles later than a push.
    static let titleReveal = Animation.timingCurve(0.16, 1.0, 0.3, 1.0, duration: 1.35)

    /// Heavy physical settle for large surfaces.
    static let cinematicSpring = Animation.spring(response: 0.72, dampingFraction: 0.90)

    /// One beat of anticipation before a large reveal.
    static let anticipation = Animation.timingCurve(0.4, 0.0, 0.6, 1.0, duration: 0.22)

    /// Staggered cascade: element N starts `step` seconds after element N-1.
    static func cascade(
        _ index: Int,
        step: Double = 0.09,
        base: Animation = AsterismaMotion.titleReveal
    ) -> Animation {
        base.delay(Double(max(0, index)) * step)
    }
}

extension AsterismaTransition {
    /// Full-scene change: the incoming surface pushes through depth while the
    /// outgoing one recedes. Used for report slides and other narrative cuts.
    static let cinematicSlide = AnyTransition.asymmetric(
        insertion: .modifier(
            active: CinematicDepth(progress: 1),
            identity: CinematicDepth(progress: 0)
        ),
        removal: .modifier(
            active: CinematicDepth(progress: -0.75),
            identity: CinematicDepth(progress: 0)
        )
    )

    /// Overlays arrive from just behind the glass instead of simply fading.
    static let cinematicOverlay = AnyTransition.asymmetric(
        insertion: .modifier(
            active: CinematicDepth(progress: 0.7, distance: 10, scaleRange: 0.035, blurRadius: 10),
            identity: CinematicDepth(progress: 0)
        ),
        removal: .opacity
    )

    /// A smaller lift for ordinary section changes: depth without drama.
    static let depthLift = AnyTransition.asymmetric(
        insertion: .modifier(
            active: CinematicDepth(progress: 0.6, distance: 10, scaleRange: 0.025, blurRadius: 8),
            identity: CinematicDepth(progress: 0)
        ),
        removal: .opacity
    )

    /// Achievement banners drop in with weight.
    static let toastDrop = AnyTransition.asymmetric(
        insertion: .modifier(
            active: CinematicDepth(progress: 1, distance: -26, scaleRange: 0.05, blurRadius: 8),
            identity: CinematicDepth(progress: 0)
        ),
        removal: .opacity.combined(with: .offset(y: -8))
    )
}

/// Interpolates a view through camera depth: scale, vertical travel, blur,
/// and opacity all follow one progress value.
private struct CinematicDepth: ViewModifier, Animatable {
    var progress: Double
    var distance: CGFloat = 16
    var scaleRange: Double = 0.045
    var blurRadius: Double = 14

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let magnitude = min(abs(progress), 1)
        content
            .scaleEffect(1 + scaleRange * progress)
            .offset(y: distance * progress)
            .blur(radius: blurRadius * magnitude)
            .opacity(1 - 0.55 * magnitude)
    }
}

// MARK: - Cinematic surfaces

/// Black letterbox bars that glide in for narrative sequences.
struct CinematicBars: View {
    var active: Bool
    var height: CGFloat = 56
    var reduceMotion: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(.black)
                .frame(height: active ? height : 0)
            Spacer(minLength: 0)
            Rectangle()
                .fill(.black)
                .frame(height: active ? height : 0)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(reduceMotion ? nil : AsterismaMotion.cameraPush, value: active)
    }
}

/// A soft radial falloff that pulls the eye to the centre of the frame.
struct CinematicVignette: View {
    var intensity: Double = 0.55

    var body: some View {
        RadialGradient(
            stops: [
                .init(color: .clear, location: 0.45),
                .init(color: .black.opacity(intensity), location: 1.0),
            ],
            center: .center,
            startRadius: 120,
            endRadius: 760
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Depth-of-field scrim behind transient overlays: frosted glass, a dark
/// wash, and a vignette in one layer.
struct CinematicScrim: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Color.black.opacity(0.30)
            CinematicVignette(intensity: 0.50)
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
    }
}

/// A one-shot camera settle for a newly opened surface.
struct CinematicPushIn: ViewModifier {
    var reduceMotion: Bool = false
    @State private var settled = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(settled ? 1 : 1.035)
            .blur(radius: settled ? 0 : 7)
            .opacity(settled ? 1 : 0.7)
            .onAppear {
                guard !reduceMotion else {
                    settled = true
                    return
                }
                withAnimation(AsterismaMotion.cameraPush) { settled = true }
            }
    }
}

/// Staggered blur-to-sharp entrance for hero copy.
struct CinematicReveal: ViewModifier {
    var active: Bool
    var index: Int = 0
    var distance: CGFloat = 18
    var reduceMotion: Bool = false

    func body(content: Content) -> some View {
        content
            .opacity(active ? 1 : 0)
            .blur(radius: active ? 0 : 8)
            .offset(y: active ? 0 : distance)
            .scaleEffect(active ? 1 : 0.99)
            .animation(
                reduceMotion ? nil : AsterismaMotion.cascade(index),
                value: active
            )
    }
}

extension View {
    func cinematicPushIn(reduceMotion: Bool = false) -> some View {
        modifier(CinematicPushIn(reduceMotion: reduceMotion))
    }

    func cinematicReveal(
        _ active: Bool,
        index: Int = 0,
        distance: CGFloat = 18,
        reduceMotion: Bool = false
    ) -> some View {
        modifier(CinematicReveal(
            active: active,
            index: index,
            distance: distance,
            reduceMotion: reduceMotion
        ))
    }
}
