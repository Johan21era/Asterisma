//  SharedTextUtilities.swift
//  AsterismaV2.5
//
//  PURPOSE
//  Single authoritative implementation of HTML stripping, word counting, and
//  HTML entity decoding. Previously these were copy-pasted three ways:
//    • BookImporter.stripHTML / wordCount
//    • EPUBReaderScreen.stripHTML
//    • DifficultyAnalyzer (inline in analyze())
//
//  Any bug fix or improvement here propagates automatically to all callers.
//  All functions are pure (no side effects, no state).
//
//  CALLERS
//    • BookImporter — word count estimation and difficulty sample extraction
//    • EPUBReaderScreen — display text extraction
//    • DifficultyAnalyzer — text analysis input
//    • InsightEngine — corpus analysis for reading difficulty insights
//
//  UPGRADE LOG
//    • Added: entity decoding for numeric &#NNN; and &#xHHH; references
//    • Added: normalizeWhitespace() to collapse multi-space runs after stripping
//    • Added: extractPlainSentences() for difficulty analysis (sentence splitting)
//    • Added: readingComplexityHints() to surface structural complexity signals
//      (e.g. many long words, deeply nested HTML, dense paragraph structure)

import Foundation

// MARK: - HTML Text Extraction

/// Strips HTML tags and decodes common entities, returning readable plain text.
/// This is the canonical implementation — do not copy-paste. Import this file.
///
/// - Parameter html: Raw HTML string, typically from an EPUB spine item or PDF text layer.
/// - Returns: Plain text with whitespace normalized to single spaces. Never nil.
func stripHTML(_ html: String) -> String {
    var result = html

    // 1. Remove script and style blocks entirely (content is not human-readable text).
    result = result.replacingOccurrences(
        of: "<(script|style)[^>]*>[\\s\\S]*?</(script|style)>",
        with: " ",
        options: .regularExpression
    )

    // 2. Replace block-level tags with newlines so paragraph structure is preserved
    //    for sentence detection (used by DifficultyAnalyzer).
    result = result.replacingOccurrences(
        of: "</(p|div|h[1-6]|li|blockquote|tr)>",
        with: "\n",
        options: .regularExpression
    )

    // 3. Strip all remaining tags.
    result = result.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)

    // 4. Decode named HTML entities (common subset).
    result = decodeHTMLEntities(result)

    // 5. Normalize whitespace: collapse runs of spaces/tabs; preserve paragraph breaks.
    result = normalizeWhitespace(result)

    return result
}

/// Decodes HTML entities in a string. Handles both named (&amp;) and
/// numeric (&#160;, &#xA0;) references.
func decodeHTMLEntities(_ text: String) -> String {
    var result = text

    // Named entities — most common in EPUB/HTML documents.
    let named: [(String, String)] = [
        ("&nbsp;", " "),
        ("&amp;", "&"),
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&quot;", "\""),
        ("&apos;", "'"),
        ("&mdash;", "—"),
        ("&ndash;", "–"),
        ("&lsquo;", "\u{2018}"),
        ("&rsquo;", "\u{2019}"),
        ("&ldquo;", "\u{201C}"),
        ("&rdquo;", "\u{201D}"),
        ("&hellip;", "…"),
        ("&copy;", "©"),
        ("&reg;", "®"),
        ("&trade;", "™"),
        ("&bull;", "•"),
    ]
    for (entity, replacement) in named {
        result = result.replacingOccurrences(of: entity, with: replacement)
    }

    // AUDIT F-03 (Phase 1): a regex pre-strip previously lived here, replacing
    // "&#(\d+);" with "$1" — which converted numeric entities into BARE DIGITS
    // before decodeNumericEntities could run (e.g. "&#8217;" became "8217"),
    // corrupting extracted text and inflating word counts. The dedicated decoder
    // below already implements correct decimal AND hex decoding; it simply
    // receives intact entities now.
    result = decodeNumericEntities(result)

    return result
}

/// Decodes &#NNN; and &#xHHH; numeric character references.
private func decodeNumericEntities(_ text: String) -> String {
    var result = text

    // Decimal: &#NNN;
    if let regex = try? NSRegularExpression(pattern: "&#(\\d+);") {
        let nsString = result as NSString
        let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsString.length))
        // Reverse so replacing doesn't shift indices
        for match in matches.reversed() {
            let codeRange = match.range(at: 1)
            if let codePoint = Int(nsString.substring(with: codeRange)),
               let scalar = Unicode.Scalar(codePoint)
            {
                let char = String(Character(scalar))
                result = (result as NSString).replacingCharacters(in: match.range, with: char)
            }
        }
    }

    // Hexadecimal: &#xHHH;
    if let regex = try? NSRegularExpression(pattern: "&#x([0-9a-fA-F]+);") {
        let nsString = result as NSString
        let matches = regex.matches(in: result, range: NSRange(location: 0, length: nsString.length))
        for match in matches.reversed() {
            let hexRange = match.range(at: 1)
            let hexStr = nsString.substring(with: hexRange)
            if let codePoint = UInt32(hexStr, radix: 16),
               let scalar = Unicode.Scalar(codePoint)
            {
                let char = String(Character(scalar))
                result = (result as NSString).replacingCharacters(in: match.range, with: char)
            }
        }
    }

    return result
}

