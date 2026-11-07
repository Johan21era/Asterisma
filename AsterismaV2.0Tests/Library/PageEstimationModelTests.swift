//  PageEstimationModelTests.swift
//  AsterismaV2.0Tests
//
//  E7 pins: one canonical content unit.
//    • Word count converts to pages at a documented density.
//    • Difficulty is metadata; it does not change the page count (E8).
//    • The text entry point and the word-count entry point cannot drift apart.

import Foundation
import Testing

@testable import AsterismaV2_0

@Suite("E7 — canonical page conversion")
struct PageEstimationModelTests {

    @Test("ordinary prose converts at 250 words per page")
    func ordinaryConversion() {
        let result = PageEstimationModel.estimatePages(wordCount: 50_000)
        #expect(result.pages == 200)
        #expect(result.confidence == 1.0)
    }

    @Test("difficulty is metadata, not a page-length multiplier")
    func difficultyDoesNotChangePages() {
        let words = 50_000
        let pages = PageEstimationModel.estimatePages(wordCount: words)
        let dense = ReadingDifficultyProfile(
            gradeLevel: 14,
            averageWordLength: 5.2,
            averageSentenceLength: 20,
            rareLexiconRatio: 0.10
        )
        #expect(dense.difficultyMultiplier > 1)
        #expect(pages.pages == 200)
        #expect(PageEstimationModel.estimatePages(wordCount: words).pages == pages.pages)
    }

    @Test("an empty document is one page, not zero")
    func emptyDocument() {
        let result = PageEstimationModel.estimatePages(wordCount: 0)
        #expect(result.pages == 1)
        #expect(result.confidence == 0)
    }

    @Test("confidence grows with the amount of evidence and saturates")
    func confidenceSaturates() {
        #expect(PageEstimationModel.estimatePages(wordCount: 1_000).confidence < 0.1)
        #expect(PageEstimationModel.estimatePages(wordCount: 40_000).confidence == 1.0)
    }

    @Test("the text and word-count entry points agree")
    func entryPointsAgree() {
        let text = Array(repeating: "word", count: 12_345).joined(separator: " ")
        let fromText = PageEstimationModel.estimatePages(from: text)
        let fromCount = PageEstimationModel.estimatePages(wordCount: 12_345)
        #expect(fromText.pages == fromCount.pages)
    }
}
