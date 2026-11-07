//  EPUBSelectionTests.swift
//  AsterismaV2.0
//
//  WP-1.2: pins for the EPUB selection bridge's pure value layer — the
//  locator format, offset clamping, quote validation, and the one-current-
//  selection state. No WKWebView is instantiated: the JS side is exercised
//  by live reading, these tests pin the Swift contract.

import Foundation
import Testing

@testable import AsterismaV2_0

@Suite("EPUB selection bridge")
struct EPUBSelectionTests {

    // 1. Locator round-trips through EPUBTextSelection and its parser.
    @Test("Locator round-trips through EPUBTextSelection and its parser")
    func locatorRoundTrip() throws {
        let selection = try #require(
            EPUBTextSelection(
                chapterIndex: 3,
                pageInChapter: 1,
                text: "Hello, world",
                startOffset: 7,
                endOffset: 12
            )
        )
        #expect(selection.locator == "ch:3:7:12")

        let parsed = try #require(EPUBTextSelection.parse(selection.locator))
        #expect(parsed.chapterIndex == 3)
        #expect(parsed.startOffset == 7)
        #expect(parsed.endOffset == 12)

        // Rebuilding from the parsed parts reproduces the same value.
        let rebuilt = EPUBTextSelection(
            chapterIndex: parsed.chapterIndex,
            pageInChapter: selection.pageInChapter,
            text: selection.text,
            startOffset: parsed.startOffset,
            endOffset: parsed.endOffset
        )
        #expect(rebuilt == selection)
    }

    @Test("Malformed locators fail to parse")
    func malformedLocatorsReject() {
        #expect(EPUBTextSelection.parse("") == nil)
        #expect(EPUBTextSelection.parse("ch:3") == nil)
        #expect(EPUBTextSelection.parse("pg:1:2:3") == nil)
        #expect(EPUBTextSelection.parse("ch:a:2:3") == nil)
        #expect(EPUBTextSelection.parse("ch:3:x:3") == nil)
        #expect(EPUBTextSelection.parse("ch:3:2:y") == nil)
    }

    // 2. Negative and out-of-range offsets clamp to 0...textLength.
    @Test("Negative and out-of-range offsets clamp to 0...textLength")
    func offsetsClamp() throws {
        // "abc" has 3 UTF-16 units.
        let clamped = try #require(
            EPUBTextSelection(
                chapterIndex: 0,
                pageInChapter: 0,
                text: "abc",
                startOffset: -5,
                endOffset: 99
            )
        )
        #expect(clamped.startOffset == 0)
        #expect(clamped.endOffset == 3)
        #expect(clamped.locator == "ch:0:0:3")

        let negative = try #require(
            EPUBTextSelection(
                chapterIndex: 0,
                pageInChapter: 0,
                text: "abc",
                startOffset: -9,
                endOffset: -1
            )
        )
        #expect(negative.startOffset == 0)
        #expect(negative.endOffset == 0)
    }

    // 3a. Whitespace-only text is rejected.
    @Test("Whitespace-only selections are rejected")
    func whitespaceOnlyRejected() {
        #expect(
            EPUBTextSelection(
                chapterIndex: 0,
                pageInChapter: 0,
                text: "   ",
                startOffset: 0,
                endOffset: 0
            ) == nil
        )
        #expect(
            EPUBTextSelection(
                chapterIndex: 0,
                pageInChapter: 0,
                text: "\n\t \u{00A0} ",
                startOffset: 0,
                endOffset: 0
            ) == nil
        )
        #expect(EPUBTextSelection(chapterIndex: 0, pageInChapter: 0, text: "", startOffset: 0, endOffset: 0) == nil)
    }

    // 3b. A 5,000-character quote truncates to 4,000.
    @Test("Long quotes truncate to 4,000 characters")
    func longQuoteTruncates() throws {
        let quote = String(repeating: "a", count: 5_000)
        let selection = try #require(
            EPUBTextSelection(
                chapterIndex: 2,
                pageInChapter: 2,
                text: quote,
                startOffset: 0,
                endOffset: 5_000
            )
        )
        #expect(selection.text.count == EPUBTextSelection.maxTextLength)
        #expect(EPUBTextSelection.maxTextLength == 4_000)
        // Offsets clamp to the stored text's UTF-16 length (4,000 for ASCII).
        #expect(selection.startOffset == 0)
        #expect(selection.endOffset == 4_000)
        #expect(selection.locator == "ch:2:0:4000")
    }

    // 4. clear() empties latest; a later record replaces it.
    @Test("EPUBSelectionState clears and replaces the latest selection")
    func stateClearAndReplace() throws {
        var state = EPUBSelectionState()
        #expect(EPUBSelectionState() == state) // fresh state == fresh state

        let first = try #require(
            EPUBTextSelection(
                chapterIndex: 0,
                pageInChapter: 0,
                text: "first quote",
                startOffset: 0,
                endOffset: 11
            )
        )
        state.record(first)
        #expect(state.latest == first)

        state.clear()
        #expect(state.latest == nil)

        let second = try #require(
            EPUBTextSelection(
                chapterIndex: 1,
                pageInChapter: 0,
                text: "second quote",
                startOffset: 5,
                endOffset: 12
            )
        )
        state.record(second)
        #expect(state.latest == second)
        #expect(state.latest != first)
    }

    // 5. Chapter index and page are preserved unchanged through the locator.
    @Test("Chapter index and page are preserved through the locator")
    func chapterAndPagePreserved() throws {
        let selection = try #require(
            EPUBTextSelection(
                chapterIndex: 7,
                pageInChapter: 2,
                text: "The answer",
                startOffset: 4,
                endOffset: 10
            )
        )
        #expect(selection.chapterIndex == 7)
        #expect(selection.pageInChapter == 2)
        #expect(selection.locator == "ch:7:4:10")
        let parsed = try #require(EPUBTextSelection.parse(selection.locator))
        #expect(parsed.chapterIndex == 7)
    }
}
