//  EPUBReaderScreen.swift
//  AsterismaV2.0
//  Architectural redesign — see EPUB_READER_REDESIGN_PLAN.txt (this file's
//  single source of truth). Previous version extracted a fixed ~3,000-
//  character plain-text snippet with no navigation; this version renders
//  full chapter content via WKWebView and supports real chapter-by-chapter
//  navigation, matching the reading-position contract SessionCoordinator
//  already establishes for the PDF reader.
//
//  External contract preserved exactly: init(book: Book, coordinator:
//  SessionCoordinator) — unchanged, so both call sites (NewContentView,
//  and the live Explorer) keep compiling untouched.
//

import os
import SwiftUI
import WebKit

// MARK: - EPUBReaderScreen

struct EPUBReaderScreen: View {
    let book: Book
    @ObservedObject var coordinator: SessionCoordinator
    @EnvironmentObject private var dataStore: DataStore
    @Environment(\.dismiss) private var dismiss

    @State private var package: EPUBPackage?
    @State private var currentChapterIndex: Int = 0
    @State private var pageInChapter: Int = 0
    @State private var pagesInChapter: Int = 1
    @State private var readableChapterIndices: [Int] = []
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var showingChapterList = false
    @State private var showingInfo = false

    /// WP-1.2: the one current EPUB selection. Cleared on every page and
    /// chapter change so a stored selection can never outlive the text it
    /// was anchored to. WP-1.4's annotation UI reads from here via
    /// `onSelection`.
    @State private var selectionState = EPUBSelectionState()

    /// Reference to the in-flight open Task so it can be cancelled on
    /// disappear, exactly like the previous implementation's loadTask.
    @State private var openTask: Task<Void, Never>?

