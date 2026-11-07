//  NewContentView.swift
//  AsterismaV2.0
//
//  THE MAIN WINDOW SHELL
//
//  One sidebar, four durable destinations (Home, Library, Insights, Goals),
//  and one main canvas. The reader still owns a NavigationStack path, so its
//  back button, title, and toolbar behavior are unchanged.
//
//  Home is the launch surface: a resume-first reading desk with live stats and
//  shelves. Library is the real browser: adaptive grid/list, search, shelf
//  filters, and a selected-book dock. Insights and Goals are embedded here
//  rather than trapped in sheets. Secondary surfaces (discovery, annual
//  reports, recommendations, achievements, session history, environment and
//  context insights, import/export, erase) live in the sidebar's More menu.
//
//  SHEET DISMISS AFFORDANCE NOTE (NA-9 verification): every top-level sheet in
//  this file presents .sheetDismissAffordance() EXCEPT BookDiscoveryView — which
//  was verified during RA-002 to carry its OWN header-bar close control with
//  Escape support (BookDiscoveryView.swift headerBar), so adding the floating
//  overlay here would render two close controls on one sheet. The LT-2 invariant
//  "a dead-end sheet is structurally impossible" holds for all sheets.

import SwiftUI
import UniformTypeIdentifiers
import WebKit

// MARK: - Sheet dismissal affordance (LIVE-TEST LT-1/LT-2/LT-4 systemic fix)

/// LIVE TESTING LT-1/LT-2/LT-4: several analytics sheets shipped with NO way to
/// close them (Discover Books, Annual Reports, Insights…), trapping the user until
/// force-quit. This floating close affordance + Escape shortcut is applied at every
/// top-level sheet root so a sheet can never again be a dead end.
private struct SheetDismissAffordance: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.secondary)
                    .background(Circle().fill(.regularMaterial))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Close (Esc)")
            .padding(14)
        }
    }
}

extension View {
    func sheetDismissAffordance() -> some View { modifier(SheetDismissAffordance()) }
}

// MARK: - ContentView

struct ContentView: View {
    @EnvironmentObject private var dataStore: DataStore
    @EnvironmentObject private var sessionCoordinator: SessionCoordinator
    @EnvironmentObject private var goalVM: GoalProgressViewModel
    @EnvironmentObject private var contextEngine: BehaviorContextEngine

    /// AUDIT §1.1 / D5 WIRING (Phase 2): the single shared EnvironmentEngine,
    /// owned here via @StateObject exactly as EnvironmentBackgroundView2's header
    /// prescribes ("ContentView owns the single instance"; a default argument or
    /// ObservedObject-owned engine would multiply 45s recompute loops).
    @StateObject private var environmentEngine = EnvironmentEngine()

    /// Used by the Sentinel launch card to open the Health Center window.
    @Environment(\.openWindow) private var openWindow

    /// Opens the Settings window from Quick Open; the App scene owns the window.
    @Environment(\.openSettings) private var openSettings

    // Estimation state (unchanged)
    @State private var inspectedBook: Book?
    @State private var detailsBook: Book?
    @State private var currentEstimation: BookEstimationResult?
    @State private var importError: String?
    @State private var bookOpenNotice: String?

    // ── Feature sheet presentation ─────────────────────────────────────────
    @State private var showRecommendations: Bool = false
    @State private var showAchievements: Bool = false
    @State private var showSessionHistory: Bool = false
    @State private var showDiscovery: Bool = false
    @State private var showAnnualReports: Bool = false
    @State private var showContextInsights: Bool = false
    @State private var showWeatherInsights: Bool = false
    @State private var importWarnings: [String]?

    // ── Achievement toast ──────────────────────────────────────────────────
    @State private var toastAchievement: EarnedAchievement?
    @State private var toastVisible: Bool = false
    @State private var pendingToasts: [EarnedAchievement] = []

    // P5 Feature 5: onboarding + library search/sort
    @AppStorage("onboarding.completed") private var onboardingDismissed = false
    @State private var showOnboarding = false
    @State private var searchText = ""
    @State private var sortMode: LibrarySortMode = .dateAddedDesc
    @State private var selectedBookID: Book.ID?
    @State private var readerBookID: Book.ID?
    @State private var missingBook: Book?
    @State private var showEraseConfirmation = false
    @State private var eraseNotice: String?
    @State private var sidebarWidth: CGFloat = DesignGrid.sidebarIdealWidth
    @State private var sidebarDragStart: CGFloat?
    @State private var section: AppSection = .home
    @State private var showCommandPalette = false

    // P6 / SG4: the launch card now reads the v2 runtime, and Review always
    // opens the Health Center — a real Release window, not the Debug console.
    @StateObject private var sentinelHealth = SentinelViewModel()
    @State private var sentinelReport: SentinelLaunchSummary?

