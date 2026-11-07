//  RSVPLogicTests.swift
//  AsterismaV2.5Tests
//
//  P5 Feature 3 — pins for the RSVP pure-logic layer (plan §6 step 2:
//  logic fully tested before UI wiring).
//
import Foundation
import Testing

@testable import AsterismaV2_5

@Suite("RSVP Tokenizer + ORP")
struct RSVPLogicTests {

    @Test("Tokenizer splits words, drops whitespace/punctuation-only tokens")
    func tokenizerSplitsWords() {
        let words = RSVPTokenizer.words(from: "Hello, world! It's a beautiful morning.")
        #expect(words.contains("Hello"))
        #expect(words.contains("world"))
        #expect(words.contains("It's"))
        #expect(words.contains("morning"))
        // No empty tokens from whitespace runs
        #expect(!words.contains { $0.isEmpty })
    }

    @Test("ORP pivot deepens with word length")
    func orpDeepensWithLength() {
        #expect(ORPCalculator.pivotIndex(for: "a") == 0)
        #expect(ORPCalculator.pivotIndex(for: "the") == 1)
        #expect(ORPCalculator.pivotIndex(for: "reading") == 2)
        #expect(ORPCalculator.pivotIndex(for: "understanding") == 3)
        #expect(ORPCalculator.pivotIndex(for: "incomprehensibilities") >= 4)
    }

    @Test("ORP pivot always inside the word")
    func orpAlwaysInBounds() {
        for word in ["", "x", "cat", "library", "extraordinarily long"] {
            let idx = ORPCalculator.pivotIndex(for: word)
            #expect(idx >= 0)
            #expect(idx <= max(word.count - 1, 0))
        }
    }
}

@Suite("RSVP Playback Engine")
@MainActor
final class RSVPPlaybackEngineTests {

    @Test("Load publishes first word and total count")
    func loadPublishesFirstWord() {
        let engine = RSVPPlaybackEngine()
        engine.load("The quick brown fox jumps")

        #expect(engine.wordCount == 5)
        #expect(engine.currentWord == "The")
        #expect(engine.progress == 0)
    }

    @Test("Seek repositions without playing")
    func seekRepositions() async {
        let engine = RSVPPlaybackEngine()
        engine.load("one two three four five six seven eight nine ten")

        engine.seek(toFraction: 0.5)
        #expect(engine.isPlaying == false)
        // Half of ten words → around index 5 ("six").
        let mid = engine.currentWord
        #expect(["five", "six"].contains(mid), "mid-seek landed on \(mid)")

        engine.stepBy(-3)
        #expect(engine.currentWord.count > 0)
    }

    @Test("Play advances and completes; pause halts immediately")
    func playPauseLifecycle() async throws {
        let engine = RSVPPlaybackEngine()
        engine.wpm = 60000 // absurdly fast so the run finishes near-instantly
        engine.load("alpha beta gamma delta epsilon zeta eta theta")

        engine.play()
        #expect(engine.isPlaying)

        // Wait for natural completion (bounded).
        for _ in 0 ..< 100 {
            try await Task.sleep(for: .milliseconds(20))
            if !engine.isPlaying { break }
        }
        #expect(!engine.isPlaying)
        #expect(engine.progress == 1.0)

        // Play after completion restarts from the beginning.
        engine.play()
        #expect(engine.isPlaying)
        engine.pause()
        #expect(!engine.isPlaying)
    }
}
