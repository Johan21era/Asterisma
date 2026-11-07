//  SessionHistoryView.swift
//  AsterismaV2.5
//  Displays all completed reading sessions grouped by book, with the
//  AudioContextProfile captured during each session shown inline.
//
//  This is the only view that exposes AudioFactor, AudioCategory, and
//  AudioContextProfile data to the user — those models are fully wired
//  in SessionCoordinator but were previously invisible.
//
//  Data accessed (no engines called, read from DataStore directly):
//    - DataStore.books               (all books and their sessions)
//    - DataStore.audioContextProfile(for:)   (per-session audio profile)
//    - AudioContextProfile.primaryCategory   (AudioCategory with .displayName)
//    - AudioContextProfile.listeningIntensity
//    - AudioContextProfile.tracksHeard
//    - AudioContextProfile.wasAudioPresent
//

import SwiftUI

struct SessionHistoryView: View {
    @EnvironmentObject private var dataStore: DataStore
    @Environment(\.dismiss) private var dismiss

    /// Sort options
    @State private var sortNewestFirst = true

    /// Total sessions across all books
    private var totalSessionCount: Int {
        dataStore.books.flatMap(\.sessions).filter { $0.endTime != nil }.count
    }

    var body: some View {
        NavigationStack {
            Group {
                if totalSessionCount == 0 {
                    emptyState
                } else {
                    sessionList
                }
            }
            .navigationTitle("Session History")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        sortNewestFirst.toggle()
                    } label: {
                        Label(
                            sortNewestFirst ? "Oldest First" : "Newest First",
                            systemImage: sortNewestFirst ? "arrow.up.circle" : "arrow.down.circle"
                        )
                    }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 600)
    }

    // MARK: - Session List

    private var sessionList: some View {
        List {
            ForEach(booksWithSessions) { book in
                let completedSessions = completedSessions(for: book)
                    .sorted { sortNewestFirst ? $0.startTime > $1.startTime : $0.startTime < $1.startTime }

                Section {
                    ForEach(completedSessions) { session in
                        SessionHistoryRow(
                            session: session,
                            audioProfile: dataStore.audioContextProfile(for: session.id)
                        )
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    }
                } header: {
                    HStack {
                        Text(book.title)
                            .font(.headline)
                        Spacer()
                        Text("\(completedSessions.count) sessions")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView(
            "No Sessions Yet",
            systemImage: "clock.arrow.circlepath",
            description: Text("Completed reading sessions will appear here with their audio environment context.")
        )
    }

    // MARK: - Helpers

    private var booksWithSessions: [Book] {
        dataStore.books
            .filter { !completedSessions(for: $0).isEmpty }
            .sorted { $0.dateAdded > $1.dateAdded }
    }

    private func completedSessions(for book: Book) -> [ReadingSession] {
        book.sessions.filter { $0.endTime != nil }
    }
}

// MARK: - SessionHistoryRow

private struct SessionHistoryRow: View {
    let session: ReadingSession
    let audioProfile: AudioContextProfile?

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Summary row ────────────────────────────────────────────────
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    // Date
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sessionDate)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(sessionTime)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .frame(width: 72, alignment: .leading)

                    Divider().frame(height: 28)

                    // Pages
                    Label("\(session.pagesRead) pg", systemImage: "book.pages")
                        .font(.subheadline)
                        .labelStyle(.titleAndIcon)

                    // Duration
                    Label(formatDuration(session.duration), systemImage: "clock")
                        .font(.subheadline)
                        .labelStyle(.titleAndIcon)

                    Spacer()

                    // Audio pill
                    if let profile = audioProfile {
                        AudioPill(profile: profile)
                    }

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)

            // ── Expanded audio detail ──────────────────────────────────────
            if isExpanded, let profile = audioProfile {
                Divider().padding(.vertical, 8)
                AudioDetailView(profile: profile)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Date formatting

    private var sessionDate: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: session.startTime)
    }

    private var sessionTime: String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: session.startTime)
    }
}

// MARK: - AudioPill

private struct AudioPill: View {
    let profile: AudioContextProfile

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: audioSymbol)
                .font(.caption2)
            Text(profile.primaryCategory.displayName)
                .font(.caption2)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(audioColor.opacity(0.12))
        .foregroundColor(audioColor)
        .clipShape(Capsule())
    }

    private var audioSymbol: String {
        switch profile.primaryCategory {
        case .silence: return "speaker.slash"
        case .music: return "music.note"
        case .podcast: return "mic"
        case .audioBook: return "book"
        case .spokenWord: return "bubble.left"
        case .videoAudio: return "play.rectangle"
        case .ambientSoundscape: return "cloud"
        case .unknown: return "waveform"
        }
    }

    private var audioColor: Color {
        switch profile.primaryCategory {
        case .silence: return .secondary
        case .music: return .purple
        case .podcast: return .orange
        case .audioBook: return .brown
        case .spokenWord: return .teal
        case .videoAudio: return .blue
        case .ambientSoundscape: return .green
        case .unknown: return .secondary
        }
    }
}

// MARK: - AudioDetailView

private struct AudioDetailView: View {
    let profile: AudioContextProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Listening intensity bar
            HStack(spacing: 8) {
                Text("Audio presence")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 100, alignment: .leading)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.15))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.purple.opacity(0.7))
                            .frame(width: geo.size.width * CGFloat(profile.listeningIntensity))
                    }
                }
                .frame(height: 6)

                Text(String(format: "%.0f%%", profile.listeningIntensity * 100))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: 32, alignment: .trailing)
            }

            // Category distribution (top 3)
            let topCategories = profile.categoryDistribution
                .sorted { $0.value > $1.value }
                .prefix(3)
                .filter { $0.value > 0.02 }

            if topCategories.count > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mix")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack(spacing: 6) {
                        ForEach(topCategories, id: \.key) { cat, frac in
                            Text("\(cat.displayName) \(Int(frac * 100))%")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.1))
                                .clipShape(Capsule())
                        }
                    }
                }
            }

            // Tracks heard
            if !profile.tracksHeard.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tracks heard")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(profile.tracksHeard.prefix(3).joined(separator: " · "))
                        .font(.caption)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                }
            }

            // Artists heard
            if !profile.artistsHeard.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "music.mic")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(profile.artistsHeard.prefix(3).joined(separator: ", "))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.top, 4)
    }
}

// MARK: - Preview

#Preview {
    SessionHistoryView()
        .environmentObject(DataStore())
}
