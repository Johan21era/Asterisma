//  ContentAnalysis.swift
//  AsterismaV2.0
//
//  E7 — the content-side analysis types, split out of BookImporter so a
//  read-only audit driver can link the same code the app ships. Nothing here
//  knows about PDFKit, SwiftUI, or the library store.

import Foundation

// MARK: - DifficultyAnalyzer

enum DifficultyAnalyzer {
    static func analyze(text: String) -> ReadingDifficultyProfile {
        guard !text.isEmpty else { return .baseline }

        let words = text.split { $0.isWhitespace }.map(String.init)
        let sentences = text.components(separatedBy: .init(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let wordCount = max(1, words.count)
        let sentenceCount = max(1, sentences.count)

        let avgWordLen = Double(words.reduce(0) { $0 + $1.count }) / Double(wordCount)
        let avgSentenceLen = Double(wordCount) / Double(sentenceCount)

        let rareCount = words.filter { $0.count > 8 }.count
        let rareLexiconRatio = Double(rareCount) / Double(wordCount)

        let syllables = words.reduce(0) { $0 + approximateSyllables($1) }
        let avgSyllables = Double(syllables) / Double(wordCount)
        let gradeLevel = 0.39 * avgSentenceLen + 11.8 * avgSyllables - 15.59

        return ReadingDifficultyProfile(
            gradeLevel: max(0, gradeLevel),
            averageWordLength: avgWordLen,
            averageSentenceLength: avgSentenceLen,
            rareLexiconRatio: rareLexiconRatio
        )
    }

    private static func approximateSyllables(_ word: String) -> Int {
        let lower = word.lowercased().filter { $0.isLetter }
        guard !lower.isEmpty else { return 1 }
        let vowels = CharacterSet(charactersIn: "aeiouy")
        var count = 0
        var prevWasVowel = false
        for char in lower.unicodeScalars {
            let isVowel = vowels.contains(char)
            if isVowel && !prevWasVowel {
                count += 1
            }
            prevWasVowel = isVowel
        }
        if lower.hasSuffix("e") && count > 1 {
            count -= 1
        }
        return max(1, count)
    }
}

// MARK: - PageEstimationModel

/// E7 — one canonical content unit for every importer.
///
/// `importEPUB` previously divided the word count by a bare 250 and ignored the
/// difficulty profile it had just computed, while `importPDF` used raw page
/// count with no word estimate at all. That made a 300-page EPUB and a
/// 300-page PDF incomparable quantities. This model is the single conversion
/// both paths use, and it is no longer dead code.
///
/// E8 separates length from difficulty. Difficulty is stored as metadata and
/// drives the label; it is not a page-length multiplier. The old conversion
/// multiplied words by `difficultyMultiplier` before dividing by 250, so the
/// same text could acquire pages it could not physically have.
enum PageEstimationModel {
    /// Words per page at ordinary prose density.
    static let wordsPerPage: Double = 250

    /// Canonical conversion from a whole-book word count.
    static func estimatePages(wordCount: Int) -> (pages: Int, confidence: Double) {
        let words = max(0, wordCount)
        let pages = max(1, Int((Double(words) / wordsPerPage).rounded(.up)))
        let confidence = min(1.0, Double(words) / 20_000.0)
        return (pages, confidence)
    }

    /// Sample-text entry point, kept for callers that only have an excerpt.
    /// Delegates to the same conversion so two page estimators cannot drift.
    static func estimatePages(from text: String) -> (pages: Int, confidence: Double) {
        estimatePages(wordCount: text.split { $0.isWhitespace }.count)
    }
}
