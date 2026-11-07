//  ComicMirageBridge.swift
//  AsterismaV2.5
//
//  2.6 — manga, manhua, manhwa, webtoon, and comic analysis for Mirage.
//
//  Mirage's engine is deliberately EPUB-only at the wire level: `import_epub`
//  reads XHTML spine documents and refuses anything else. A comic is a stack
//  of page images, so this bridge does the only honest thing that needs no
//  engine or protocol change:
//
//      comic pages → on-device Vision OCR → deterministic temporary EPUB
//      → the existing `import_epub` action
//
//  The derived EPUB is an ANALYSIS ARTIFACT, not a library book. It lives in
//  Mirage's own directory, is never imported into RT's library, and is keyed
//  by the comic's source digest. The bridge is byte-deterministic — the same
//  pages and the same recognized text always produce the same EPUB digest, so
//  re-analysis reuses the engine's stored edition (`reused: true`) instead of
//  duplicating work.
//
//  Cancellation is cooperative between page batches; nothing is written until
//  a complete edition exists.

import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Vision
import ZIPFoundation

// MARK: - Edition

nonisolated struct ComicMirageEdition: Sendable, Equatable {
    let url: URL
    /// sha256 of the original comic container — the identity anchor RT hashes
    /// for drift detection.
    let sourceFingerprint: String
    /// sha256 of the derived EPUB — the digest the engine derives its edition
    /// id from, and the one the import receipt is checked against.
    let editionFingerprint: String
    let pageCount: Int
    let textPageCount: Int
    let recognizedCharacters: Int
    /// True when a verified edition already existed and no OCR ran.
    let reused: Bool
}

// MARK: - Errors

nonisolated enum ComicMirageBridgeError: LocalizedError, Equatable {
    case unreadableComic(String)
    case noRecognizableText(pageCount: Int)
    case writeFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case let .unreadableComic(reason):
            return "This comic's container could not be read. \(reason)"
        case let .noRecognizableText(pageCount):
            return "Text recognition found no readable text on any of this comic's \(pageCount) pages."
        case let .writeFailed(reason):
            return "The temporary text edition could not be written. \(reason)"
        case .cancelled:
            return "Analysis preparation was canceled."
        }
    }

    /// Typed translation into the flow's outcome vocabulary. Preparation
    /// failures are their own case: claiming the source file could not be
    /// read would be false when the container opened fine and the write failed.
    var outcome: MirageImportOutcome {
        switch self {
        case .cancelled:
            return .cancelled(engineCommitted: false)
        case let .unreadableComic(reason):
            return .sourceUnavailable(reason: reason)
        case let .noRecognizableText(pageCount):
            return .notApplicableFileType(
                reason: "text recognition found no readable text on any of this comic's \(pageCount) pages, so there is nothing for Mirage to analyze")
        case let .writeFailed(reason):
            return .analysisPreparationFailed(reason: reason)
        }
    }
}

// MARK: - Bridge

