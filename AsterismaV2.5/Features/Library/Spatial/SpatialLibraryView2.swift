//  SpatialLibraryView2.swift
//  AsterismaV2.5
//  Spatial Library — Phase F/G/H entry point (Part 9.1, 9.2 of the build spec)
//
//  Operates on whatever [Book] it's given — it does not know or care
//  whether that array is the full library or an already-filtered subset.
//  Progressive Filtering (Part 10 / Phase I) doesn't exist yet; per Part
//  9.1's pipeline order ("Filtering always happens first and produces a
//  subset. Layout and navigation only ever operate on that already-filtered
//  subset"), this view IS the layout+navigation half of that pipeline, and
//  is agnostic to how its input was produced. Whoever wires this in later
//  is responsible for filtering first.
//
//  The tier cross-fade below is built now, ahead of Part 10 actually
//  existing, specifically so that once real filtering starts changing
//  `books.count` across tier boundaries, it already animates smoothly per
//  Part 10's own requirement ("This transition between tiers should itself
//  be a smooth cross-fade/settle, not an abrupt layout swap") instead of
//  needing to be retrofitted later.
//

import SwiftUI

struct SpatialLibraryView: View {
    let books: [Book]
    var reducedMotion: Bool = false
    var onSelect: (Book) -> Void

    private var tier: AdaptiveLayoutTier {
        AdaptiveLayoutTier.tier(forCount: books.count)
    }

    var body: some View {
        Group {
            if books.isEmpty {
                emptyState
            } else {
                switch tier {
                case .floatingCluster:
                    FloatingClusterView(books: books, reducedMotion: reducedMotion, onSelect: onSelect)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                case .shallowPerspective:
                    ShallowPerspectiveView(books: books, reducedMotion: reducedMotion, onSelect: onSelect)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                case .fullSpatialNavigator:
                    SpatialNavigatorView(books: books, reducedMotion: reducedMotion, onSelect: onSelect)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
        }
        // The tier cross-fade itself is a genuine state change (the layout
        // fundamentally changed), so per Part 11's "keep only essential
        // state-change cross-fades," this one stays even under reduced
        // motion — just shorter, rather than removed.
        .animation(.easeInOut(duration: reducedMotion ? 0.25 : 0.5), value: tier)
        .animation(.easeInOut(duration: reducedMotion ? 0.15 : 0.3), value: books.isEmpty)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "books.vertical")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No books to show")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }
}