    private var sentinelReviewAction: (() -> Void)? {
        {
            withAnimation { sentinelReport = nil }
            openWindow(id: SentinelHealthCenterWindowID.id)
        }
    }

    /// Filtered+sorted library source for the Home shelves and Library browser.
    ///
    /// Owner-test F5: the old memoization cache could hold an empty array
    /// against a signature that already described the loaded library, so the
    /// sidebar showed 0 while DataStore had 7 books. A direct computation is
    /// cheap for this library and always reflects the live store.
    private var visibleBooks: [Book] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = query.isEmpty ? dataStore.books : dataStore.books.filter {
            $0.title.lowercased().contains(query) ||
                $0.author.lowercased().contains(query) ||
                ($0.series ?? "").lowercased().contains(query)
        }
        return filtered.sorted(by: sortMode.sort)
    }

    // MARK: - Navigation shell

    /// A persistent four-destination sidebar. It replaces the old book list,
    /// which duplicated the library and hid every secondary surface behind an
    /// ellipsis menu. The library itself now lives in the main canvas, where it
    /// has room for a grid, a list, search, and a selected-book dock.
    private var navigationSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            sidebarHeader
            quickOpenButton

            VStack(spacing: 3) {
                ForEach(AppSection.allCases) { destination in
                    navigationRow(destination)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            if section == .home {
                jumpBackIn
            }

            Spacer(minLength: 12)
            sidebarFooter
        }
        .frame(width: sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.clear)
        .overlay(alignment: .trailing) { sidebarResizeHandle }
    }

    /// A visible, keyboard-reachable entry point for the palette. The shortcut
    /// is attached to a real control rather than a hidden button, so it also
    /// works when the pointer never enters the sidebar.
    private var quickOpenButton: some View {
        Button {
            showCommandPalette = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                Text("Quick open")
                    .font(.system(size: 12))
                Spacer(minLength: 4)
                Text("⌘K")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("k", modifiers: .command)
        .help("Find a book, destination, or action (⌘K)")
        .accessibilityLabel("Quick open")
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var sidebarHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Asterisma")
                .font(.system(size: 21, weight: .semibold, design: .serif))
            Text("Reading desk")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private func navigationRow(_ destination: AppSection) -> some View {
        let isSelected = section == destination

        return Button {
            selectSection(destination)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: destination.systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 18)

                Text(destination.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))

                Spacer(minLength: 6)

                if let badge = badgeCount(for: destination) {
                    Text("\(badge)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: DesignGrid.navRowCornerRadius, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.10) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(destination.shortcut, modifiers: .command)
        .help(destination.purpose)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func badgeCount(for destination: AppSection) -> Int? {
        switch destination {
        case .home:
            let count = dataStore.books.filter(\.isInProgress).count
            return count > 0 ? count : nil
        case .library:
            return dataStore.books.isEmpty ? nil : dataStore.books.count
        case .insights, .goals:
            return nil
        }
    }

    private var inProgressBooks: [Book] {
        dataStore.books
            .filter(\.isInProgress)
            .sorted { ($0.lastReadDate ?? .distantPast) > ($1.lastReadDate ?? .distantPast) }
    }

    @ViewBuilder
    private var jumpBackIn: some View {
        let books = Array(inProgressBooks.prefix(3))

        if !books.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("Jump back in")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 4)

                ForEach(books) { book in
                    Button {
                        openBook(book)
                    } label: {
                        HStack(spacing: 9) {
                            BookCoverThumbnail(book: book, width: 26, height: 36)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(book.title)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                Text("\(Int(book.progressFraction * 100))% read")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Resume \(book.title)")
                }
            }
        }
    }

    private var sidebarFooter: some View {
        VStack(spacing: 10) {
            Divider()
                .opacity(0.16)
                .padding(.horizontal, 14)

            Button(action: addItem) {
                Label("Add Book", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 14)

            HStack(spacing: 8) {
                libraryActionsMenu
                Spacer(minLength: 0)
                Text("\(dataStore.books.count) \(dataStore.books.count == 1 ? "book" : "books")")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
    }

    private var libraryActionsMenu: some View {
        Menu {
            Button {
                showDiscovery = true
            } label: {
                Label("Discover Books", systemImage: "sparkle.magnifyingglass")
            }

            Button {
                showRecommendations = true
            } label: {
                Label("What to Read Next", systemImage: "star.leadinghalf.filled")
            }

            Button {
                showAchievements = true
            } label: {
                Label("Achievements", systemImage: "medal")
            }

            Button {
                showSessionHistory = true
            } label: {
                Label("Session History", systemImage: "clock.arrow.circlepath")
            }

            Divider()

            Button {
                showAnnualReports = true
            } label: {
                Label("Annual Reports", systemImage: "chart.bar.doc.horizontal")
            }

            Button {
                showWeatherInsights = true
            } label: {
                Label("Environment", systemImage: "cloud.sun")
            }

            Button {
                showContextInsights = true
            } label: {
                Label("Your Context", systemImage: "brain")
            }

            Divider()

            Button {
                exportLibrary()
            } label: {
                Label("Export Library…", systemImage: "square.and.arrow.up")
            }

            Button {
                importLibrary()
            } label: {
                Label("Import Library…", systemImage: "square.and.arrow.down")
            }

            Divider()

            Button(role: .destructive) {
                showEraseConfirmation = true
            } label: {
                Label("Erase Library & Data…", systemImage: "trash")
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .help("More actions")
        .accessibilityLabel("More actions")
    }

    // MARK: - Main canvas

    private var mainCanvas: some View {
        // A single item-driven destination, not a typed NavigationPath. The
        // reader used to bind `[UUID]`, and macOS 26's NavigationColumnState
        // asserted with `AnyNavigationPath.Error.comparisonTypeMismatch` when
        // that path was replaced after a nested stack had been on screen.
        // `navigationDestination(item:)` keeps the push internal to SwiftUI
        // and has no path type for it to compare.
        NavigationStack {
            ZStack {
                if let book = inspectedBook, let estimation = currentEstimation {
                    estimationScreen(book: book, estimation: estimation)
                } else {
                    sectionContent
                }
            }
            .navigationDestination(item: $readerBookID) { id in
                if let book = dataStore.book(id: id) {
                    Group {
                        switch book.fileType {
                        case .pdf:
                            PDFReaderScreen(book: book, coordinator: sessionCoordinator)
                        case .epub:
                            EPUBReaderScreen(book: book, coordinator: sessionCoordinator)
                        case .cbz, .comic:
                            ComicReaderScreen(book: book, coordinator: sessionCoordinator)
                        }
                    }
                    // The readers close themselves with @Environment(\.dismiss).
                    // Clear the item when they leave so the sidebar and keyboard
                    // handling cannot get stranded behind a popped destination.
                    .onDisappear {
                        if readerBookID == id { readerBookID = nil }
                    }
                } else {
                    Text("This book is no longer in your library.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .onExitCommand {
            if readerBookID != nil {
                readerBookID = nil
            } else if inspectedBook != nil {
                inspectedBook = nil
                currentEstimation = nil
            } else if section != .home {
                selectSection(.home)
            }
        }
    }

    private var commandPaletteIndex: CommandPaletteIndex {
        let books = dataStore.books
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .map { book in
                CommandPaletteBook(
                    id: book.id,
                    title: book.title,
                    author: book.author,
                    series: book.series
                )
            }
        return CommandPaletteIndex(books: books)
    }

    private func handlePaletteSelection(_ item: CommandPaletteItem) {
        showCommandPalette = false
        switch item.target {
        case .section(let destination):
            selectSection(destination)
        case .book(let id):
            guard let book = dataStore.book(id: id) else { return }
            openBook(book)
        case .discover:
            showDiscovery = true
        case .addBook:
            addItem()
        case .settings:
            openSettings()
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch section {
        case .home:
            ReadingDeskView(
                onOpenBook: { openBook($0) },
                onShowBook: { book in
                    selectedBookID = book.id
                    selectSection(.library)
                },
                onBrowseLibrary: { selectSection(.library) },
                onAddBook: addItem,
                onOpenInsights: { selectSection(.insights) },
                onOpenGoals: { selectSection(.goals) },
                onDiscover: { showDiscovery = true }
            )

        case .library:
            LibraryBrowserView(
                books: visibleBooks,
                allBooks: dataStore.books,
                selectedBookID: $selectedBookID,
                searchText: $searchText,
                sortMode: $sortMode,
                onOpenBook: { openBook($0) },
                onShowInfo: { detailsBook = $0 },
                onEstimate: { book in
                    let result = EstimationEngine.estimate(for: book, allBooks: dataStore.books)
                    inspectedBook = book
                    currentEstimation = EstimationEngine.validate(result: result)
                },
                onAddBook: addItem,
                onDiscover: { showDiscovery = true }
            )

        case .insights:
            ReadingInsightsDashboard(embedded: true)
                .environmentObject(dataStore)

        case .goals:
            GoalsDashboard(embedded: true)
                .environmentObject(goalVM)
                .environmentObject(dataStore)
        }
    }

    private func estimationScreen(book: Book, estimation: BookEstimationResult) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    inspectedBook = nil
                    currentEstimation = nil
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()
                .opacity(0.15)

            BookEstimationView(book: book, estimation: estimation)
        }
    }

    private func selectSection(_ destination: AppSection) {
        withAnimation(.easeOut(duration: 0.15)) {
            section = destination
            inspectedBook = nil
            currentEstimation = nil
        }
    }

    /// A transparent drag strip at the sidebar edge. The tonal gradient is the
    /// only separation; there is deliberately no second border here.
    private var sidebarResizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 7)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if sidebarDragStart == nil { sidebarDragStart = sidebarWidth }
                        let proposed = (sidebarDragStart ?? sidebarWidth) + value.translation.width
                        sidebarWidth = min(max(proposed, DesignGrid.sidebarMinWidth), DesignGrid.sidebarMaxWidth)
                    }
                    .onEnded { _ in sidebarDragStart = nil }
            )
    }

    private func openBook(_ book: Book) {
        // A view can hold a Book value that was removed from the store (a
        // stale shelf, a palette result, a deferred action). Pushing its id
        // would open a destination with no backing record, so refuse the
        // navigation and explain instead.
        guard let liveBook = dataStore.book(id: book.id) else {
            bookOpenNotice = "\u{201C}\(book.title)\u{201D} is no longer in your library. "
                + "Refresh the library or re-import the file."
            return
        }
        // A moved or deleted source file is also a normal state. Do not push a
        // reader that can only fail: offer the relink path in an alert first.
        guard liveBook.isFileAvailable else {
            missingBook = liveBook
            return
        }
        selectedBookID = liveBook.id
        if readerBookID != liveBook.id {
            readerBookID = liveBook.id
        }
    }

    /// Opens the same restricted panel the importer uses, then attaches the
    /// chosen file to the existing record. Progress, notes, sessions, and
    /// collections all survive because only the source location changes.
    private func locateFile(for book: Book) {
        BookFilePicker.chooseReplacement(for: book) { url in
            guard let url else { return }
            do {
                let relinked = try dataStore.relinkBookFile(id: book.id, to: url)
                openBook(relinked)
            } catch {
                bookOpenNotice = error.localizedDescription
            }
        }
    }

    /// Arrow keys move the sidebar selection; Return opens it. Typing in the
    /// search field is passed through untouched by KeyNavigationConfigurator.
    private func handleKeyCommand(_ command: KeyNavigationCommand) -> Bool {
        guard readerBookID == nil else { return false }

        switch command {
        case .up, .left:
            guard section == .library else { return false }
            moveSelection(-1)
            return true
        case .down, .right:
            guard section == .library else { return false }
            moveSelection(1)
            return true
        case .returnKey:
            guard section == .library,
                  let id = selectedBookID,
                  let book = dataStore.book(id: id)
            else { return false }
            openBook(book)
            return true
        case .escape:
            if inspectedBook != nil {
                inspectedBook = nil
                currentEstimation = nil
                return true
            }
            if !searchText.isEmpty {
                searchText = ""
                return true
            }
            if section != .home {
                selectSection(.home)
                return true
            }
            return false
        }
    }

    private func moveSelection(_ delta: Int) {
        let books = visibleBooks
        guard !books.isEmpty else { return }

        let current = selectedBookID.flatMap { id in
            books.firstIndex(where: { $0.id == id })
        }
        let next: Int
        if let current {
            next = min(max(current + delta, 0), books.count - 1)
        } else {
            next = delta >= 0 ? 0 : books.count - 1
        }
        selectedBookID = books[next].id
    }

    /// Destructive test reset. Closes active sessions, erases the whole
    /// app-owned data root, and resets every in-memory surface that could
    /// otherwise retain the previous library.
    private func eraseAllUserData() {
        sessionCoordinator.endAllActiveSessions()
        Task { await SentinelAppIntegration.stop() }

        do {
            try dataStore.eraseAllUserData()
            contextEngine.reset()
            inspectedBook = nil
            currentEstimation = nil
            selectedBookID = nil
            readerBookID = nil
            section = .home
            searchText = ""
            importWarnings = nil
            importNotice = nil
            showOnboarding = false
            sentinelReport = nil

            WKWebsiteDataStore.default().removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast,
                completionHandler: {}
            )
            WeatherKitService.shared.resetStore()

            Task { await SentinelAppIntegration.start(dataStore: dataStore) }
            eraseNotice = "The library and all app-owned data were erased. You are starting from a clean slate."
        } catch {
            Task { await SentinelAppIntegration.start(dataStore: dataStore) }
            importError = "Could not erase all data: \(error.localizedDescription)"
        }
    }

    // P5 Feature 1: durability
    @State private var importNotice: String?
    @State private var pendingImportURL: URL?

    private func exportLibrary() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: LibraryArchiveManager.fileExtension) ?? .data]
        panel.nameFieldStringValue = "AsterismaV2.0-Backup." + LibraryArchiveManager.fileExtension
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try LibraryArchiveManager.shared.exportLibrary(from: dataStore)
                try data.write(to: url, options: .atomic)
                importNotice = "Library exported successfully."
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func importLibrary() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            UTType(filenameExtension: LibraryArchiveManager.fileExtension) ?? .data,
            .json,
        ]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard let data = try? Data(contentsOf: url) else {
                importError = "Could not read that file."
                return
            }
            do {
                let s = try LibraryArchiveManager.shared.summarize(archiveData: data)
                pendingImportURL = url
                let goalsText = s.hasGoals ? "goals included" : "no goals set"
                importNotice = "REPLACE LIBRARY? Found \(s.bookCount) books, "
                    + "\(s.sessionCount) sessions, \(goalsText). "
                    + "Your current library is auto-backed-up first. Use Import again to confirm — or Cancel now."
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func performConfirmedImportIfArmed() {
        guard let url = pendingImportURL else {
            importLibrary()
            return
        }
        pendingImportURL = nil
        guard let data = try? Data(contentsOf: url) else {
            importError = "Could not read that file."
            return
        }
        do {
            try LibraryArchiveManager.shared.importLibrary(data, into: dataStore)
            importNotice = "Library restored."
        } catch {
            importError = error.localizedDescription
        }
    }

    var body: some View {
        ZStack {
            EnvironmentBackgroundView(engine: environmentEngine)
                .ignoresSafeArea()

            // One continuous tonal surface. The leading gradient gives the
            // sidebar legibility without a panel, card, border, or divider.
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.32), location: 0.0),
                    .init(color: .black.opacity(0.16), location: 0.20),
                    .init(color: .clear, location: 0.46),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            HStack(spacing: 0) {
                if readerBookID == nil {
                    navigationSidebar
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                mainCanvas
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.2), value: readerBookID == nil)
        }
        .background(WindowChromeConfigurator())
        .background(WindowToolbarVisibility(visible: false))
        .background(KeyNavigationConfigurator(isEnabled: readerBookID == nil, onCommand: handleKeyCommand))
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .environmentObject(environmentEngine) // Phase 2: downstream consumers read the same instance
        // P5 Feature 5: first-run wizard when library is empty and never dismissed.
        .onChange(of: dataStore.books.isEmpty) { _, empty in
            showOnboarding = empty && !onboardingDismissed
        }
        .onAppear {
            showOnboarding = OnboardingView.shouldShow(
                books: dataStore.books, dismissed: onboardingDismissed
            )
            // SG4: one integration point starts the v2 runtime, attaches the
            // live snapshot source and repair bridge, and runs its launch
            // cycle. The v1 engine is no longer started from the app.
            Task { @MainActor in
                await SentinelAppIntegration.start(dataStore: dataStore)
                await sentinelHealth.refresh()
                sentinelReport = sentinelHealth.launchSummary()
            }

        }
        .onChange(of: selectedBookID) { _, _ in
            // A different selection supersedes any hover estimate.
            inspectedBook = nil
            currentEstimation = nil
        }
        .sheet(isPresented: $showOnboarding, onDismiss: { onboardingDismissed = true }) {
            OnboardingView()
                .environmentObject(dataStore)
        }

        // ── Import error alert (unchanged) ─────────────────────────────────
        .alert("Import Failed", isPresented: Binding(
            get: { importError != nil },
            set: {
                if !$0 {
                    importError = nil
                }
            }
        )) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }

        .alert("Book Unavailable", isPresented: Binding(
            get: { bookOpenNotice != nil },
            set: { if !$0 { bookOpenNotice = nil } }
        )) {
            Button("OK") { bookOpenNotice = nil }
        } message: {
            Text(bookOpenNotice ?? "")
        }

        .alert("Book File Missing", isPresented: Binding(
            get: { missingBook != nil },
            set: { if !$0 { missingBook = nil } }
        )) {
            Button("Locate File…") {
                let book = missingBook
                missingBook = nil
                if let book { locateFile(for: book) }
            }
            Button("Cancel", role: .cancel) { missingBook = nil }
        } message: {
            Text("Asterisma can't find the file for “\(missingBook?.title ?? "this book")”. " +
                "It may have been moved, renamed, or deleted. Choose Locate File… to point " +
                "Asterisma at it; your reading progress and notes are kept.")
        }

        // ── AUDIT §1.1 verdict executed (Phase 2): Import Intelligence surfaces ──
        // ROADMAP 2.2: also carries the duplicate-import notice.
        .alert("Import Notes", isPresented: Binding(
            get: { importWarnings != nil },
            set: { if !$0 { importWarnings = nil } }
        )) {
            Button("OK") { importWarnings = nil }
        } message: {
            Text(importWarnings?.joined(separator: "\n") ?? "")
        }

        // P5 Feature 1: archive import confirm / result notices
        .alert("Library Archive", isPresented: Binding(
            get: { importNotice != nil },
            set: { if !$0 { importNotice = nil; pendingImportURL = nil } }
        )) {
            if pendingImportURL != nil {
                Button("Replace My Library", role: .destructive) {
                    performConfirmedImportIfArmed()
                }
                Button("Cancel", role: .cancel) {
                    pendingImportURL = nil
                }
            } else {
                Button("OK") { importNotice = nil }
            }
        } message: {
            Text(importNotice ?? "")
        }

        // ── Feature sheets ─────────────────────────────────────────────────
        .sheet(isPresented: $showRecommendations) {
            RecommendationPanel()
                .environmentObject(dataStore)
                .sheetDismissAffordance()
        }
        .sheet(isPresented: $showAchievements) {
            AchievementPanel()
                .environmentObject(dataStore)
                .onAppear { dataStore.clearNewAchievements() }
                .sheetDismissAffordance()
        }
        .sheet(isPresented: $showSessionHistory) {
            SessionHistoryView()
                .environmentObject(dataStore)
                .sheetDismissAffordance()
        }
        .sheet(isPresented: $showDiscovery) {
            // NA-9 (verified): this view ships its own header close control +
            // Escape shortcut; the floating overlay is intentionally NOT stacked.
            BookDiscoveryView()
        }
        .sheet(isPresented: $showAnnualReports) {
            AnnualReportArchiveView()
                .environmentObject(dataStore)
                .sheetDismissAffordance()
        }
        .sheet(isPresented: $showContextInsights) {
            ContextInsightPanel()
                .environmentObject(contextEngine)
                .sheetDismissAffordance()
        }
        .sheet(isPresented: $showWeatherInsights) {
            WeatherInsightPanel()
                .environmentObject(dataStore)
                .sheetDismissAffordance()
        }
        .sheet(item: $detailsBook) { book in
            BookDetailsView(bookID: book.id)
                .environmentObject(dataStore)
        }

        // ── Destructive testing reset ──────────────────────────────────────
        .confirmationDialog(
            "Erase all library data?",
            isPresented: $showEraseConfirmation,
            titleVisibility: .visible
        ) {
            Button("Erase Everything", role: .destructive) {
                eraseAllUserData()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the library, reading history, page timings, goals, achievements, notes, collections, covers, weather/audio/behavior records, backups, caches, and Mirage data. App preferences and window layout are kept. This cannot be undone.")
        }
        .alert("Library Erased", isPresented: Binding(
            get: { eraseNotice != nil },
            set: { if !$0 { eraseNotice = nil } }
        )) {
            Button("OK") { eraseNotice = nil }
        } message: {
            Text(eraseNotice ?? "")
        }

        // ── Achievement toast ──────────────────────────────────────────────
        .onReceive(dataStore.$newlyEarnedAchievements) { newly in
            // AUDIT §2.2: queue everything new instead of dropping updates while
            // a toast is visible or reading only `.first` of a batch.
            let knownIDs = Set(pendingToasts.map(\.id))
            let fresh = newly.filter { $0.id != toastAchievement?.id && !knownIDs.contains($0.id) }
            guard !fresh.isEmpty else { return }
            pendingToasts.append(contentsOf: fresh)
            showNextToastIfNeeded()
        }
        .overlay(alignment: .top) {
            if toastVisible, let achievement = toastAchievement {
                AchievementToastView(achievement: achievement) {
                    // Tap opens the full achievements panel
                    withAnimation(.easeOut) { toastVisible = false }
                    if let tapped = toastAchievement {
                        dataStore.markAchievementToastShown(id: tapped.id)
                    }
                    toastAchievement = nil
                    pendingToasts.removeAll()
                    showAchievements = true
                }
                .padding(.top, DesignGrid.hudTopInset)
                .padding(.horizontal, DesignGrid.toastHorizontalInset)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // AUDIT §1.2 / TECH_DEBT D1: persistent (dismiss-on-fix) persistence banner.
        .overlay(alignment: .bottom) {
            if case .degraded(let message) = dataStore.persistenceHealth {
                PersistenceWarningBanner(message: message)
            }
        }
        // P5 Feature 3 + UI REVIEW grid: HUD inset from shared constants.
        .overlay(alignment: .topLeading) {
            if readerBookID == nil {
                ReadingHUD()
                    .padding(.leading, DesignGrid.hudLeadingInset)
                    .padding(.top, DesignGrid.hudTopInset)
            }
        }

        // Quick Open is the last overlay so it sits above the HUD, toasts, and
        // the Sentinel card. The dimmed backdrop is also a dismissal target.
        .overlay {
            if showCommandPalette {
                ZStack {
                    Color.black.opacity(0.32)
                        .ignoresSafeArea()
                        .onTapGesture { showCommandPalette = false }

                    CommandPaletteView(
                        index: commandPaletteIndex,
                        onSelect: handlePaletteSelection,
                        onDismiss: { showCommandPalette = false }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: showCommandPalette)

        // P6: "While you were away" Sentinel card (top-center, above toasts).
        .overlay(alignment: .top) {
            if let report = sentinelReport {
                SentinelReportCardView(
                    fixed: report.fixed,
                    stalled: report.needsDecision,
                    headline: report.headline,
                    onReview: sentinelReviewAction
                ) {
                    withAnimation { sentinelReport = nil }
                }
                .padding(.top, 8)
                .padding(.leading, sidebarWidth + 20)
                .padding(.trailing, 40)
            }
        }
        // Owner-test F4: the main window had no usable minimum; macOS restored
        // a 900x450 frame and the toolbar buttons were inaccessible. This floor
        // also gives the green zoom button something to zoom to.
        .frame(minWidth: 900, minHeight: 640)
    }

    // MARK: - Toolbar: Add Book

    private func addItem() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        // Folder-form EPUBs are directories/packages on macOS. Allow selecting
        // them; BookImporter validates that the directory actually contains an
        // EPUB container.xml before importing.
        BookImportPanel.configure(panel)

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    let book = try await BookImporter.importBook(from: url)

                    // Phase 2 — Import Intelligence verdict EXECUTED: the previously
                    // unreachable ~250-line facade now analyzes every real import;
                    // findings surface to the user instead of vanishing (AUDIT §1.1).
                    let fileSizeBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
                    let report = ImportIntelligenceFacade.analyze(
                        book: book,
                        fileName: url.lastPathComponent,
                        fileSizeBytes: fileSizeBytes,
                        fileType: book.fileType.displayName
                    )
                    var messages = report.warnings.map { warning -> String in
                        (warning.level == .critical ? "⚠️ " : "• ") + warning.message
                    }

                    // ROADMAP 2.2 (O-8): addBook previously returned Void and silently
                    // dropped duplicates — importing the same file twice gave zero
                    // feedback. It now reports acceptance; rejection becomes a visible
                    // note through the existing Import Notes alert channel.
                    let accepted = dataStore.addBook(book)
                    if !accepted {
                        messages.append("• This book is already in your library (same file). Nothing was added.")
                    }

                    await MainActor.run {
                        if !messages.isEmpty { importWarnings = messages }
                    }
                } catch {
                    await MainActor.run { importError = error.localizedDescription }
                }
            }
        }
    }

    /// AUDIT §2.2: presents queued achievements one at a time, consuming each
    /// from DataStore as its toast finishes — nothing dropped, nothing re-shown.
    private func showNextToastIfNeeded() {
        guard !toastVisible, !pendingToasts.isEmpty else { return }
        toastAchievement = pendingToasts.removeFirst()
        withAnimation(.spring(duration: 0.4)) { toastVisible = true }

        Task {
            try? await Task.sleep(for: .seconds(3.5))
            withAnimation(.easeOut(duration: 0.3)) { toastVisible = false }
            try? await Task.sleep(for: .seconds(0.3))
            if let shown = toastAchievement {
                dataStore.markAchievementToastShown(id: shown.id)
            }
            toastAchievement = nil
            showNextToastIfNeeded()
        }
    }
}

// MARK: - Persistence Warning Banner

/// AUDIT §1.2 / TECH_DEBT D1: Release-visible, dismiss-on-fix banner.
/// Rendered whenever `DataStore.persistenceHealth` is degraded; disappears
/// only when a save succeeds again. Never auto-dismisses.
// MARK: - Library Sorting (P5 Feature 5)

enum LibrarySortMode: String, CaseIterable, Identifiable {
    case dateAddedDesc
    case dateAddedAsc
    case titleAsc
    case titleDesc
    case author
    case recentlyRead
    case progress

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dateAddedDesc: return "Recently Added"
        case .dateAddedAsc: return "Oldest Added"
        case .titleAsc: return "Title A-Z"
        case .titleDesc: return "Title Z-A"
        case .author: return "Author"
        case .recentlyRead: return "Recently Read"
        case .progress: return "Progress"
        }
    }

    func sort(_ a: Book, _ b: Book) -> Bool {
        switch self {
        case .dateAddedDesc: return a.dateAdded > b.dateAdded
        case .dateAddedAsc: return a.dateAdded < b.dateAdded
        case .titleAsc: return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        case .titleDesc: return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedDescending
        case .author: return a.author.localizedCaseInsensitiveCompare(b.author) == .orderedAscending
        case .recentlyRead:
            return (a.lastReadDate ?? .distantPast) > (b.lastReadDate ?? .distantPast)
        case .progress: return a.progressFraction > b.progressFraction
        }
    }
}

