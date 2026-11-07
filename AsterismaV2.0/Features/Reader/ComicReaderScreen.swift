//  ComicReaderScreen.swift
//  AsterismaV2.0
//
//  2.5.1 — the comic reader now reads like a surface, not a slideshow:
//    • native horizontal paging with correct LTR/RTL visual order
//    • adjacent-page prefetch, so a turn almost never waits
//    • a continuous webtoon strip with the same prefetch window
//    • floating, auto-hiding chrome over a quiet paper palette
//    • a direct-manipulation scrubber and a close-inspection zoom surface
//    • keyboard, trackpad, slider, and full-screen control without modes
//      feeling like different applications.
//
//  Progress still goes through SessionCoordinator (the single page authority),
//  and notes still write through DataStore.upsertNote. The reading experience
//  changed; the data contracts did not.

import AppKit
import ImageIO
import SwiftUI

struct ComicReaderScreen: View {
    let book: Book
    @ObservedObject var coordinator: SessionCoordinator

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var dataStore: DataStore

    @AppStorage("reader.comic.paper") private var paperRaw = ComicPaper.graphite.rawValue
    @AppStorage("reader.comic.autoHideChrome") private var autoHideChrome = true
    @AppStorage("reader.brightness") private var readerBrightness: Double = 1.0

    @State private var archive: ComicArchive?
    @State private var loadError: String?
    @State private var scopedURL: URL?
    @State private var mode: ComicReadingMode
    @State private var showingNotes = false
    @State private var showingMirageAnalysis = false
    @State private var showingAppearance = false
    @State private var zoomPage: ComicPage?
    @State private var imageStore = ComicPageImageStore()
    @State private var didStartSession = false

    @State private var chromeVisible = true
    @State private var chromeHovered = false
    @State private var chromeHideTask: Task<Void, Never>?
    @State private var pagedLayoutReady = false

    init(book: Book, coordinator: SessionCoordinator) {
        self.book = book
        self.coordinator = coordinator
        _mode = State(initialValue: book.resolvedComicReadingMode)
    }

    // MARK: - Derived state

    private var paper: ComicPaper {
        ComicPaper(rawValue: paperRaw) ?? .graphite
    }

    private var pages: [ComicPage] {
        archive?.pages ?? []
    }

    private var pageIndex: Int {
        ComicPagination.clamped(coordinator.currentPage, pageCount: pages.count)
    }

    private var currentPage: ComicPage? {
        guard pages.indices.contains(pageIndex) else { return nil }
        return pages[pageIndex]
    }

    private var notesOnCurrentPage: [BookNote] {
        (dataStore.book(id: book.id)?.notes ?? []).filter { note in
            guard case let .comic(index) = note.anchor else { return false }
            return index == pageIndex
        }
    }

    private var currentChapter: Chapter? {
        book.chapters.first { pageIndex >= $0.startPage && pageIndex <= $0.endPage }
    }

    private var visualPageOrder: [Int] {
        ComicPagination.visualOrder(pageCount: pages.count, mode: mode)
    }

    private var pageInset: CGFloat {
        paper.isDark ? 10 : 18
    }

    private func visualIndex(for page: Int) -> Int {
        ComicPagination.visualIndex(forPage: page, pageCount: pages.count, mode: mode)
    }

    private func pageIndex(forVisual visual: Int) -> Int {
        ComicPagination.pageIndex(forVisual: visual, pageCount: pages.count, mode: mode)
    }

    private var backwardSymbol: String {
        mode == .rightToLeft ? "chevron.right" : "chevron.left"
    }

    private var forwardSymbol: String {
        mode == .rightToLeft ? "chevron.left" : "chevron.right"
    }

    // MARK: - Body

