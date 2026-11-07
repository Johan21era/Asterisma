//  LibraryFilterState.swift
//  AsterismaV2.0
//
//  Progressive Filtering — Phase I (Part 10 of the build spec)
//
//  Covers all six filter dimensions Part 10 names at minimum: author,
//  series, genre, reading status, favorites, and custom collections.
//  `apply(to:)` is the entire filtering mechanism — it's what feeds
//  SpatialLibraryView (Phase F/G/H), which was deliberately built agnostic
//  to how its input array was produced.
//
//  Reading status reuses Book's own existing isCompleted/isInProgress
//  semantics (VERIFIED this session, Book 2.swift) rather than inventing a
//  parallel status concept — "not started" is simply currentPage == 0 &&
//  !isCompleted, the one state isInProgress's own definition already implies
//  but doesn't name.
//

import Foundation

enum ReadingStatusFilter: String, CaseIterable, Equatable {
    case all = "All"
    case notStarted = "Not Started"
    case inProgress = "In Progress"
    case completed = "Completed"

    var displayName: String { rawValue }
}

struct LibraryFilterState: Equatable {
    var searchText: String = ""
    var selectedAuthor: String?
    var selectedSeries: String?
    var selectedGenre: ReadingGenre?
    /// 2.5: filter by container format so a comic shelf can exclude prose.
    var selectedFormat: BookFileType?
    var readingStatus: ReadingStatusFilter = .all
    var favoritesOnly: Bool = false
    var selectedCollectionID: UUID?

    static let none = LibraryFilterState()

    var isActive: Bool {
        !searchText.isEmpty || selectedAuthor != nil || selectedSeries != nil || selectedGenre != nil
            || selectedFormat != nil
            || readingStatus != .all || favoritesOnly || selectedCollectionID != nil
    }

    mutating func clearSelections() {
        self = .none
    }

    /// The filtering step in Part 9.1's pipeline ("Full library →
    /// Progressive Filtering → filtered subset"). Read-only with respect to
    /// Book — every check below reads a Book property, none assigns one.
    func apply(to books: [Book]) -> [Book] {
        var result = books

        if !searchText.isEmpty {
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(searchText) ||
                    $0.author.localizedCaseInsensitiveContains(searchText)
            }
        }
        if let selectedAuthor {
            result = result.filter { $0.author == selectedAuthor }
        }
        if let selectedSeries {
            result = result.filter { $0.series == selectedSeries }
        }
        if let selectedGenre {
            result = result.filter { $0.genre == selectedGenre }
        }
        if let selectedFormat {
            result = result.filter { $0.fileType == selectedFormat }
        }
        switch readingStatus {
        case .all:
            break
        case .notStarted:
            result = result.filter { $0.currentPage == 0 && !$0.isCompleted }
        case .inProgress:
            result = result.filter { $0.isInProgress }
        case .completed:
            result = result.filter { $0.isCompleted }
        }
        if favoritesOnly {
            result = result.filter { $0.isFavorite }
        }
        if let selectedCollectionID {
            result = result.filter { $0.collectionIDs.contains(selectedCollectionID) }
        }
        return result
    }
}
