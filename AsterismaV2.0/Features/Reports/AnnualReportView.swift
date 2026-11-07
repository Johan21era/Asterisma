//  AnnualReportView.swift
//  AsterismaV2.0
//
//  Full-screen Annual Reading Report — 9 slides, user-navigated.
//
//  ARCHITECTURE
//  Pure presentation layer. All data arrives in AnnualReportData.
//  This file contains no analytics logic.
//
//  NAVIGATION
//  Arrow keys, on-screen buttons, keyboard shortcuts.
//  No automatic advancement.
//  Progress indicator shows current position.
//
//  DESIGN LANGUAGE
//  Dark background (#0D0F14) — deep navy-black, not pure black.
//  Accent: #4B7BEC — electric cobalt, calm and distinctive.
//  Secondary accent: #A8B8D8 — muted slate for supporting text.
//  Type hierarchy: very large display numbers, restrained body.
//  Generous whitespace. One dominant element per slide.
//  Every slide answers exactly one question.

import SwiftUI

// MARK: - Color Constants

private extension Color {
    static let reportBackground = Color(red: 0.051, green: 0.059, blue: 0.078) // #0D0F14
    static let reportAccent = Color(red: 0.294, green: 0.482, blue: 0.925) // #4B7BEC
    static let reportSecondary = Color(red: 0.659, green: 0.722, blue: 0.847) // #A8B8D8
    static let reportSurface = Color(red: 0.102, green: 0.118, blue: 0.149) // #1A1E26
    static let reportHighlight = Color(red: 0.945, green: 0.953, blue: 0.969) // #F1F3F7
    static let reportSubtle = Color(red: 0.200, green: 0.224, blue: 0.278) // #333947
}

// MARK: - Annual Report View

/// Full-screen annual reading report.
/// Presented modally; dismiss returns to the archive or the Jan 1 banner.
struct AnnualReportView: View {
    let data: AnnualReportData
    var onDismiss: () -> Void = {}

    @State private var currentSlide: Int = 0

    private let totalSlides = 9

    var body: some View {
        ZStack {
            Color.reportBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Top bar: close + progress
                reportTopBar

                // Slide content — LIVE-TEST LT-6: GeometryReader+ScrollView keeps
                // the designed layout at full size but scrolls instead of clipping
                // when the window is small (zoom-calibrated).
                GeometryReader { geo in
                    ScrollView {
                        reportSlideContent
                            .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                    }
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
                    .animation(.easeInOut(duration: 0.38), value: currentSlide)

                // Bottom navigation
                reportBottomBar
            }
        }
        .preferredColorScheme(.dark)
        .onKeyPress(.rightArrow) { advanceSlide(); return .handled }
        .onKeyPress(.leftArrow) { retreatSlide(); return .handled }
        .onKeyPress(.escape) { onDismiss(); return .handled }
    }

    // MARK: - Top Bar

