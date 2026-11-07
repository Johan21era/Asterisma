//  CommandPaletteTests.swift
//  AsterismaV2.5Tests
//
//  The palette is presentation code except for one decision: what a query
//  returns and in what order. These tests pin that decision so a future
//  ranking tweak cannot silently bury an exact book title.

@testable import AsterismaV2_5
import Foundation
import Testing

struct CommandPaletteTests {
    private let leftHand = CommandPaletteBook(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        title: "The Left Hand of Darkness",
        author: "Ursula K. Le Guin",
        series: "Hainish Cycle"
    )

    private let dune = CommandPaletteBook(
        id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        title: "Dune",
        author: "Frank Herbert",
        series: nil
    )

    private var index: CommandPaletteIndex {
        CommandPaletteIndex(books: [leftHand, dune])
    }

    @Test func emptyQueryShowsDestinationsAndActionsButNotBooks() {
        let results = index.results(for: "")
        #expect(results.allSatisfy { $0.kind != .book })
        #expect(results.contains { $0.target == .section(.home) })
        #expect(results.contains { $0.target == .discover })
        #expect(results.contains { $0.target == .addBook })
        #expect(results.contains { $0.target == .settings })
    }

    @Test func exactTitleRanksFirst() {
        let results = index.results(for: "Dune")
        #expect(results.first?.title == "Dune")
    }

    @Test func authorQueryFindsBookAndAllTokensMustMatch() {
        let results = index.results(for: "ursula le")
        #expect(results.first?.title == "The Left Hand of Darkness")

        let missing = index.results(for: "ursula tolkien")
        #expect(missing.isEmpty)
    }

    @Test func seriesAndSubtitleMatchesDoNotOutrankTitleMatches() {
        let results = index.results(for: "hainish")
        #expect(results.first?.title == "The Left Hand of Darkness")
        #expect(results.first?.kind == .book)
    }

    @Test func limitCapsResults() {
        let results = index.results(for: "", limit: 3)
        #expect(results.count == 3)
    }
}
