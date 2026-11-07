//  BookCoverSupport.swift
//  AsterismaV2.0
//
//  P5 / Feature 3 (Reader 2.0): cover-art support.
//
//  WHY THIS EXISTS
//  `Book.coverImageData` has existed on the model since v1 and
//  `BookCoverCardView` exists in the spatial cluster — but NO importer ever
//  wrote cover data and no live view ever rendered it, so every library in
//  the app displayed as bare text rows. This file provides the decode half;
//  BookImporter now provides the capture half (PDF first-page thumbnail,
//  EPUB OPF-declared cover image).
//
//  Kept as a separate file so the Core model stays AppKit-free and this
//  presentation concern stays swappable.

import AppKit
import Foundation
import SwiftUI

extension Book {
    /// Decoded cover image. FINAL TRACES Upgrade #2: external file store
    /// first (post-migration covers live on disk, not in the payload);
    /// embedded data remains as legacy fallback.
    var coverImage: NSImage? {
        if let image = CoverStore.active.image(forBookID: id) {
            return image
        }
        guard let data = coverImageData else { return nil }
        return NSImage(data: data)
    }

    /// True when a cover exists anywhere (file store or embedded).
    var hasCoverArt: Bool {
        CoverStore.active.hasCover(forBookID: id) || coverImageData != nil
    }
}

/// Small rounded cover thumbnail used in list rows and panes.
struct BookCoverThumbnail: View {
    let book: Book
    var width: CGFloat = 34
    var height: CGFloat = 48

    var body: some View {
        Group {
            if let image = book.coverImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.15)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: book.fileType.coverSymbolName)
                        .font(.system(size: height * 0.32))
                        .foregroundColor(.accentColor.opacity(0.8))
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
    }
}
