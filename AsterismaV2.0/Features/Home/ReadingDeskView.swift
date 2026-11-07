//  ReadingDeskView.swift
//  AsterismaV2.0
//
//  The launch surface. Before this view, the app opened on a book list and a
//  mostly-empty detail canvas that said "Select a book to see details." The
//  reading task was reachable, but the user had to construct it themselves.
//
//  The desk answers three questions in order:
//    1. What am I reading now?       → one resume-first hero
//    2. How is my reading going?     → four honest, live stats
//    3. What is next?                → in-progress / unread shelves
//
//  It reads only existing DataStore and AnalyticsEngine values. No new source
//  of truth, no fabricated streaks, and no recommendation ranking is invented
//  here.

import SwiftUI

struct ReadingDeskView: View {
    @EnvironmentObject private var dataStore: DataStore
    /// Goals are already the app's prescriptive layer; the desk reads them so
    /// “today” means today's target, not just a raw page count.
    @EnvironmentObject private var goalVM: GoalProgressViewModel

    let onOpenBook: (Book) -> Void
    let onShowBook: (Book) -> Void
    let onBrowseLibrary: () -> Void
    let onAddBook: () -> Void
    let onOpenInsights: () -> Void
    let onOpenGoals: () -> Void
    let onDiscover: () -> Void

    // MARK: - Live data

    private var inProgress: [Book] {
        dataStore.books
            .filter(\.isInProgress)
            .sorted { ($0.lastReadDate ?? .distantPast) > ($1.lastReadDate ?? .distantPast) }
    }

    private var nextUp: [Book] {
        dataStore.books
            .filter { !$0.isCompleted && $0.currentPage == 0 }
            .sorted { $0.dateAdded > $1.dateAdded }
    }

    /// Most recently read book first; otherwise the newest book the reader has
    /// not started. This deliberately does not invent a recommendation score.
    private var focusBook: Book? {
        inProgress.first ?? nextUp.first
    }

    private var today: DailyActivity? {
        AnalyticsEngine.dailyActivity(books: dataStore.books, days: 1).last
    }

    private var streak: ReadingStreak {
        AnalyticsEngine.streak(books: dataStore.books, epoch: dataStore.analyticsEpoch)
    }

    private var finishedCount: Int {
        dataStore.books.filter(\.isCompleted).count
    }

    /// The most recently finished books. This closes the loop after a finish:
    /// without it, a completed book disappears from Home at the moment the
    /// reader is most likely to want to see it.
    private var recentlyFinished: [Book] {
        dataStore.books
            .filter(\.isCompleted)
            .sorted { ($0.lastReadDate ?? $0.dateAdded) > ($1.lastReadDate ?? $1.dateAdded) }
    }

    /// Prefer the daily page target because it is the most legible unit for a
    /// reading desk. A time-only goal is still shown, just with duration units.
    private var dailyGoal: GoalStatus? {
        goalVM.statuses.first { $0.goal == .dailyPages }
            ?? goalVM.statuses.first { $0.goal == .dailyTime }
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignGrid.sectionSpacing) {
                header
                focusCard
                statsRow

                if inProgress.count > 1 {
                    shelf(title: "Also in progress", books: Array(inProgress.dropFirst().prefix(8)))
                }

                if !nextUp.isEmpty {
                    shelf(title: "Next up", books: Array(nextUp.prefix(8)))
                }

                if !recentlyFinished.isEmpty {
                    shelf(title: "Recently finished", books: Array(recentlyFinished.prefix(8)))
                }

                footerActions
            }
            .padding(.horizontal, DesignGrid.workspaceHorizontalPadding)
            .padding(.vertical, DesignGrid.workspaceVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
    }