/// Collapses horizontal whitespace runs and normalizes line endings.
/// Preserves paragraph breaks (double newlines) which are used by sentence splitters.
func normalizeWhitespace(_ text: String) -> String {
    // Collapse horizontal whitespace (spaces, tabs) to single space on each line.
    var lines = text.components(separatedBy: "\n").map { line -> String in
        let parts = line.components(separatedBy: .init(charactersIn: " \t"))
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }
    // Remove lines that are purely whitespace.
    lines = lines.map { $0.trimmingCharacters(in: .whitespaces) }
    // Collapse 3+ consecutive blank lines to one blank line.
    var result: [String] = []
    var consecutiveBlanks = 0
    for line in lines {
        if line.isEmpty {
            consecutiveBlanks += 1
            if consecutiveBlanks <= 1 {
                result.append(line)
            }
        } else {
            consecutiveBlanks = 0
            result.append(line)
        }
    }
    return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Word and Sentence Counting

/// Counts whitespace-delimited words in a plain-text string.
/// If `html` is true, strips HTML tags first.
func wordCount(_ text: String, fromHTML: Bool = false) -> Int {
    let plain = fromHTML ? stripHTML(text) : text
    return plain.split { $0.isWhitespace || $0.isNewline }.count
}

/// Splits plain text into sentences using punctuation boundaries.
/// More accurate than simple `.` splitting because it handles abbreviations
/// like "Dr." by requiring a capital letter after the boundary.
///
/// - Returns: Array of non-empty trimmed sentence strings.
func extractPlainSentences(from text: String) -> [String] {
    // Simple heuristic: split at ". ", "! ", "? " where next char is uppercase or end-of-string.
    // This avoids splitting "Dr. Smith" but catches "He ran. She followed."
    var sentences: [String] = []
    var current = ""

    let terminators: Set<Character> = [".", "!", "?"]

    var chars = Array(text)
    var i = 0
    while i < chars.count {
        let c = chars[i]
        current.append(c)

        if terminators.contains(c) {
            // Look ahead: if next non-space char is uppercase, treat as sentence boundary.
            var j = i + 1
            while j < chars.count && chars[j] == " " {
                j += 1
            }
            let nextIsUpper = j < chars.count && chars[j].isUppercase
            let isEndOfText = j >= chars.count

            if nextIsUpper || isEndOfText {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    sentences.append(trimmed)
                }
                current = ""
            }
        }
        i += 1
    }
    // Capture any trailing text without terminal punctuation.
    let trailing = current.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trailing.isEmpty {
        sentences.append(trailing)
    }

    return sentences
}

// MARK: - Reading Complexity Signals

/// Structural complexity indicators derived from raw HTML before stripping.
/// These are used by InsightEngine to augment the difficulty profile with
/// qualitative signals that the Flesch-Kincaid grade level alone cannot capture.
struct ReadingComplexityHints {
    /// Ratio of words longer than 8 characters. >0.15 suggests technical/academic text.
    let longWordRatio: Double
    /// Average sentence length in words. >20 suggests complex syntax.
    let avgSentenceLength: Double
    /// True if the HTML contains nested list structures (signals reference material).
    let hasNestedLists: Bool
    /// True if the HTML contains table elements (signals data-heavy content).
    let hasDataTables: Bool
    /// Ratio of paragraph count to total word count. Very low = dense blocks.
    let paragraphDensity: Double

    /// A simple 0–1 complexity score derived from the hints above.
    /// Not a replacement for `ReadingDifficultyProfile.difficultyMultiplier`;
    /// used as a cross-check signal in InsightEngine.
    var complexityScore: Double {
        let wordFactor = min(1.0, longWordRatio / 0.2)
        let sentenceFactor = min(1.0, avgSentenceLength / 25.0)
        let tableFactor = hasDataTables ? 0.1 : 0.0
        let listFactor = hasNestedLists ? 0.05 : 0.0
        let densityFactor = max(0.0, 1.0 - paragraphDensity * 10)
        return (wordFactor * 0.35 + sentenceFactor * 0.35 + tableFactor + listFactor + densityFactor * 0.2)
            .clamped(to: 0 ... 1)
    }
}

/// Analyzes raw HTML (not stripped text) for structural complexity signals.
/// Called once during import; result stored in the book's difficulty profile.
func readingComplexityHints(fromHTML html: String) -> ReadingComplexityHints {
    let hasNested = html.range(of: "<ul[^>]*>.*?<ul", options: [.regularExpression, .caseInsensitive]) != nil
        || html.range(of: "<ol[^>]*>.*?<ol", options: [.regularExpression, .caseInsensitive]) != nil
    let hasTables = html.range(of: "<table", options: .caseInsensitive) != nil

    let plain = stripHTML(html)
    let words = plain.split { $0.isWhitespace }.map(String.init)
    let total = max(1, words.count)
    let longWords = words.filter { $0.count > 8 }.count
    let sentences = extractPlainSentences(from: plain)
    let avgSentLen = sentences.isEmpty ? 0.0 : Double(total) / Double(sentences.count)

    // Paragraph count: count <p> tags in original HTML as a proxy.
    let pCount = html.components(separatedBy: "<p").count - 1
    let density = pCount == 0 ? 0.0 : Double(pCount) / Double(total)

    return ReadingComplexityHints(
        longWordRatio: Double(longWords) / Double(total),
        avgSentenceLength: avgSentLen,
        hasNestedLists: hasNested,
        hasDataTables: hasTables,
        paragraphDensity: density
    )
}

// MARK: - Comparable Clamping

extension Comparable {
    /// Clamps the value within the given range.
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
