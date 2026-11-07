//  ShallowPerspectiveView2.swift
//  Spatial Library — Phase F/G (Part 9.2 of the build spec)
//
//  Tier 2: 6-15 books. A compact arrangement with modest spatial depth —
//  small scale/opacity variation center-to-edge — without the Full
//  Navigator's snap-scrolling mechanism. A shallow stack/fanned row, not a
//  carousel: deliberately no rotation3DEffect and no live-scroll-position
//  tracking here (that's what makes this tier distinct from Tier 3, not
//  just a smaller version of it). Depth is a fixed function of each card's
//  index position, not a function of live scroll offset. 15 books is small
//  enough that no virtualization is needed at this tier either.
//

import SwiftUI

struct ShallowPerspectiveView: View {
    let books: [Book]
    var reducedMotion: Bool = false
    var onSelect: (Book) -> Void

    @State private var hasSettled = false

    private let cardWidth: CGFloat = 110
    private let cardHeight: CGFloat = 165
    private let spacing: CGFloat = 18
    private let minScale = 0.84
    private let minOpacity = 0.55

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(books.enumerated()), id: \.element.id) { index, book in
                    BookCoverCardView(book: book, width: cardWidth, height: cardHeight)
                        .applying(visualState(for: index, count: books.count))
                        .onTapGesture { onSelect(book) }
                }
            }
            .padding(.horizontal, 24)
        }
        // Part 11: the scale-in is ambient/decorative and skipped under
        // reduced motion (starts at its final scale); the opacity fade is
        // the essential state-change cross-fade and stays either way.
        .scaleEffect(hasSettled || reducedMotion ? 1 : 0.92)
        .opacity(hasSettled ? 1 : 0)
        .onAppear {
            withAnimation(.easeOut(duration: reducedMotion ? 0.2 : 0.6)) {
                hasSettled = true
            }
        }
    }

    private func visualState(for index: Int, count: Int) -> BookVisualState {
        let distance = distanceFromCenter(index: index, count: count)
        return BookVisualState(
            offset: CGSize(width: 0, height: distance * 8), // edges sit fractionally lower — the "shallow stack" cue
            rotationDegrees: 0,
            rotationStyle: .flat,
            scale: 1 - distance * (1 - minScale),
            opacity: 1 - distance * (1 - minOpacity),
            isFocused: distance < 0.05,
            zIndex: 1 - distance
        )
    }

    /// 0 at the row's center, approaching 1 at either end — a fixed,
    /// index-based falloff computed once, not a live scroll readout.
    private func distanceFromCenter(index: Int, count: Int) -> Double {
        guard count > 1 else { return 0 }
        let center = Double(count - 1) / 2.0
        return min(1, abs(Double(index) - center) / center)
    }
}
