//  BookDiscoveryView.swift
//  AsterismaV2.5
//
//  LIVE-TEST LT-1 REDESIGN: the previous presentation embedded a hidden
//  left-edge drawer inside a nearly transparent sheet — no title bar, no close
//  control, no visible search field until you found a floating tab. Users were
//  trapped ("bricks the entire app"). This is now a proper modal surface:
//  prominent centered search, real results list, detail on selection, and an
//  always-present close affordance with Escape support.
//

import SwiftUI

struct BookDiscoveryView: View {
    @Environment(\.dismiss) private var dismiss

    @StateObject private var viewModel = BookDiscoveryViewModel()
    @State private var selectedBook: OnlineBook?

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            searchBar
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

            if let error = viewModel.errorMessage, !viewModel.isOffline {
                bannerLabel(error, systemImage: "exclamationmark.triangle", color: .red)
            }

            resultsArea
        }
        .frame(minWidth: 680, minHeight: 600)
        .sheet(item: $selectedBook) { book in
            OnlineBookDetailView(book: book)
                .frame(minWidth: 560, minHeight: 500)
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "books.vertical.fill")
                .font(.title3)
                .foregroundStyle(.tint)
            Text("Discover Books")
                .font(.title3.weight(.semibold))
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.secondary)
                    .background(Circle().fill(.regularMaterial))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Close (Esc)")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search titles or authors…", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .submitLabel(.search)
            if viewModel.isLoading {
                ProgressView()
                    .scaleEffect(0.8)
            } else if !viewModel.query.isEmpty {
                Button {
                    viewModel.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
        )
        .cornerRadius(10)
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsArea: some View {
        if viewModel.isOffline {
            emptyState(
                icon: "wifi.slash",
                title: "Online discovery is offline",
                subtitle: "Your library, goals, insights, and readers work fully without a connection. Search will resume when the network returns."
            )
        } else if viewModel.query.trimmingCharacters(in: .whitespaces).isEmpty {
            emptyState(
                icon: "magnifyingglass",
                title: "Search the world's books",
                subtitle: "Type a title, author, or topic above — results come from Open Library and Project Gutenberg."
            )
        } else if viewModel.isLoading && viewModel.results.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("Searching…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.results.isEmpty {
            emptyState(
                icon: "questionmark.folder",
                title: "No results",
                subtitle: "Try different keywords — fewer words often works better."
            )
        } else {
            List(viewModel.results) { book in
                Button {
                    selectedBook = book
                } label: {
                    OnlineBookRow(book: book)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)
        }
    }

    // MARK: - Helpers

    private func bannerLabel(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
    }

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    BookDiscoveryView()
}
