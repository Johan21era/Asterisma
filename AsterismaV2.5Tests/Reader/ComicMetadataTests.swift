//  ComicMetadataTests.swift
//  AsterismaV2.5
//
//  2.6 — ComicInfo.xml parsing and import wiring. The parser is a metadata
//  enhancer only: these pins prove both that it maps the standard fields and
//  that a missing or malformed file can never block a readable comic.

import AppKit
import Foundation
import Testing
import ZIPFoundation

@testable import AsterismaV2_5

@Suite("ComicInfo metadata")
struct ComicMetadataTests {
    private static let pixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII="
    )!

    private func makeRoot() throws -> URL {
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

    private func makeCBZ(at url: URL, pageNames: [String], comicInfo: String?) throws {
        guard let zip = Archive(url: url, accessMode: .create) else {
            Issue.record("Could not create the CBZ fixture")
            return
        }
        for name in pageNames {
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
        if let comicInfo {
            let data = Data(comicInfo.utf8)
            try zip.addEntry(
                with: "ComicInfo.xml",
                type: .file,
                uncompressedSize: Int64(data.count),
                compressionMethod: .deflate
            ) { position, size in
                data.subdata(in: Int(position) ..< Int(position) + size)
            }
        }
    }

    // MARK: - Parser

    @Test func parsesTheStandardFields() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <ComicInfo>
          <Title>The Long Night</Title>
          <Series>Nightfall</Series>
          <Number>3</Number>
          <Volume>2</Volume>
          <Writer>A. Writer</Writer>
          <Penciller>P. Artist</Penciller>
          <Publisher>Ink House</Publisher>
          <Summary>A city without dawn.</Summary>
          <Genre>Fantasy, Adventure</Genre>
          <LanguageISO>ja</LanguageISO>
          <Manga>YesAndRightToLeft</Manga>
          <PageCount>12</PageCount>
          <Pages>
            <Page Image="4" Type="FrontCover"/>
          </Pages>
        </ComicInfo>
        """
        let metadata = try #require(ComicMetadata.parse(data: Data(xml.utf8)))

        #expect(metadata.title == "The Long Night")
        #expect(metadata.series == "Nightfall")
        #expect(metadata.number == "3")
        #expect(metadata.volume == 2)
        #expect(metadata.author == "A. Writer")
        #expect(metadata.publisher == "Ink House")
        #expect(metadata.summary == "A city without dawn.")
        #expect(metadata.subjects == ["Fantasy", "Adventure"])
        #expect(metadata.languageISO == "ja")
        #expect(metadata.pageCount == 12)
        #expect(metadata.coverPageIndex == 4)
        #expect(metadata.displayTitle == "The Long Night")
        #expect(metadata.seriesLabel == "Nightfall #3")
        #expect(metadata.readingMode == .rightToLeft)
    }

    @Test func composesASeriesTitleWhenTitleIsAbsent() throws {
        let xml = """
        <ComicInfo>
          <Series>Nightfall</Series>
          <Number>7.5</Number>
          <Manga>No</Manga>
        </ComicInfo>
        """
        let metadata = try #require(ComicMetadata.parse(data: Data(xml.utf8)))
        #expect(metadata.displayTitle == "Nightfall #7.5")
        #expect(metadata.seriesLabel == "Nightfall #7.5")
        #expect(metadata.readingMode == .leftToRight)
    }

    @Test func unknownMangaValueCarriesNoDirectionClaim() throws {
        let xml = "<ComicInfo><Series>X</Series><Manga>Unknown</Manga></ComicInfo>"
        let metadata = try #require(ComicMetadata.parse(data: Data(xml.utf8)))
        #expect(metadata.readingMode == nil)
    }

    @Test func malformedOrEmptyDocumentsAreMetadataMisses() {
        #expect(ComicMetadata.parse(data: Data()) == nil)
        #expect(ComicMetadata.parse(data: Data("<ComicInfo><Title>oops".utf8)) == nil)
        #expect(ComicMetadata.parse(data: Data("<ComicInfo></ComicInfo>".utf8)) == nil)
    }

    // MARK: - Import wiring

    @Test func cbzImportUsesComicInfoMetadata() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let cbz = root.appendingPathComponent("fallback-name.cbz")
        let comicInfo = """
        <ComicInfo>
          <Title>The Long Night</Title>
          <Series>Nightfall</Series>
          <Number>3</Number>
          <Writer>A. Writer</Writer>
          <Genre>Fantasy, Adventure</Genre>
          <Summary>A city without dawn.</Summary>
          <Manga>YesAndRightToLeft</Manga>
          <Pages><Page Image="1" Type="FrontCover"/></Pages>
        </ComicInfo>
        """
        try makeCBZ(
            at: cbz,
            pageNames: ["001.png", "002.png", "003.png"],
            comicInfo: comicInfo)

        let book = try await BookImporter.importBook(from: cbz)

        #expect(book.title == "The Long Night")
        #expect(book.author == "A. Writer")
        #expect(book.series == "Nightfall")
        #expect(book.genre == .fantasy)
        #expect(book.totalPages == 3)
        #expect(book.resolvedComicReadingMode == .rightToLeft)
        #expect(book.comicInfo?.summary == "A city without dawn.")
        #expect(book.comicInfo?.coverPageIndex == 1)
    }

    @Test func folderImportReadsComicInfoAtTheRoot() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = root.appendingPathComponent("Webtoon", isDirectory: true)
        try writePage(folder.appendingPathComponent("Episode 1/001.png"))
        try writePage(folder.appendingPathComponent("Episode 1/002.png"))
        try writePage(folder.appendingPathComponent("Episode 2/001.png"))
        let comicInfo = """
        <ComicInfo>
          <Series>Moonlit</Series>
          <Number>12</Number>
          <Writer>Web Author</Writer>
        </ComicInfo>
        """
        try Data(comicInfo.utf8).write(to: folder.appendingPathComponent("comicinfo.xml"))

        let book = try await BookImporter.importBook(from: folder)

        #expect(book.title == "Moonlit #12")
        #expect(book.author == "Web Author")
        #expect(book.fileType == .comic)
        #expect(book.chapters.map(\.title) == ["Episode 1", "Episode 2"])
        // The folder default stays vertical: ComicInfo states no direction.
        #expect(book.resolvedComicReadingMode == .vertical)
    }

    @Test func malformedComicInfoNeverBlocksImport() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let cbz = root.appendingPathComponent("Unlabelled Manga.cbz")
        try makeCBZ(
            at: cbz,
            pageNames: ["001.png", "002.png"],
            comicInfo: "<ComicInfo><Title>unterminated")

        let book = try await BookImporter.importBook(from: cbz)

        #expect(book.title == "Unlabelled Manga")
        #expect(book.author == "Unknown")
        #expect(book.comicInfo == nil)
        #expect(book.totalPages == 2)
    }
}
