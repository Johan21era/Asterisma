//  DiscoveryOfflineTests.swift
//  AsterismaV2.5Tests
//
//  Offline contract for online book discovery. Discovery is optional browse
//  surface; when the machine has no route to the network it must return an
//  empty result quickly instead of holding the sheet open on a default
//  URLSession timeout. These tests never touch the real network.

import Foundation
import Testing
@testable import AsterismaV2_5

// MARK: - URL protocol fixtures

private final class OfflineURLProtocol: URLProtocol {
    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(
            self,
            didFailWithError: URLError(.notConnectedToInternet)
        )
    }

    override func stopLoading() {}
}

private func offlineSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OfflineURLProtocol.self]
    configuration.timeoutIntervalForRequest = 0.5
    configuration.timeoutIntervalForResource = 1
    configuration.waitsForConnectivity = false
    return URLSession(configuration: configuration)
}

// MARK: - Provider stubs

private struct StaticProvider: BookProvider {
    let books: [OnlineBook]

    func searchBooks(query _: String) async -> [OnlineBook] {
        books
    }
}

private struct SlowProvider: BookProvider {
    func searchBooks(query _: String) async -> [OnlineBook] {
        try? await Task.sleep(for: .seconds(2))
        return []
    }
}

private func book(
    _ title: String,
    author: String = "Author",
    isbn: String? = nil,
    source: BookSource = .openLibrary
) -> OnlineBook {
    OnlineBook(
        id: "\(source)-\(title)",
        title: title,
        author: author,
        isbn: isbn,
        source: source,
        availability: .referenceOnly
    )
}

// MARK: - Tests

@Suite("Discovery · offline behaviour", .serialized)
struct DiscoveryOfflineTests {

    @Test("Discovery session is bounded and never waits for connectivity")
    func sessionIsBounded() {
        let configuration = DiscoveryNetworking.session.configuration

        #expect(configuration.timeoutIntervalForRequest == DiscoveryNetworking.requestTimeout)
        #expect(configuration.timeoutIntervalForResource == DiscoveryNetworking.resourceTimeout)
        #expect(configuration.waitsForConnectivity == false)
        #expect(DiscoveryNetworking.requestTimeout <= 10)
    }

    @Test("Open Library returns an empty result, not a hang, when offline")
    func openLibraryOffline() async {
        let provider = OpenLibraryProvider(session: offlineSession())
        let started = ContinuousClock.now

        let results = await provider.searchBooks(query: "Dune")

        #expect(results.isEmpty)
        #expect(ContinuousClock.now - started < .seconds(1))
    }

    @Test("Gutendex returns an empty result, not a hang, when offline")
    func gutenbergOffline() async {
        let provider = GutenbergProvider(session: offlineSession())
        let started = ContinuousClock.now

        let results = await provider.searchBooks(query: "Dune")

        #expect(results.isEmpty)
        #expect(ContinuousClock.now - started < .seconds(1))
    }

    @Test("Service merges providers and removes duplicate ISBNs")
    func deduplicatesAcrossProviders() async {
        let service = BookDiscoveryService(
            openLibraryProvider: StaticProvider(books: [
                book("Dune", isbn: "9780441172719"),
                book("Dune Messiah", isbn: "9780593098233"),
            ]),
            gutenbergProvider: StaticProvider(books: [
                book("Dune (duplicate)", isbn: "9780441172719", source: .gutenberg),
                book("Frankenstein", isbn: "9780486282114", source: .gutenberg),
            ])
        )

        let results = await service.searchBooks(query: "Dune")

        #expect(results.count == 3)
        #expect(results.filter { $0.isbn == "9780441172719" }.count == 1)
    }

    @Test("Cancelling a search cancels both in-flight provider requests")
    func cancellationIsPrompt() async {
        let service = BookDiscoveryService(
            openLibraryProvider: SlowProvider(),
            gutenbergProvider: SlowProvider()
        )

        let started = ContinuousClock.now
        let task = Task {
            await service.searchBooks(query: "Dune")
        }

        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        let results = await task.value
        let elapsed = ContinuousClock.now - started

        #expect(results.isEmpty)
        #expect(elapsed < .seconds(1.5))
    }
}
