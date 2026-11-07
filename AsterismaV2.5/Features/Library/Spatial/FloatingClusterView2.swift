//  FloatingClusterView2.swift
//  Spatial Library — Phase F (Part 9.2 of the build spec)
//
//  Tier 1: 1-5 books. Static, gently fanned/overlapping, centered, minimal
//  motion — a slow settle-into-place animation on appearance is fine,
//  continuous ambient motion is not. No scroll affordance is shown or
//  implied, because there's nothing to scroll to.
//

import SwiftUI

struct FloatingClusterView: View {
    let books: [Book]
    var reducedMotion: Bool = false
    var onSelect: (Book) -> Void

    @State private var hasSettled = false

    private let fanAngleStep = 7.0     // degrees between adjacent cards
    private let fanOffsetStep = 26.0   // points between adjacent cards, horizontally
    private let verticalLift = 10.0    // points per step away from center — a gentle arc, not a flat row

    var body: some View {
        ZStack {
            ForEach(Array(books.enumerated()), id: \.element.id) { index, book in
                BookCoverCardView(book: book)
                    .applying(visualState(for: index, count: books.count))
                    .onTapGesture { onSelect(book) }
            }
        }
        .onAppear {
            // Part 11: the *position* settle (bunched -> fanned) is the
            // kind of ambient/decorative motion reduced motion asks to be
            // minimized; the opacity fade is the "essential state-change
            // cross-fade" Part 11 says to keep either way. Under reduced
            // motion, cards appear already in their fanned position and
            // only fade in.
            withAnimation(.easeOut(duration: reducedMotion ? 0.2 : 0.8)) {
                hasSettled = true
            }
        }
    }

    private func visualState(for index: Int, count: Int) -> BookVisualState {
        let centeredIndex = Double(index) - Double(count - 1) / 2.0
        let zIndex = Double(count) - abs(centeredIndex)
        let fannedOffset = CGSize(width: centeredIndex * fanOffsetStep, height: abs(centeredIndex) * verticalLift)
        let fannedRotation = centeredIndex * fanAngleStep

        guard hasSettled else {
            return BookVisualState(
                // Reduced motion: start already in the fanned position/
                // rotation, opacity 0 -> only the fade animates.
                // Full motion: start small, unfanned, offset downward —
                // the "slow settle into place" the brief allows, once.
                offset: reducedMotion ? fannedOffset : CGSize(width: 0, height: 40),
                rotationDegrees: reducedMotion ? fannedRotation : 0,
                rotationStyle: .flat,
                scale: reducedMotion ? 1 : 0.85,
                opacity: 0,
                isFocused: false,
                zIndex: zIndex
            )
        }
        return BookVisualState(
            offset: fannedOffset,
            rotationDegrees: fannedRotation,
            rotationStyle: .flat,
            scale: 1,
            opacity: 1,
            isFocused: index == count / 2,
            zIndex: zIndex
        )
    }
}