    private var reportTopBar: some View {
        HStack(alignment: .center) {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.reportSecondary)
                    .frame(width: 32, height: 32)
                    .background(Color.reportSurface)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])

            Spacer()

            Text(String(data.year))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.reportSecondary)
                .tracking(2)
                .textCase(.uppercase)

            Spacer()

            // Slide progress dots
            HStack(spacing: 6) {
                ForEach(0 ..< totalSlides, id: \.self) { i in
                    Circle()
                        .fill(i == currentSlide ? Color.reportAccent : Color.reportSubtle)
                        .frame(width: i == currentSlide ? 8 : 5, height: i == currentSlide ? 8 : 5)
                        .animation(.spring(response: 0.3), value: currentSlide)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
    }

    // MARK: - Bottom Bar

    private var reportBottomBar: some View {
        HStack {
            if currentSlide > 0 {
                Button(action: retreatSlide) {
                    // LIVE-TEST LT-5: hairline plain-style targets needed double/
                    // triple clicks. Real padded capsule targets now.
                    Label("Previous", systemImage: "chevron.left")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.reportSecondary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Color.reportSurface, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 80)
            }

            Spacer()

            Text("\(currentSlide + 1) of \(totalSlides)")
                .font(.system(size: 12))
                .foregroundColor(.reportSubtle)

            Spacer()

            if currentSlide < totalSlides - 1 {
                Button(action: advanceSlide) {
                    Label("Next", systemImage: "chevron.right")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.reportSecondary)
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Color.reportAccent.opacity(0.18), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Button(action: onDismiss) {
                    Text("Done")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.reportAccent)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Color.reportAccent.opacity(0.18), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 28)
        .padding(.top, 12)
    }

    // MARK: - Slide Router

    @ViewBuilder
    private var reportSlideContent: some View {
        switch currentSlide {
        case 0: VolumeSlide(data: data)
        case 1: RhythmSlide(data: data)
        case 2: LibrarySlide(data: data)
        case 3: PaceSlide(data: data)
        case 4: HighlightsSlide(data: data)
        case 5: StreakSlide(data: data)
        case 6: AchievementsSlide(data: data)
        case 7: GoalsSlide(data: data)
        case 8: NarrativeSlide(data: data)
        default: EmptyView()
        }
    }

    // MARK: - Navigation

    private func advanceSlide() {
        guard currentSlide < totalSlides - 1 else { return }
        withAnimation(.easeInOut(duration: 0.38)) { currentSlide += 1 }
    }

    private func retreatSlide() {
        guard currentSlide > 0 else { return }
        withAnimation(.easeInOut(duration: 0.38)) { currentSlide -= 1 }
    }
}

// MARK: - Slide 1: Volume — How much did I read?

private struct VolumeSlide: View {
    let data: AnnualReportData

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            slideEyebrow("How much did I read?")

            Spacer()

            // Primary number — total reading time
            let hours = Int(data.totalReadingTime / 3600)
            let minutes = Int((data.totalReadingTime.truncatingRemainder(dividingBy: 3600)) / 60)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    Text(hours > 0 ? "\(hours)" : "\(minutes)")
                        .font(.system(size: 120, weight: .black, design: .rounded))
                        .foregroundColor(.reportHighlight)
                        .minimumScaleFactor(0.4)

                    Text(hours > 0 ? "hours" : "minutes")
                        .font(.system(size: 36, weight: .regular, design: .rounded))
                        .foregroundColor(.reportSecondary)
                        .padding(.bottom, 16)
                }

                if hours > 0 && minutes > 0 {
                    Text("\(minutes) minutes more")
                        .font(.system(size: 16))
                        .foregroundColor(.reportSubtle)
                }
            }

            Spacer()

            // Supporting stats row
            HStack(spacing: 0) {
                volumeStat(
                    value: data.totalPagesRead.formatted(),
                    label: "pages"
                )
                Divider()
                    .frame(height: 40)
                    .background(Color.reportSubtle)
                    .padding(.horizontal, 32)
                volumeStat(
                    value: "\(data.totalBooksStarted)",
                    label: data.totalBooksStarted == 1 ? "book started" : "books started"
                )
                Divider()
                    .frame(height: 40)
                    .background(Color.reportSubtle)
                    .padding(.horizontal, 32)
                volumeStat(
                    value: "\(data.totalSessions)",
                    label: data.totalSessions == 1 ? "session" : "sessions"
                )
                Divider()
                    .frame(height: 40)
                    .background(Color.reportSubtle)
                    .padding(.horizontal, 32)
                volumeStat(
                    value: "\(data.totalReadingDays)",
                    label: "reading days"
                )
            }
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 56)
        .padding(.bottom, 12)
    }

    private func volumeStat(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(.reportHighlight)
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(.reportSecondary)
        }
    }
}

// MARK: - Slide 2: Rhythm — When did I read?

private struct RhythmSlide: View {
    let data: AnnualReportData

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            slideEyebrow("When did I read?")

            Spacer()

            // Activity heatmap — 52 weeks × 7 days
            ActivityHeatmapView(activities: data.dailyActivityForYear)
                .padding(.bottom, 32)

            HStack(alignment: .top, spacing: 48) {
                rhythmStat(
                    headline: bestWindowLabel,
                    subhead: "best reading time",
                    icon: bestWindowIcon
                )

                rhythmStat(
                    headline: weekdayName(data.mostActiveDayOfWeek),
                    subhead: "most active day",
                    icon: "calendar"
                )

                rhythmStat(
                    headline: formatDuration(data.longestSingleSession),
                    subhead: "longest session",
                    icon: "clock.fill"
                )

                rhythmStat(
                    headline: formatDuration(data.averageSessionLength),
                    subhead: "avg session",
                    icon: "chart.bar.fill"
                )
            }