private struct PersistenceWarningBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Saving problems detected")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignGrid.cardCornerRadius))
        // UI REVIEW §5 (Medium #5): stroke softened — hierarchy via contrast,
        // not an extra bright boundary.
        .overlay(
            RoundedRectangle(cornerRadius: DesignGrid.cardCornerRadius)
                .stroke(Color.yellow.opacity(0.28), lineWidth: 1)
        )
        .padding(.horizontal, DesignGrid.bannerHorizontalInset)
        .padding(.bottom, DesignGrid.bannerBottomInset)
    }
}

// MARK: - Achievement Toast

private struct AchievementToastView: View {
    let achievement: EarnedAchievement
    let onTap: () -> Void

    private var definition: AchievementDefinition? {
        AchievementDefinition.definition(for: achievement.kind)
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: definition?.symbolName ?? "medal.fill")
                    .font(.title2)
                    .foregroundColor(.yellow)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Achievement Unlocked")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(definition?.title ?? achievement.kind.rawValue)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
    }
}

// MARK: - BookEstimationView (unchanged)

struct BookEstimationView: View {
    let book: Book
    let estimation: BookEstimationResult

    /// LIVE-TEST LT-7: information arrives in three soft waves instead of one
    /// wall — wave 1 identity+headline, wave 2 per-session stats, wave 3
    /// chapters+confidence. Reduced-motion users get instant reveal.
    @State private var revealedWave = 0