    var body: some View {
        Group {
            if let loadError {
                errorView(loadError)
            } else if let archive, !archive.pages.isEmpty {
                readerBody(archive)
            } else {
                loadingView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(paper.background.ignoresSafeArea())
        .overlay {
            if let zoomPage, let archive {
                ComicZoomView(
                    page: zoomPage,
                    archive: archive,
                    store: imageStore,
                    paper: paper,
                    onClose: closeZoom
                )
                .transition(.opacity)
                .zIndex(20)
            }
        }
        .background(
            ComicKeyboardMonitor(
                isEnabled: archive != nil && loadError == nil && !showingAppearance,
                onCommand: handleKey
            )
        )
        .onAppear { showChrome() }
        .onContinuousHover { phase in
            if case .active = phase {
                showChrome()
            }
        }
        .onDisappear {
            chromeHideTask?.cancel()
            finishReading()
        }
        .task { await openArchiveIfNeeded() }
        .sheet(isPresented: $showingNotes) {
            ComicNotesSheet(book: book, pageIndex: pageIndex)
                .environmentObject(dataStore)
        }
        // 2.6: the same analyze sheet the EPUB reader owns. Comics reach it
        // through the OCR bridge, so the entry belongs beside page notes.
        .sheet(isPresented: $showingMirageAnalysis) {
            MirageAnalysisSheet(book: book)
        }
        .onChange(of: showingNotes) { _, showing in
            if !showing { showChrome() }
        }
        .onChange(of: showingAppearance) { _, showing in
            if showing {
                chromeHideTask?.cancel()
            } else {
                showChrome()
            }
        }
        .onChange(of: autoHideChrome) { _, enabled in
            if enabled {
                scheduleChromeHide()
            } else {
                chromeHideTask?.cancel()
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    chromeVisible = true
                }
            }
        }
    }

    @ViewBuilder
    private func readerBody(_ archive: ComicArchive) -> some View {
        ZStack {
            paper.background.ignoresSafeArea()

            if mode == .vertical {
                verticalReader(archive)
            } else {
                pagedReader(archive)
            }

            ReaderBrightnessOverlay(brightness: readerBrightness)

            if chromeVisible {
                chromeLayer
                    .transition(.opacity)
            } else {
                readingRibbon
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: chromeVisible)
        .onAppear {
            prefetch(around: pageIndex, in: archive)
            showChrome()
        }
        .onChange(of: pageIndex) { _, newPage in
            prefetch(around: newPage, in: archive)
        }
        .onChange(of: mode) { _, _ in
            prefetch(around: pageIndex, in: archive)
        }
    }

    // MARK: - Paged layout

    private func pagedReader(_ archive: ComicArchive) -> some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(visualPageOrder, id: \.self) { visual in
                            let page = pageIndex(forVisual: visual)
                            ComicPageImageView(
                                page: pages[page],
                                archive: archive,
                                store: imageStore,
                                fixedWidth: nil,
                                paper: paper,
                                pageLabel: "Page \(page + 1)",
                                showsShadow: true,
                                onDoubleTap: { openZoom(pages[page]) }
                            )
                            .padding(pageInset)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .id(visual)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: pagedScrollPosition)
                .scrollIndicators(.hidden)
                .background(paper.background)
                .opacity(pagedLayoutReady ? 1 : 0)
                .task {
                    // LazyHStack starts at visual zero. For RTL or a resumed
                    // page, anchor before accepting the scroll view's first
                    // layout write, then fade the surface in.
                    try? await Task.sleep(for: .milliseconds(30))
                    proxy.scrollTo(visualIndex(for: pageIndex), anchor: .center)
                    try? await Task.sleep(for: .milliseconds(30))
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                        pagedLayoutReady = true
                    }
                }
            }
        }
    }

    /// The native ScrollView writes the visual index; the reading model keeps
    /// page indices increasing in story order for manga. In RTL the order is
    /// reversed visually, so visual N-1 is story page 0.
    private var pagedScrollPosition: Binding<Int?> {
        Binding(
            get: {
                pages.isEmpty ? nil : visualIndex(for: pageIndex)
            },
            set: { newValue in
                guard pagedLayoutReady, let newValue, !pages.isEmpty else { return }
                let target = pageIndex(forVisual: newValue)
                guard target != pageIndex else { return }
                coordinator.turnToPage(target)
            }
        )
    }

    // MARK: - Vertical layout

    private func verticalReader(_ archive: ComicArchive) -> some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                            ComicPageImageView(
                                page: page,
                                archive: archive,
                                store: imageStore,
                                fixedWidth: geometry.size.width,
                                paper: paper,
                                pageLabel: "Page \(index + 1)",
                                showsShadow: false,
                                onDoubleTap: { openZoom(page) }
                            )
                            .id(index)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollPosition(id: verticalScrollPosition)
                .scrollIndicators(.hidden)
                .background(paper.background)
                .onAppear {
                    DispatchQueue.main.async {
                        proxy.scrollTo(pageIndex, anchor: .top)
                    }
                }
            }
        }
    }

    private var verticalScrollPosition: Binding<Int?> {
        Binding(
            get: { pages.isEmpty ? nil : pageIndex },
            set: { newValue in
                guard let newValue, !pages.isEmpty, newValue != pageIndex else { return }
                coordinator.turnToPage(
                    ComicPagination.clamped(newValue, pageCount: pages.count)
                )
            }
        )
    }

    // MARK: - Chrome

    private var chromeLayer: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 0)
            bottomBar
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .transition(.opacity)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            chromeButton("xmark", help: "Close the reader") {
                dismiss()
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(book.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text("\(mode.shortName) · Page \(pageIndex + 1) of \(max(pages.count, 1))")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(paper.secondaryText)
                    .monospacedDigit()
            }
            .frame(maxWidth: 320, alignment: .leading)

            Spacer(minLength: 12)

            chromeButton("magnifyingglass", help: "Zoom this page") {
                if let currentPage { openZoom(currentPage) }
            }

            notesButton

            chromeButton("sparkles.rectangle.stack", help: "Analyze with Mirage") {
                showingMirageAnalysis = true
            }

            if book.chapters.count > 1 {
                chapterMenu
            }

            chromeButton("circle.lefthalf.filled", help: "Appearance") {
                showingAppearance.toggle()
            }
            .popover(isPresented: $showingAppearance) {
                ComicReaderAppearancePanel(
                    paperRaw: $paperRaw,
                    brightness: $readerBrightness,
                    autoHideChrome: $autoHideChrome,
                    mode: Binding(
                        get: { mode },
                        set: { changeMode($0) }
                    )
                )
            }

            modeMenu

            chromeButton("arrow.up.left.and.arrow.down.right", help: "Toggle full screen") {
                toggleFullScreen()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 900)
        .background(paper.chromeBackground, in: Capsule())
        .overlay(Capsule().strokeBorder(paper.chromeStroke, lineWidth: 1))
        .shadow(color: paper.chromeShadow, radius: 14, y: 5)
        .onHover { hovering in
            chromeHovered = hovering
            if hovering {
                chromeHideTask?.cancel()
            } else {
                scheduleChromeHide()
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            chromeButton(backwardSymbol, help: "Previous page") {
                goBackward()
            }
            .disabled(ComicPagination.previous(before: pageIndex, pageCount: pages.count) == nil)

            ComicProgressScrubber(
                pageIndex: pageIndex,
                pageCount: pages.count,
                tint: paper.chromeForeground,
                onSeek: { turn(to: $0) }
            )
            .frame(minWidth: 140, idealWidth: 280, maxWidth: 320)
            .disabled(pages.count <= 1)

            chromeButton(forwardSymbol, help: "Next page") {
                goForward()
            }
            .disabled(ComicPagination.next(after: pageIndex, pageCount: pages.count) == nil)

            Text("\(pageIndex + 1) / \(max(pages.count, 1))")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(paper.secondaryText)
                .frame(minWidth: 62, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(maxWidth: 560)
        .background(paper.chromeBackground, in: Capsule())
        .overlay(Capsule().strokeBorder(paper.chromeStroke, lineWidth: 1))
        .shadow(color: paper.chromeShadow, radius: 14, y: 5)
        .onHover { hovering in
            chromeHovered = hovering
            if hovering {
                chromeHideTask?.cancel()
            } else {
                scheduleChromeHide()
            }
        }
    }

    private var notesButton: some View {
        Button {
            showingNotes = true
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "note.text")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 26, height: 26)
                if !notesOnCurrentPage.isEmpty {
                    Circle()
                        .fill(paper.isDark ? Color.white : Color.black)
                        .frame(width: 5, height: 5)
                        .offset(x: 2, y: -2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(paper.chromeForeground)
        .help(notesOnCurrentPage.isEmpty ? "Page notes" : "Page notes (\(notesOnCurrentPage.count))")
        .accessibilityLabel(notesOnCurrentPage.isEmpty ? "Page notes" : "Page notes, \(notesOnCurrentPage.count) on this page")
    }

    private var chapterMenu: some View {
        Menu {
            ForEach(book.chapters, id: \.index) { chapter in
                Button {
                    turn(to: chapter.startPage)
                } label: {
                    if chapter.index == currentChapter?.index {
                        Label(chapter.title, systemImage: "checkmark")
                    } else {
                        Text(chapter.title)
                    }
                }
            }
        } label: {
            Image(systemName: "list.bullet")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
                .foregroundStyle(paper.chromeForeground)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Jump to chapter")
        .accessibilityLabel("Chapters")
    }

    private var modeMenu: some View {
        Menu {
            ForEach(ComicReadingMode.allCases, id: \.self) { candidate in
                Button {
                    changeMode(candidate)
                } label: {
                    if candidate == mode {
                        Label(candidate.displayName, systemImage: "checkmark")
                    } else {
                        Text(candidate.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: mode.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                Text(mode.shortName)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(paper.chromeForeground)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Reading mode")
        .accessibilityLabel("Reading mode, \(mode.displayName)")
    }

    private func chromeButton(
        _ systemName: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(paper.chromeForeground)
        .help(help)
    }

    private var readingRibbon: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(paper.chromeForeground.opacity(0.09))
                    Rectangle()
                        .fill(paper.chromeForeground.opacity(0.38))
                        .frame(
                            width: geometry.size.width
                                * CGFloat(ComicPagination.progress(index: pageIndex, pageCount: pages.count))
                        )
                }
                .frame(height: 2)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Navigation

    private func handleKey(_ key: ComicKeyCommand) -> Bool {
        if zoomPage != nil {
            switch key {
            case .escape:
                closeZoom()
                return true
            default:
                return false
            }
        }

        switch key {
        case .left:
            return mode.isForward(.left) ? goForward() : goBackward()
        case .right:
            return mode.isForward(.right) ? goForward() : goBackward()
        case .up:
            if mode == .vertical { return false }
            return mode.isForward(.up) ? goForward() : goBackward()
        case .down:
            if mode == .vertical { return false }
            return mode.isForward(.down) ? goForward() : goBackward()
        case .pageUp:
            return goBackward()
        case .pageDown:
            return goForward()
        case .first:
            turn(to: 0)
            return true
        case .last:
            turn(to: max(0, pages.count - 1))
            return true
        case .space:
            return goForward()
        case .shiftSpace:
            return goBackward()
        case .escape:
            dismiss()
            return true
        case .toggleFullScreen:
            toggleFullScreen()
            return true
        case .toggleChrome:
            if chromeVisible {
                hideChromeNow()
            } else {
                showChrome()
            }
            return true
        }
    }

    @discardableResult
    private func goForward() -> Bool {
        guard let next = ComicPagination.next(after: pageIndex, pageCount: pages.count) else {
            return false
        }
        turn(to: next)
        return true
    }

    @discardableResult
    private func goBackward() -> Bool {
        guard let previous = ComicPagination.previous(before: pageIndex, pageCount: pages.count) else {
            return false
        }
        turn(to: previous)
        return true
    }

    private func turn(to index: Int) {
        let target = ComicPagination.clamped(index, pageCount: pages.count)
        guard target != pageIndex else { return }
        if reduceMotion {
            coordinator.turnToPage(target)
        } else {
            withAnimation(.easeOut(duration: 0.22)) {
                coordinator.turnToPage(target)
            }
        }
        showChrome()
    }

    private func changeMode(_ newMode: ComicReadingMode) {
        guard newMode != mode else { return }
        pagedLayoutReady = false
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            mode = newMode
        }

        guard var stored = dataStore.book(id: book.id) else { return }
        stored.comicReadingMode = newMode
        dataStore.updateBook(stored)
        showChrome()
    }

    private func openZoom(_ page: ComicPage) {
        chromeHideTask?.cancel()
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            zoomPage = page
            chromeVisible = false
        }
    }

    private func closeZoom() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            zoomPage = nil
        }
        showChrome()
    }

    private func toggleFullScreen() {
        (NSApp.keyWindow ?? NSApp.mainWindow)?.toggleFullScreen(nil)
    }

    private func prefetch(around index: Int, in archive: ComicArchive) {
        imageStore.prefetch(
            pages: pages,
            around: index,
            radius: mode == .vertical ? 2 : 2,
            in: archive
        )
    }

    // MARK: - Chrome lifecycle

    private func showChrome() {
        chromeHideTask?.cancel()
        if !chromeVisible {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                chromeVisible = true
            }
        }
        scheduleChromeHide()
    }

    private func hideChromeNow() {
        chromeHideTask?.cancel()
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) {
            chromeVisible = false
        }
    }

    private func scheduleChromeHide() {
        chromeHideTask?.cancel()
        guard autoHideChrome else { return }

        chromeHideTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                if chromeHovered || showingAppearance || showingNotes || zoomPage != nil {
                    continue
                }
                guard chromeVisible else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.4)) {
                    chromeVisible = false
                }
                return
            }
        }
    }

    // MARK: - Lifecycle

    private func openArchiveIfNeeded() async {
        guard archive == nil, loadError == nil else { return }

        guard let url = book.resolveURL() else {
            loadError = "This comic’s file could not be found. Relink it from the library, then try again."
            return
        }

        let scope = url.startAccessingSecurityScopedResource()
        if scope { scopedURL = url }

        do {
            let opened = try await Task.detached(priority: .userInitiated) {
                try ComicArchive.open(url: url)
            }.value

            archive = opened
            let start = ComicPagination.clamped(book.currentPage, pageCount: opened.pages.count)
            coordinator.startReading(bookID: book.id, page: start)
            didStartSession = true
            imageStore.prefetch(pages: opened.pages, around: start, radius: 2, in: opened)
            showChrome()
        } catch {
            if scope { url.stopAccessingSecurityScopedResource() }
            scopedURL = nil
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func finishReading() {
        if let scopedURL {
            scopedURL.stopAccessingSecurityScopedResource()
            self.scopedURL = nil
        }
        if didStartSession {
            coordinator.endCurrentSession()
            didStartSession = false
        }
    }

    // MARK: - States

    private var loadingView: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(paper.placeholder)
                    .frame(width: 150, height: 216)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(paper.chromeStroke, lineWidth: 1)
                    )
                ProgressView()
                    .controlSize(.large)
                    .tint(paper.chromeForeground)
            }
            Text("Opening \(book.title)…")
                .font(.callout)
                .foregroundStyle(paper.secondaryText)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(40)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 42))
                .foregroundStyle(.orange)
            Text("Could Not Open Comic")
                .font(.title2.bold())
                .foregroundStyle(paper.chromeForeground)
            Text(message)
                .foregroundStyle(paper.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(40)
    }
}

