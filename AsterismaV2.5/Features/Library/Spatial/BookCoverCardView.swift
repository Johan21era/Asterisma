//  BookCoverCardView.swift
//  AsterismaV2.5
//
//  Spatial Library — Phase F (supports Part 9.2's three tiers)
//
//  The single, shared visual representation of a book as a card. All three
//  Adaptive Layout tiers use this same view and only wrap it in their own
//  positioning transforms via BookVisualState — none of them re-implement
//  cover/title/author rendering ("nothing renders its own opinion," Part 4).
//
//  VERIFIED (this session): Book.coverImageData is a real Data? property —
//  Book 2.swift:40. Used directly via NSImage(data:); falls back to a
//  deterministic gradient+icon placeholder when nil or undecodable.
//

import SwiftUI
import AppKit

struct BookCoverCardView: View {
    let book: Book
    var width: CGFloat = 120
    var height: CGFloat = 180

    var body: some View {
        VStack(spacing: 6) {
            coverArt
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 3)

            Text(book.title)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
                .frame(width: width)
            Text(book.author)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: width)
        }
    }

    @ViewBuilder
    private var coverArt: some View {
        // G1 FIX: imports write covers to CoverStore and migrateEmbeddedCovers
        // clears `coverImageData`, so reading the raw field made every spatial
        // card a permanent placeholder. `coverImage` is the store-aware accessor.
        if let nsImage = book.coverImage {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                LinearGradient(
                    colors: [placeholderColor.opacity(0.9), placeholderColor.opacity(0.5)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "book.closed")
                    .font(.system(size: min(width, height) * 0.3))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
    }

    /// A stable, deterministic color per book (from its id) so placeholder
    /// covers are visually distinguishable from one another instead of all
    /// identical — no stored "color" field needed on Book itself.
    /// `.magnitude` (not `abs()`) deliberately avoids the Int.min overflow
    /// trap `abs()` has on a hash's full range.
    private var placeholderColor: Color {
        var hasher = Hasher()
        hasher.combine(book.id)
        let magnitude = hasher.finalize().magnitude
        let hue = Double(magnitude % 360) / 360.0
        return Color(hue: hue, saturation: 0.35, brightness: 0.55)
    }
}