            Spacer()
        }
        .padding(.horizontal, 56)
    }

    private var bestWindowLabel: String {
        switch data.bestReadingWindow {
        case .morning: return "Morning"
        case .afternoon: return "Afternoon"
        case .evening: return "Evening"
        case .night: return "Night"
        }
    }

    private var bestWindowIcon: String {
        switch data.bestReadingWindow {
        case .morning: return "sunrise.fill"
        case .afternoon: return "sun.max.fill"
        case .evening: return "sunset.fill"
        case .night: return "moon.fill"
        }
    }

    private func rhythmStat(headline: String, subhead: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundColor(.reportAccent)
                Text(subhead)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.reportSecondary)
                    .textCase(.uppercase)
                    .tracking(1)
            }
            Text(headline)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundColor(.reportHighlight)
        }
    }
}

// MARK: - Slide 3: Library — What did I read?

private struct LibrarySlide: View {
    let data: AnnualReportData

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left: numbers
            VStack(alignment: .leading, spacing: 0) {
                slideEyebrow("What did I read?")

                Spacer()

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .lastTextBaseline, spacing: 8) {
                        Text("\(data.totalBooksCompleted)")
                            .font(.system(size: 96, weight: .black, design: .rounded))
                            .foregroundColor(.reportHighlight)
                        Text(data.totalBooksCompleted == 1 ? "book\nfinished" : "books\nfinished")
                            .font(.system(size: 22, weight: .regular))
                            .foregroundColor(.reportSecondary)
                            .padding(.bottom, 12)
                    }

                    if data.totalBooksStarted > data.totalBooksCompleted {
                        Text("\(data.totalBooksStarted - data.totalBooksCompleted) more in progress")
                            .font(.system(size: 15))
                            .foregroundColor(.reportSubtle)
                    }
                }

                Spacer()

                // Genre & format breakdown
                if let genre = data.dominantGenre, genre != .unknown {
                    libraryStat(label: "Favourite Genre", value: genre.displayName)
                        .padding(.bottom, 16)
                }

                HStack(spacing: 32) {
                    if data.formatBreakdown.epub > 0 {
                        libraryStat(label: "EPUB", value: "\(data.formatBreakdown.epub)")
                    }
                    if data.formatBreakdown.pdf > 0 {
                        libraryStat(label: "PDF", value: "\(data.formatBreakdown.pdf)")
                    }
                    if data.formatBreakdown.comic > 0 {
                        libraryStat(label: "COMICS", value: "\(data.formatBreakdown.comic)")
                    }
                }
                .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 56)

            // Right: book list
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(data.booksReadThisYear.prefix(12)), id: \.id) { book in
                        libraryBookRow(book: book)
                    }
                    if data.booksReadThisYear.count > 12 {
                        Text("+ \(data.booksReadThisYear.count - 12) more")
                            .font(.system(size: 12))
                            .foregroundColor(.reportSubtle)
                            .padding(.top, 4)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxWidth: 280)
            .padding(.trailing, 48)
        }
    }

    private func libraryStat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.reportSubtle)
                .textCase(.uppercase)
                .tracking(1)
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundColor(.reportHighlight)
        }
    }

    private func libraryBookRow(book: Book) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(book.isCompleted ? Color.reportAccent : Color.reportSubtle)
                .frame(width: 3, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.reportHighlight)
                    .lineLimit(1)
                Text(book.author)
                    .font(.system(size: 11))
                    .foregroundColor(.reportSecondary)
                    .lineLimit(1)
            }

            Spacer()

            if book.isCompleted {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.reportAccent)
            }
        }
        .padding(10)
        .background(Color.reportSurface)
        .cornerRadius(8)
    }
}

// MARK: - Slide 4: Pace — How did I read?

private struct PaceSlide: View {
    let data: AnnualReportData

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            slideEyebrow("How did I read?")

            Spacer()