// MARK: - Page image

/// Decodes one page without blocking the reading surface, then fades it in.
/// The store prefetches neighbours, so the usual case is a cache hit and no
/// visible placeholder at all.
struct ComicPageImageView: View {
    let page: ComicPage
    let archive: ComicArchive
    let store: ComicPageImageStore
    /// nil = fit the parent (paged reader); a value = fixed strip width.
    let fixedWidth: CGFloat?
    let paper: ComicPaper
    let pageLabel: String
    let showsShadow: Bool
    let onDoubleTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: NSImage?
    @State private var failed = false
    @State private var pulse = false

    var body: some View {
        Group {
            if let image {
                pageImage(image)
                    .transition(.opacity)
            } else if failed {
                failure
            } else {
                placeholder
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: image != nil)
        .task(id: page.id) {
            await loadIfNeeded()
        }
        .onAppear {
            if !reduceMotion { pulse = true }
        }
    }

    @ViewBuilder
    private func pageImage(_ image: NSImage) -> some View {
        if let fixedWidth {
            let aspect = image.size.width > 0 ? image.size.height / image.size.width : 1.4
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: fixedWidth, height: fixedWidth * aspect)
                .shadow(
                    color: showsShadow ? paper.pageShadow : .clear,
                    radius: showsShadow ? 16 : 0,
                    y: showsShadow ? 6 : 0
                )
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { onDoubleTap() }
                .accessibilityLabel(pageLabel)
        } else {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .shadow(
                    color: showsShadow ? paper.pageShadow : .clear,
                    radius: showsShadow ? 16 : 0,
                    y: showsShadow ? 6 : 0
                )
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { onDoubleTap() }
                .accessibilityLabel(pageLabel)
        }
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(paper.placeholder)
            ProgressView()
                .controlSize(.small)
                .tint(paper.secondaryText)
        }
        .opacity(pulse ? 1 : 0.55)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 1.15).repeatForever(autoreverses: true),
            value: pulse
        )
        .frame(
            width: fixedWidth,
            height: fixedWidth.map { $0 * 1.4 }
        )
        .frame(maxWidth: fixedWidth == nil ? .infinity : nil,
               maxHeight: fixedWidth == nil ? .infinity : nil)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityLabel("Loading \(pageLabel)")
    }

    private var failure: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.system(size: 26))
            Text("Page unavailable")
                .font(.caption)
            Button("Retry") {
                failed = false
                Task { await loadIfNeeded() }
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.semibold))
        }
        .foregroundStyle(paper.secondaryText)
        .frame(
            width: fixedWidth,
            height: fixedWidth.map { $0 * 1.4 } ?? 260
        )
        .frame(maxWidth: fixedWidth == nil ? .infinity : nil,
               maxHeight: fixedWidth == nil ? .infinity : nil)
        .background(paper.placeholder, in: RoundedRectangle(cornerRadius: 4))
    }

    private func loadIfNeeded() async {
        guard image == nil, !failed else { return }

        if let cached = store.image(for: page.id) {
            image = cached
            return
        }

        if let loaded = await store.loadImage(for: page, in: archive) {
            guard !Task.isCancelled else { return }
            image = loaded
        } else if !Task.isCancelled {
            failed = true
        }
    }
}

