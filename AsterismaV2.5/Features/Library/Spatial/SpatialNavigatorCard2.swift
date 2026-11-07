//  SpatialNavigatorCard2.swift
//  Spatial Library — Phase H (Part 9.2's Full Spatial Navigator)
//
//  Reads its own position relative to the navigator's center via a
//  GeometryReader in the shared "spatialNavigator" coordinate space
//  (established by SpatialNavigatorView), and derives rotation/scale/
//  opacity continuously from that live distance — this is what makes the
//  carousel feel calibrated as you drag, rather than snapping between
//  fixed per-index states only at rest.
//
//  Uses EnvironmentMath.clampUnit/smoothstep/lerp (from the Environment
//  Engine, Phase B) rather than re-implementing equivalent helpers — they
//  were written generically, with no Environment-specific coupling, so
//  reusing them here avoids duplicate utility code across features.
//
//  Rotation sign convention (turning left vs. right of center) is a visual
//  choice I couldn't verify by eye without a compiler/simulator — if it
//  looks inverted once run, flip the ternary's two branches in `visualState`.
//
//  Part 11: the live-geometry-driven rotation/scale/opacity here is exactly
//  the "parallax" Part 11 names as something to disable under reduced
//  motion — not just tone down. When reducedMotion is true, this card skips
//  the GeometryReader-driven calculation entirely and renders flat, at full
//  scale and opacity, positioned by ordinary layout instead of `.position()`.
//

import SwiftUI

struct SpatialNavigatorCard: View {
    let book: Book
    let containerCenterX: CGFloat
    var reducedMotion: Bool = false
    var onSelect: (Book) -> Void

    private let cardWidth: CGFloat = 130
    private let cardHeight: CGFloat = 195
    /// Distance (in card-widths) at which rotation/scale/opacity fully
    /// saturate. Kept above 1 so neighboring cards still feel continuous
    /// rather than each maxing out the instant it's off-center.
    private let saturationDistanceInCards = 1.6
    private let maxRotationDegrees = 22.0   // within Part 9.2's ±20-25° cap
    private let minScale = 0.8              // within Part 9.2's 0.75-0.85 range
    private let minOpacity = 0.25           // "fading toward, not necessarily to, transparent"

    var body: some View {
        if reducedMotion {
            BookCoverCardView(book: book, width: cardWidth, height: cardHeight)
                .applying(.identity)
                .onTapGesture { onSelect(book) }
        } else {
            GeometryReader { proxy in
                let myMidX = proxy.frame(in: .named("spatialNavigator")).midX
                let distanceInCards = Double(myMidX - containerCenterX) / Double(cardWidth + 24)

                ZStack {
                    BookCoverCardView(book: book, width: cardWidth, height: cardHeight)
                        .applying(visualState(distanceInCards: distanceInCards))
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .onTapGesture { onSelect(book) }
            }
            .frame(width: cardWidth, height: cardHeight)
        }
    }

    private func visualState(distanceInCards: Double) -> BookVisualState {
        let normalizedDistance = EnvironmentMath.clampUnit(abs(distanceInCards) / saturationDistanceInCards)
        let eased = EnvironmentMath.smoothstep(normalizedDistance)
        let signedRotation = maxRotationDegrees * eased * (distanceInCards < 0 ? 1.0 : -1.0)

        return BookVisualState(
            offset: .zero,
            rotationDegrees: signedRotation,
            rotationStyle: .threeDimensional,
            scale: EnvironmentMath.lerp(1.0, minScale, eased),
            opacity: EnvironmentMath.lerp(1.0, minOpacity, eased),
            isFocused: normalizedDistance < 0.05,
            zIndex: 1 - normalizedDistance
        )
    }
}
