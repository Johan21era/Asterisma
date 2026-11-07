//  RSVPTokenizer.swift
//  AsterismaV2.5
//
//  P5 / Feature 3 (Reader 2.0) — RSVP mode, Part 1: pure logic.
//  Built from rsvp-speed-reading-feature-plan.md §6 build-order doctrine:
//  tokenizer + ORP calculator are UI-free and unit-testable first.

import Foundation
import NaturalLanguage

enum RSVPTokenizer {
    /// Locale-aware word tokenization via NaturalLanguage.
    static func words(from text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var tokens: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex ..< text.endIndex) { range, _ in
            tokens.append(String(text[range]))
            return true
        }
        return tokens
    }
}

enum ORPCalculator {
    /// Optimal Recognition Point: the pivot letter sits deeper into longer
    /// words (Spritz-style heuristic), so every word can be pinned to one
    /// fixed x-position on screen regardless of length.
    static func pivotIndex(for word: String) -> Int {
        switch word.count {
        case 0...1: return 0
        case 2...5: return 1
        case 6...9: return 2
        case 10...13: return 3
        default: return 4
        }
    }
}