    /// P5 Feature 3: RSVP speed-reading over the CURRENT chapter.
    @AppStorage("rsvp.enabled") private var rsvpEnabled = true
    @AppStorage("reader.fontScale") private var fontScale: Double = 1.0
    @AppStorage("reader.lineHeight") private var lineHeight: Double = 1.55
    @AppStorage("reader.alignment") private var alignment: String = "left"
    @AppStorage("reader.theme") private var readerTheme: String = ReaderThemePreset.original.rawValue
    @AppStorage("reader.fontFamily") private var readerFontFamily: String = ReaderFontFamily.original.rawValue
    @AppStorage("reader.bold") private var readerBold = false
    @AppStorage("reader.characterSpacing") private var readerCharacterSpacing: Double = 0
    @AppStorage("reader.wordSpacing") private var readerWordSpacing: Double = 0
    @AppStorage("reader.margin") private var readerMargin: Double = 46
    @AppStorage("reader.columns") private var readerColumns: String = ReaderColumnLayout.automatic.rawValue
    @AppStorage("reader.hyphenation") private var readerHyphenation = true
    @AppStorage("reader.pageTurn") private var readerPageTurn: String = ReaderPageTurnStyle.slide.rawValue
    @AppStorage("reader.readingMode") private var readerReadingMode: String = ReaderReadingMode.paged.rawValue
    @AppStorage("reader.showPageNumbers") private var readerShowPageNumbers = true
    @AppStorage("reader.brightness") private var readerBrightness: Double = 1.0
    @AppStorage("reader.bothMarginsAdvance") private var readerBothMarginsAdvance = false
    @State private var showingAppearance = false
    @State private var rsvpText: String?
    @State private var readerControlsVisible = true
    @State private var readerControlsHovered = false
    @State private var readerControlsHideTask: Task<Void, Never>?

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Asterisma",
        category: "EPUBReaderScreen"
    )

    init(book: Book, coordinator: SessionCoordinator) {
        self.book = book
        self.coordinator = coordinator
    }

    var body: some View {
        Group {
            if let errorMessage {
                errorView(errorMessage)
            } else if isLoading {
                loadingView
            } else {
                contentView
            }
        }
        .onAppear {
            errorMessage = nil
            isLoading = true
            openTask = Task {
                await openPackage()

                // LIVE-TEST LT-3b: timing begins ONLY when content actually
                // opened. Previously startReading() ran unconditionally here,
                // so staring at the load-error screen accrued phantom reading
                // time on books that never opened.
                guard !Task.isCancelled else { return }
                if errorMessage == nil, package != nil {
                    coordinator.startReading(bookID: book.id, page: book.currentPage)
                    updatePositionLabel()
                    showReaderControls()
                }
            }
        }
        .onDisappear {
            readerControlsHideTask?.cancel()
            persistPosition()
            dataStore.saveImmediately()
            openTask?.cancel()
            openTask = nil
            package?.close()
            package = nil
            coordinator.endCurrentSession()
        }
    }

    // MARK: - Opening

    private func openPackage() async {
        logger.debug("Opening EPUB package")
        do {
            let opened = try await EPUBPackage.open(book: book)

            guard !Task.isCancelled else {
                // Nobody will ever hold a reference to `opened` if we bail
                // out here — release it ourselves rather than leaking it.
                opened.close()
                return
            }

            let readable = opened.readableChapterIndices()
            let fallbackIndex = startingChapterIndex(in: opened, resumingFrom: book.currentPage)
            var startIndex = min(
                max(0, book.epubChapterIndex ?? fallbackIndex),
                max(0, opened.chapterCount - 1)
            )
            if !readable.contains(startIndex) {
                startIndex = readable.first(where: { $0 >= startIndex })
                    ?? readable.first
                    ?? 0
            }
            let startPage = max(0, book.epubPageInChapter ?? 0)

            await MainActor.run {
                guard !Task.isCancelled else {
                    opened.close()
                    return
                }
                self.package = opened
                self.readableChapterIndices = readable
                self.currentChapterIndex = startIndex
                self.pageInChapter = startPage
                self.isLoading = false
            }
            logger.info("EPUB package opened with \(opened.chapterCount, privacy: .public) chapters, resuming at chapter \(startIndex, privacy: .public)")
        } catch {
            logger.error("Failed to open EPUB package: \(error.localizedDescription)")
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    /// Maps the coordinator's persisted page back to a chapter index, so
    /// reopening a book resumes where the reader left off instead of always
    /// restarting at chapter 1. Falls back to chapter 0 if nothing matches.
    ///
    /// Defensive by design: book.chapters (persisted at import time) and the
    /// freshly-parsed spine (package.chapterCount) are not guaranteed to be
    /// the same length — see EPUB_READER_REDESIGN_PLAN.txt Section 1 — so
    /// the result is always clamped to a real spine index.
    private func startingChapterIndex(in package: EPUBPackage, resumingFrom page: Int) -> Int {
        guard package.chapterCount > 0 else { return 0 }
        let match = book.chapters.first { page >= $0.startPage && page <= $0.endPage }
        let index = match?.index ?? 0
        return min(max(0, index), package.chapterCount - 1)
    }

    // MARK: - Chapter navigation

    private var readablePosition: Int? {
        readableChapterIndices.firstIndex(of: currentChapterIndex)
    }

    private var canGoToPreviousChapter: Bool {
        (readablePosition ?? 0) > 0
    }

    private var canGoToNextChapter: Bool {
        guard let position = readablePosition else { return false }
        return position + 1 < readableChapterIndices.count
    }

    private func goToChapter(_ index: Int) {
        guard let package, package.chapterCount > 0 else { return }
        let target = readableChapterIndices.contains(index)
            ? index
            : (readableChapterIndices.first(where: { $0 > index })
                ?? readableChapterIndices.last
                ?? 0)
        let clamped = max(0, min(target, package.chapterCount - 1))
        currentChapterIndex = clamped
        pageInChapter = 0
        pagesInChapter = 1
        // WP-1.2: chapter change — the previous selection no longer anchors
        // to text the reader is showing.
        selectionState.clear()
        persistPosition()
        coordinator.turnToPage(globalPage)
        updatePositionLabel()
        showReaderControls()
    }

    private func goToPreviousReadableChapter() {
        guard let position = readablePosition, position > 0 else { return }
        goToChapter(readableChapterIndices[position - 1])
    }

    private func goToNextReadableChapter() {
        guard let position = readablePosition,
              position + 1 < readableChapterIndices.count else { return }
        goToChapter(readableChapterIndices[position + 1])
    }

    private func chapterTitle(at index: Int) -> String {
        // `book.chapters` comes from TOC entries at import time; the EPUB
        // spine can have a different count. Never show a TOC title against a
        // mismatched spine index — that produced the Chapter 25/12 conflict.
        guard let package,
              package.chapterCount == book.chapters.count,
              book.chapters.indices.contains(index)
        else {
            return "Chapter \(index + 1)"
        }
        return book.chapters[index].title
    }

    private var bookProgress: Double {
        let chapters = max(package?.chapterCount ?? book.chapters.count, 1)
        let withinChapter = Double(pageInChapter + 1) / Double(max(pagesInChapter, 1))
        let value = (Double(currentChapterIndex) + withinChapter) / Double(chapters)
        return min(1.0, max(0.0, value))
    }

    private var globalPage: Int {
        guard book.chapters.indices.contains(currentChapterIndex) else {
            return max(0, pageInChapter)
        }
        let chapter = book.chapters[currentChapterIndex]
        return min(max(chapter.startPage + pageInChapter, chapter.startPage), chapter.endPage)
    }

    private func updatePositionLabel() {
        let chapters = max(book.chapters.count, 1)
        coordinator.updatePositionLabel(
            "Ch \(currentChapterIndex + 1)/\(chapters) · \(pageInChapter + 1)/\(max(pagesInChapter, 1)) · \(Int(bookProgress * 100))%"
        )
    }

    private func persistPosition() {
        guard var current = dataStore.book(id: book.id) else { return }
        current.epubChapterIndex = currentChapterIndex
        current.epubPageInChapter = pageInChapter
        current.currentPage = globalPage
        dataStore.updateBook(current)
    }

    private func handleReaderKey(_ command: KeyNavigationCommand) -> Bool {
        switch command {
        case .left, .up:
            turnPage(-1)
            return true
        case .right, .down:
            turnPage(1)
            return true
        case .escape:
            dismiss()
            return true
        case .returnKey:
            return false
        }
    }

    private func turnPage(_ delta: Int) {
        if delta < 0 {
            if pageInChapter > 0 {
                pageInChapter -= 1
            } else if canGoToPreviousChapter {
                goToPreviousReadableChapter()
                return
            } else {
                return
            }
        } else {
            if pageInChapter + 1 < pagesInChapter {
                pageInChapter += 1
            } else if canGoToNextChapter {
                goToNextReadableChapter()
                return
            } else {
                return
            }
        }

        // WP-1.2: page change — clear any selection from the previous page.
        selectionState.clear()
        persistPosition()
        coordinator.turnToPage(globalPage)
        updatePositionLabel()
    }

    // MARK: - Content Views

    private var loadingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Loading EPUB...")
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 50))
                .foregroundColor(.red)
            Text("Error")
                .font(.title)
                .fontWeight(.bold)
            Text(message)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func showReaderControls() {
        readerControlsHideTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) {
            readerControlsVisible = true
        }
        scheduleReaderControlsHide()
    }

    private func cancelReaderControlsHide() {
        readerControlsHideTask?.cancel()
        readerControlsHideTask = nil
    }

    private func scheduleReaderControlsHide() {
        readerControlsHideTask?.cancel()
        readerControlsHideTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                if readerControlsHovered
                    || showingChapterList
                    || showingInfo
                    || showingAppearance
                    || showingMirageAnalysis {
                    continue
                }
                guard readerControlsVisible else { return }
                withAnimation(.easeOut(duration: 0.4)) {
                    readerControlsVisible = false
                }
                return
            }
        }
    }

    /// Compact floating controls replace the native reader toolbar, so there
    /// is no full-width gray strip in fullscreen.
    private var readerTopControls: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
            }
            .help("Back to Library")
            .accessibilityLabel("Back to Library")

            Button {
                showingChapterList = true
            } label: {
                Text(chapterTitle(at: currentChapterIndex))
                    .lineLimit(1)
                    .frame(maxWidth: 260, alignment: .leading)
            }
            .popover(isPresented: $showingChapterList) {
                chapterListPopover
            }
            .accessibilityLabel("Table of contents")

            if rsvpEnabled {
                Button {
                    loadRSVPText()
                } label: {
                    Image(systemName: "hare")
                }
                .help("Speed-read this chapter (RSVP)")
                .accessibilityLabel("Speed read this chapter")
                .disabled(package == nil)
            }

            Button {
                showingAppearance = true
            } label: {
                Image(systemName: "textformat.size")
            }
            .popover(isPresented: $showingAppearance) {
                readerAppearancePanel
            }
            .help("Appearance")
            .accessibilityLabel("Appearance")

            Button {
                showingInfo = true
            } label: {
                Image(systemName: "info.circle")
            }
            .popover(isPresented: $showingInfo) {
                metadataSection
                    .padding()
                    .frame(minWidth: 260)
            }
            .help("Book information")
            .accessibilityLabel("Book information")
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(activeAppearance.theme.chromeForeground)
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(activeAppearance.theme.chromeBackground, in: Capsule())
        .overlay(
            Capsule().strokeBorder(activeAppearance.theme.chromeStroke, lineWidth: 1)
        )
        .padding(14)
    }

    private var readerAppearancePanel: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Appearance")
                        .font(.headline)
                    Text("Themes set a starting point. Fine-tune anything below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { showingAppearance = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    appearanceThemeSection
                    Divider()
                    appearanceComfortSection
                    Divider()
                    appearanceTextSection
                    Divider()
                    appearanceSpacingSection
                    Divider()
                    appearanceLayoutSection
                    Divider()
                    appearancePageSection
                }
                .padding(18)
            }

            Divider()

            HStack {
                Button("Reset Theme") { resetCurrentTheme() }
                    .buttonStyle(.link)
                    .help("Restore this theme's font, spacing, and layout defaults")
                Spacer()
                Button("Reset Size") { fontScale = 1.0 }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("Reset text size to 100%")
                Text("\(Int(fontScale * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(width: 410, height: 600)
    }

    private func appearanceSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.8)
            content()
        }
    }

    private var appearanceThemeSection: some View {
        appearanceSection("Theme") {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                spacing: 10
            ) {
                ForEach(ReaderThemePreset.allCases) { preset in
                    let selected = activeAppearance.theme == preset
                    Button {
                        applyTheme(preset)
                    } label: {
                        VStack(spacing: 5) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(preset.backgroundColor)
                                Text("Aa")
                                    .font(.system(
                                        size: 19,
                                        weight: preset.defaultBold ? .bold : .regular,
                                        design: preset.previewDesign
                                    ))
                                    .foregroundStyle(preset.foregroundColor)
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(
                                        selected ? Color.accentColor : Color.primary.opacity(0.10),
                                        lineWidth: selected ? 2 : 1
                                    )
                            }
                            .frame(height: 50)
                            Text(preset.displayName)
                                .font(.caption2.weight(selected ? .semibold : .regular))
                                .foregroundStyle(selected ? Color.primary : Color.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(preset.displayName) theme")
                    .accessibilityValue(selected ? "Selected" : "")
                }
            }
        }
    }

    private var appearanceComfortSection: some View {
        appearanceSection("Comfort") {
            appearanceSlider(
                "Brightness",
                value: $readerBrightness,
                range: ReaderComfort.brightnessRange,
                step: 0.01,
                display: "\(Int(readerBrightness * 100))%"
            )
            Text("Dims the page only; the controls stay at full brightness.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var appearanceTextSection: some View {
        appearanceSection("Text") {
            HStack {
                Text("Font")
                    .font(.callout)
                Spacer()
                Picker("Font", selection: $readerFontFamily) {
                    ForEach(ReaderFontFamily.allCases) { font in
                        Text(font.displayName).tag(font.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 190)
            }

            Toggle("Bold Text", isOn: $readerBold)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.callout)

            HStack(spacing: 10) {
                Text("Size")
                    .font(.callout)

                Button {
                    fontScale = max(0.8, fontScale - 0.05)
                } label: {
                    Text("A")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("Smaller text")
                .accessibilityLabel("Smaller text")

                Slider(value: $fontScale, in: 0.8 ... 2.0, step: 0.05)

                Button {
                    fontScale = min(2.0, fontScale + 0.05)
                } label: {
                    Text("A")
                        .font(.system(size: 17, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("Larger text")
                .accessibilityLabel("Larger text")

                Text("\(Int(fontScale * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }

    private var appearanceSpacingSection: some View {
        appearanceSection("Spacing") {
            appearanceSlider(
                "Line Spacing",
                value: $lineHeight,
                range: 1.2 ... 2.2,
                step: 0.05,
                display: String(format: "%.2f", lineHeight)
            )
            appearanceSlider(
                "Character Spacing",
                value: $readerCharacterSpacing,
                range: -0.02 ... 0.12,
                step: 0.005,
                display: abs(readerCharacterSpacing) < 0.0001
                    ? "Default"
                    : String(format: "%+.3f em", readerCharacterSpacing)
            )
            appearanceSlider(
                "Word Spacing",
                value: $readerWordSpacing,
                range: 0 ... 0.50,
                step: 0.05,
                display: readerWordSpacing < 0.001
                    ? "Default"
                    : String(format: "%.2f em", readerWordSpacing)
            )
            appearanceSlider(
                "Margins",
                value: $readerMargin,
                range: 24 ... 90,
                step: 2,
                display: "\(Int(readerMargin)) pt"
            )
        }
    }

    private func appearanceSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        display: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.callout)
                Spacer()
                Text(display)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }

    private var appearanceLayoutSection: some View {
        appearanceSection("Layout") {
            Toggle(
                "Justify Text",
                isOn: Binding(
                    get: { alignment == "justify" },
                    set: { alignment = $0 ? "justify" : "left" }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.callout)

            HStack {
                Text("Columns")
                    .font(.callout)
                Spacer()
                Picker("Columns", selection: $readerColumns) {
                    ForEach(ReaderColumnLayout.allCases) { layout in
                        Text(layout.displayName).tag(layout.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
            }
            .help(activeAppearance.columns.helpText)

            Toggle("Hyphenate", isOn: $readerHyphenation)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.callout)
        }
    }

    private var appearancePageSection: some View {
        appearanceSection("Page Turn") {
            HStack {
                Text("Mode")
                    .font(.callout)
                Spacer()
                Picker("Reading Mode", selection: $readerReadingMode) {
                    ForEach(ReaderReadingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
            }

            Picker("Page Turn", selection: $readerPageTurn) {
                ForEach(ReaderPageTurnStyle.allCases) { style in
                    Text(style.displayName).tag(style.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(readerReadingMode == ReaderReadingMode.scroll.rawValue)
            .opacity(readerReadingMode == ReaderReadingMode.scroll.rawValue ? 0.5 : 1)
            .help("Page-turn animation; applies to paged mode only")

            Toggle("Show Page Numbers", isOn: $readerShowPageNumbers)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.callout)

            Toggle("Both Margins Advance", isOn: $readerBothMarginsAdvance)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.callout)
                .help("Either edge goes to the next page. Off: left edge goes back.")
        }
    }

    private func applyTheme(_ theme: ReaderThemePreset) {
        let defaults = ReaderAppearance.defaults(for: theme)
        readerTheme = theme.rawValue
        readerFontFamily = defaults.font.rawValue
        readerBold = defaults.isBold
        lineHeight = defaults.lineHeight
        readerCharacterSpacing = defaults.characterSpacing
        readerWordSpacing = defaults.wordSpacing
        readerMargin = defaults.margin
        alignment = defaults.alignment
        readerColumns = defaults.columns.rawValue
        readerHyphenation = defaults.hyphenation
    }

    private func resetCurrentTheme() {
        applyTheme(activeAppearance.theme)
    }

    private var readerPageControls: some View {
        HStack(spacing: 14) {
            Button {
                turnPage(-1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .accessibilityLabel("Previous page")
            .disabled(pageInChapter == 0 && !canGoToPreviousChapter)

            Text("\(pageInChapter + 1) / \(max(pagesInChapter, 1))")
                .monospacedDigit()
                .frame(minWidth: 62)

            ProgressView(value: bookProgress)
                .progressViewStyle(.linear)
                .tint(activeAppearance.theme.chromeForeground.opacity(0.65))
                .frame(width: 70)

            Button {
                turnPage(1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .accessibilityLabel("Next page")
            .disabled(pageInChapter + 1 >= pagesInChapter && !canGoToNextChapter)
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(activeAppearance.theme.chromeForeground)
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(activeAppearance.theme.chromeBackground, in: Capsule())
        .overlay(
            Capsule().strokeBorder(activeAppearance.theme.chromeStroke, lineWidth: 1)
        )
        .padding(.bottom, 16)
    }

    private var activeAppearance: ReaderAppearance {
        ReaderAppearance(
            theme: ReaderThemePreset.resolve(readerTheme),
            font: ReaderFontFamily(rawValue: readerFontFamily) ?? .original,
            isBold: readerBold,
            textScale: fontScale,
            lineHeight: lineHeight,
            characterSpacing: readerCharacterSpacing,
            wordSpacing: readerWordSpacing,
            margin: readerMargin,
            alignment: alignment,
            columns: ReaderColumnLayout(rawValue: readerColumns) ?? .automatic,
            hyphenation: readerHyphenation,
            pageTurn: ReaderPageTurnStyle(rawValue: readerPageTurn) ?? .slide,
            readingMode: ReaderReadingMode(rawValue: readerReadingMode) ?? .paged,
            showPageNumbers: readerShowPageNumbers,
            brightness: readerBrightness,
            bothMarginsAdvance: readerBothMarginsAdvance
        )
    }

    private var readerSettingsJSON: String {
        activeAppearance.settingsJSON
    }

    private var contentView: some View {
        ZStack {
            if let package, let url = package.fileURL(forChapterAt: currentChapterIndex) {
                EPUBChapterWebView(
                    fileURL: url,
                    allowedReadRoot: package.allowedReadRoot,
                    chapterIndex: currentChapterIndex,
                    startPage: pageInChapter,
                    targetPage: pageInChapter,
                    settingsJSON: readerSettingsJSON,
                    onExternalLink: { url in
                        NSWorkspace.shared.open(url)
                    },
                    onLoadError: { message in
                        logger.error("Chapter failed to render: \(message)")
                    },
                    onPageCount: { pages in
                        pagesInChapter = max(1, pages)
                        if pageInChapter >= pagesInChapter {
                            // Clamping to the last real page is a page change:
                            // a selection made on the dropped page is stale.
                            selectionState.clear()
                            pageInChapter = pagesInChapter - 1
                        }
                        if book.chapters.indices.contains(currentChapterIndex) {
                            coordinator.turnToPage(globalPage)
                        }
                        updatePositionLabel()
                    },
                    onPageChanged: { page in
                        // WP-1.2: a page change can move a selection onto
                        // different text; drop it rather than mis-anchoring.
                        selectionState.clear()
                        pageInChapter = max(0, page)
                        persistPosition()
                        coordinator.turnToPage(globalPage)
                        updatePositionLabel()
                    },
                    onSelection: { selection in
                        selectionState.record(selection)
                        #if DEBUG
                        logger.debug(
                            "EPUB latest selection: \(selectionState.latest?.locator ?? "none", privacy: .public)"
                        )
                        #endif
                    }
                )
            } else {
                Text("This chapter is unavailable.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            ReaderBrightnessOverlay(brightness: readerBrightness)
        }
        .background(activeAppearance.theme.backgroundColor)
        .navigationTitle(book.title)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    goToChapter(currentChapterIndex - 1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!canGoToPreviousChapter)
                .help("Previous Chapter")

                Button {
                    showingChapterList = true
                } label: {
                    Text(chapterTitle(at: currentChapterIndex))
                        .lineLimit(1)
                }
                .popover(isPresented: $showingChapterList) {
                    chapterListPopover
                }

                Button {
                    goToChapter(currentChapterIndex + 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!canGoToNextChapter)
                .help("Next Chapter")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if rsvpEnabled {
                    Button {
                        loadRSVPText()
                    } label: {
                        Image(systemName: "hare")
                    }
                    .help("Speed-read this chapter (RSVP)")
                    .disabled(package == nil)
                }
                Button {
                    showingInfo = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .popover(isPresented: $showingInfo) {
                    metadataSection
                        .padding()
                        .frame(minWidth: 260)
                }
            }
        }
        // P5 Feature 3: RSVP overlay (sheet — fullScreenCover is not a
        // native macOS SwiftUI presentation).
        .sheet(isPresented: Binding(
            get: { rsvpText != nil },
            set: { if !$0 { rsvpText = nil } }
        )) {
            if let text = rsvpText {
                RSVPReaderView(text: text) { rsvpText = nil }
                    .frame(minWidth: 720, minHeight: 520)
            }
        }
        // PR-5: the Mirage analyze sheet (book detail entry per owner choice).
        .sheet(isPresented: $showingMirageAnalysis) {
            MirageAnalysisSheet(book: book)
        }
        .background(KeyNavigationConfigurator(isEnabled: true, onCommand: handleReaderKey))
        .overlay(alignment: .topLeading) {
            if readerControlsVisible {
                readerTopControls
                    .transition(.opacity)
                    .onHover { hovering in
                        readerControlsHovered = hovering
                        if hovering {
                            cancelReaderControlsHide()
                        } else {
                            scheduleReaderControlsHide()
                        }
                    }
            } else {
                Button {
                    showReaderControls()
                } label: {
                    Image(systemName: "chevron.down.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(activeAppearance.theme.chromeForeground.opacity(0.75))
                        .padding(10)
                        .background(activeAppearance.theme.chromeBackground, in: Circle())
                        .overlay(
                            Circle().strokeBorder(
                                activeAppearance.theme.chromeStroke,
                                lineWidth: 1
                            )
                        )
                }
                .buttonStyle(.plain)
                .help("Show reading controls")
                .accessibilityLabel("Show reading controls")
                .padding(14)
                .onHover { hovering in
                    if hovering { showReaderControls() }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if readerShowPageNumbers {
                readerPageControls
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.16), value: readerShowPageNumbers)
    }

    /// Extracts plain text from the current chapter for RSVP streaming.
    private func loadRSVPText() {
        guard let package,
              let url = package.fileURL(forChapterAt: currentChapterIndex),
              let data = try? Data(contentsOf: url),
              let html = String(data: data, encoding: .utf8) else { return }
        let plain = stripHTML(html)
        guard !plain.isEmpty else { return }
        rsvpText = plain
    }

    private var chapterListPopover: some View {
        let indices = readableChapterIndices.isEmpty
            ? Array(0..<max(package?.chapterCount ?? book.chapters.count, 1))
            : readableChapterIndices
        return List(indices, id: \.self) { index in
            Button {
                goToChapter(index)
                showingChapterList = false
            } label: {
                HStack {
                    Text(chapterTitle(at: index))
                    Spacer()
                    if index == currentChapterIndex {
                        Image(systemName: "checkmark")
                            .foregroundColor(.accentColor)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .frame(minWidth: 280, minHeight: 320)
    }

    @State private var showingMirageAnalysis = false

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(book.title)
                .font(.title2)
                .fontWeight(.bold)
            Text("By \(book.author)")
                .font(.headline)
                .foregroundColor(.secondary)
            HStack(spacing: 16) {
                Label("\(book.totalPages) pages", systemImage: "doc.text")
                Label("\(package?.chapterCount ?? book.chapters.count) chapters", systemImage: "list.bullet")
            }
            .font(.subheadline)
            .foregroundColor(.secondary)
            if let difficulty = book.difficultyProfile {
                Label(String(format: "Grade %.1f", difficulty.gradeLevel), systemImage: "chart.bar")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            // PR-5 mount (owner-approved): "Analyze with Mirage" lives on this
            // book's detail popover. EPUB-only (PDF books are not Mirage-input),
            // never auto-run, and the sheet carries all typed outcomes (ADR-5,
            // S10-ES-1; the app writes no RT state — ADR-6 coherence note).
            Divider()
            Button("Analyze with Mirage…") {
                showingMirageAnalysis = true
            }
            .buttonStyle(.bordered)
        }
    }
}

// MARK: - EPUBTextSelection (WP-1.2)

/// One settled text selection captured inside the EPUB `WKWebView`.
///
/// ### Offset contract (documented here so it cannot drift silently)
///
/// `startOffset` and `endOffset` are **0-based UTF-16 code-unit offsets into
/// the chapter's full `document.body.textContent` at the moment of selection**,
/// independent of layout, columns, page turns, or font settings. They are
/// clamped on construction to `0...length` where `length` is the UTF-16 count
/// of the stored text, so a stale or hostile payload can never produce a
/// locator pointing past the captured quote. Re-flowing the text does not
/// change `document.body.textContent`, which is what makes this locator
/// reflow-invariant.
///
/// `text` is the quoted string, truncated to `maxTextLength` characters
/// (grapheme clusters) so a pathological selection cannot carry an unbounded
/// payload. If the quote was truncated, offsets inside the truncated range
/// still clamp to the stored length.
///
/// ### Locator
///
/// `locator == "ch:<chapterIndex>:<startOffset>:<endOffset>"`. This string is
/// what WP-1.4 must store in `BookNoteAnchor.epub.cfi`. **It is a dense,
/// Asterisma-internal locator, NOT a standards-compliant W3C EPUB CFI** — it
/// only resolves against the same chapter's `document.body.textContent`
/// produced by this reader. The field name is dictated by the frozen WP-1.1
/// schema (`BookNoteAnchor.epub(chapterIndex:cfi:pageInChapter:)`).
struct EPUBTextSelection: Equatable {
    /// Upper bound on retained quote text, characters (grapheme clusters).
    static let maxTextLength = 4_000

    let chapterIndex: Int
    let pageInChapter: Int
    let text: String
    let startOffset: Int
    let endOffset: Int

    /// Dense locator: `ch:<chapterIndex>:<startOffset>:<endOffset>`.
    /// See the offset-contract comment above. Not a standards-compliant CFI.
    let locator: String

    /// Builds a validated selection: whitespace-only text is rejected (nil),
    /// the quote is truncated to `maxTextLength`, and both offsets are clamped
    /// to `0...chapterLength`.
    ///
    /// CR-1 defect fixed here: the offsets address the **whole chapter**, so
    /// they must be clamped against the chapter's length, never against the
    /// captured quote's own length. Clamping to the quote collapsed every
    /// selection that started past the quote's length to a zero-width locator
    /// pointing at the wrong text. When the caller does not know the chapter
    /// length, the offsets are preserved as given rather than collapsed.
    init?(
        chapterIndex: Int,
        pageInChapter: Int,
        chapterLength: Int? = nil,
        text: String,
        startOffset: Int,
        endOffset: Int
    ) {
        // Whitespace-only (or empty) selections are not annotations.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        self.chapterIndex = chapterIndex
        self.pageInChapter = pageInChapter
        let clipped = String(text.prefix(Self.maxTextLength))
        self.text = clipped
        let limit = max(0, chapterLength ?? max(startOffset, endOffset))
        let clampedStart = max(0, min(startOffset, limit))
        // The stored quote is truncated, so the anchor range is capped at the
        // same length: quote and range must always describe the same text.
        let quoteLength = clipped.utf16.count
        let clampedEnd = max(clampedStart, min(endOffset, limit, clampedStart + quoteLength))
        self.startOffset = clampedStart
        self.endOffset = clampedEnd
        self.locator = "ch:\(chapterIndex):\(clampedStart):\(clampedEnd)"
    }

    /// Parses a locator produced by `init` back into its three components.
    /// Returns nil for anything not shaped exactly like
    /// `"ch:<int>:<int>:<int>"`.
    static func parse(
        _ locator: String
    ) -> (chapterIndex: Int, startOffset: Int, endOffset: Int)? {
        let parts = locator.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts[0] == "ch",
              let chapterIndex = Int(parts[1]),
              let startOffset = Int(parts[2]),
              let endOffset = Int(parts[3])
        else { return nil }
        return (chapterIndex, startOffset, endOffset)
    }
}

// MARK: - EPUBSelectionState (WP-1.2)

/// Holds the one current EPUB selection for `EPUBReaderScreen`. A plain
/// struct so the screen can hold it in `@State`; record/clear are both
/// explicit so page and chapter navigation can drop stale selections.
struct EPUBSelectionState: Equatable {
    private(set) var latest: EPUBTextSelection?

    /// Records a selection, replacing any previous one.
    mutating func record(_ selection: EPUBTextSelection) {
        latest = selection
    }

    /// Drops the current selection (page/chapter changed, or the screen left).
    mutating func clear() {
        latest = nil
    }
}

// MARK: - EPUBChapterWebView

/// Renders one already-unzipped chapter file. Holds no resource lifecycle
/// of its own — EPUBPackage (owned by the parent view's @State) is what
/// keeps the underlying files and security scope alive; this view only
/// ever needs to be handed a currently-valid local file URL.
private struct EPUBChapterWebView: NSViewRepresentable {
    let fileURL: URL
    let allowedReadRoot: URL
    /// 0-based spine index of the chapter being rendered, embedded in the
    /// page so the selection bridge can stamp it onto every post.
    let chapterIndex: Int
    let startPage: Int
    let targetPage: Int
    let settingsJSON: String
    let onExternalLink: (URL) -> Void
    let onLoadError: (String) -> Void
    let onPageCount: (Int) -> Void
    let onPageChanged: (Int) -> Void
    /// WP-1.2: called with each settled, validated selection. WP-1.4's
    /// annotation UI attaches here; this packet deliberately stops short
    /// of building that UI.
    let onSelection: (EPUBTextSelection) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Pagination and selection both require a tiny amount of injected
        // JavaScript. Book content itself still cannot be trusted with
        // app privileges.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // Both handlers live on the same content controller as the user
        // scripts; `dismantleNSView` removes both so the controller does not
        // retain the coordinator after the view goes away.
        configuration.userContentController.add(context.coordinator, name: "epubPage")
        configuration.userContentController.add(context.coordinator, name: "epubSelection")
        for script in Self.makeUserScripts(
            chapterIndex: chapterIndex,
            startPage: startPage,
            settingsJSON: settingsJSON
        ) {
            configuration.userContentController.addUserScript(script)
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = .clear

        context.coordinator.webView = webView
        context.coordinator.targetPage = startPage
        context.coordinator.settingsJSON = settingsJSON
        context.coordinator.currentlyLoadedURL = fileURL
        webView.loadFileURL(fileURL, allowingReadAccessTo: allowedReadRoot)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.webView = webView
        context.coordinator.onExternalLink = onExternalLink
        context.coordinator.onLoadError = onLoadError
        context.coordinator.onPageCount = onPageCount
        context.coordinator.onPageChanged = onPageChanged
        context.coordinator.onSelection = onSelection

        if context.coordinator.currentlyLoadedURL != fileURL {
            context.coordinator.currentlyLoadedURL = fileURL
            context.coordinator.targetPage = startPage
            context.coordinator.ready = false
            // Chapter changed: user scripts are frozen at their make-time
            // source, so rebuild them so `__epubSelectionChapter` /
            // `__epubInitialPage` carry the NEW chapter and page instead of
            // ones from the chapter the view was first built with.
            let controller = webView.configuration.userContentController
            controller.removeAllUserScripts()
            for script in Self.makeUserScripts(
                chapterIndex: chapterIndex,
                startPage: startPage,
                settingsJSON: settingsJSON
            ) {
                controller.addUserScript(script)
            }
            webView.loadFileURL(fileURL, allowingReadAccessTo: allowedReadRoot)
            return
        }

        if context.coordinator.settingsJSON != settingsJSON {
            context.coordinator.settingsJSON = settingsJSON
            webView.evaluateJavaScript(
                "window.__epubApplySettings && window.__epubApplySettings(\(settingsJSON))"
            )
        }

        if context.coordinator.targetPage != targetPage {
            context.coordinator.go(to: targetPage)
        }
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        // Remove BOTH script-message handlers so the userContentController
        // does not retain the coordinator (and its closures) after the view
        // is dismantled.
        nsView.configuration.userContentController.removeScriptMessageHandler(
            forName: "epubPage")
        nsView.configuration.userContentController.removeScriptMessageHandler(
            forName: "epubSelection")
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            startPage: startPage,
            settingsJSON: settingsJSON,
            onExternalLink: onExternalLink,
            onLoadError: onLoadError,
            onPageCount: onPageCount,
            onPageChanged: onPageChanged,
            onSelection: onSelection
        )
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var targetPage: Int
        var settingsJSON: String
        var currentlyLoadedURL: URL?
        weak var webView: WKWebView?
        var ready = false
        var onExternalLink: (URL) -> Void
        var onLoadError: (String) -> Void
        var onPageCount: (Int) -> Void
        var onPageChanged: (Int) -> Void
        var onSelection: (EPUBTextSelection) -> Void

        init(
            startPage: Int,
            settingsJSON: String,
            onExternalLink: @escaping (URL) -> Void,
            onLoadError: @escaping (String) -> Void,
            onPageCount: @escaping (Int) -> Void,
            onPageChanged: @escaping (Int) -> Void,
            onSelection: @escaping (EPUBTextSelection) -> Void
        ) {
            targetPage = startPage
            self.settingsJSON = settingsJSON
            self.onExternalLink = onExternalLink
            self.onLoadError = onLoadError
            self.onPageCount = onPageCount
            self.onPageChanged = onPageChanged
            self.onSelection = onSelection
        }

        func go(to page: Int) {
            targetPage = page
            guard ready, let webView else { return }
            // The script clamps to the real page count after layout. Keep the
            // selection bridge's page global in sync so a settled selection
            // stamps the page the reader is actually on.
            webView.evaluateJavaScript(
                "window.__epubSelectionPage = \(page); " +
                "window.__epubGoToPage && window.__epubGoToPage(\(page))"
            )
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            if message.name == "epubSelection" {
                guard let body = message.body as? [String: Any],
                      let chapterIndex = body["chapterIndex"] as? Int,
                      let pageInChapter = body["pageInChapter"] as? Int,
                      let text = body["text"] as? String,
                      let startOffset = body["startOffset"] as? Int,
                      let endOffset = body["endOffset"] as? Int,
                      // CR-1: offsets are chapter-absolute. The script posts the
                      // chapter length so they clamp to the chapter, not to the
                      // quote; the init still rejects whitespace-only text and
                      // truncates the quote at maxTextLength.
                      let selection = EPUBTextSelection(
                          chapterIndex: chapterIndex,
                          pageInChapter: pageInChapter,
                          chapterLength: body["textLength"] as? Int,
                          text: text,
                          startOffset: startOffset,
                          endOffset: endOffset
                      )
                else { return }
                DispatchQueue.main.async {
                    self.onSelection(selection)
                }
                return
            }

            guard message.name == "epubPage",
                  let body = message.body as? [String: Any],
                  let pages = body["pages"] as? Int,
                  let page = body["page"] as? Int
            else { return }
            DispatchQueue.main.async {
                self.onPageCount(max(1, pages))
                self.onPageChanged(max(0, page))
            }
        }

        func webView(
            _: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url
            {
                onExternalLink(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            ready = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                webView.evaluateJavaScript(
                    "window.__epubGoToPage && window.__epubGoToPage(\(self.targetPage))"
                )
            }
        }

        func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
            onLoadError(error.localizedDescription)
        }

        func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
            onLoadError(error.localizedDescription)
        }
    }

    /// The full set of user scripts for one chapter load. Rebuilt on every
    /// chapter change (see updateNSView) so document-start globals reflect
    /// the chapter and page the view is actually showing.
    static func makeUserScripts(
        chapterIndex: Int,
        startPage: Int,
        settingsJSON: String
    ) -> [WKUserScript] {
        [
            WKUserScript(
                source: "window.__epubInitialPage = \(startPage); " +
                    "window.__epubSelectionChapter = \(chapterIndex);",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ),
            WKUserScript(
                source: "window.__epubReaderSettings = \(settingsJSON);",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ),
            WKUserScript(
                source: paginationScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ),
            WKUserScript(
                source: selectionScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            ),
        ]
    }

    private static let paginationScript = """
    (function() {
      function post(pages, page) {
        // Keep the selection bridge's page global in sync; the selection
        // script stamps `pageInChapter` from it on every post.
        window.__epubSelectionPage = page;
        if (window.webkit && window.webkit.messageHandlers.epubPage) {
          window.webkit.messageHandlers.epubPage.postMessage({pages: pages, page: page});
        }
      }
      function build() {
        if (window.__epubPaginationReady) return;
        window.__epubPaginationReady = true;

        var body = document.body;
        if (!body) return;
        var wrapper = document.createElement('div');
        wrapper.id = '__epub_paginator';
        while (body.firstChild) wrapper.appendChild(body.firstChild);
        body.appendChild(wrapper);

        var style = document.createElement('style');
        style.id = '__epubReaderStyle';
        document.head.appendChild(style);

        var currentPage = (window.__epubInitialPage || 0) | 0;
        var settings = {
          scale: 1,
          lineHeight: 1.55,
          align: 'left',
          bold: false,
          letterSpacing: 0,
          wordSpacing: 0,
          margin: 46,
          columns: 'automatic',
          hyphenation: true,
          pageTurn: 'slide',
          readingMode: 'paged',
          bg: '#ffffff',
          fg: '#111111',
          brightness: 1,
          bothMarginsAdvance: false
        };
        var suppressScroll = false;
        var animationToken = 0;

        function metrics() {
          var w = window.innerWidth;
          var h = window.innerHeight;
          var minMargin = Math.max(18, Number(settings.margin) || 46);

          if (settings.readingMode === 'scroll') {
            var scrollMargin = Math.max(minMargin, (w - 720) / 2);
            scrollMargin = Math.min(scrollMargin, Math.max(18, (w - 240) / 2));
            wrapper.style.columnWidth = 'auto';
            wrapper.style.columnGap = '0px';
            wrapper.style.height = 'auto';
            wrapper.style.paddingLeft = scrollMargin + 'px';
            wrapper.style.paddingRight = scrollMargin + 'px';
            var scrollPages = Math.max(1, Math.ceil(wrapper.scrollHeight / h));
            return {pages: scrollPages, spread: 1, margin: scrollMargin, col: w - scrollMargin * 2, gap: 0, scroll: true};
          }

          var requested = settings.columns || 'automatic';
          var spread = requested === 'single' ? 1
            : requested === 'double' ? (w >= 760 ? 2 : 1)
            : (w >= 1000 ? 2 : 1);
          var preferredGap = 44;
          var maxColumn = 620;
          var wantedWidth = maxColumn * spread + preferredGap * (spread - 1);
          var margin = Math.max(minMargin, (w - wantedWidth) / 2);
          margin = Math.min(margin, Math.max(18, (w - 240) / 2));
          var gap = spread === 2 ? preferredGap : 0;
          var available = Math.max(240, w - margin * 2 - gap * (spread - 1));
          var col = Math.max(180, Math.min(maxColumn, available / spread));
          wrapper.style.columnWidth = col + 'px';
          wrapper.style.columnGap = gap + 'px';
          wrapper.style.height = h + 'px';
          wrapper.style.paddingLeft = margin + 'px';
          wrapper.style.paddingRight = margin + 'px';
          var cols = Math.max(1, Math.round((wrapper.scrollWidth - margin * 2 + gap) / (col + gap)));
          var pages = Math.max(1, Math.ceil(cols / spread));
          return {pages: pages, spread: spread, margin: margin, col: col, gap: gap, scroll: false};
        }

        function go(page, animate) {
          var m = metrics();
          page = Math.max(0, Math.min(page | 0, m.pages - 1));
          currentPage = page;
          animationToken++;
          var token = animationToken;

          if (m.scroll) {
            suppressScroll = false;
            var top = page * window.innerHeight;
            if (!animate) {
              window.scrollTo(0, top);
            } else {
              window.scrollTo({top: top, behavior: 'smooth'});
            }
            post(m.pages, page);
            return;
          }

          if (window.scrollY) window.scrollTo(0, 0);
          var target = page * window.innerWidth;
          var turnStyle = settings.pageTurn || 'slide';

          if (!animate || turnStyle === 'instant') {
            suppressScroll = false;
            wrapper.scrollLeft = target;
            post(m.pages, page);
            return;
          }

          suppressScroll = true;

          if (turnStyle === 'fade') {
            wrapper.style.transition = 'opacity 110ms ease';
            wrapper.style.opacity = '0.3';
            setTimeout(function() {
              if (token !== animationToken) return;
              wrapper.scrollLeft = target;
              wrapper.style.opacity = '1';
              setTimeout(function() {
                if (token !== animationToken) return;
                suppressScroll = false;
                post(m.pages, page);
              }, 120);
            }, 90);
            return;
          }

          var start = wrapper.scrollLeft;
          var distance = target - start;
          var started = null;
          function step(timestamp) {
            if (token !== animationToken) return;
            if (started === null) started = timestamp;
            var t = Math.min(1, (timestamp - started) / 170);
            var eased = 1 - Math.pow(1 - t, 3);
            wrapper.scrollLeft = start + distance * eased;
            if (t < 1) {
              requestAnimationFrame(step);
            } else {
              wrapper.scrollLeft = target;
              suppressScroll = false;
              post(m.pages, page);
            }
          }
          requestAnimationFrame(step);
        }
        function apply(s) {
          settings = Object.assign(settings, s || {});
          var scale = Number(settings.scale) || 1;
          var lh = Number(settings.lineHeight) || 1.55;
          var align = settings.align === 'justify' ? 'justify' : 'left';
          var bg = settings.bg || '#ffffff';
          var fg = settings.fg || '#111111';
          var weight = settings.bold ? '600' : 'normal';
          var letter = Number(settings.letterSpacing) || 0;
          var word = Number(settings.wordSpacing) || 0;
          var hyphens = settings.hyphenation === false ? 'manual' : 'auto';
          var family = settings.fontFamily || '';
          var familyRule = family
            ? '#__epub_paginator, #__epub_paginator p, #__epub_paginator li, #__epub_paginator div, #__epub_paginator span, #__epub_paginator h1, #__epub_paginator h2, #__epub_paginator h3, #__epub_paginator h4, #__epub_paginator h5, #__epub_paginator h6 { font-family:' + family + ' !important; }'
            : '';
          var scrollMode = settings.readingMode === 'scroll';
          var pageRule = scrollMode
            ? 'html, body { margin:0 !important; padding:0 !important; height:auto !important; overflow-y:auto !important; overflow-x:hidden !important; background:' + bg + ' !important; color:' + fg + ' !important; }'
            : 'html, body { margin:0 !important; padding:0 !important; height:100% !important; overflow:hidden !important; background:' + bg + ' !important; color:' + fg + ' !important; }';
          var wrapperRule = scrollMode
            ? '#__epub_paginator { height:auto; box-sizing:border-box; padding:34px 0; overflow:visible; column-width:auto; column-gap:0; background:' + bg + ' !important; color:' + fg + ' !important; font-size:' + (16 * scale) + 'px !important; line-height:' + lh + ' !important; letter-spacing:' + letter + 'em !important; word-spacing:' + word + 'em !important; }'
            : '#__epub_paginator { height:100vh; box-sizing:border-box; padding:34px 0; overflow-x:auto; overflow-y:hidden; column-fill:auto; background:' + bg + ' !important; color:' + fg + ' !important; font-size:' + (16 * scale) + 'px !important; line-height:' + lh + ' !important; letter-spacing:' + letter + 'em !important; word-spacing:' + word + 'em !important; }';
          style.textContent = [
            pageRule,
            wrapperRule,
            '#__epub_paginator p, #__epub_paginator li, #__epub_paginator div { text-align:' + align + ' !important; line-height:' + lh + ' !important; letter-spacing:' + letter + 'em !important; word-spacing:' + word + 'em !important; color:' + fg + ' !important; hyphens:' + hyphens + '; -webkit-hyphens:' + hyphens + '; }',
            '#__epub_paginator p, #__epub_paginator li, #__epub_paginator div, #__epub_paginator span { font-weight:' + weight + ' !important; }',
            familyRule,
            '#__epub_paginator a { color:' + fg + ' !important; }',
            '#__epub_paginator::-webkit-scrollbar { display:none; }',
            'img, svg { max-width:100%; height:auto; }'
          ].join(String.fromCharCode(10));
          var m = metrics();
          currentPage = Math.max(0, Math.min(currentPage, m.pages - 1));
          go(currentPage, false);
        }

        window.__epubApplySettings = apply;
        apply(window.__epubReaderSettings || {});

        wrapper.addEventListener('scroll', function() {
          if (settings.readingMode === 'scroll' || suppressScroll) return;
          var m = metrics();
          var p = Math.round(wrapper.scrollLeft / window.innerWidth);
          if (p !== currentPage) {
            currentPage = p;
            post(m.pages, p);
          }
        });
        window.addEventListener('scroll', function() {
          if (settings.readingMode !== 'scroll') return;
          var h = window.innerHeight;
          var pages = Math.max(1, Math.ceil(wrapper.scrollHeight / h));
          var top = window.scrollY || document.documentElement.scrollTop || 0;
          var p = Math.max(0, Math.min(Math.round(top / h), pages - 1));
          if (p !== currentPage) {
            currentPage = p;
            post(pages, p);
          }
        }, {passive: true});
        window.addEventListener('resize', function() {
          setTimeout(function() {
            var m = metrics();
            currentPage = Math.min(currentPage, m.pages - 1);
            go(currentPage, false);
          }, 60);
        });
        window.__epubGoToPage = function(page) { go(page, true); };

        // Apple Books-style edge clicks. This lives in the document rather than
        // in a SwiftUI overlay, so trackpad scrolling and links still work.
        document.addEventListener('click', function(event) {
          if (event.defaultPrevented) return;
          if (event.target && event.target.closest && event.target.closest('a')) return;
          if (window.getSelection && String(window.getSelection()).length > 0) return;
          var x = event.clientX;
          if (settings.bothMarginsAdvance) {
            if (x < 64 || x > window.innerWidth - 64) {
              go(currentPage + 1, true);
            }
          } else if (x < 64) {
            go(currentPage - 1, true);
          } else if (x > window.innerWidth - 64) {
            go(currentPage + 1, true);
          }
        }, true);
        setTimeout(function() {
          var m = metrics();
          currentPage = Math.min(currentPage, m.pages - 1);
          go(currentPage, false);
        }, 120);
        setTimeout(function() { go(currentPage, false); }, 600);
      }
      if (document.readyState === 'complete') build();
      else window.addEventListener('load', build);
    })();
    """

    /// WP-1.2 selection bridge. Injected at `.atDocumentEnd` on the same
    /// content controller as the pagination script. A settled selection
    /// (debounced 120 ms so a drag posts once) is posted through
    /// `window.webkit.messageHandlers.epubSelection` as
    /// `{chapterIndex, pageInChapter, text, startOffset, endOffset, textLength}`.
    ///
    /// OFFSET CONTRACT (must match EPUBTextSelection's documented contract —
    /// do not let this drift silently): `startOffset`/`endOffset` are 0-based
    /// UTF-16 code-unit offsets into the chapter's full
    /// `document.body.textContent`, independent of layout. They are computed
    /// by ranging from the body start to the selection boundary and counting
    /// the range's text in UTF-16 units (`String.length`). Swift clamps the
    /// received values to `textLength`, so this side must report the chapter's
    /// own length rather than the quote's.
    private static let selectionScript = """
    (function() {
      if (window.__epubSelectionInstalled) return;
      window.__epubSelectionInstalled = true;

      var DEBOUNCE_MS = 120;
      var timer = null;

      // UTF-16 length of the text from the body's start up to a boundary
      // point. Returns -1 if the point is not measurable (book content is
      // untrusted, so nothing here is allowed to throw).
      function offsetOfBoundary(container, offsetInContainer) {
        try {
          var range = document.createRange();
          range.setStart(document.body, 0);
          range.setEnd(container, offsetInContainer);
          return range.toString().length;
        } catch (e) {
          return -1;
        }
      }

      function postSelection() {
        timer = null;
        var body = document.body;
        var selection = window.getSelection ? window.getSelection() : null;
        if (!body || !selection || selection.rangeCount === 0 || selection.isCollapsed) return;

        var text = selection.toString() || '';
        // Whitespace-only selections are not annotations; Swift validates
        // independently, but never post empty payloads at all.
        if (!text.trim()) return;

        var range = selection.getRangeAt(0);
        var startOffset = offsetOfBoundary(range.startContainer, range.startOffset);
        var endOffset = offsetOfBoundary(range.endContainer, range.endOffset);
        if (startOffset < 0 || endOffset < 0) return;

        var chapter = window.__epubSelectionChapter;
        var page = window.__epubSelectionPage;
        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.epubSelection) {
          window.webkit.messageHandlers.epubSelection.postMessage({
            chapterIndex: (typeof chapter === 'number') ? chapter : 0,
            pageInChapter: (typeof page === 'number') ? page : 0,
            text: text,
            startOffset: startOffset,
            endOffset: endOffset,
            textLength: body.textContent ? body.textContent.length : 0
          });
        }
      }

      document.addEventListener('selectionchange', function() {
        if (timer !== null) clearTimeout(timer);
        timer = setTimeout(postSelection, DEBOUNCE_MS);
      });
    })();
    """
}
