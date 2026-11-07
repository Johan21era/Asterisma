//  ComicImportTests.swift
//  AsterismaV2.0
//
//  2.5 — end-to-end importer pins for the two supported comic containers.
//  These go through the same `importBook(from:)` entry point the open panel
//  uses, so directory routing and extension routing are exercised together.

import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
import ZIPFoundation

@testable import AsterismaV2_0

@Suite("Comic import")
struct ComicImportTests {
    /// A valid 1×1 PNG. The importer only requires NSImage to decode it for
    /// the cover; page counts and types come from the archive itself.
    private static let pixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII="
    )!

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writePage(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.pixelPNG.write(to: url)
    }

    @Test("An image folder imports as a vertical comic with chapters")
    func folderImport() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = root.appendingPathComponent("Webtoon", isDirectory: true)
        try writePage(folder.appendingPathComponent("Episode 1/001.png"))
        try writePage(folder.appendingPathComponent("Episode 1/002.png"))
        try writePage(folder.appendingPathComponent("Episode 2/001.png"))

        let book = try await BookImporter.importBook(from: folder)

        #expect(book.title == "Webtoon")
        #expect(book.fileType == .comic)
        #expect(book.totalPages == 3)
        #expect(book.resolvedComicReadingMode == .vertical)
        #expect(book.chapters.map(\.title) == ["Episode 1", "Episode 2"])
        #expect(book.chapters.map(\.endPage) == [1, 2])
        #expect(book.wordCountEstimate == nil)
    }

    @Test("A CBZ imports as a paged comic with its page count")
    func cbzImport() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let cbz = root.appendingPathComponent("Manga Volume 1.cbz")
        guard let zip = Archive(url: cbz, accessMode: .create) else {
            Issue.record("Could not create the CBZ fixture")
            return
        }
        for name in ["page10.png", "page2.png", "page1.png"] {
            let data = Self.pixelPNG
            try zip.addEntry(
                with: name,
                type: .file,
                uncompressedSize: Int64(data.count),
                compressionMethod: .deflate
            ) { position, size in
                data.subdata(in: Int(position) ..< Int(position) + size)
            }
        }

        let book = try await BookImporter.importBook(from: cbz)

        #expect(book.title == "Manga Volume 1")
        #expect(book.fileType == .cbz)
        #expect(book.totalPages == 3)
        #expect(book.resolvedComicReadingMode == .rightToLeft)
        #expect(book.chapters.count == 1)
    }

    @Test("CBR is rejected with a message naming the missing decoder")
    func cbrRejected() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let cbr = root.appendingPathComponent("Old Comic.cbr")
        try Data("not a zip".utf8).write(to: cbr)

        do {
            _ = try await BookImporter.importBook(from: cbr)
            Issue.record("A CBR import unexpectedly succeeded")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("CBR"))
            #expect(message.contains("not supported"))
        }
    }

    @Test("An empty folder is rejected instead of becoming a zero-page book")
    func emptyFolderRejected() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = root.appendingPathComponent("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        do {
            _ = try await BookImporter.importBook(from: folder)
            Issue.record("An empty comic folder unexpectedly imported")
        } catch {
            #expect(error.localizedDescription.contains("no readable page images"))
        }
    }

    @Test("The open panel accepts directories and CBZ files")
    @MainActor
    func openPanelContract() {
        #expect(BookImportPanel.allowedTypes.contains { $0.preferredFilenameExtension == "cbz" })

        let panel = NSOpenPanel()
        BookImportPanel.configure(panel)
        #expect(panel.canChooseDirectories)
        #expect(panel.canChooseFiles)
        #expect(panel.allowedContentTypes.contains(.pdf))
        #expect(panel.allowedContentTypes.contains(.epub))
    }
}
