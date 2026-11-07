//  LibraryBrowserView.swift
//  AsterismaV2.0
//
//  One library, two presentations. This replaces the old arrangement where the
//  sidebar listed every book and an "Explore" menu item opened a second,
//  spatially-styled library in a modal sheet. Duplicate libraries created two
//  mental models for the same task and made the primary destination depend on
//  an overflow menu.
//
//  The browser owns presentation state (grid/list and shelf filter). Search,
//  sort, and selection remain owned by the main window so the library stays
//  consistent when the user moves between Home and Library.

import SwiftUI

struct LibraryBrowserView: View {
    /// Already searched and sorted by ContentView. This view applies only the
    /// shelf filter, so there is exactly one search/sort path.
    let books: [Book]
    let allBooks: [Book]

    @Binding var selectedBookID: UUID?
    @Binding var searchText: String
    @Binding var sortMode: LibrarySortMode

    let onOpenBook: (Book) -> Void
    let onShowInfo: (Book) -> Void
    let onEstimate: (Book) -> Void
    let onAddBook: () -> Void
    let onDiscover: () -> Void

    @State private var layout: BrowserLayout = .grid
    @State private var filter: BrowserShelfFilter = .all
    @FocusState private var searchFocused: Bool

    private var filteredBooks: [Book] {
        books.filter(filter.matches)
    }

    private var selectedBook: Book? {
        selectedBookID.flatMap { id in allBooks.first { $0.id == id } }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            filterBar

            if allBooks.isEmpty {
                emptyLibrary
            } else if filteredBooks.isEmpty {
                noMatches
            } else {
                GeometryReader { proxy in
                    libraryAndDock(availableWidth: proxy.size.width)
                }
            }
        }
        .background(
            Button("Focus Search") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        )
        .onChange(of: filteredBooks.map(\.id)) { _, visibleIDs in
            if let selectedBookID, !visibleIDs.contains(selectedBookID) {
                self.selectedBookID = nil
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 20) {
                    headerTitle
                    Spacer(minLength: 12)
                    headerActions
                }

                VStack(alignment: .leading, spacing: 12) {
                    headerTitle
                    headerActions
                }
            }

