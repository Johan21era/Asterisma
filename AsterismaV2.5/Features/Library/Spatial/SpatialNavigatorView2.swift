//  SpatialNavigatorView2.swift
//  Spatial Library — Phase H (Part 9.2's Full Spatial Navigator)
//
//  Tier 3: 16+ books. Built with native SwiftUI 3D transforms
//  (rotation3DEffect, via SpatialNavigatorCard), NOT SceneKit — a
//  deliberate choice in the brief to avoid the readability cost of a
//  literal circular carousel.
//
//  Snap-scrolling: .scrollTargetBehavior(.viewAligned) + .scrollPosition(id:)
//  (macOS 14+; this project's confirmed macOS 26.5 deployment target
//  supports it directly, so no drag-gesture fallback is needed).
//
//  Virtualization (Part 9.2, Part 13): only books within `renderRadius` of
//  the focused index become real SpatialNavigatorCard views (image decode,
//  text layout, geometry tracking). Everything else is a fixed-size
//  Color.clear placeholder — present only so the ScrollView has correct
//  content extent for view-aligned snapping, with no book-cover cost
//  whatsoever. See `content(for:at:containerCenterX:)` below — this is a
//  real conditional in the code, not a claim to take on faith.
//

import SwiftUI

struct SpatialNavigatorView: View {
    let books: [Book]
    var reducedMotion: Bool = false
    var onSelect: (Book) -> Void

    @State private var focusedBookID: Book.ID?
    private let renderRadius = 4 // cards on each side of focus that get real views
    private let cardWidth: CGFloat = 130
    private let cardHeight: CGFloat = 195

    var body: some View {
        GeometryReader { outer in
            let containerCenterX = outer.size.width / 2
            let edgeInset = max(0, outer.size.width / 2 - cardWidth / 2)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 24) {
                    ForEach(Array(books.enumerated()), id: \.element.id) { index, book in
                        content(for: book, at: index, containerCenterX: containerCenterX)
                            .id(book.id)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, edgeInset) // lets the first/last card reach center
            }
            .coordinateSpace(name: "spatialNavigator")
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $focusedBookID)
        }
        .onAppear {
            if focusedBookID == nil {
                focusedBookID = books.first?.id
            }
        }
    }

    @ViewBuilder
    private func content(for book: Book, at index: Int, containerCenterX: CGFloat) -> some View {
        if isWithinRenderRadius(index: index) {
            SpatialNavigatorCard(
                book: book,
                containerCenterX: containerCenterX,
                reducedMotion: reducedMotion,
                onSelect: onSelect
            )
        } else {
            // Virtual: data-only, no view. Layout scaffolding for scroll
            // geometry — no cover decode, no text, nothing book-shaped.
            Color.clear
                .frame(width: cardWidth, height: cardHeight)
        }
    }

    private func isWithinRenderRadius(index: Int) -> Bool {
        guard let focusedID = focusedBookID,
              let focusedIndex = books.firstIndex(where: { $0.id == focusedID }) else {
            return index <= renderRadius // before first layout: render the leading window
        }
        return abs(index - focusedIndex) <= renderRadius
    }
}