// MARK: - Page cache

/// Per-reader cache with in-flight de-duplication and a prefetch window.
/// NSCache handles memory-pressure eviction; the count/cost limits keep a
/// 300-page CBZ from turning into an unbounded image atlas.
final nonisolated class ComicPageImageStore: @unchecked Sendable {
    private struct DecodedImage: @unchecked Sendable {
        let image: NSImage?
    }

    private let cache = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<DecodedImage, Never>] = [:]
    private let lock = NSLock()

    init() {
        cache.countLimit = 24
        cache.totalCostLimit = 256 * 1024 * 1024
    }

    func image(for id: String) -> NSImage? {
        cache.object(forKey: id as NSString)
    }

    func loadImage(for page: ComicPage, in archive: ComicArchive) async -> NSImage? {
        if let cached = image(for: page.id) {
            return cached
        }

        let key = page.id
        let task = decodeTask(for: key, page: page, in: archive)
        let decoded = await task.value
        record(decoded.image, for: key)
        return decoded.image
    }

    /// The lock never crosses an await: this helper only starts or joins a
    /// decode, and `record` only publishes a completed one.
    private func decodeTask(
        for key: String,
        page: ComicPage,
        in archive: ComicArchive
    ) -> Task<DecodedImage, Never> {
        lock.lock()
        defer { lock.unlock() }

        if let existing = inFlight[key] {
            return existing
        }

        let created = Task.detached(priority: .userInitiated) {
            guard let data = try? archive.data(for: page),
                  let decoded = Self.decode(data)
            else {
                return DecodedImage(image: nil)
            }
            return DecodedImage(image: decoded)
        }
        inFlight[key] = created
        return created
    }

    private func record(_ image: NSImage?, for key: String) {
        if let image {
            cache.setObject(image, forKey: key as NSString, cost: cost(of: image))
        }
        lock.lock()
        inFlight.removeValue(forKey: key)
        lock.unlock()
    }

    /// ImageIO does the actual bitmap decode here, off the main actor, so the
    /// first draw of a prefetched page is a texture upload rather than a
    /// multi-megapixel decode in the middle of a page turn.
    private static func decode(_ data: Data) -> NSImage? {
        if let source = CGImageSourceCreateWithData(data as CFData, nil) {
            let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
            if let cgImage = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) {
                return NSImage(
                    cgImage: cgImage,
                    size: NSSize(width: cgImage.width, height: cgImage.height)
                )
            }
        }
        return NSImage(data: data)
    }

    /// Runs in the background and warms the cache around the current page.
    /// The in-flight map means a page already being decoded by its view is
    /// not extracted twice.
    func prefetch(
        pages: [ComicPage],
        around index: Int,
        radius: Int,
        in archive: ComicArchive
    ) {
        guard !pages.isEmpty else { return }
        let lower = max(0, index - radius)
        let upper = min(pages.count - 1, index + radius)
        guard lower <= upper else { return }

        for candidate in lower ... upper {
            let page = pages[candidate]
            if cache.object(forKey: page.id as NSString) != nil { continue }
            Task { _ = await loadImage(for: page, in: archive) }
        }
    }

    private func cost(of image: NSImage) -> Int {
        let pixels = max(image.size.width * image.size.height, 1)
        return max(Int(pixels * 4), 1)
    }
}