nonisolated enum ComicMirageBridge {
    /// Bumped whenever OCR ordering, page XHTML, or EPUB structure changes.
    /// A cached edition from another derivation version is rebuilt, so an
    /// engine-facing change can never silently reuse stale text.
    static let derivationVersion = "comic-ocr-epub@1"

    /// Four pages in flight keeps every core busy without holding a whole
    /// volume's bitmaps in memory.
    static let maxParallelPages = 4

    /// OCR runs on a bounded thumbnail: Vision's accuracy does not improve
    /// above this for speech balloons, and multi-thousand-pixel webtoon strips
    /// would otherwise dominate the analysis time.
    static let maxOCRDimension = 2_400

    typealias TextRecognizer = @Sendable (Data) async -> [String]

    static func defaultCacheDirectory() -> URL {
        MirageSupportPaths.mirageDirectory()
            .appendingPathComponent("comic-editions", isDirectory: true)
    }

    /// Builds (or reuses) the deterministic text edition for one comic.
    ///
    /// `recognizer` is injectable so tests can pin EPUB structure and byte
    /// determinism without depending on Vision's output for synthetic images.
    static func prepareEdition(
        comicURL: URL,
        cacheDirectory: URL? = nil,
        recognizer: TextRecognizer? = nil,
        checkCancelled: @escaping @Sendable () async -> Bool = { false }
    ) async throws -> ComicMirageEdition {
        guard !(await checkCancelled()) else { throw ComicMirageBridgeError.cancelled }

        let archive: ComicArchive
        do {
            archive = try ComicArchive.open(url: comicURL)
        } catch {
            throw ComicMirageBridgeError.unreadableComic(error.localizedDescription)
        }

        let sourceFingerprint: String
        do {
            sourceFingerprint = try MirageSourceFingerprint.sha256Hex(sourceAt: comicURL)
        } catch {
            throw ComicMirageBridgeError.unreadableComic(
                "the comic file could not be read for a fingerprint")
        }

        let directory = cacheDirectory ?? defaultCacheDirectory()
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        } catch {
            throw ComicMirageBridgeError.writeFailed(error.localizedDescription)
        }

        let editionURL = directory.appendingPathComponent("\(sourceFingerprint).epub")
        let manifestURL = directory.appendingPathComponent("\(sourceFingerprint).json")

        if let cached = cachedEdition(
            editionURL: editionURL,
            manifestURL: manifestURL,
            sourceFingerprint: sourceFingerprint
        ) {
            return cached
        }

        let metadata = archive.comicMetadata()
        let title = metadata?.displayTitle
            ?? comicURL.deletingPathExtension().lastPathComponent
        let author = metadata?.author ?? "Asterisma"
        let language = normalizedLanguage(metadata?.languageISO)

        // Manga, manhua, and manhwa read right-to-left. Line order is preserved
        // by Vision's vertical sort, but balloons on the same line must be
        // consumed right-to-left so the engine's unit order matches the page.
        let readingMode = metadata?.readingMode
            ?? ComicReadingMode.suggested(for: title, fileType: archive.fileType)
        let recognize: TextRecognizer = recognizer
            ?? { data in
                await ComicTextOCR.recognize(
                    data, rightToLeft: readingMode == .rightToLeft)
            }

        var recognitions: [[String]] = Array(repeating: [], count: archive.pages.count)
        var index = 0
        while index < archive.pages.count {
            guard !(await checkCancelled()) else { throw ComicMirageBridgeError.cancelled }
            let end = min(index + maxParallelPages, archive.pages.count)
            let slice = Array(index ..< end)

            // Container reads are serialized by ComicArchive; decode the batch
            // here, then hand only encoded bytes to the parallel OCR tasks.
            let decoded: [(index: Int, data: Data)] = slice.map { pageIndex in
                let page = archive.pages[pageIndex]
                return (pageIndex, (try? archive.data(for: page)) ?? Data())
            }

            let batch = await withTaskGroup(of: (Int, [String]).self) { group in
                for (pageIndex, data) in decoded {
                    group.addTask {
                        guard !data.isEmpty else { return (pageIndex, []) }
                        let lines = await recognize(data)
                        return (pageIndex, lines)
                    }
                }
                var collected: [(Int, [String])] = []
                for await result in group { collected.append(result) }
                return collected
            }

            for (pageIndex, lines) in batch {
                recognitions[pageIndex] = normalizedLines(lines)
            }
            index = end
        }

        guard !(await checkCancelled()) else { throw ComicMirageBridgeError.cancelled }

        let textPages: [(index: Int, lines: [String])] = recognitions.enumerated().compactMap { offset, lines in
            lines.isEmpty ? nil : (index: offset, lines: lines)
        }
        guard !textPages.isEmpty else {
            throw ComicMirageBridgeError.noRecognizableText(pageCount: archive.pages.count)
        }
        let characterCount = textPages.reduce(0) { total, page in
            total + page.lines.reduce(0) { $0 + $1.count }
        }

        let buildURL = directory.appendingPathComponent(".build-\(UUID().uuidString).epub")
        do {
            try ComicEPUBBuilder.build(
                title: title,
                author: author,
                language: language,
                identifier: "urn:uuid:\(uuidString(from: sourceFingerprint))",
                textPages: textPages,
                to: buildURL)

            let editionFingerprint = try MirageSourceFingerprint.sha256Hex(fileAt: buildURL)
            let manifest = ComicEditionManifest(
                derivationVersion: derivationVersion,
                sourceFingerprint: sourceFingerprint,
                editionFingerprint: editionFingerprint,
                pageCount: archive.pages.count,
                textPageCount: textPages.count,
                recognizedCharacters: characterCount)

            try replaceItem(at: buildURL, with: editionURL)
            let manifestData = try JSONEncoder().encode(manifest)
            try manifestData.write(to: manifestURL, options: .atomic)

            return ComicMirageEdition(
                url: editionURL,
                sourceFingerprint: sourceFingerprint,
                editionFingerprint: editionFingerprint,
                pageCount: archive.pages.count,
                textPageCount: textPages.count,
                recognizedCharacters: characterCount,
                reused: false)
        } catch {
            try? FileManager.default.removeItem(at: buildURL)
            if let typed = error as? ComicMirageBridgeError { throw typed }
            throw ComicMirageBridgeError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: - Cache

    static func cachedEdition(
        editionURL: URL,
        manifestURL: URL,
        sourceFingerprint: String
    ) -> ComicMirageEdition? {
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(
                  ComicEditionManifest.self, from: manifestData),
              manifest.derivationVersion == derivationVersion,
              manifest.sourceFingerprint == sourceFingerprint,
              FileManager.default.fileExists(atPath: editionURL.path),
              let digest = try? MirageSourceFingerprint.sha256Hex(fileAt: editionURL),
              digest == manifest.editionFingerprint
        else { return nil }

        return ComicMirageEdition(
            url: editionURL,
            sourceFingerprint: sourceFingerprint,
            editionFingerprint: digest,
            pageCount: manifest.pageCount,
            textPageCount: manifest.textPageCount,
            recognizedCharacters: manifest.recognizedCharacters,
            reused: true)
    }

    // MARK: - Text normalization

    /// Whitespace-collapsed, empty-free, adjacent-duplicate-free lines. Comic
    /// lettering commonly repeats the same balloon across two OCR passes;
    /// feeding the duplicate to the engine would double-count it.
    static func normalizedLines(_ lines: [String]) -> [String] {
        var result: [String] = []
        for line in lines {
            let collapsed = line
                .replacingOccurrences(of: "\u{00AD}", with: "")
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !collapsed.isEmpty else { continue }
            for chunk in paragraphChunks(collapsed) where result.last != chunk {
                result.append(chunk)
            }
        }
        return result
    }

    /// The engine refuses any paragraph above 64 KiB, and one such paragraph
    /// refuses the whole edition. Split pathological OCR lines at word
    /// boundaries well below that cap so a single bad page cannot cost the
    /// comic its analysis.
    static func paragraphChunks(_ line: String, limit: Int = 2_000) -> [String] {
        guard line.count > limit else { return [line] }
        var chunks: [String] = []
        var current = ""

        for word in line.split(separator: " ") {
            var token = String(word)
            while token.count > limit {
                if !current.isEmpty {
                    chunks.append(current)
                    current = ""
                }
                chunks.append(String(token.prefix(limit)))
                token = String(token.dropFirst(limit))
            }
            if current.isEmpty {
                current = token
            } else if current.count + 1 + token.count <= limit {
                current += " " + token
            } else {
                chunks.append(current)
                current = token
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// A language tag the EPUB metadata can honestly declare. ComicInfo writes
    /// ISO codes ("en", "ja"); anything unrecognisable degrades to "en" rather
    /// than emitting invalid XML or a made-up tag.
    static func normalizedLanguage(_ raw: String?) -> String {
        guard let raw else { return "en" }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = trimmed.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first.map(String.init) ?? trimmed
        guard (2 ... 3).contains(base.count), base.allSatisfy(\.isLetter) else {
            return "en"
        }
        return base
    }

    private static func uuidString(from fingerprint: String) -> String {
        let hex = String(fingerprint.prefix(32)).uppercased()
        guard hex.count == 32 else { return UUID().uuidString }
        let parts = [
            hex.prefix(8),
            hex.dropFirst(8).prefix(4),
            hex.dropFirst(12).prefix(4),
            hex.dropFirst(16).prefix(4),
            hex.dropFirst(20).prefix(12),
        ]
        return parts.map(String.init).joined(separator: "-")
    }

    private static func replaceItem(at source: URL, with destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: source, to: destination)
    }
}

// MARK: - Cache manifest

nonisolated private struct ComicEditionManifest: Codable, Sendable {
    let derivationVersion: String
    let sourceFingerprint: String
    let editionFingerprint: String
    let pageCount: Int
    let textPageCount: Int
    let recognizedCharacters: Int
}

// MARK: - Deterministic EPUB builder

/// Writes an EPUB 3 container whose bytes depend only on its inputs:
/// fixed entry order, fixed 1980-01-01 timestamps, fixed permissions, and a
/// stored (never recompressed) `mimetype` entry. Deflate output for identical
/// input is deterministic, so two builds of the same text produce one digest.
nonisolated private enum ComicEPUBBuilder {
    /// ZIP timestamps cannot precede 1980. One fixed instant for every entry.
    private static let fixedDate = Date(timeIntervalSince1970: 315_532_800)

    static func build(
        title: String,
        author: String,
        language: String,
        identifier: String,
        textPages: [(index: Int, lines: [String])],
        to url: URL
    ) throws {
        try? FileManager.default.removeItem(at: url)
        guard let archive = Archive(url: url, accessMode: .create) else {
            throw ComicMirageBridgeError.writeFailed(
                "the derived EPUB archive could not be created")
        }

        func add(_ path: String, _ text: String, compressed: Bool) throws {
            let data = Data(text.utf8)
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                modificationDate: fixedDate,
                permissions: 0o644,
                compressionMethod: compressed ? .deflate : .none
            ) { position, size in
                data.subdata(in: Int(position) ..< Int(position) + size)
            }
        }

        let pageNames = textPages.indices.map { String(format: "page-%04d.xhtml", $0 + 1) }

        try add("mimetype", "application/epub+zip", compressed: false)
        try add("META-INF/container.xml", containerXML, compressed: true)
        try add(
            "OEBPS/content.opf",
            contentOPF(
                title: title,
                author: author,
                language: language,
                identifier: identifier,
                pageNames: pageNames),
            compressed: true)
        try add(
            "OEBPS/toc.ncx",
            tocNCX(title: title, identifier: identifier, textPages: textPages, pageNames: pageNames),
            compressed: true)
        try add(
            "OEBPS/nav.xhtml",
            navXHTML(language: language, textPages: textPages, pageNames: pageNames),
            compressed: true)

        for (offset, page) in textPages.enumerated() {
            try add(
                "OEBPS/text/\(pageNames[offset])",
                pageXHTML(
                    pageNumber: page.index + 1,
                    language: language,
                    lines: page.lines),
                compressed: true)
        }
    }

    // MARK: Documents

    private static let containerXML = """
    <?xml version="1.0" encoding="utf-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """

    private static func contentOPF(
        title: String,
        author: String,
        language: String,
        identifier: String,
        pageNames: [String]
    ) -> String {
        let manifest = pageNames.enumerated().map { offset, name in
            "    <item id=\"page-\(offset + 1)\" href=\"text/\(name)\" media-type=\"application/xhtml+xml\"/>"
        }.joined(separator: "\n")
        let spine = pageNames.indices.map {
            "    <itemref idref=\"page-\($0 + 1)\"/>"
        }.joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="pub-id">\(escape(identifier))</dc:identifier>
            <dc:title>\(escape(title))</dc:title>
            <dc:creator>\(escape(author))</dc:creator>
            <dc:language>\(escape(language))</dc:language>
            <dc:source>Asterisma comic text edition</dc:source>
            <meta property="dcterms:modified">1980-01-01T00:00:00Z</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
        \(manifest)
          </manifest>
          <spine toc="ncx">
        \(spine)
          </spine>
        </package>
        """
    }

    private static func tocNCX(
        title: String,
        identifier: String,
        textPages: [(index: Int, lines: [String])],
        pageNames: [String]
    ) -> String {
        let points = textPages.enumerated().map { offset, page in
            """
                <navPoint id="page-\(offset + 1)" playOrder="\(offset + 1)">
                  <navLabel><text>Page \(page.index + 1)</text></navLabel>
                  <content src="text/\(pageNames[offset])"/>
                </navPoint>
            """
        }.joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="utf-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <head>
            <meta name="dtb:uid" content="\(escape(identifier))"/>
            <meta name="dtb:depth" content="1"/>
          </head>
          <docTitle><text>\(escape(title))</text></docTitle>
          <navMap>
        \(points)
          </navMap>
        </ncx>
        """
    }

    private static func navXHTML(
        language: String,
        textPages: [(index: Int, lines: [String])],
        pageNames: [String]
    ) -> String {
        let items = textPages.enumerated().map { offset, page in
            "        <li><a href=\"text/\(pageNames[offset])\">Page \(page.index + 1)</a></li>"
        }.joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="\(escape(language))" lang="\(escape(language))">
        <head><title>Contents</title></head>
        <body>
          <nav epub:type="toc">
            <h1>Contents</h1>
            <ol>
        \(items)
            </ol>
          </nav>
        </body>
        </html>
        """
    }

    private static func pageXHTML(pageNumber: Int, language: String, lines: [String]) -> String {
        let paragraphs = lines.map { "  <p>\(escape($0))</p>" }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="\(escape(language))" lang="\(escape(language))">
        <head><title>Page \(pageNumber)</title></head>
        <body>
        \(paragraphs)
        </body>
        </html>
        """
    }

    // MARK: XML text

    /// Escapes XML text and drops code points XML 1.0 cannot carry. OCR can
    /// emit control characters from damaged scans; one of them would make the
    /// whole page document unparseable and cost the engine that page's text.
    private static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default:
                if scalar.value < 0x20, scalar != "\n", scalar != "\t" { continue }
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}

// MARK: - Vision OCR

nonisolated enum ComicTextOCR {
    /// On-device text recognition for one encoded page image. Returns lines in
    /// reading order (top-to-bottom, then left-to-right). Never throws: an
    /// unreadable page contributes no text rather than failing the volume, and
    /// the bridge refuses only when EVERY page is unreadable.
    static func recognize(_ data: Data, rightToLeft: Bool = false) async -> [String] {
        await Task.detached(priority: .userInitiated) { () -> [String] in
            autoreleasepool {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let full = CGImageSourceCreateImageAtIndex(source, 0, nil)
                else { return [] }

                // A webtoon episode is one very tall strip. Downscaling it whole
                // to the OCR budget would shrink speech balloons below Vision's
                // readable size, so tall strips are recognized in overlapping
                // tiles at native resolution instead.
                if full.height > ComicMirageBridge.maxOCRDimension * 2 {
                    return recognizeTiles(full, rightToLeft: rightToLeft)
                }

                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: ComicMirageBridge.maxOCRDimension,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ]
                let image = CGImageSourceCreateThumbnailAtIndex(
                    source, 0, options as CFDictionary) ?? full
                return recognizeLines(in: image, rightToLeft: rightToLeft)
            }
        }.value
    }

    /// Slices a tall strip into top-to-bottom tiles with a small overlap. The
    /// overlap catches dialogue split across a boundary; adjacent-duplicate
    /// normalization in the bridge removes the repeated line.
    private static func recognizeTiles(_ image: CGImage, rightToLeft: Bool) -> [String] {
        let tileHeight = ComicMirageBridge.maxOCRDimension
        let overlap = 120
        var lines: [String] = []
        var originY = 0

        while originY < image.height {
            let height = min(tileHeight, image.height - originY)
            let rect = CGRect(x: 0, y: originY, width: image.width, height: height)
            if let tile = image.cropping(to: rect) {
                lines.append(contentsOf: recognizeLines(in: tile, rightToLeft: rightToLeft))
            }
            if originY + height >= image.height { break }
            originY += tileHeight - overlap
        }
        return lines
    }

    private static func recognizeLines(in image: CGImage, rightToLeft: Bool) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Comic lettering is not prose; language correction invents words
        // across balloon breaks.
        request.usesLanguageCorrection = false
        if #available(macOS 13.0, *) {
            request.automaticallyDetectsLanguage = true
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return [] }

        let observations = request.results ?? []
        return observations
            .sorted { lhs, rhs in
                let delta = lhs.boundingBox.maxY - rhs.boundingBox.maxY
                if abs(delta) > 0.02 { return delta > 0 }
                return rightToLeft
                    ? lhs.boundingBox.minX > rhs.boundingBox.minX
                    : lhs.boundingBox.minX < rhs.boundingBox.minX
            }
            .compactMap { $0.topCandidates(1).first?.string }
    }
}
