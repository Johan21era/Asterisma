//  ComicArchiveTests.swift
//  AsterismaV2.0
//
//  2.5 — pins the comic container contract: natural page order, junk
//  filtering, folder chapter grouping, and CBZ extraction. These are the
//  invariants the importer and both reader layouts depend on.

import AppKit
import Foundation
import Testing
import ZIPFoundation

@testable import AsterismaV2_0

@Suite("Comic archive")
struct ComicArchiveTests {
    /// A valid 1×1 PNG, used by the image-store test so decoding is real.
    private static let pixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    @Test("Folder pages sort naturally and group into chapters")
    func folderOrderAndChapters() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try write(Data("page 2".utf8), to: root.appendingPathComponent("Chapter 2/page2.png"))
        try write(Data("page 10".utf8), to: root.appendingPathComponent("Chapter 2/page10.png"))
        try write(Data("chapter 10 page 1".utf8), to: root.appendingPathComponent("Chapter 10/page1.png"))
        try write(Data("cover".utf8), to: root.appendingPathComponent("cover.png"))
        try write(Data("not a page".utf8), to: root.appendingPathComponent("Chapter 2/notes.txt"))
        try write(Data("junk".utf8), to: root.appendingPathComponent("__MACOSX/._page2.png"))
        try write(Data("hidden".utf8), to: root.appendingPathComponent(".hidden.png"))

        let archive = try ComicArchive.open(url: root)

        #expect(archive.kind == .folder)
        #expect(archive.fileType == .comic)
        #expect(archive.pages.map(\.path) == [
            "Chapter 2/page2.png",
            "Chapter 2/page10.png",
            "Chapter 10/page1.png",
            "cover.png",
        ])
        #expect(archive.pages.map(\.name) == [
            "page2.png", "page10.png", "page1.png", "cover.png",
        ])

        let chapters = ComicChapterBuilder.chapters(from: archive.pages)
        #expect(chapters.map(\.title) == ["Chapter 2", "Chapter 10", "Pages"])
        #expect(chapters.map(\.startPage) == [0, 2, 3])
        #expect(chapters.map(\.endPage) == [1, 2, 3])
    }

    @Test("A CBZ archive orders pages naturally and extracts the requested entry")
    func cbzOrderAndExtraction() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let cbzURL = root.appendingPathComponent("Manga.cbz")
        let one = Data("first page".utf8)
        let two = Data("second page".utf8)
        let ten = Data("tenth page".utf8)

        guard let zip = Archive(url: cbzURL, accessMode: .create) else {
            Issue.record("Could not create the CBZ fixture archive")
            return
        }
        for (path, data) in [
            ("p10.png", ten),
            ("p2.png", two),
            ("p1.png", one),
            ("readme.txt", Data("ignore me".utf8)),
            ("__MACOSX/._p1.png", Data("junk".utf8)),
        ] {
            try zip.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                compressionMethod: .deflate
            ) { position, size in
                data.subdata(in: Int(position) ..< Int(position) + size)
            }
        }

        let archive = try ComicArchive.open(url: cbzURL)

        #expect(archive.kind == .cbz)
        #expect(archive.fileType == .cbz)
        #expect(archive.pages.map(\.path) == ["p1.png", "p2.png", "p10.png"])
        let loadedOne = try archive.data(for: archive.pages[0])
        let loadedTwo = try archive.data(for: archive.pages[1])
        let loadedTen = try archive.data(for: archive.pages[2])
        #expect(loadedOne == one)
        #expect(loadedTwo == two)
        #expect(loadedTen == ten)

        let chapters = ComicChapterBuilder.chapters(from: archive.pages)
        #expect(chapters.count == 1)
        #expect(chapters[0].title == "Pages")
        #expect(chapters[0].startPage == 0)
        #expect(chapters[0].endPage == 2)
    }

    @Test("An image-free folder and an unsupported container are rejected")
    func emptyAndUnsupportedContainers() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let emptyFolder = root.appendingPathComponent("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyFolder, withIntermediateDirectories: true)
        #expect(throws: ComicArchiveError.self) {
            try ComicArchive.open(url: emptyFolder)
        }

        let cbr = root.appendingPathComponent("Book.cbr")
        try Data("not a zip".utf8).write(to: cbr)
        #expect(throws: ComicArchiveError.self) {
            try ComicArchive.open(url: cbr)
        }
    }

    @Test("A page decodes into the image cache through the real store path")
    func pageImageStore() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let cbzURL = root.appendingPathComponent("Pixels.cbz")
        guard let zip = Archive(url: cbzURL, accessMode: .create) else {
            Issue.record("Could not create the image cache fixture")
            return
        }
        let data = Self.pixelPNG
        try zip.addEntry(
            with: "001.png",
            type: .file,
            uncompressedSize: Int64(data.count),
            compressionMethod: .deflate
        ) { position, size in
            data.subdata(in: Int(position) ..< Int(position) + size)
        }

        let archive = try ComicArchive.open(url: cbzURL)
        let store = ComicPageImageStore()
        let page = try #require(archive.pages.first)

        let loaded = await store.loadImage(for: page, in: archive)
        #expect(loaded != nil)
        #expect(loaded?.size == NSSize(width: 1, height: 1))
        #expect(store.image(for: page.id) != nil)
    }

    @Test("Page progress clamps at both ends")
    func progressClamping() {
        #expect(ComicPagination.clamped(-3, pageCount: 10) == 0)
        #expect(ComicPagination.clamped(99, pageCount: 10) == 9)
        #expect(ComicPagination.clamped(0, pageCount: 0) == 0)
        #expect(ComicPagination.progress(index: 9, pageCount: 10) == 1.0)
        #expect(ComicPagination.progress(index: 0, pageCount: 10) == 0.1)
    }
}
