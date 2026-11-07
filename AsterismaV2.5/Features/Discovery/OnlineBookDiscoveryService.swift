//  OnlineBookDiscoveryService.swift
//  Online Book Discovery System
//
//  Responsibilities:
//  1. Query Open Library and Gutenberg concurrently
//  2. Merge results
//  3. Deduplicate
//  4. Rank results
//
//  Both providers are queried at once so an offline or unreachable network
//  costs one request timeout, not two. Cancellation propagates through the
//  task group, so a new keystroke cannot leave an old query running.
//

import Foundation

nonisolated struct BookDiscoveryService: Sendable {
    private let openLibraryProvider: any BookProvider
    private let gutenbergProvider: any BookProvider

    init(
        openLibraryProvider: any BookProvider = OpenLibraryProvider(),
        gutenbergProvider: any BookProvider = GutenbergProvider()
    ) {
        self.openLibraryProvider = openLibraryProvider
        self.gutenbergProvider = gutenbergProvider
    }

    func searchBooks(query: String) async -> [OnlineBook] {
        let normalizedQuery = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !normalizedQuery.isEmpty, !Task.isCancelled else {
            return []
        }

        let primaryProvider = openLibraryProvider
        let secondaryProvider = gutenbergProvider

        let results = await withTaskGroup(of: [OnlineBook].self) { group in
            group.addTask {
                await primaryProvider.searchBooks(query: normalizedQuery)
            }
            group.addTask {
                await secondaryProvider.searchBooks(query: normalizedQuery)
            }

            var merged: [OnlineBook] = []
            for await batch in group {
                merged.append(contentsOf: batch)
            }
            return merged
        }

        guard !Task.isCancelled else {
            return []
        }

        let deduplicated = deduplicate(results)

        return rank(
            deduplicated,
            query: normalizedQuery
        )
    }
}

// MARK: - Deduplication

private extension BookDiscoveryService {
    func deduplicate(
        _ books: [OnlineBook]
    ) -> [OnlineBook] {
        var seenISBNs = Set<String>()
        var seenTitleAuthor = Set<String>()

        var uniqueBooks: [OnlineBook] = []

        for book in books {
            if let isbn = book.isbn?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !isbn.isEmpty
            {
                if seenISBNs.contains(isbn) {
                    continue
                }

                seenISBNs.insert(isbn)
                uniqueBooks.append(book)
                continue
            }

            let normalizedKey = normalizedTitleAuthorKey(
                title: book.title,
                author: book.author
            )

            if seenTitleAuthor.contains(normalizedKey) {
                continue
            }

            seenTitleAuthor.insert(normalizedKey)
            uniqueBooks.append(book)
        }

        return uniqueBooks
    }
}

// MARK: - Ranking

private extension BookDiscoveryService {
    func rank(
        _ books: [OnlineBook],
        query: String
    ) -> [OnlineBook] {
        let normalizedQuery = normalize(query)

        return books.sorted { lhs, rhs in
            let lhsScore = score(
                lhs,
                query: normalizedQuery
            )

            let rhsScore = score(
                rhs,
                query: normalizedQuery
            )

            if lhsScore == rhsScore {
                return lhs.title.localizedCaseInsensitiveCompare(
                    rhs.title
                ) == .orderedAscending
            }

            return lhsScore > rhsScore
        }
    }

    func score(
        _ book: OnlineBook,
        query: String
    ) -> Int {
        var score = 0

        let normalizedTitle = normalize(book.title)

        if normalizedTitle.contains(query) {
            score += 50
        } else if partialMatch(
            title: normalizedTitle,
            query: query
        ) {
            score += 20
        }

        if !book.author.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty {
            score += 15
        }

        if let description = book.description,
           !description.trimmingCharacters(
               in: .whitespacesAndNewlines
           ).isEmpty
        {
            score += 15
        }

        if book.coverURL != nil {
            score += 10
        }

        if book.availability == .free {
            score += 10
        }

        return score
    }
}

// MARK: - Helpers

private extension BookDiscoveryService {
    func normalizedTitleAuthorKey(
        title: String,
        author: String
    ) -> String {
        "\(normalize(title))|\(normalize(author))"
    }

    func normalize(
        _ value: String
    ) -> String {
        value
            .lowercased()
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
    }

    func partialMatch(
        title: String,
        query: String
    ) -> Bool {
        let queryTokens = query
            .split(separator: " ")
            .map(String.init)

        guard !queryTokens.isEmpty else {
            return false
        }

        return queryTokens.contains {
            token in
            title.contains(token)
        }
    }
}
