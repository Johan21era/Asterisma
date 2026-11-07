//  RSVPPlaybackEngine.swift
//  AsterismaV2.5
//
//  P5 / Feature 3 — RSVP Part 2: playback engine.
//
//  ObservableObject holding WPM / position / play-state, driving a single
//  cancellable Task with per-word duration adjusted for word length and
//  trailing punctuation (short words flash, long words linger, sentence
//  ends get a beat). Pause is instant cancellation; scrubbing repositions
//  without disturbing pacing state.

import Combine
import Foundation

@MainActor
final class RSVPPlaybackEngine: ObservableObject {
    @Published private(set) var currentWord: String = ""
    @Published private(set) var pivotIndex: Int = 0
    @Published private(set) var isPlaying = false
    @Published var wpm: Double = 300

    /// Whole-text progress in [0, 1], for the scrub bar.
    @Published private(set) var progress: Double = 0

    private(set) var words: [String] = []
    private var index = 0
    private var task: Task<Void, Never>?

    var wordCount: Int { words.count }

    func load(_ text: String) {
        pause()
        words = RSVPTokenizer.words(from: text)
        index = 0
        publishCurrentWord()
    }

    func play() {
        guard !words.isEmpty, !isPlaying else { return }
        // Finished? Restarting play from the end rewinds to the beginning.
        if index >= words.count { index = 0 }

        isPlaying = true
        task = Task { [weak self] in
            guard let self else { return }
            while self.isPlaying, self.index < self.words.count {
                let word = self.words[self.index]
                self.currentWord = word
                self.pivotIndex = ORPCalculator.pivotIndex(for: word)
                try? await Task.sleep(for: .seconds(self.interval(for: word)))
                guard !Task.isCancelled else { return }
                self.index += 1
                self.progress = Double(self.index) / Double(max(1, self.words.count))
            }
            if Task.isCancelled { return }
            self.isPlaying = false
            self.progress = 1.0
        }
    }

    func pause() {
        isPlaying = false
        task?.cancel()
        task = nil
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    /// Scrub to a fraction of the text ([0, 1]) while paused or playing.
    func seek(toFraction fraction: Double) {
        guard !words.isEmpty else { return }
        let clamped = max(0, min(1, fraction))
        index = min(words.count - 1, Int(clamped * Double(words.count)))
        progress = clamped
        publishCurrentWord()
    }

    func stepBy(_ delta: Int) {
        guard !words.isEmpty else { return }
        index = max(0, min(words.count - 1, index + delta))
        progress = Double(index) / Double(max(1, words.count - 1))
        publishCurrentWord()
    }

    private func publishCurrentWord() {
        guard words.indices.contains(index) else {
            currentWord = ""
            pivotIndex = 0
            return
        }
        currentWord = words[index]
        pivotIndex = ORPCalculator.pivotIndex(for: currentWord)
    }

    /// Base interval from WPM, stretched for long words and terminal
    /// punctuation so comprehension keeps a beat where reading needs it.
    private func interval(for word: String) -> Double {
        var seconds = 60.0 / max(wpm, 60)
        if word.count > 7 { seconds *= 1.25 }
        if word.hasSuffix(",") || word.hasSuffix(";") || word.hasSuffix(":") { seconds *= 1.4 }
        if word.hasSuffix(".") || word.hasSuffix("!") || word.hasSuffix("?") { seconds *= 1.9 }
        return seconds
    }
}
