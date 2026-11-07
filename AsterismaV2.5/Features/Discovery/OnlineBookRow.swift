//  OnlineBookRow.swift
//  Online Book Discovery System
//

import SwiftUI

struct OnlineBookRow: View {
    let book: OnlineBook

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: 6
        ) {
            Text(book.title)
                .font(.headline)
                .lineLimit(2)

            Text(book.author)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(spacing: 8) {
                Text(sourceLabel)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Color.secondary.opacity(0.15)
                    )
                    .clipShape(Capsule())

                Text(availabilityLabel)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        availabilityColor.opacity(0.15)
                    )
                    .foregroundStyle(
                        availabilityColor
                    )
                    .clipShape(Capsule())
            }
        }
        .frame(
            maxWidth: .infinity,
            alignment: .leading
        )
        .padding(.vertical, 6)
    }
}

// MARK: - Labels

private extension OnlineBookRow {
    var sourceLabel: String {
        switch book.source {
        case .openLibrary:
            return "Open Library"

        case .gutenberg:
            return "Gutenberg"

        case .worldCat:
            return "WorldCat"
        }
    }

    var availabilityLabel: String {
        switch book.availability {
        case .free:
            return "Free"

        case .referenceOnly:
            return "Reference Only"

        case .unknown:
            return "Unknown"
        }
    }

    var availabilityColor: Color {
        switch book.availability {
        case .free:
            return .green

        case .referenceOnly:
            return .orange

        case .unknown:
            return .secondary
        }
    }
}

#Preview {
    List {
        OnlineBookRow(
            book: OnlineBook(
                id: "1",
                title: "The Great Gatsby",
                author: "F. Scott Fitzgerald",
                description: nil,
                isbn: nil,
                coverURL: nil,
                source: .openLibrary,
                availability: .referenceOnly
            )
        )

        OnlineBookRow(
            book: OnlineBook(
                id: "2",
                title: "Pride and Prejudice",
                author: "Jane Austen",
                description: nil,
                isbn: nil,
                coverURL: nil,
                source: .gutenberg,
                availability: .free
            )
        )
    }
    .frame(width: 420, height: 300)
}
