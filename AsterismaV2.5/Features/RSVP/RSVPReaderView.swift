//  RSVPReaderView.swift
//  AsterismaV2.5
//
//  P5 / Feature 3 — RSVP Part 3: reader UI.
//
//  Full-screen overlay: the pivot-pinned word at center, scrub bar, WPM
//  control, and macOS-native controls (Space = play/pause, ←/→ = step,
//  ↑/↓ = speed, Esc = exit). Standalone by design — no imports from any
//  other feature cluster.

import SwiftUI

struct RSVPReaderView: View {
    /// Text to stream. Callers own sourcing it (reader text, pasted excerpt).
    let text: String
    let onClose: () -> Void

    @StateObject private var engine = RSVPPlaybackEngine()
    @State private var wpm: Double = 300

    var body: some View {
        VStack(spacing: 28) {
            header

            Spacer()

            RSVPPivotWordView(word: engine.currentWord, pivotIndex: engine.pivotIndex)
                .frame(height: 120)

            ProgressView(value: engine.progress)
                .progressViewStyle(.linear)
                .frame(maxWidth: 520)

            controls

            Spacer()

            footerHint
        }
        .padding(32)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .onAppear {
            engine.load(text)
            engine.wpm = wpm
        }
        .onChange(of: wpm) { _, newValue in
            engine.wpm = newValue
        }
        .onExitCommand { close() } // Esc
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Label("Speed Read", systemImage: "hare")
                .font(.headline)
            Spacer()
            Text("\(engine.wordCount) words")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Done") { close() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private var controls: some View {
        VStack(spacing: 16) {
            HStack(spacing: 24) {
                Button {
                    engine.stepBy(-1)
                } label: {
                    Image(systemName: "backward.frame")
                }
                .keyboardShortcut(.leftArrow, modifiers: [])

                Button {
                    engine.toggle()
                } label: {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 56, height: 36)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.space, modifiers: [])

                Button {
                    engine.stepBy(1)
                } label: {
                    Image(systemName: "forward.frame")
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
            }
            .buttonStyle(.bordered)

            HStack {
                Slider(
                    value: Binding(
                        get: { wpm },
                        set: { wpm = $0 }
                    ),
                    in: 150 ... 800,
                    step: 25
                ) {
                    Text("Speed")
                } onEditingChanged: { editing in
                    if !editing {
                        // Scrubbing the WPM bar ends with a seek so the current
                        // word re-renders at the new pace immediately.
                        engine.seek(toFraction: engine.progress)
                    }
                }
                .frame(maxWidth: 320)
                .keyboardShortcut(.upArrow, modifiers: []) // focus affordance; value via arrows handled natively when focused

                Text("\(Int(wpm)) WPM")
                    .monospacedDigit()
                    .font(.callout.weight(.semibold))
                    .frame(width: 80, alignment: .leading)
            }

            // Position scrubber
            Slider(
                value: Binding(
                    get: { engine.progress },
                    set: { engine.seek(toFraction: $0) }
                ),
                in: 0 ... 1
            )
            .frame(maxWidth: 520)
        }
    }

    private var footerHint: some View {
        Text("Space = play/pause · ← → = word · Esc = exit · long words and sentence ends pause slightly longer for comprehension")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }

    private func close() {
        engine.pause()
        onClose()
    }
}

// MARK: - Pivot Word Renderer

/// Splits the word at its ORP index; prefix right-aligned into a fixed-width
/// slot, pivot letter highlighted, suffix left-aligned into a matching slot —
/// the pivot therefore lands at the same x-position for every word.
struct RSVPPivotWordView: View {
    let word: String
    let pivotIndex: Int

    private var characters: [Character] { Array(word) }
    private var prefix: String { String(characters.prefix(pivotIndex)) }
    private var pivot: String {
        guard characters.indices.contains(pivotIndex) else { return "" }
        return String(characters[pivotIndex])
    }
    private var suffix: String {
        let start = pivotIndex + 1
        guard start < characters.count else { return "" }
        return String(characters[start...])
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(prefix)
                .frame(width: 110, alignment: .trailing)
            Text(pivot)
                .foregroundStyle(.red)
                .fontWeight(.bold)
            Text(suffix)
                .frame(width: 110, alignment: .leading)
        }
        .font(.system(size: 40, weight: .medium, design: .rounded))
        .contentTransition(.numericText())
        .animation(.default, value: word)
    }
}