    var body: some View {
        revealGroup
            .onAppear {
                Task { @MainActor in
                    for wave in 1...3 {
                        try? await Task.sleep(for: .seconds(0.14))
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeOut(duration: 0.32)) { revealedWave = wave }
                    }
                }
            }
    }

    @ViewBuilder
    private var revealGroup: some View {
        let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let wave1 = revealedWave >= 1 || reducedMotion
        let wave2 = revealedWave >= 2 || reducedMotion
        let wave3 = revealedWave >= 3 || reducedMotion

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(book.title)
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text(book.author)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .opacity(wave1 ? 1 : 0)
                .offset(y: wave1 ? 0 : 14)

                Divider()
                    .opacity(wave1 ? 1 : 0)

                VStack(alignment: .leading, spacing: 6) {
                    Label("Time to Finish", systemImage: "clock")
                        .font(.headline)
                    Text(estimation.formattedRemaining)
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    Text(completionLabel)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    // E6: a baseline or default estimate must say so. Rule 8 of
                    // the analytics plan forbids silent fallbacks.
                    Text(estimation.provenance.status.disclosure)
                        .font(.caption2)
                        .foregroundColor(estimation.provenance.status.isFallback
                            ? .orange : .secondary)
                        .accessibilityIdentifier("estimationProvenance")
                }
                .opacity(wave2 ? 1 : 0)
                .offset(y: wave2 ? 0 : 16)

                Divider()
                    .opacity(wave2 ? 1 : 0)

                VStack(alignment: .leading, spacing: 8) {
                    Label("Per Reading Session", systemImage: "book.pages")
                        .font(.headline)
                        .opacity(wave2 ? 1 : 0)
                    HStack(spacing: 32) {
                        statCell(
                            value: formatDuration(estimation.expectedSessionDuration),
                            label: "Expected duration"
                        )
                        statCell(
                            value: "\(Int(estimation.expectedPagesPerSession)) pages",
                            label: "Per session"
                        )
                    }
                }

                if !estimation.chapterEstimates.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Chapter Estimates", systemImage: "list.number")
                            .font(.headline)
                        ForEach(
                            Array(estimation.chapterEstimates.prefix(10).enumerated()),
                            id: \.element.chapterID
                        ) { index, chapter in
                            HStack {
                                Text("Chapter \(index + 1)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(chapter.pages) pg")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(chapter.estimatedFormatted)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .frame(minWidth: 50, alignment: .trailing)
                            }
                        }
                        if estimation.chapterEstimates.count > 10 {
                            Text("+ \(estimation.chapterEstimates.count - 10) more chapters")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label("Prediction confidence", systemImage: "chart.bar.fill")
                            .opacity(wave3 ? 1 : 0)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(confidenceLabel(estimation.confidence.level))
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(confidenceColor(estimation.confidence.level))
                    }
                    if estimation.confidence.level == .low {
                        Text("Read more of this book to improve estimate accuracy.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .italic()
                    }
                }

                Spacer()
            }
            .padding(24)
        }
    }

    private var completionLabel: String {
        let days = estimation.estimatedDaysRemaining
        if days == 0 {
            return "Could finish today"
        }
        if days == 1 {
            return "Estimated completion tomorrow"
        }
        return "Estimated completion in \(days) days"
    }

    private func statCell(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3).fontWeight(.semibold)
            Text(label).font(.caption).foregroundColor(.secondary)
        }
    }

    private func confidenceLabel(_ level: ConfidenceLevel) -> String {
        switch level {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    private func confidenceColor(_ level: ConfidenceLevel) -> Color {
        switch level {
        case .low: return .orange
        case .medium: return .yellow
        case .high: return .green
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(DataStore())
        .environmentObject(SessionCoordinator(dataStore: DataStore()))
        .environmentObject(GoalProgressViewModel())
        .environmentObject(BehaviorContextEngine())
}