            // Primary: pages per hour
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    Text(pagesPerHour)
                        .font(.system(size: 96, weight: .black, design: .rounded))
                        .foregroundColor(.reportHighlight)
                        .minimumScaleFactor(0.5)
                    Text("pages per hour")
                        .font(.system(size: 28, weight: .regular))
                        .foregroundColor(.reportSecondary)
                        .padding(.bottom, 10)
                }

                Text(paceDescription)
                    .font(.system(size: 16))
                    .foregroundColor(.reportSecondary)
            }

            Spacer()

            // Speed + trend row
            HStack(spacing: 48) {
                paceStat(
                    value: "\(Int(data.averageSecondsPerPage))s",
                    label: "avg seconds per page",
                    accent: false
                )

                paceStat(
                    value: trendLabel,
                    label: "reading trend",
                    accent: data.speedTrend.direction == .growth
                )

                if data.improvementAnalysis.speedImprovement > 0.05 {
                    paceStat(
                        value: "+\(Int(data.improvementAnalysis.speedImprovement * 100))%",
                        label: "speed improvement",
                        accent: true
                    )
                }

                if data.improvementAnalysis.enduranceImprovement > 0.05 {
                    paceStat(
                        value: "+\(Int(data.improvementAnalysis.enduranceImprovement * 100))%",
                        label: "session endurance",
                        accent: true
                    )
                }
            }

            Spacer()
        }
        .padding(.horizontal, 56)
    }

    private var pagesPerHour: String {
        let pph = data.averageSecondsPerPage > 0 ? 3600 / data.averageSecondsPerPage : 0
        return "\(Int(pph))"
    }

    private var paceDescription: String {
        let pph = data.averageSecondsPerPage > 0 ? 3600 / data.averageSecondsPerPage : 0
        switch pph {
        case 0 ..< 20: return "A deliberate, deep reading pace — you savour the text."
        case 20 ..< 30: return "A measured pace. Thorough, not rushed."
        case 30 ..< 50: return "A solid, well-calibrated reading pace."
        case 50 ..< 70: return "A confident, efficient pace."
        default: return "A fast, well-trained reading pace."
        }
    }

    private var trendLabel: String {
        switch data.speedTrend.direction {
        case .growth: return "↑ Growing"
        case .decline: return "↓ Slowing"
        case .plateau: return "→ Steady"
        }
    }

    private func paceStat(value: String, label: String, accent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(accent ? .reportAccent : .reportHighlight)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.reportSecondary)
        }
    }
}

// MARK: - Slide 5: Highlights — Which books mattered most?

private struct HighlightsSlide: View {
    let data: AnnualReportData

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            slideEyebrow("Which books stood out?")

            Spacer()

            let cards = highlightCards
            if cards.isEmpty {
                Text("Not enough data for highlights this year.")
                    .font(.system(size: 18))
                    .foregroundColor(.reportSecondary)
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 20),
                        GridItem(.flexible(), spacing: 20),
                    ],
                    spacing: 20
                ) {
                    ForEach(cards) { card in
                        highlightCard(card)
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, 56)
    }

    struct HighlightCard: Identifiable {
        let id = UUID()
        let category: String
        let bookTitle: String
        let bookAuthor: String
        let detail: String
        let icon: String
    }

    private var highlightCards: [HighlightCard] {
        var cards: [HighlightCard] = []

        if let book = data.mostReadBook {
            cards.append(HighlightCard(
                category: "Most Time Spent",
                bookTitle: book.title,
                bookAuthor: book.author,
                detail: formatDuration(book.totalReadingTime),
                icon: "clock.fill"
            ))
        }

        if let book = data.longestBook {
            cards.append(HighlightCard(
                category: "Longest Book",
                bookTitle: book.title,
                bookAuthor: book.author,
                detail: "\(book.totalPages) pages",
                icon: "book.fill"
            ))
        }

        if let book = data.fastestBook {
            let speed = data.averageSecondsPerPage > 0 ? 3600.0 / data.averageSecondsPerPage : 0
            cards.append(HighlightCard(
                category: "Fastest Read",
                bookTitle: book.title,
                bookAuthor: book.author,
                detail: "~\(Int(speed)) pages/hr",
                icon: "bolt.fill"
            ))
        }

        if let book = data.deepestBook {
            cards.append(HighlightCard(
                category: "Most Deliberate",
                bookTitle: book.title,
                bookAuthor: book.author,
                detail: "Slowest pace — most engaged",
                icon: "brain.head.profile"
            ))
        }

        return cards
    }

    private func highlightCard(_ card: HighlightCard) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: card.icon)
                    .font(.system(size: 14))
                    .foregroundColor(.reportAccent)
                Text(card.category)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.reportAccent)
                    .textCase(.uppercase)
                    .tracking(1)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(card.bookTitle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.reportHighlight)
                    .lineLimit(2)
                Text(card.bookAuthor)
                    .font(.system(size: 13))
                    .foregroundColor(.reportSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(card.detail)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundColor(.reportSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.reportSubtle)
                .cornerRadius(6)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .background(Color.reportSurface)
        .cornerRadius(14)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.reportSubtle, lineWidth: 1)
        )
    }
}

