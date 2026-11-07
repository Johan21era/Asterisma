//  LibraryFilterSidebarView.swift
//  AsterismaV2.5
//
//  Progressive Filtering — Phase I (Part 10 of the build spec)
//
//  "Users first reduce the scope of the library by selecting filters such
//  as author, series, genre, reading status, favorites, or custom
//  collections" (Appendix A). Every section below except Status/Favorites
//  only appears when the current library actually has values for it —
//  there's no point offering a Series filter with zero options.
//
//  Scope note: this is filtering, not organizing. It can filter BY an
//  existing BookCollection; it has no UI to create one — collection
//  creation/management is a different feature Part 10 doesn't ask for.
//  Until something elsewhere creates a BookCollection, the Collections
//  section simply won't appear (empty collections array), which is correct
//  behavior, not a bug.
//

import SwiftUI

struct LibraryFilterSidebarView: View {
    let books: [Book]
    let collections: [BookCollection]
    @Binding var filterState: LibraryFilterState

    var body: some View {
        List {
            Section("Search") {
                TextField("Search books", text: $filterState.searchText)
                    .textFieldStyle(.plain)
            }

            Section("Status") {
                Picker("Status", selection: $filterState.readingStatus) {
                    ForEach(ReadingStatusFilter.allCases, id: \.self) { status in
                        Text(status.displayName).tag(status)
                    }
                }
                .labelsHidden()
                .pickerStyle(.inline)

                Toggle("Favorites Only", isOn: $filterState.favoritesOnly)
            }

            if !availableFormats.isEmpty {
                Section("Format") {
                    ForEach(availableFormats, id: \.self) { format in
                        filterRow(format.displayName, isSelected: filterState.selectedFormat == format) {
                            filterState.selectedFormat = (filterState.selectedFormat == format) ? nil : format
                        }
                    }
                }
            }

            if !availableGenres.isEmpty {
                Section("Genre") {
                    ForEach(availableGenres, id: \.self) { genre in
                        filterRow(genre.displayName, isSelected: filterState.selectedGenre == genre) {
                            filterState.selectedGenre = (filterState.selectedGenre == genre) ? nil : genre
                        }
                    }
                }
            }

            if !availableAuthors.isEmpty {
                Section("Author") {
                    ForEach(availableAuthors, id: \.self) { author in
                        filterRow(author, isSelected: filterState.selectedAuthor == author) {
                            filterState.selectedAuthor = (filterState.selectedAuthor == author) ? nil : author
                        }
                    }
                }
            }

            if !availableSeries.isEmpty {
                Section("Series") {
                    ForEach(availableSeries, id: \.self) { series in
                        filterRow(series, isSelected: filterState.selectedSeries == series) {
                            filterState.selectedSeries = (filterState.selectedSeries == series) ? nil : series
                        }
                    }
                }
            }

            if !collections.isEmpty {
                Section("Collections") {
                    ForEach(collections) { collection in
                        filterRow(collection.name, isSelected: filterState.selectedCollectionID == collection.id) {
                            filterState.selectedCollectionID =
                                (filterState.selectedCollectionID == collection.id) ? nil : collection.id
                        }
                    }
                }
            }

            if filterState.isActive {
                Section {
                    Button("Clear All Filters") {
                        filterState.clearSelections()
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Available option derivation

    /// Only genres actually present in the current library, in the enum's
    /// own declared order — not the full 19-case list regardless of content.
    private var availableGenres: [ReadingGenre] {
        let present = Set(books.map(\.genre))
        return ReadingGenre.allCases.filter { present.contains($0) }
    }

    /// 2.5: only formats present in the library, in the enum's declared
    /// order (EPUB, PDF, CBZ, Comic) so the list is stable between launches.
    private var availableFormats: [BookFileType] {
        let present = Set(books.map(\.fileType))
        return BookFileType.allCases.filter { present.contains($0) }
    }

    private var availableAuthors: [String] {
        Array(Set(books.map(\.author))).sorted()
    }

    private var availableSeries: [String] {
        Array(Set(books.compactMap(\.series))).sorted()
    }

    // MARK: - Row

    @ViewBuilder
    private func filterRow(_ label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
