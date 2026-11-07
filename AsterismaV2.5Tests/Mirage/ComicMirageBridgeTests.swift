//  ComicMirageBridgeTests.swift
//  AsterismaV2.5
//
//  2.6 — the deterministic comic→EPUB path that lets Mirage analyze manga,
//  manhua, manhwa, webtoons, and comics without an engine protocol change.
//  Vision is injected so these pins test structure, caching, determinism, and
//  failure typing rather than OCR accuracy on synthetic images.

import AppKit
import Foundation
import Testing
import ZIPFoundation

@testable import AsterismaV2_5

@Suite("Comic Mirage Bridge")
struct ComicMirageBridgeTests {
    // MARK: - Fixtures

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func renderPNG(width: Int, height: Int, color: NSColor) throws -> Data {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            throw CocoaError(.fileWriteUnknown)
        }
        NSGraphicsContext.current = context
        color.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    private func makeCBZ(
        at url: URL,
        pages: [(name: String, data: Data)],
        comicInfo: String?
    ) throws {
        guard let zip = Archive(url: url, accessMode: .create) else {
            Issue.record("Could not create the CBZ fixture")
            return
        }
        var entries = pages
        if let comicInfo {
            entries.append(("ComicInfo.xml", Data(comicInfo.utf8)))
        }
        for entry in entries {
            try zip.addEntry(
                with: entry.name,
                type: .file,
                uncompressedSize: Int64(entry.data.count),
                compressionMethod: .deflate
            ) { position, size in
                entry.data.subdata(in: Int(position) ..< Int(position) + size)
            }
        }
    }

    private func readEntry(_ archive: Archive, _ path: String) throws -> String {
        let entry = try #require(archive[path])
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Structure + determinism

    @Test func buildsADeterministicEditionWithOnlyTextPages() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let pages = [
            (name: "001.png", data: try renderPNG(width: 4, height: 4, color: .red)),
            (name: "002.png", data: try renderPNG(width: 5, height: 4, color: .green)),
            (name: "003.png", data: try renderPNG(width: 6, height: 4, color: .blue)),
        ]
        let textByPage: [Data: [String]] = [
            pages[0].data: ["Page one text"],
            pages[2].data: ["Page three & <special>"],
        ]
        let recognizer: ComicMirageBridge.TextRecognizer = { data in
            textByPage[data] ?? []
        }
        let comicInfo = """
        <ComicInfo><Title>Silent Volume</Title><Writer>Comic Author</Writer>
        <LanguageISO>ja</LanguageISO></ComicInfo>
        """
        let cbz = root.appendingPathComponent("Silent Volume.cbz")
        try makeCBZ(at: cbz, pages: pages, comicInfo: comicInfo)

        let cache = root.appendingPathComponent("cache-a", isDirectory: true)
        let edition = try await ComicMirageBridge.prepareEdition(
            comicURL: cbz,
            cacheDirectory: cache,
            recognizer: recognizer)

        #expect(edition.pageCount == 3)
        #expect(edition.textPageCount == 2)
        #expect(!edition.reused)
        #expect(edition.sourceFingerprint == (try MirageSourceFingerprint.sha256Hex(fileAt: cbz)))
        #expect(edition.recognizedCharacters == "Page one text".count + "Page three & <special>".count)

        let archive = try #require(Archive(url: edition.url, accessMode: .read))
        let names = Set(archive.map(\.path))
        #expect(names.contains("mimetype"))
        #expect(names.contains("META-INF/container.xml"))
        #expect(names.contains("OEBPS/content.opf"))
        #expect(names.contains("OEBPS/nav.xhtml"))
        #expect(names.contains("OEBPS/toc.ncx"))
        #expect(names.contains("OEBPS/text/page-0001.xhtml"))
        #expect(names.contains("OEBPS/text/page-0002.xhtml"))
        #expect(!names.contains("OEBPS/text/page-0003.xhtml"))

        let mimetype = try readEntry(archive, "mimetype")
        #expect(mimetype == "application/epub+zip")

        let opf = try readEntry(archive, "OEBPS/content.opf")
        #expect(opf.contains("<dc:title>Silent Volume</dc:title>"))
        #expect(opf.contains("<dc:creator>Comic Author</dc:creator>"))
        #expect(opf.contains("<dc:language>ja</dc:language>"))

        let pageTwo = try readEntry(archive, "OEBPS/text/page-0002.xhtml")
        #expect(pageTwo.contains("<p>Page three &amp; &lt;special&gt;</p>"))
        #expect(pageTwo.contains("<title>Page 3</title>"))

        // A second build from the same pages and text must be byte-identical.
        let cacheB = root.appendingPathComponent("cache-b", isDirectory: true)
        let rebuilt = try await ComicMirageBridge.prepareEdition(
            comicURL: cbz,
            cacheDirectory: cacheB,
            recognizer: recognizer)
        #expect(rebuilt.editionFingerprint == edition.editionFingerprint)
        #expect(rebuilt.sourceFingerprint == edition.sourceFingerprint)
    }