// MARK: - Slide 6: Streak & Consistency

private struct StreakSlide: View {
    let data: AnnualReportData

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            slideEyebrow("How consistent was I?")

            Spacer()

            HStack(alignment: .top, spacing: 64) {
                // Left: streak number
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .lastTextBaseline, spacing: 8) {
                        Text("\(data.longestYearStreak)")
                            .font(.system(size: 100, weight: .black, design: .rounded))
                            .foregroundColor(.reportHighlight)
                        Text("days")
                            .font(.system(size: 32, weight: .regular))
                            .foregroundColor(.reportSecondary)
                            .padding(.bottom, 8)
                    }
                    Text("longest reading streak in \(data.year)")
                        .font(.system(size: 16))
                        .foregroundColor(.reportSecondary)
                }

                // Right: supporting stats
                VStack(alignment: .leading, spacing: 28) {
                    streakStat(
                        value: "\(Int(data.readingDaysPercentage * 100))%",
                        label: "of days you read",
                        detail: "\(data.totalReadingDays) out of \(daysInYear) days"
                    )

                    streakStat(
                        value: weekdayName(data.mostActiveDayOfWeek),
                        label: "your best weekday",
                        detail: "consistently highest output"
                    )

                    if data.longestYearStreak >= 7 {
                        streakStat(
                            value: "\(data.longestYearStreak) days",
                            label: "best streak",
                            detail: "consecutive days of reading"
                        )
                    }
                }
            }

            Spacer()

            // Weekly pattern bar chart
            if !data.weeklyPatternScores.isEmpty {
                weeklyPatternBars
                    .padding(.bottom, 8)
            }
        }
        .padding(.horizontal, 56)
    }

    private var daysInYear: Int {
        var comps = DateComponents()
        comps.year = data.year; comps.month = 1; comps.day = 1
        let calendar = Calendar.current
        guard let start = calendar.date(from: comps) else { return 365 }
        comps.year = data.year + 1
        guard let end = calendar.date(from: comps) else { return 365 }
        return calendar.dateComponents([.day], from: start, to: end).day ?? 365
    }

    private var weeklyPatternBars: some View {
        let maxValue = data.weeklyPatternScores.values.max() ?? 1
        let days = [1, 2, 3, 4, 5, 6, 7] // Sun…Sat
        let abbreviations = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]

        return VStack(alignment: .leading, spacing: 8) {
            Text("Reading by day of week")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.reportSubtle)
                .textCase(.uppercase)
                .tracking(1)

            HStack(alignment: .bottom, spacing: 10) {
                ForEach(0 ..< 7, id: \.self) { i in
                    let value = data.weeklyPatternScores[days[i]] ?? 0
                    let height = maxValue > 0 ? (value / maxValue) * 60 : 4
                    let isActive = days[i] == data.mostActiveDayOfWeek

                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isActive ? Color.reportAccent : Color.reportSubtle)
                            .frame(width: 28, height: max(4, height))
                        Text(abbreviations[i])
                            .font(.system(size: 10))
                            .foregroundColor(isActive ? .reportAccent : .reportSubtle)
                    }
                }
            }
        }
    }

    private func streakStat(value: String, label: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundColor(.reportHighlight)
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.reportSecondary)
            Text(detail)
                .font(.system(size: 11))
                .foregroundColor(.reportSubtle)
        }
    }
}

// MARK: - Slide 7: Achievements

private struct AchievementsSlide: View {
    let data: AnnualReportData

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            slideEyebrow("What did I unlock?")

            Spacer()

