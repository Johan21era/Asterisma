//  LibraryExplorerView2.swift
//  AsterismaV2.5
//
//  Created by Johan Rembeci on 7/13/26.
//
//
//  LibraryExplorerView.swift
//  AsterismaV2.5
//
//  Progressive Filtering — Phase I entry point (Part 9.1, Part 10 of the build spec)
//
//  Enforces Part 9.1's pipeline order in one place: filtering happens
//  first and produces a subset; SpatialLibraryView (Phase F/G/H) only ever
//  operates on that already-filtered subset, never on `allBooks` directly.
//  Selecting a filter that drops the subset across a tier threshold (e.g.
//  16 books down to 4) is handled automatically — SpatialLibraryView's own
//  cross-fade, built in Phase F specifically for this moment, takes care of
//  it without anything new here.
//
//  Uses NavigationSplitView (not HSplitView) to match the root ContentView's
//  own navigation paradigm (NewContentView.swift), confirmed in Phase A —
//  same reasoning as matching the house ObservableObject convention earlier
//  in this project: consistency with what's already there over introducing
//  a second pattern for the same job.
//
//  WIRED: NewContentView presents this from the Explore toolbar item.
//  Keeping the header truthful matters more than preserving the old phase
//  narrative; the Phase-K note was stale.
//

import SwiftUI

struct LibraryExplorerView: View {
    let allBooks: [Book]
    let collections: [BookCollection]
    var reducedMotion: Bool = false
    var onSelect: (Book) -> Void

    @State private var filterState = LibraryFilterState.none
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .automatic

    private var filteredBooks: [Book] {
        filterState.apply(to: allBooks)
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            LibraryFilterSidebarView(books: allBooks, collections: collections, filterState: $filterState)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            SpatialLibraryView(books: filteredBooks, reducedMotion: reducedMotion, onSelect: onSelect)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) {
                    if filterState.isActive {
                        resultCountBanner
                    }
                }
        }
    }

    private var resultCountBanner: some View {
        Text("\(filteredBooks.count) of \(allBooks.count) books")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 8)
    }
}