    // MARK: - Header

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) {
                headerTitle
                Spacer(minLength: 20)
                headerActions
            }

            VStack(alignment: .leading, spacing: 14) {
                headerTitle
                headerActions
            }
        }
    }

    private var headerTitle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your reading desk")
                .font(.system(size: 34, weight: .semibold, design: .serif))
            Text("\(greeting). Pick up where you left off, or choose what comes next.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var headerActions: some View {
        HStack(spacing: 10) {
            Button {
                onDiscover()
            } label: {
                Label("Discover", systemImage: "sparkle.magnifyingglass")
            }
            .buttonStyle(.bordered)

            Button {
                onAddBook()
            } label: {
                Label("Add Book", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .controlSize(.large)
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5 ..< 12: return "Good morning"
        case 12 ..< 17: return "Good afternoon"
        case 17 ..< 22: return "Good evening"
        default: return "Late night reading"
        }
    }

    // MARK: - Focus card

    @ViewBuilder
    private var focusCard: some View {
        if let book = focusBook {
            focusCard(for: book)
        } else if dataStore.books.isEmpty {
            emptyLibraryCard
        } else {
            caughtUpCard
        }
    }

    /// The hero has two honest shapes. At a wide canvas the cover sits beside
    /// the copy; at the 900 pt window floor the copy drops below the cover so
    /// the title never competes with the dock or runs under the sidebar.
    /// `ViewThatFits` chooses by real measured width, not a guessed size class.
    private func focusCard(for book: Book) -> some View {
        ViewThatFits(in: .horizontal) {
            focusWide(book)
            focusNarrow(book)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
    }

    private func focusWide(_ book: Book) -> some View {
        HStack(alignment: .center, spacing: 26) {
            BookCoverThumbnail(book: book, width: 148, height: 212)
                .shadow(color: .black.opacity(0.3), radius: 18, y: 10)

            VStack(alignment: .leading, spacing: 14) {
                focusEyebrow(book)
                focusTitle(book, compact: false)
                focusMeta(book)
                focusActions(book)
            }
            .frame(minWidth: 380, idealWidth: 520, maxWidth: 560, alignment: .leading)

            Spacer(minLength: 0)
        }
    }

    private func focusNarrow(_ book: Book) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 16) {
                BookCoverThumbnail(book: book, width: 96, height: 138)
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 6)

                VStack(alignment: .leading, spacing: 8) {
                    focusEyebrow(book)
                    focusTitle(book, compact: true)
                }
                Spacer(minLength: 0)
            }

            focusMeta(book)
            focusActions(book)
        }
    }

    private func focusEyebrow(_ book: Book) -> some View {
        Text(book.currentPage > 0 ? "CONTINUE READING" : "START READING")
            .font(.caption.weight(.semibold))
            .tracking(1.2)
            .foregroundStyle(.secondary)
    }

    private func focusTitle(_ book: Book, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(book.title)
                .font(.system(size: compact ? 26 : 34, weight: .semibold, design: .serif))
                .lineLimit(3)
            Text(book.author)
                .font(compact ? .body : .title3)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func focusMeta(_ book: Book) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                deskPill(book.fileType.displayName)
                if book.totalPages > 0 {
                    deskPill("\(book.totalPages) pages")
                }
                if let remaining = timeRemaining(for: book) {
                    deskPill("≈ \(remaining) left")
                }
            }

            if book.progressFraction > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: book.progressFraction)
                        .tint(.accentColor)
                        .frame(maxWidth: 360)
                    Text("\(Int(book.progressFraction * 100))% complete · \(pagesRemaining(for: book)) pages left")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func focusActions(_ book: Book) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                focusPrimaryButton(book)
                focusDetailsButton(book)
            }

            VStack(alignment: .leading, spacing: 8) {
                focusPrimaryButton(book)
                focusDetailsButton(book)
            }
        }
    }

    private func focusPrimaryButton(_ book: Book) -> some View {
        Button {
            onOpenBook(book)
        } label: {
            Label(book.currentPage > 0 ? "Resume" : "Start reading", systemImage: "book")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private func focusDetailsButton(_ book: Book) -> some View {
        Button("Book details") {
            onShowBook(book)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private var emptyLibraryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Your library is empty", systemImage: "books.vertical")
                .font(.title2.weight(.semibold))
            Text("Add an EPUB or PDF and it will appear here, ready to resume.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button {
                    onAddBook()
                } label: {
                    Label("Add your first book", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Browse the library") { onBrowseLibrary() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var caughtUpCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("You are all caught up", systemImage: "checkmark.circle")
                .font(.title2.weight(.semibold))
            Text("Every book in your library is finished. Add another, or look through what you have read.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Browse the library") { onBrowseLibrary() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Button("Add a book") { onAddBook() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Stats

    private var statsRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("At a glance")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Open insights") { onOpenInsights() }
                    .buttonStyle(.link)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 170), spacing: 12)],
                spacing: 12
            ) {
                todayGoalCard
                DeskStatCard(
                    label: "Streak",
                    value: "\(streak.currentStreak) days",
                    detail: streak.currentStreak == 0
                        ? "Start with one page"
                        : "Best: \(streak.longestStreak) days",
                    symbol: "flame"
                )
                DeskStatCard(
                    label: "In progress",
                    value: "\(inProgress.count)",
                    detail: inProgress.count == 1 ? "book on the go" : "books on the go",
                    symbol: "bookmark"
                )
                DeskStatCard(
                    label: "Finished",
                    value: "\(finishedCount)",
                    detail: "all time",
                    symbol: "checkmark.seal"
                )
            }
        }
    }

    /// A goal-aware “today” card. With no goal it still reports today's pages
    /// and offers the Goals destination instead of pretending a target exists.
    @ViewBuilder
    private var todayGoalCard: some View {
        if let status = dailyGoal {
            let isPages = status.goal == .dailyPages
            let value = isPages
                ? "\(Int(status.current)) / \(Int(status.target))"
                : "\(formatDuration(status.current)) / \(formatDuration(status.target))"
            DeskStatCard(
                label: "Today's goal",
                value: value,
                detail: goalDetail(for: status, isPages: isPages),
                symbol: "target",
                action: onOpenGoals
            )
        } else {
            DeskStatCard(
                label: "Today",
                value: todayValue,
                detail: "\(todayDetail) · Set a daily goal",
                symbol: "book.pages",
                action: onOpenGoals
            )
        }
    }

    private func goalDetail(for status: GoalStatus, isPages: Bool) -> String {
        if status.isAchieved {
            return isPages ? "pages · goal met" : "reading · goal met"
        }
        if isPages {
            return "pages · \(Int(max(0, status.target - status.current))) to go"
        }
        return "reading today"
    }

    private var todayValue: String {
        guard let today else { return "0 pages" }
        return "\(today.pagesRead) \(today.pagesRead == 1 ? "page" : "pages")"
    }

    private var todayDetail: String {
        guard let today, today.totalDuration > 0 else { return "No reading yet" }
        return formatDuration(today.totalDuration)
    }

    // MARK: - Shelves

    private func shelf(title: String, books: [Book]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("See all") { onBrowseLibrary() }
                    .buttonStyle(.link)
            }

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 18) {
                    ForEach(books) { book in
                        Button {
                            onShowBook(book)
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                BookCoverCardView(
                                    book: book,
                                    width: DesignGrid.shelfTileWidth,
                                    height: DesignGrid.shelfTileHeight
                                )

                                if book.isCompleted {
                                    Text(finishedDetail(book))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                } else if book.progressFraction > 0 {
                                    ProgressView(value: book.progressFraction)
                                        .tint(.accentColor)
                                        .frame(width: DesignGrid.shelfTileWidth)
                                    Text("\(Int(book.progressFraction * 100))% read")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("Not started")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel(
                            "\(book.title) by \(book.author), \(Int(book.progressFraction * 100)) percent read"
                        )
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: - Footer

    private var footerActions: some View {
        HStack(spacing: 16) {
            Button {
                onBrowseLibrary()
            } label: {
                Label("Browse the whole library", systemImage: "books.vertical")
            }
            .buttonStyle(.link)

            Button {
                onOpenGoals()
            } label: {
                Label("Set a reading goal", systemImage: "target")
            }
            .buttonStyle(.link)

            Spacer()
        }
        .font(.callout)
    }

    // MARK: - Helpers

    private func pagesRemaining(for book: Book) -> Int {
        max(0, book.totalPages - book.currentPage)
    }

    private func timeRemaining(for book: Book) -> String? {
        let estimate = EstimationEngine.estimate(for: book, allBooks: dataStore.books)
        guard estimate.remainingSeconds > 0 else { return nil }
        return formatDuration(estimate.remainingSeconds)
    }

    private func finishedDetail(_ book: Book) -> String {
        guard let date = book.lastReadDate else { return "Finished" }
        return "Finished \(date.formatted(.relative(presentation: .named)))"
    }

    private func deskPill(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: Capsule())
    }
}

// MARK: - Stat card

private struct DeskStatCard: View {
    let label: String
    let value: String
    let detail: String
    let symbol: String
    var action: (() -> Void)? = nil

    var body: some View {
        Group {
            if let action {
                Button(action: action) {
                    cardBody
                }
                .buttonStyle(.plain)
                .help("\(label): open goals")
                .accessibilityLabel("\(label), \(value), \(detail). Open goals.")
            } else {
                cardBody
            }
        }
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(label, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignGrid.cardCornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignGrid.cardCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}