            if data.achievementsEarnedThisYear.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("No achievements earned this year.")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(.reportSecondary)
                    Text("Achievements are awarded for streaks, milestones, session counts, and goal completions. Next year is a fresh start.")
                        .font(.system(size: 15))
                        .foregroundColor(.reportSubtle)
                }
            } else {
                // Header count
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .lastTextBaseline, spacing: 10) {
                        Text("\(data.totalAchievementsEarned)")
                            .font(.system(size: 72, weight: .black, design: .rounded))
                            .foregroundColor(.reportHighlight)
                        Text(data.totalAchievementsEarned == 1 ? "achievement" : "achievements")
                            .font(.system(size: 26, weight: .regular))
                            .foregroundColor(.reportSecondary)
                            .padding(.bottom, 6)
                    }

                    if let tier = data.highestTierEarned {
                        Text("Highest: \(tier.rawValue.capitalized) tier")
                            .font(.system(size: 14))
                            .foregroundColor(tierColor(tier))
                    }
                }
                .padding(.bottom, 28)

                // Achievement grid
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12),
                        GridItem(.flexible(), spacing: 12),
                    ],
                    spacing: 12
                ) {
                    ForEach(Array(data.achievementsEarnedThisYear.prefix(9)), id: \.id) { achievement in
                        achievementBadge(achievement)
                    }
                }

                if data.achievementsEarnedThisYear.count > 9 {
                    Text("+ \(data.achievementsEarnedThisYear.count - 9) more")
                        .font(.system(size: 13))
                        .foregroundColor(.reportSubtle)
                        .padding(.top, 8)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 56)
    }

    private func achievementBadge(_ achievement: EarnedAchievement) -> some View {
        let def = AchievementDefinition.definition(for: achievement.kind)
        let tier = def?.tier ?? .bronze

        return VStack(spacing: 8) {
            Image(systemName: def?.symbolName ?? "star.fill")
                .font(.system(size: 22))
                .foregroundColor(tierColor(tier))

            Text(def?.title ?? achievement.kind.rawValue)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.reportHighlight)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            Text(tier.rawValue.capitalized)
                .font(.system(size: 9))
                .foregroundColor(tierColor(tier).opacity(0.7))
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color.reportSurface)
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(tierColor(tier).opacity(0.25), lineWidth: 1)
        )
    }

    private func tierColor(_ tier: AchievementDefinition.AchievementTier) -> Color {
        switch tier {
        case .bronze: return Color(red: 0.72, green: 0.45, blue: 0.20)
        case .silver: return Color(red: 0.72, green: 0.72, blue: 0.75)
        case .gold: return Color(red: 0.85, green: 0.72, blue: 0.25)
        case .platinum: return Color(red: 0.70, green: 0.88, blue: 0.98)
        }
    }
}

// MARK: - Slide 8: Goals

private struct GoalsSlide: View {
    let data: AnnualReportData

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            slideEyebrow("Did I meet my goals?")

            Spacer()

            if !data.hadAnnualGoal && data.annualGoalStatus == nil {
                VStack(alignment: .leading, spacing: 12) {
                    Text("No annual goal set for \(data.year).")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(.reportSecondary)
                    Text("Setting an annual book target gives this report a score to track against. You can set one in settings anytime.")
                        .font(.system(size: 15))
                        .foregroundColor(.reportSubtle)
                    Spacer()
                    // Still show what they accomplished
                    HStack(spacing: 40) {
                        goalFact(value: "\(data.totalBooksCompleted)", label: "books finished")
                        goalFact(value: "\(data.totalReadingDays)", label: "reading days")
                        goalFact(value: formatDuration(data.totalReadingTime), label: "total reading")
                    }
                }
            } else if let status = data.annualGoalStatus {
                let target = Int(status.target)
                let current = Int(status.current)
                let achieved = status.isAchieved

                VStack(alignment: .leading, spacing: 16) {
                    // Big progress fraction
                    HStack(alignment: .lastTextBaseline, spacing: 6) {
                        Text("\(current)")
                            .font(.system(size: 100, weight: .black, design: .rounded))
                            .foregroundColor(achieved ? .reportAccent : .reportHighlight)
                        Text("/ \(target)")
                            .font(.system(size: 40, weight: .regular))
                            .foregroundColor(.reportSecondary)
                            .padding(.bottom, 8)
                    }

                    Text(achieved ? "Goal achieved." : "books completed against your goal of \(target).")
                        .font(.system(size: 18))
                        .foregroundColor(.reportSecondary)

                    // Progress bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.reportSubtle)
                                .frame(height: 8)
                            RoundedRectangle(cornerRadius: 6)
                                .fill(achieved ? Color.reportAccent : Color.reportAccent.opacity(0.7))
                                .frame(
                                    width: geo.size.width * min(1, status.percentComplete),
                                    height: 8
                                )
                        }
                    }
                    .frame(height: 8)
                    .padding(.top, 4)