            HStack(spacing: 8) {
                searchField
                Button {
                    onDiscover()
                } label: {
                    Label("Discover", systemImage: "sparkle.magnifyingglass")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .padding(.horizontal, DesignGrid.workspaceHorizontalPadding)
        .padding(.top, DesignGrid.workspaceVerticalPadding)
        .padding(.bottom, 12)
    }

    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Library")
                .font(.system(size: 34, weight: .semibold, design: .serif))
            Text(countLabel)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            sortMenu
            layoutPicker
            Button {
                onAddBook()
            } label: {
                Label("Add Book", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private var countLabel: String {
        if filter == .all {
            return "\(allBooks.count) \(allBooks.count == 1 ? "book" : "books")"
        }
        return "\(filteredBooks.count) of \(allBooks.count) books · \(filter.title)"
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField("Search title, author, or series", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                .accessibilityLabel("Search library")

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .onExitCommand {
            if !searchText.isEmpty {
                searchText = ""
            } else {
                searchFocused = false
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(searchFocused ? 0.09 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(searchFocused ? 0.8 : 0), lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.12), value: searchFocused)
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $sortMode) {
                ForEach(LibrarySortMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(sortMode.label, systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .help("Sort the library")
    }

    private var layoutPicker: some View {
        Picker("Layout", selection: $layout) {
            ForEach(BrowserLayout.allCases) { option in
                Image(systemName: option.systemImage)
                    .tag(option)
                    .accessibilityLabel(option.title)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 82)
        .help("Grid or list")
    }

    /// A fixed 292 pt dock leaves only ~368 pt for the grid at the 900 pt
    /// window floor. The dock is therefore clamped between 236 and 292 pt and
    /// takes about a third of the canvas, so the grid keeps a usable column.
    private func libraryAndDock(availableWidth: CGFloat) -> some View {
        let dockWidth = min(DesignGrid.dockWidth, max(DesignGrid.dockMinWidth, availableWidth * 0.34))
        let compact = dockWidth < 270

        return HStack(spacing: 0) {
            libraryContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let selectedBook {
                Divider().opacity(0.25)
                bookDock(selectedBook, compact: compact)
                    .frame(width: dockWidth)
                    .frame(maxHeight: .infinity)
            }
        }
    }

    // MARK: - Filters

    private var filterBar: some View {
        HStack(spacing: 8) {
            ForEach(BrowserShelfFilter.allCases) { option in
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        filter = option
                    }
                } label: {
                    Text(option.title)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(
                                filter == option
                                    ? Color.accentColor.opacity(0.18)
                                    : Color.primary.opacity(0.05)
                            )
                        )
                        .overlay(
                            Capsule().strokeBorder(
                                filter == option
                                    ? Color.accentColor.opacity(0.45)
                                    : Color.primary.opacity(0.06),
                                lineWidth: 1
                            )
                        )
                }
                .buttonStyle(.plain)
                .foregroundStyle(filter == option ? Color.accentColor : Color.primary)
                .accessibilityLabel("\(option.title) filter")
                .accessibilityValue(filter == option ? "Selected" : "Not selected")
                .accessibilityAddTraits(filter == option ? .isSelected : [])
            }

            Spacer()
        }
        .padding(.horizontal, DesignGrid.workspaceHorizontalPadding)
        .padding(.vertical, 10)
    }

    // MARK: - Content

    @ViewBuilder
    private var libraryContent: some View {
        switch layout {
        case .grid:
            grid
        case .list:
            list
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: DesignGrid.shelfTileWidth, maximum: 166), spacing: DesignGrid.gridSpacing)],
                spacing: 26
            ) {
                ForEach(filteredBooks) { book in
                    gridTile(book)
                }
            }
            .padding(.horizontal, DesignGrid.workspaceHorizontalPadding)
            .padding(.vertical, 22)
        }
        .scrollIndicators(.automatic)
    }

    private func gridTile(_ book: Book) -> some View {
        let isSelected = selectedBookID == book.id

        return VStack(alignment: .leading, spacing: 7) {
            BookCoverCardView(
                book: book,
                width: DesignGrid.shelfTileWidth,
                height: DesignGrid.shelfTileHeight
            )

            if book.progressFraction > 0 {
                ProgressView(value: book.progressFraction)
                    .tint(.accentColor)
                    .frame(width: DesignGrid.shelfTileWidth)
                Text("\(Int(book.progressFraction * 100))% read")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if book.isCompleted {
                Label("Finished", systemImage: "checkmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Not started")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.075) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.7) : Color.clear,
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onOpenBook(book)
        }
        .onTapGesture {
            selectedBookID = book.id
        }
        .help("Click to select · Double-click to open")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(book.title) by \(book.author), \(Int(book.progressFraction * 100)) percent read"
        )
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var list: some View {
        List(selection: $selectedBookID) {
            ForEach(filteredBooks) { book in
                HStack(spacing: 12) {
                    BookCoverThumbnail(book: book, width: 34, height: 48)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(book.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(book.author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 12)

                    if book.isCompleted {
                        Label("Finished", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if book.progressFraction > 0 {
                        Text("\(Int(book.progressFraction * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    } else {
                        Text("Unread")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .tag(book.id)
                .onTapGesture(count: 2) {
                    onOpenBook(book)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .padding(.horizontal, 16)
    }

    // MARK: - Empty states

    private var emptyLibrary: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical")
                .font(.system(size: 54))
                .foregroundStyle(.secondary)
            Text("Your library is empty")
                .font(.title2.weight(.semibold))
            Text("Add an EPUB, PDF, or comic to start building your reading desk.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button {
                    onAddBook()
                } label: {
                    Label("Add Book", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    onDiscover()
                } label: {
                    Label("Discover Books", systemImage: "sparkle.magnifyingglass")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var noMatches: some View {
        VStack(spacing: 14) {
            ContentUnavailableView(
                "No books match",
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text("Clear the filters or try a different search.")
            )
            Button("Clear filters and search") {
                filter = .all
                searchText = ""
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - Book dock

    private func bookDock(_ book: Book, compact: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: compact ? 13 : 16) {
                HStack {
                    Text("Selected book")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        selectedBookID = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear selection")
                    .accessibilityLabel("Clear book selection")
                }

                BookCoverThumbnail(
                    book: book,
                    width: compact ? 100 : 118,
                    height: compact ? 142 : 168
                )
                .shadow(color: .black.opacity(0.24), radius: 12, y: 6)

                VStack(alignment: .leading, spacing: 5) {
                    Text(book.title)
                        .font(.headline)
                        .lineLimit(compact ? 4 : 3)
                    Text(book.author)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 6) {
                    dockPill(book.fileType.displayName)
                    if book.isCompleted {
                        dockPill("Finished")
                    } else if book.isInProgress {
                        dockPill("In progress")
                    } else {
                        dockPill("Unread")
                    }
                }

                if book.progressFraction > 0 {
                    VStack(alignment: .leading, spacing: 5) {
                        ProgressView(value: book.progressFraction)
                            .tint(.accentColor)
                        Text("\(Int(book.progressFraction * 100))% · \(max(0, book.totalPages - book.currentPage)) pages left")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        onOpenBook(book)
                    } label: {
                        Label("Open Book", systemImage: "book")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        infoButton(book)
                        estimateButton(book)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        infoButton(book)
                        estimateButton(book)
                    }
                }
                .controlSize(.regular)

                Divider()

                VStack(alignment: .leading, spacing: 9) {
                    dockFact("Pages", "\(book.totalPages)")
                    dockFact("Notes", "\(book.notes.count)")
                    dockFact("Sessions", "\(book.completedSessionCount)")
                    dockFact("Reading time", formatDuration(book.totalReadingTime))
                    dockFact("Last read", lastReadLabel(book))
                }

                Spacer(minLength: 0)
            }
            .padding(compact ? 16 : 20)
        }
        .background(.regularMaterial)
    }

    private func infoButton(_ book: Book) -> some View {
        Button {
            onShowInfo(book)
        } label: {
            Label("Info", systemImage: "info.circle")
        }
        .buttonStyle(.bordered)
    }

    private func estimateButton(_ book: Book) -> some View {
        Button {
            onEstimate(book)
        } label: {
            Label("Estimate", systemImage: "chart.bar")
        }
        .buttonStyle(.bordered)
    }

    private func dockPill(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.06), in: Capsule())
    }

    private func dockFact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 10)
            Text(value)
                .font(.caption.monospacedDigit())
                .lineLimit(1)
        }
    }

    private func lastReadLabel(_ book: Book) -> String {
        guard let date = book.lastReadDate else { return "Not started" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

// MARK: - Presentation enums

enum BrowserLayout: String, CaseIterable, Identifiable {
    case grid
    case list

    var id: String { rawValue }

    var title: String {
        switch self {
        case .grid: return "Grid"
        case .list: return "List"
        }
    }

    var systemImage: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .list: return "list.bullet"
        }
    }
}

enum BrowserShelfFilter: String, CaseIterable, Identifiable {
    case all
    case reading
    case unread
    case finished
    case favorites

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .reading: return "Reading"
        case .unread: return "Unread"
        case .finished: return "Finished"
        case .favorites: return "Favorites"
        }
    }

    func matches(_ book: Book) -> Bool {
        switch self {
        case .all: return true
        case .reading: return book.isInProgress
        case .unread: return !book.isCompleted && book.currentPage == 0
        case .finished: return book.isCompleted
        case .favorites: return book.isFavorite
        }
    }
}
