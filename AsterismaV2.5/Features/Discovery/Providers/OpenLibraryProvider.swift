//  OpenLibraryProvider.swift
//  Online Book Discovery System
//
//  Primary provider for online book discovery.
//  Uses Open Library Search API.
//  Never throws.
//  Always returns a valid array.
//

import Foundation

nonisolated struct OpenLibraryProvider: BookProvider {
    private let session: URLSession

    init(session: URLSession = DiscoveryNetworking.session) {
        self.session = session
    }

    func searchBooks(query: String) async -> [OnlineBook] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedQuery.isEmpty, !Task.isCancelled else {
            return []
        }

        guard let encodedQuery = trimmedQuery.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) else {
            return []
        }

        let urlString = "https://openlibrary.org/search.json?q=\(encodedQuery)"

        guard let url = URL(string: urlString) else {
            return []
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = DiscoveryNetworking.requestTimeout

        do {
            let (data, response) = try await session.data(for: request)

            guard !Task.isCancelled else {
                return []
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  200 ... 299 ~= httpResponse.statusCode
            else {
                return []
            }

            let decoded = try JSONDecoder().decode(
                OpenLibrarySearchResponse.self,
                from: data
            )

            return decoded.docs.compactMap { document in
                mapDocumentToOnlineBook(document)
            }

        } catch {
            // Includes the offline case (URLError.notConnectedToInternet) and
            // task cancellation. Discovery never surfaces network errors as
            // thrown failures; the view model owns the single offline message.
            return []
        }
    }
}

// MARK: - Mapping

private extension OpenLibraryProvider {
    func mapDocumentToOnlineBook(
        _ document: OpenLibraryDocument
    ) -> OnlineBook? {
        let title = document.title?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard let title,
              !title.isEmpty
        else {
            return nil
        }

        let author =
            document.authorName?.first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "Unknown Author"

        let isbn = document.isbn?.first

        let coverURL: URL? = {
            guard let coverID = document.coverI else {
                return nil
            }

            return URL(
                string: "https://covers.openlibrary.org/b/id/\(coverID)-L.jpg"
            )
        }()

        let identifier =
            document.key ??
            isbn ??
            "\(title)-\(author)"

        return OnlineBook(
            id: identifier,
            title: title,
            author: author,
            description: nil,
            isbn: isbn,
            coverURL: coverURL,
            source: .openLibrary,
            availability: .referenceOnly
        )
    }
}

// MARK: - API Models

private struct OpenLibrarySearchResponse: Codable {
    let docs: [OpenLibraryDocument]
}

private struct OpenLibraryDocument: Codable {
    let key: String?

    let title: String?

    let authorName: [String]?

    let isbn: [String]?

    let coverI: Int?

    enum CodingKeys: String, CodingKey {
        case key
        case title
        case isbn

        case authorName = "author_name"
        case coverI = "cover_i"
    }
}