                    Text("\(Int(status.percentComplete * 100))% complete")
                        .font(.system(size: 13))
                        .foregroundColor(.reportSubtle)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 56)
    }

    private func goalFact(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(.reportHighlight)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.reportSecondary)
        }
    }
}

// MARK: - Slide 9: Narrative — Who did I become?

private struct NarrativeSlide: View {
    let data: AnnualReportData

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            slideEyebrow("Who did I become as a reader?")

            Spacer()

            let profile = data.narrativeProfile

            VStack(alignment: .leading, spacing: 36) {
                // Identity
                VStack(alignment: .leading, spacing: 8) {
                    Text(profile.identityLabel)
                        .font(.system(size: 52, weight: .black, design: .rounded))
                        .foregroundColor(.reportHighlight)
                        .minimumScaleFactor(0.6)
                        .lineLimit(2)

                    Text(profile.identitySubtitle)
                        .font(.system(size: 16))
                        .foregroundColor(.reportSecondary)
                }

                // Three narrative blocks — LIVE-TEST LT-6: ViewThatFits stacks
                // them when the window is narrow instead of squeezing/clipping.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 24) {
                        narrativeBlock(headline: profile.standoutStat, body: profile.standoutContext)
                        Divider().background(Color.reportSubtle)
                        narrativeBlock(headline: profile.trajectoryLabel, body: profile.trajectoryDetail)
                        Divider().background(Color.reportSubtle)
                        narrativeBlock(headline: profile.characterObservation, body: profile.characterEvidence)
                    }

                    VStack(alignment: .leading, spacing: 20) {
                        narrativeBlock(headline: profile.standoutStat, body: profile.standoutContext)
                        narrativeBlock(headline: profile.trajectoryLabel, body: profile.trajectoryDetail)
                        narrativeBlock(headline: profile.characterObservation, body: profile.characterEvidence)
                    }
                }

                // Growth signal (optional)
                if let signal = profile.growthSignal, let detail = profile.growthDetail {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.reportAccent)
                            .frame(width: 3, height: 44)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(signal)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.reportAccent)
                            Text(detail)
                                .font(.system(size: 14))
                                .foregroundColor(.reportSecondary)
                        }
                    }
                    .padding(14)
                    .background(Color.reportSurface)
                    .cornerRadius(10)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 56)
    }

    private func narrativeBlock(headline: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headline)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundColor(.reportHighlight)
            // LIVE-TEST LT-6: no truncation — long sentences must be readable.
            Text(body)
                .font(.system(size: 13))
                .foregroundColor(.reportSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Shared Slide Utilities

private func slideEyebrow(_ question: String) -> some View {
    Text(question)
        .font(.system(size: 13, weight: .semibold))
        .foregroundColor(.reportAccent)
        .textCase(.uppercase)
        .tracking(1.5)
        .padding(.top, 12)
}

// MARK: - Activity Heatmap View

/// A 52-week × 7-day activity heatmap using the year's daily activity data.
private struct ActivityHeatmapView: View {
    let activities: [DailyActivity]

    private let columns = 53
    private let cellSize: CGFloat = 11
    private let spacing: CGFloat = 2

    var body: some View {
        let maxValue = activities.map(\.totalDuration).max() ?? 1

        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: spacing) {
                ForEach(0 ..< columns, id: \.self) { col in
                    VStack(spacing: spacing) {
                        ForEach(0 ..< 7, id: \.self) { row in
                            let index = col * 7 + row
                            if index < activities.count {
                                let activity = activities[index]
                                let intensity = maxValue > 0 ? activity.totalDuration / maxValue : 0
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(cellColor(intensity: intensity))
                                    .frame(width: cellSize, height: cellSize)
                            } else {
                                Color.clear
                                    .frame(width: cellSize, height: cellSize)
                            }
                        }
                    }
                }
            }
        }
        .frame(height: (cellSize + spacing) * 7)
    }

    private func cellColor(intensity: Double) -> Color {
        if intensity <= 0 {
            return Color.reportSurface
        }
        switch intensity {
        case 0 ..< 0.2: return Color.reportAccent.opacity(0.15)
        case 0.2 ..< 0.4: return Color.reportAccent.opacity(0.30)
        case 0.4 ..< 0.6: return Color.reportAccent.opacity(0.55)
        case 0.6 ..< 0.8: return Color.reportAccent.opacity(0.75)
        default: return Color.reportAccent
        }
    }
}
