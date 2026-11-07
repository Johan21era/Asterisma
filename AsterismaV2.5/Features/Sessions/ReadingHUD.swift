//  ReadingHUD.swift
//  AsterismaV2.5
//
//  P5 / Feature 3 (Reader 2.0): live reading HUD.
//
//  SessionCoordinator already publishes everything a reader wants to see
//  mid-session — activeBookID, currentPage, elapsedTime — but nothing
//  rendered any of it until you left the book. This compact panel floats in
//  the main window's upper-left corner while a session is active:
//    • book title + cover
//    • live elapsed time (updates every second off the existing timer)
//    • page position (currentPage / totalPages)
//    • one-click "End Session"
//
//  Positioned top-left deliberately: the bottom edge hosts the persistence
//  warning banner (D1), and the achievement toast owns top-center — this
//  placement collides with neither. Reads ONLY existing published state;
//  introduces zero new sources of truth. Hidden whenever no session is active.

import SwiftUI

struct ReadingHUD: View {
    @EnvironmentObject private var coordinator: SessionCoordinator
    @EnvironmentObject private var dataStore: DataStore

    private var activeBook: Book? {
        coordinator.activeBookID.flatMap { dataStore.book(id: $0) }
    }

    var body: some View {
        if coordinator.isReading, let book = activeBook {
            HStack(spacing: 10) {
                BookCoverThumbnail(book: book, width: 30, height: 42)

                VStack(alignment: .leading, spacing: 2) {
                    Text(book.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Label(formatElapsed(coordinator.elapsedTime), systemImage: "clock")
                        Text("·")
                        if coordinator.positionLabel.isEmpty {
                            Label("\(coordinator.currentPage + 1)/\(max(book.totalPages, 1))", systemImage: "book.pages")
                        } else {
                            Label(coordinator.positionLabel, systemImage: "book.pages")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }

                Divider()
                    .frame(height: 22)

                Button {
                    coordinator.endCurrentSession()
                } label: {
                    Image(systemName: "stop.circle")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .help("End reading session")
            }
            .padding(.horizontal, DesignGrid.cardPaddingH)
            .padding(.vertical, DesignGrid.cardPaddingV)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignGrid.cardCornerRadius))
            // UI REVIEW §5 (Medium #5): accent stroke removed — the material
            // + shadow alone separate it; fewer boundaries, quieter chrome.
            .shadow(color: .black.opacity(0.14), radius: 6, y: 3)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
