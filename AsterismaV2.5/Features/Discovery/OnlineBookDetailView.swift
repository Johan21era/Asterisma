//  OnlineBookDetailView.swift
//  Online Book Discovery System
//

import SwiftUI

struct OnlineBookDetailView: View {
    let book: OnlineBook

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let coverURL = book.coverURL {
                    AsyncImage(url: coverURL) { phase in
                        switch phase {
                        case .empty:
                            ProgressView()
                                .frame(height: 220)

                        case let .success(image):
                            image
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 260)

                        case .failure:
                            placeholder

                        @unknown default:
                            placeholder
                        }
                    }
                } else {
                    placeholder
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(book.title)
                        .font(.title2)
                        .bold()

                    Text(book.author)
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    HStack {
                        Text(book.sourceLabel)
                        Text("•")
                        Text(book.availabilityLabel)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if let description = book.description {
                        Text(description)
                            .font(.body)
                            .padding(.top, 8)
                    } else {
                        Text("No description available.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)
            }
            .padding()
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(Color.gray.opacity(0.2))
            .frame(height: 220)
            .overlay(
                Image(systemName: "book")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            )
    }
}

// MARK: - Helpers

private extension OnlineBook {
    var sourceLabel: String {
        switch source {
        case .openLibrary: return "Open Library"
        case .gutenberg: return "Gutenberg"
        case .worldCat: return "WorldCat"
        }
    }

    var availabilityLabel: String {
        switch availability {
        case .free: return "Free"
        case .referenceOnly: return "Reference Only"
        case .unknown: return "Unknown"
        }
    }
}