    @Test func verifiedCacheIsReusedWithoutRunningOCR() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let page = try renderPNG(width: 4, height: 4, color: .orange)
        let cbz = root.appendingPathComponent("Cached.cbz")
        try makeCBZ(at: cbz, pages: [("001.png", page)], comicInfo: nil)

        let cache = root.appendingPathComponent("cache", isDirectory: true)
        let first = try await ComicMirageBridge.prepareEdition(
            comicURL: cbz,
            cacheDirectory: cache,
            recognizer: { _ in ["only page"] })
        #expect(!first.reused)

        let second = try await ComicMirageBridge.prepareEdition(
            comicURL: cbz,
            cacheDirectory: cache,
            recognizer: { _ in
                Issue.record("OCR ran for a verified cached edition")
                return []
            })

        #expect(second.reused)
        #expect(second.editionFingerprint == first.editionFingerprint)
        #expect(second.textPageCount == 1)
    }

    @Test func aCorruptCacheEntryIsRebuilt() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let page = try renderPNG(width: 4, height: 4, color: .purple)
        let cbz = root.appendingPathComponent("Rebuild.cbz")
        try makeCBZ(at: cbz, pages: [("001.png", page)], comicInfo: nil)

        let cache = root.appendingPathComponent("cache", isDirectory: true)
        let first = try await ComicMirageBridge.prepareEdition(
            comicURL: cbz,
            cacheDirectory: cache,
            recognizer: { _ in ["original text"] })

        // Rewriting the edition must invalidate the manifest's digest.
        try Data("tampered".utf8).write(to: first.url)

        let rebuilt = try await ComicMirageBridge.prepareEdition(
            comicURL: cbz,
            cacheDirectory: cache,
            recognizer: { _ in ["original text"] })

        #expect(!rebuilt.reused)
        #expect(rebuilt.editionFingerprint == first.editionFingerprint)
    }

    // MARK: - Failure typing

    @Test func aComicWithoutAnyRecognizedTextIsTyped() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let page = try renderPNG(width: 4, height: 4, color: .gray)
        let cbz = root.appendingPathComponent("Wordless.cbz")
        try makeCBZ(at: cbz, pages: [("001.png", page), ("002.png", page)], comicInfo: nil)

        do {
            _ = try await ComicMirageBridge.prepareEdition(
                comicURL: cbz,
                cacheDirectory: root.appendingPathComponent("cache"),
                recognizer: { _ in [] })
            Issue.record("A wordless comic produced an edition")
        } catch let error as ComicMirageBridgeError {
            #expect(error == .noRecognizableText(pageCount: 2))
            #expect(error.outcome == .notApplicableFileType(
                reason: "text recognition found no readable text on any of this comic's 2 pages, so there is nothing for Mirage to analyze"))
        }
    }

    @Test func cancellationIsCooperativeAndWritesNothing() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let page = try renderPNG(width: 4, height: 4, color: .brown)
        let cbz = root.appendingPathComponent("Cancelled.cbz")
        try makeCBZ(at: cbz, pages: [("001.png", page)], comicInfo: nil)
        let cache = root.appendingPathComponent("cache", isDirectory: true)

        do {
            _ = try await ComicMirageBridge.prepareEdition(
                comicURL: cbz,
                cacheDirectory: cache,
                recognizer: { _ in ["text"] },
                checkCancelled: { true })
            Issue.record("A cancelled preparation completed")
        } catch let error as ComicMirageBridgeError {
            #expect(error == .cancelled)
        }

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: cache, includingPropertiesForKeys: nil)) ?? []
        #expect(contents.isEmpty)
    }

    // MARK: - Normalization

    @Test func normalizationCollapsesAndDeduplicates() {
        #expect(ComicMirageBridge.normalizedLines(
            ["  hello   world ", "", "hello world", "goodbye"]
        ) == ["hello world", "goodbye"])
        #expect(ComicMirageBridge.normalizedLanguage("ja") == "ja")
        #expect(ComicMirageBridge.normalizedLanguage("en-US") == "en")
        #expect(ComicMirageBridge.normalizedLanguage(nil) == "en")
        #expect(ComicMirageBridge.normalizedLanguage("not a language") == "en")

        // A pathological OCR line is split below the engine's paragraph cap.
        let longLine = Array(repeating: "word", count: 900).joined(separator: " ")
        let split = ComicMirageBridge.normalizedLines([longLine])
        #expect(split.count > 1)
        #expect(split.allSatisfy { $0.count <= 2_000 })
    }
}
