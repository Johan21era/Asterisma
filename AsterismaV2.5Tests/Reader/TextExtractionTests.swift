//  TextExtractionTests.swift
//  AsterismaV2.5Tests
//
//  Phase 1 regression battery — pins AUDIT F-03.
//
//  Defect being pinned: a regex pre-strip inside decodeHTMLEntities converted
//  numeric character references to bare digits before the real decoder ran
//  ("&#8217;" → "8217" instead of "'"), corrupting reader display text and
//  inflating word counts across EPUB/PDF extraction, DifficultyAnalyzer, and
//  InsightEngine corpus analysis. These fixtures prove true decoding end-to-end
//  through the public canonical API.

import Foundation
import Testing

@testable import AsterismaV2_5

@Suite("Text Extraction — F-03 regression pins")
struct TextExtractionTests {

    // MARK: - Numeric entities decode to their true characters

    @Test("F-03: decimal numeric entity decodes to its code point")
    func decimalEntityDecodes() {
        #expect(decodeHTMLEntities("&#8217;") == "\u{2019}")   // right single quote
        #expect(decodeHTMLEntities("&#160;") == "\u{00A0}")    // non-breaking space
        #expect(decodeHTMLEntities("&#8212;") == "\u{2014}")   // em dash
    }

    @Test("F-03: hexadecimal numeric entity decodes to its code point")
    func hexEntityDecodes() {
        #expect(decodeHTMLEntities("&#x2014;") == "\u{2014}")
        #expect(decodeHTMLEntities("&#xA0;") == "\u{00A0}")
    }

    @Test("F-03: the pre-fix corruption signature can never reappear")
    func bareDigitCorruptionIsImpossible() {
        // Pre-fix, these produced literal digit runs. They must now be characters.
        let out = decodeHTMLEntities("word&#8217;s&#160;joint&#x2014;line")
        #expect(out == "word\u{2019}s\u{00A0}joint\u{2014}line")
        #expect(!out.contains("8217"))
        #expect(!out.contains("8212"))
    }

    @Test("F-03: named entities still decode (no regression on existing path)")
    func namedEntitiesStillDecode() {
        #expect(decodeHTMLEntities("&amp;&lt;&quot;") == "&<\"")
        #expect(decodeHTMLEntities("&mdash;") == "\u{2014}")
    }

    // MARK: - End-to-end through stripHTML

    @Test("F-03: stripHTML preserves decoded entities through tag stripping")
    func stripHTMLPreservesEntities() {
        let html = "<p>It&#8217;s a test&nbsp;&#8212; done.</p>"
        let plain = stripHTML(html)
        #expect(plain.contains("It\u{2019}s"))
        #expect(plain.contains("\u{2014}"))
        #expect(!plain.contains("&#"))
    }

    // MARK: - Word-count integrity

    @Test("F-03: word counts no longer inflated by entity digit-runs")
    func wordCountNotInflated() {
        // Pre-fix: "65" and "66" counted as two bogus words.
        let text = "&#65;&#66;"
        #expect(wordCount(text) == 1) // decodes to "AB" — a single token
    }

    @Test("F-03: malformed entity is left as inert text (documented behavior)")
    func malformedEntityStaysInert() {
        // Out-of-range scalar → decoder skips replacement; raw reference remains.
        // The contract is "never crash, never fabricate characters."
        let out = decodeHTMLEntities("&#999999999999;")
        #expect(out.contains("999999999999")) // untouched, not corrupted into something else
    }
}
