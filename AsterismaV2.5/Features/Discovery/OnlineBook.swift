//  OnlineBook.swift
//  Online Book Discovery System
//
//  Created for isolated discovery subsystem.
//  No dependencies on existing reader infrastructure.

import Foundation

nonisolated enum BookSource: Hashable, Codable, Sendable {
    case openLibrary
    case gutenberg
    case worldCat
}

nonisolated enum AvailabilityState: Hashable, Codable, Sendable {
    case free
    case referenceOnly
    case unknown
}

nonisolated struct OnlineBook: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let author: String
    let description: String?
    let isbn: String?
    let coverURL: URL?
    let source: BookSource
    let availability: AvailabilityState

    init(
        id: String,
        title: String,
        author: String,
        description: String? = nil,
        isbn: String? = nil,
        coverURL: URL? = nil,
        source: BookSource,
        availability: AvailabilityState
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.description = description
        self.isbn = isbn
        self.coverURL = coverURL
        self.source = source
        self.availability = availability
    }
}
