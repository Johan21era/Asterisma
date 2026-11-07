//  CommandPalette.swift
//  AsterismaV2.0
//
//  One keyboard-first surface for the two things a reader does before reading:
//  find a book, or move to a destination. It is deliberately an index over
//  existing state, not a second source of truth. The result rules are pure and
//  unit-tested in `CommandPaletteTests`.
//
//  Design constraints:
//    • Empty query shows destinations and quick actions, not every book.
//    • Typing ranks exact title, title prefix, title token, then contains.
//    • All query tokens must match somewhere, so "urs le" can find
//      "The Left Hand of Darkness" by Ursula K. Le Guin.
//    • The palette never mutates data. It returns a target; ContentView owns
//      navigation and sheet presentation.

import Foundation
import SwiftUI

struct CommandPaletteBook: Identifiable, Equatable {
    let id: UUID
    let title: String
    let author: String
    let series: String?
}

enum CommandPaletteTarget: Equatable {
    case section(AppSection)
    case book(UUID)
    case discover
    case addBook
    case settings
}

struct CommandPaletteItem: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case destination
        case book
        case action
    }

    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let kind: Kind
    let target: CommandPaletteTarget
}

struct CommandPaletteIndex {
    let items: [CommandPaletteItem]

    init(sections: [AppSection] = AppSection.allCases, books: [CommandPaletteBook]) {
        var built: [CommandPaletteItem] = sections.map { section in
            CommandPaletteItem(
                id: "section.\(section.rawValue)",
                title: section.title,
                subtitle: "Destination · \(section.purpose)",
                systemImage: section.systemImage,
                kind: .destination,
                target: .section(section)
            )
        }

        built.append(contentsOf: [
            CommandPaletteItem(
                id: "action.discover",
                title: "Discover Books",
                subtitle: "Action · Search online catalogs for something new",
                systemImage: "sparkle.magnifyingglass",
                kind: .action,
                target: .discover
            ),
            CommandPaletteItem(
                id: "action.addBook",
                title: "Add a Book",
                subtitle: "Action · Import an EPUB, PDF, or comic from this Mac",
                systemImage: "plus",
                kind: .action,
                target: .addBook
            ),
            CommandPaletteItem(
                id: "action.settings",
                title: "Open Settings",
                subtitle: "Action · Goals, Mirage, and app preferences",
                systemImage: "gearshape",
                kind: .action,
                target: .settings
            ),
        ])

        built.append(contentsOf: books.map { book in
            var subtitle = book.author
            if let series = book.series, !series.isEmpty {
                subtitle += " · \(series)"
            }
            return CommandPaletteItem(
                id: "book.\(book.id.uuidString)",
                title: book.title,
                subtitle: subtitle,
                systemImage: "book.closed",
                kind: .book,
                target: .book(book.id)
            )
        })

        self.items = built
    }

    /// Returns at most `limit` results. An empty query intentionally omits
    /// books: the palette is a navigator first, not a second library list.
    func results(for query: String, limit: Int = 10) -> [CommandPaletteItem] {
        let normalized = Self.normalize(query)
        guard !normalized.isEmpty else {
            return Array(items.filter { $0.kind != .book }.prefix(limit))
        }

        let tokens = normalized.split(whereSeparator: \.isWhitespace).map(String.init)
        let ranked = items.compactMap { item -> (item: CommandPaletteItem, score: Int)? in
            guard let score = Self.score(item: item, query: normalized, tokens: tokens) else {
                return nil
            }
            return (item, score)
        }

        return ranked
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.item.title.localizedStandardCompare(rhs.item.title) == .orderedAscending
            }
            .prefix(limit)
            .map(\.item)
    }

    private static func score(
        item: CommandPaletteItem,
        query: String,
        tokens: [String]
    ) -> Int? {
        let title = normalize(item.title)
        let subtitle = normalize(item.subtitle)
        let haystack = title + " " + subtitle

        guard tokens.allSatisfy({ haystack.contains($0) }) else { return nil }

        var score = 0
        if title == query {
            score += 100
        } else if title.hasPrefix(query) {
            score += 60
        } else if title.split(separator: " ").contains(where: { $0.hasPrefix(query) }) {
            score += 40
        } else if title.contains(query) {
            score += 20
        } else if subtitle.contains(query) {
            score += 8
        }

        // Tokens that match the title are worth more than tokens that only
        // match a subtitle, so "the" does not drown out a title match.
        for token in tokens where title.contains(token) {
            score += 6
        }

        switch item.kind {
        case .destination: score += 4
        case .action: score += 2
        case .book: break
        }

        return score
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

struct CommandPaletteView: View {
    let index: CommandPaletteIndex
    let onSelect: (CommandPaletteItem) -> Void
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var searchFocused: Bool

    private var results: [CommandPaletteItem] {
        index.results(for: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider().opacity(0.4)

            if results.isEmpty {
                emptyState
            } else {
                resultList
            }

            Divider().opacity(0.4)
            footer
        }
        .frame(width: 620, height: 430)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 40, y: 18)
        .onAppear { searchFocused = true }
        .onChange(of: query) { _, _ in selection = 0 }
        .onExitCommand(perform: onDismiss)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField("Find a book, destination, or action", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($searchFocused)
                .onSubmit {
                    if let first = results.first { onSelect(first) }
                }
                .onMoveCommand { direction in
                    moveSelection(direction)
                }
                .accessibilityLabel("Quick open search")

            Text("esc")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { offset, item in
                        row(item, isSelected: offset == selection)
                            .id(item.id)
                            .onTapGesture { onSelect(item) }
                    }
                }
                .padding(8)
            }
            .onChange(of: selection) { _, newValue in
                guard results.indices.contains(newValue) else { return }
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo(results[newValue].id, anchor: .center)
                }
            }
        }
    }

    private func row(_ item: CommandPaletteItem, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if isSelected {
                Image(systemName: "return")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.09) : Color.clear)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text("No matches")
                .font(.headline)
            Text("Try a title, author, destination, or action.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Label("Navigate", systemImage: "arrow.up.arrow.down")
            Label("Open", systemImage: "return")
            Label("Close", systemImage: "escape")
            Spacer()
            Text("Asterisma Quick Open")
                .foregroundStyle(.tertiary)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard !results.isEmpty else { return }
        switch direction {
        case .down:
            selection = min(selection + 1, results.count - 1)
        case .up:
            selection = max(selection - 1, 0)
        default:
            break
        }
    }
}