// MARK: - Page notes

/// Page-scoped note sheet for comic pages. Writes through the single
/// DataStore mutation path and uses the shared `BookNote` model, so comic
/// notes appear everywhere notes already appear.
struct ComicNotesSheet: View {
    let book: Book
    let pageIndex: Int

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var dataStore: DataStore
    @State private var draft = ""
    @FocusState private var editorFocused: Bool

    private var pageNotes: [BookNote] {
        (dataStore.book(id: book.id)?.notes ?? []).filter { note in
            guard case let .comic(index) = note.anchor else { return false }
            return index == pageIndex
        }
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Notes — Page \(pageIndex + 1)")
                    .font(.title3.bold())
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            if pageNotes.isEmpty {
                Text("No notes on this page yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(pageNotes) { note in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(note.text)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                HStack {
                                    Text(note.createdAt, style: .date)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button(role: .destructive) {
                                        _ = dataStore.deleteNote(id: note.id, inBook: book.id)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.plain)
                                    .help("Delete this note")
                                }
                            }
                            .padding(10)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }

            TextEditor(text: $draft)
                .font(.body)
                .frame(height: 90)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(0.15))
                )
                .focused($editorFocused)

            HStack {
                Spacer()
                Button("Save Note") { saveNote() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedDraft.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460, height: 430)
        .onAppear { editorFocused = true }
    }

    private func saveNote() {
        guard !trimmedDraft.isEmpty else { return }
        let note = AnnotationCreation.makePageNote(
            text: trimmedDraft,
            bookID: book.id,
            pageIndex: pageIndex
        )
        guard dataStore.upsertNote(note, inBook: book.id) else { return }
        draft = ""
    }
}
