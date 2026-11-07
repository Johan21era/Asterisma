// BookImporter.swift
// Handles importing EPUB and PDF files, extracting metadata and chapter structure.
// P5 Feature 3: captures COVER ART at import (PDF first page / EPUB OPF cover).
// PATCHED: B4 — security-scoped bookmark is now computed AND stored in Book.bookmarkData
//               for both PDF and EPUB paths so file access survives app restart.
// AUDIT:
//   Task 1  — importPDF: bookmark creation wrapped in do/catch; failure is logged,
//             not silently dropped via try?. Book is still created (import succeeded).
//   Task 2  — importEPUB: same treatment as Task 1.
//   Task 21 — importBook: scope opened before switch (confirmed correct; validated).
//
// ROADMAP 3.4 (RA-002 / AUDIT F-09): the private divergent stripHTML /
// wordCount implementations are GONE. This module now delegates to the canonical
// SharedTextUtilities versions, so import-time word counts / page estimates /
// difficulty sampling use IDENTICAL entity handling to reader-time extraction
// and InsightEngine corpus analysis (numeric entities like &#8217; decode
// correctly everywhere). SharedTextUtilities' header listing BookImporter as a
// caller is now true.

import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers
#if canImport(ZIPFoundation)
    import ZIPFoundation
#endif
#if canImport(Compression)
    import Compression
#endif

// MARK: - ImportError

enum ImportError: LocalizedError {
    case unsupportedFileType(String)
    case fileNotReadable(URL)
    case notAnEPUBPackage(URL)
    case epubMissingOPF
    case epubParseFailure(String)
    case epubUnzipFailure(String)
    case pdfOpenFailure
    /// 2.5: CBZ/image-folder import failures.
    case comicArchiveFailure(String)
    case comicEmpty(URL)
    case comicUnsupportedContainer(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedFileType(ext):
            return ext.isEmpty
                ? "That item has no file extension. Choose a .pdf, .epub, or .cbz file, or an image folder."
                : "Unsupported file type: .\(ext). Choose a .pdf, .epub, or .cbz file, or an image folder."
        case let .fileNotReadable(url): return "Cannot read file at \(url.path)"
        case let .notAnEPUBPackage(url):
            return "“\(url.lastPathComponent)” is a folder, not an EPUB package. Open it and select the .epub file or package inside."
        case .epubMissingOPF: return "EPUB is missing OPF package document"
        case let .epubParseFailure(msg): return "EPUB parse error: \(msg)"
        case let .epubUnzipFailure(msg): return "Failed to unzip EPUB: \(msg)"
        case .pdfOpenFailure: return "Could not open PDF document"
        case let .comicArchiveFailure(msg): return "Could not read comic archive: \(msg)"
        case let .comicEmpty(url):
            return "“\(url.lastPathComponent)” contains no readable page images."
        case let .comicUnsupportedContainer(ext):
            return ".\(ext.uppercased()) comics are not supported. Use .cbz or an image folder — CBR, CB7, and CBT need a RAR or 7z decoder this app does not include."
        }
    }
}

// MARK: - Open panel contract

/// Restrict the file picker to actual books, iBooks-style EPUB packages, and
/// comic containers. Directories are selectable because a webcomic can be an
/// image folder; the importer distinguishes an unzipped EPUB package from an
/// image folder by its META-INF/container.xml.
enum BookImportPanel {
    static let iBooksEPUB = UTType(importedAs: "com.apple.ibooks.epub")

    static var allowedTypes: [UTType] {
        var types: [UTType] = [.pdf, .epub, iBooksEPUB]
        if let cbz = UTType(filenameExtension: "cbz") {
            types.append(cbz)
        }
        return types
    }

    static func configure(_ panel: NSOpenPanel) {
        // AppKit recomputes directory eligibility when allowedContentTypes is
        // assigned, so set the type filter first and the directory/file
        // switches last.
        panel.allowedContentTypes = allowedTypes
        panel.treatsFilePackagesAsDirectories = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.message = "Choose an EPUB, PDF, CBZ, or an image folder of comic pages."
        panel.prompt = "Import"
    }
}

/// Reuses the import panel's exact type restrictions when repairing a moved
/// book. Kept beside `BookImportPanel` so imports and relinks can never drift
/// into accepting different files.
enum BookFilePicker {
    static func chooseReplacement(for book: Book, completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        BookImportPanel.configure(panel)
        panel.message = "Choose the \(book.fileType.displayName) file for “\(book.title)”"
        panel.prompt = "Relink"
        let parent = book.fileURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: parent.path) {
            panel.directoryURL = parent
        }
        // A relink is often launched from an alert button. Let SwiftUI finish
        // dismissing that presentation before the panel tries to become key;
        // otherwise the panel can be swallowed by the closing alert.
        DispatchQueue.main.async {
            panel.begin { response in
                completion(response == .OK ? panel.url : nil)
            }
        }
    }
}

// MARK: - BookImporter

enum BookImporter {
    /// TASK 21 (validated): Security scope is opened before the switch dispatch and
    /// released via defer when importBook returns. Since importEPUB is async, the
    /// defer fires only after `await importEPUB(url:)` completes — holding the scope
    /// for the full duration of both synchronous (PDF) and asynchronous (EPUB) imports.
    static func importBook(from url: URL) async throws -> Book {
        // A URL chosen through NSOpenPanel is security-scoped. A URL supplied
        // by a test or drag/drop may not be, but is still readable in-process;
        // do not reject it before the real read/parse has a chance to report.
        let accessingScope = url.startAccessingSecurityScopedResource()
        defer {
            if accessingScope { url.stopAccessingSecurityScopedResource() }
        }

        let isDirectory = (try? url.resourceValues(
            forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        if isDirectory {
            let container = url.appendingPathComponent("META-INF/container.xml")
            if FileManager.default.fileExists(atPath: container.path) {
                return try await importEPUB(url: url)
            }
            // 2.5: any other folder is treated as an image-folder comic.
            // It must contain at least one readable page image.
            return try await importComic(url: url)
        }

        switch url.pathExtension.lowercased() {
        case "epub": return try await importEPUB(url: url)
        case "pdf": return try await importPDF(url: url)
        case "cbz": return try await importComic(url: url)
        case "cbr", "cb7", "cbt", "rar", "7z":
            throw ImportError.comicUnsupportedContainer(url.pathExtension.lowercased())
        default: throw ImportError.unsupportedFileType(url.pathExtension)
        }
    }

    // MARK: - Comic Import (2.5)

    /// Imports a CBZ archive or an image folder. Page count is the number of
    /// readable images after natural sorting; chapters are folder groupings;
    /// the cover is the first page. Everything is analyzed off-main so a large
    /// archive does not stall the library.
    static func importComic(url: URL) async throws -> Book {
        let archive: ComicArchive
        do {
            archive = try ComicArchive.open(url: url)
        } catch let error as ComicArchiveError {
            throw ImportError.comicArchiveFailure(error.localizedDescription)
        } catch {
            throw ImportError.comicArchiveFailure(error.localizedDescription)
        }

        guard !archive.pages.isEmpty else { throw ImportError.comicEmpty(url) }

        // 2.6: ComicInfo.xml is the de-facto comic metadata standard. It is a
        // metadata hint, never a gate — a malformed file leaves the filename
        // title and Unknown author exactly as they were before 2.6.
        let metadata = archive.comicMetadata()

        let fallbackTitle = archive.kind == .folder
            ? url.lastPathComponent
            : url.deletingPathExtension().lastPathComponent
        let title = metadata?.displayTitle ?? fallbackTitle
        let author = metadata?.author ?? "Unknown"

        let coverData: Data? = await Task.detached(priority: .utility) {
            let coverPage: ComicPage? = {
                if let index = metadata?.coverPageIndex,
                   let declared = archive.page(at: index)
                {
                    return declared
                }
                return archive.pages.first
            }()
            guard let coverPage,
                  let data = try? archive.data(for: coverPage)
            else { return nil }
            return BookCoverCapture.from(data: data)
        }.value

        var bookmarkData: Data?
        do {
            bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            print("[BookImporter] Warning: could not create security-scoped bookmark " +
                "for comic '\(url.lastPathComponent)': \(error). " +
                "File will not be accessible after app restart. " +
                "Check that the app has the com.apple.security.files.bookmarks.app-scope entitlement.")
        }

        let fileType: BookFileType = archive.kind == .cbz ? .cbz : .comic
        let newBook = Book(
            title: title,
            author: author,
            fileURL: url,
            fileType: fileType,
            totalPages: archive.pages.count,
            chapters: ComicChapterBuilder.chapters(from: archive.pages),
            bookmarkData: bookmarkData,
            genre: metadata.map { ReadingGenre.mapped(from: $0.subjects) } ?? .unknown,
            series: metadata?.series,
            comicReadingMode: metadata?.readingMode
                ?? ComicReadingMode.suggested(for: title, fileType: fileType),
            comicInfo: metadata
        )
        if let coverData {
            CoverStore.active.store(coverData, forBookID: newBook.id)
        }
        return newBook
    }

    // MARK: - PDF Import

    /// HOTFIX (stall report): now async so cover rasterization can run
    /// off-main. Sole caller importBook already awaits.
    static func importPDF(url: URL) async throws -> Book {
        guard let doc = PDFDocument(url: url) else { throw ImportError.pdfOpenFailure }

        let totalPages = doc.pageCount
        let title = (doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let author = (doc.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String)
            ?? "Unknown"

        var chapters: [Chapter] = []
        if let outline = doc.outlineRoot {
            chapters = extractChapters(from: outline, totalPages: totalPages)
        }

        // TASK 1 FIX: Wrap bookmark creation in do/catch so failures are logged
        // rather than silently discarded by try?.
        //
        // A nil bookmark means the book can only be opened in the same app launch
        // as the import (the sandbox URL remains valid within a session). On restart,
        // resolveURL() falls back to the raw URL, which the sandbox will reject.
        //
        // We still create the Book even if bookmark creation fails — the import
        // itself succeeded and the book is usable in the current session.
        var bookmarkData: Data?
        do {
            bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            print("[BookImporter] Warning: could not create security-scoped bookmark " +
                "for PDF '\(url.lastPathComponent)': \(error). " +
                "File will not be accessible after app restart. " +
                "Check that the app has the com.apple.security.files.bookmarks.app-scope entitlement.")
        }

        // HOTFIX (stall report): PDF page rasterization is expensive; run it on
        // a detached task instead of stalling main during import.
        let coverData = await Task.detached(priority: .utility) {
            BookCoverCapture.fromPDFDocument(doc)
        }.value

        // FINAL TRACES Upgrade #2: cover goes to the FILE STORE keyed by the
        // book's id — NOT into the library payload.
        // E7: give PDFs the same content record EPUBs get. A PDF previously had
        // no word estimate and no difficulty profile, so its estimate was pure
        // page-duration extrapolation. Sampling is bounded and off-main.
        let sample = await Task.detached(priority: .utility) {
            PDFTextSampler.sample(doc)
        }.value
        let difficulty = sample.text.isEmpty
            ? nil
            : DifficultyAnalyzer.analyze(text: sample.text)
        let estimatedWordCount = sample.pagesSampled > 0
            ? Int((Double(sample.wordCount) / Double(sample.pagesSampled))
                    * Double(totalPages))
            : 0

        let newBook = Book(
            title: title,
            author: author,
            fileURL: url,
            fileType: .pdf,
            totalPages: totalPages,
            chapters: chapters,
            difficultyProfile: difficulty,
            bookmarkData: bookmarkData,
            wordCountEstimate: max(0, estimatedWordCount)
        )
        if let coverData {
            CoverStore.active.store(coverData, forBookID: newBook.id)
        }
        return newBook
    }

    private static func extractChapters(from outline: PDFOutline, totalPages: Int) -> [Chapter] {
        var result: [Chapter] = []
        var index = 0

        func visit(_ node: PDFOutline) {
            if let dest = node.destination,
               let page = dest.page,
               let doc = page.document,
               let label = node.label, !label.isEmpty
            {
                let pageNum = doc.index(for: page)
                result.append(Chapter(title: label, index: index, startPage: pageNum, endPage: pageNum))
                index += 1
            }
            for i in 0 ..< node.numberOfChildren {
                if let child = node.child(at: i) {
                    visit(child)
                }
            }
        }
        visit(outline)

        for i in 0 ..< result.count {
            let nextStart = i + 1 < result.count ? result[i + 1].startPage - 1 : totalPages - 1
            result[i].endPage = max(result[i].startPage, nextStart)
        }
        return result
    }

    // MARK: - EPUB Import

    private static func unzipEPUB(at source: URL, to destination: URL) throws {
        #if canImport(ZIPFoundation)
            do {
                try FileManager.default.unzipItem(at: source, to: destination)
                return
            } catch { /* fall through */ }
        #endif
        do {
            guard let archive = Archive(url: source, accessMode: .read) else {
                throw ImportError.epubUnzipFailure("Cannot open archive")
            }
            for entry in archive {
                let entryURL = destination.appendingPathComponent(entry.path)
                let entryDir = entryURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: entryDir, withIntermediateDirectories: true)
                _ = try archive.extract(entry, to: entryURL)
            }
        } catch {
            throw ImportError.epubUnzipFailure(error.localizedDescription)
        }
    }

    static func importEPUB(url: URL) async throws -> Book {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // EPUBs are normally zip archives, but iBooks and some tools leave the
        // package as an unzipped directory with a .epub extension. macOS then
        // reports it as a package/directory, so the open panel must allow it
        // and the importer must parse it in place instead of trying to unzip it.
        let isDirectory = (try? url.resourceValues(
            forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let contentRoot: URL
        if isDirectory {
            contentRoot = url
        } else {
            try unzipEPUB(at: url, to: tempDir)
            contentRoot = tempDir
        }

        let containerURL = contentRoot.appendingPathComponent("META-INF/container.xml")
        let opfURL = try findOPFURL(containerURL: containerURL, baseDir: contentRoot)
        let metadata = try parseOPF(opfURL: opfURL, baseDir: contentRoot)

        let wordCount = await estimateTotalWords(spineItems: metadata.spineItems)

        let sampleText = await extractSampleText(spineItems: metadata.spineItems, maxChars: 5000)
        let difficulty = DifficultyAnalyzer.analyze(text: sampleText)

        // E7 / E8: page count is a function of words at the canonical density.
        // Difficulty is stored on the book as metadata; it is not a page-length
        // multiplier. The old conversion multiplied words by the difficulty
        // multiplier before dividing by wordsPerPage.
        let estimatedPages = PageEstimationModel.estimatePages(
            wordCount: wordCount
        ).pages
        let chapters = buildChapters(from: metadata, estimatedTotalPages: estimatedPages)

        // TASK 2 FIX: Same treatment as Task 1 — do/catch instead of try?.
        var bookmarkData: Data?
        do {
            bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            print("[BookImporter] Warning: could not create security-scoped bookmark " +
                "for EPUB '\(url.lastPathComponent)': \(error). " +
                "File will not be accessible after app restart. " +
                "Check that the app has the com.apple.security.files.bookmarks.app-scope entitlement.")
        }

        // P5 Feature 3 + HOTFIX (stall report): image decode/rasterize runs
        // off-main; importEPUB is already async so this is a free win.
        var coverData: Data?
        if let coverHref = metadata.coverHref {
            let coverURL = opfURL.deletingLastPathComponent()
                .appendingPathComponent(coverHref.removingPercentEncoding ?? coverHref)
            coverData = await Task.detached(priority: .utility) {
                BookCoverCapture.fromFile(coverURL)
            }.value
        }

        let newBook = Book(
            title: metadata.title,
            author: metadata.author,
            fileURL: url,
            fileType: .epub,
            totalPages: estimatedPages,
            chapters: chapters,
            difficultyProfile: difficulty,
            bookmarkData: bookmarkData,
            genre: ReadingGenre.mapped(from: metadata.subjects),
            wordCountEstimate: wordCount,
            series: metadata.series
        )
        // FINAL TRACES Upgrade #2: file-store the cover, keep payload lean.
        if let coverData {
            CoverStore.active.store(coverData, forBookID: newBook.id)
        }
        return newBook
    }

    // MARK: - EPUB Parsing Helpers

    private struct OPFMetadata {
        var title: String
        var author: String
        var spineItems: [(id: String, href: URL)]
        var tocEntries: [(title: String, href: String)]
        var coverHref: String? // OPF-declared cover image path (relative to OPF dir)
        var subjects: [String]
        var series: String?
    }

    private static func findOPFURL(containerURL: URL, baseDir: URL) throws -> URL {
        guard let data = try? Data(contentsOf: containerURL) else { throw ImportError.epubMissingOPF }
        let xml = try XMLDocument(data: data, options: [])
        guard let opfPath = try xml.nodes(forXPath: "//@full-path").first?.stringValue else {
            throw ImportError.epubMissingOPF
        }
        return baseDir.appendingPathComponent(opfPath)
    }

    private static func parseOPF(opfURL: URL, baseDir _: URL) throws -> OPFMetadata {
        guard let data = try? Data(contentsOf: opfURL) else {
            throw ImportError.epubParseFailure("Cannot read OPF at \(opfURL.path)")
        }

        let xml: XMLDocument
        do { xml = try XMLDocument(data: data, options: []) } catch {
            throw ImportError.epubParseFailure(error.localizedDescription)
        }

        let opfDir = opfURL.deletingLastPathComponent()
        let title = (try? xml.nodes(forXPath: "//*[local-name()='title']").first?.stringValue) ?? "Unknown Title"
        let creator = (try? xml.nodes(forXPath: "//*[local-name()='creator']").first?.stringValue) ?? "Unknown Author"
        let subjects = (try? xml.nodes(forXPath: "//*[local-name()='subject']"))?
            .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        let series = (try? xml.nodes(
            forXPath: "//*[local-name()='meta'][@property='belongs-to-collection']"
        ).first?.stringValue)
            ?? (try? xml.nodes(
                forXPath: "//*[local-name()='meta'][@name='calibre:series']/@content"
            ).first?.stringValue)

        var manifest: [String: URL] = [:]
        if let items = try? xml.nodes(forXPath: "//*[local-name()='item']") {
            for item in items {
                guard let el = item as? XMLElement,
                      let id = el.attribute(forName: "id")?.stringValue,
                      let href = el.attribute(forName: "href")?.stringValue else { continue }
                let decoded = href.removingPercentEncoding ?? href
                manifest[id] = opfDir.appendingPathComponent(decoded)
            }
        }

        var spineItems: [(id: String, href: URL)] = []
        if let refs = try? xml.nodes(forXPath: "//*[local-name()='itemref']/@idref") {
            for ref in refs {
                guard let idref = ref.stringValue, let href = manifest[idref] else { continue }
                spineItems.append((id: idref, href: href))
            }
        }

        var tocEntries: [(title: String, href: String)] = []
        if let ncxID = (try? xml.nodes(forXPath: "//*[local-name()='spine']/@toc").first?.stringValue),
           let ncxURL = manifest[ncxID]
        {
            tocEntries = parseTOCncx(ncxURL: ncxURL)
        }

        // P5 Feature 3: resolve the declared cover — EPUB3 uses
        // <item properties="cover-image">; older EPUB2 uses <meta name="cover">
        // pointing at a manifest id.
        var coverHref: String?
        if let items = try? xml.nodes(forXPath: "//*[local-name()='item']") {
            for item in items {
                guard let el = item as? XMLElement else { continue }
                let props = el.attribute(forName: "properties")?.stringValue ?? ""
                let id = el.attribute(forName: "id")?.stringValue ?? ""
                let href = el.attribute(forName: "href")?.stringValue
                if props.contains("cover-image"), let href {
                    coverHref = href
                    break
                }
                if id.lowercased() == "cover-image", let href {
                    coverHref = href
                    break
                }
            }
        }
        if coverHref == nil,
           let coverMetaID = (try? xml.nodes(
               forXPath: "//*[local-name()='meta'][@name='cover']/@content"
           ).first?.stringValue),
           let manifestItems = try? xml.nodes(forXPath: "//*[local-name()='item']")
        {
            for item in manifestItems {
                guard let el = item as? XMLElement,
                      el.attribute(forName: "id")?.stringValue == coverMetaID,
                      let href = el.attribute(forName: "href")?.stringValue else { continue }
                coverHref = href
                break
            }
        }

        return OPFMetadata(title: title, author: creator,
                           spineItems: spineItems, tocEntries: tocEntries,
                           coverHref: coverHref,
                           subjects: subjects,
                           series: series)
    }

    private static func parseTOCncx(ncxURL: URL) -> [(title: String, href: String)] {
        guard let data = try? Data(contentsOf: ncxURL),
              let xml = try? XMLDocument(data: data, options: []) else { return [] }

        var entries: [(title: String, href: String)] = []
        if let points = try? xml.nodes(forXPath: "//*[local-name()='navPoint']") {
            for point in points {
                guard let el = point as? XMLElement else { continue }
                let label = (try? el.nodes(forXPath: ".//*[local-name()='text']").first?.stringValue) ?? "Chapter"
                let href = (try? el.nodes(forXPath: ".//*[local-name()='content']/@src").first?.stringValue) ?? ""
                entries.append((title: label, href: href))
            }
        }
        return entries
    }

    private static func buildChapters(from meta: OPFMetadata, estimatedTotalPages: Int) -> [Chapter] {
        let spineCount = max(1, meta.spineItems.count)
        let pagesPerSpineItem = max(1, estimatedTotalPages / spineCount)

        if !meta.tocEntries.isEmpty {
            return meta.tocEntries.enumerated().map { idx, entry in
                let startPage = idx * pagesPerSpineItem
                let endPage = idx + 1 < meta.tocEntries.count
                    ? (idx + 1) * pagesPerSpineItem - 1
                    : estimatedTotalPages - 1
                return Chapter(title: entry.title, index: idx, startPage: startPage, endPage: endPage)
            }
        } else {
            return meta.spineItems.enumerated().map { idx, _ in
                let startPage = idx * pagesPerSpineItem
                let endPage = idx + 1 < meta.spineItems.count
                    ? (idx + 1) * pagesPerSpineItem - 1
                    : estimatedTotalPages - 1
                return Chapter(title: "Chapter \(idx + 1)", index: idx, startPage: startPage, endPage: endPage)
            }
        }
    }

    // MARK: - Text Analysis Helpers
    //
    // ROADMAP 3.4 (F-09): these were previously LOCAL re-implementations that
    // handled only five named entities and destroyed numeric ones differently
    // than the canonical path. Both now delegate to SharedTextUtilities.

    private static func estimateTotalWords(spineItems: [(id: String, href: URL)]) async -> Int {
        await Task.detached(priority: .utility) {
            var total = 0
            for item in spineItems {
                guard let data = try? Data(contentsOf: item.href),
                      let html = String(data: data, encoding: .utf8) else { continue }
                total += wordCount(html, fromHTML: true) // canonical (SharedTextUtilities)
            }
            return total
        }.value
    }

    private static func extractSampleText(spineItems: [(id: String, href: URL)], maxChars: Int) async -> String {
        await Task.detached(priority: .utility) {
            var collected = ""
            for item in spineItems {
                guard collected.count < maxChars else { break }
                guard let data = try? Data(contentsOf: item.href),
                      let html = String(data: data, encoding: .utf8) else { continue }
                collected += stripHTML(html) // canonical (SharedTextUtilities)
            }
            return String(collected.prefix(maxChars))
        }.value
    }
}

// MARK: - Cover Art Capture (P5 Feature 3)

// HOTFIX note: NSBitmapImageRep/NSImage draw are thread-safe here; these helpers
// are intentionally nonisolated so they can run inside detached tasks.
nonisolated enum BookCoverCapture {
    /// JPEG budget: sharp at pane sizes, small on disk (a few hundred books ~ few MB).
    private static let maxDimension: CGFloat = 600

    static func fromPDFDocument(_ doc: PDFDocument) -> Data? {
        // PDFPage.thumbnail is non-optional on current SDKs; only the missing
        // page needs guarding.
        guard let page = doc.page(at: 0) else { return nil }
        let image = page.thumbnail(of: CGSize(width: maxDimension, height: maxDimension * 1.5),
                                   for: .mediaBox)
        return jpegData(from: image)
    }

    static func fromFile(_ fileURL: URL) -> Data? {
        guard let image = NSImage(contentsOf: fileURL) else { return nil }
        return jpegData(from: image)
    }

    /// 2.5: comic pages are already encoded images inside a CBZ or folder;
    /// this decodes the first page and normalizes it to the cover JPEG budget.
    static func from(data: Data) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        return jpegData(from: image)
    }

    private static func jpegData(from image: NSImage) -> Data? {
        let targetSize = downscaledSize(for: image.size)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetSize.width),
            pixelsHigh: Int(targetSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep else { return nil }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: targetSize))
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    private static func downscaledSize(for original: NSSize) -> NSSize {
        guard original.width > maxDimension || original.height > maxDimension else {
            return original
        }
        let scale = min(maxDimension / original.width, maxDimension / original.height)
        return NSSize(width: original.width * scale, height: original.height * scale)
    }
}

// MARK: - APPENDED IMPORT INTELLIGENCE LAYER (v2 FULL MODULE)

import Foundation

// MARK: - Import Analytics

struct ImportAnalyticsReport {
    let fileName: String
    let fileSizeBytes: Int?
    let fileType: String
    let complexityScore: Double
    let contentRichnessScore: Double
    let chapterQualityScore: Double
    let failureProbability: Double
}

enum ImportAnalyticsEngine {
    static func analyze(book: Book, fileName: String, fileSizeBytes: Int?, fileType: String) -> ImportAnalyticsReport {
        let chapterCount = max(book.chapters.count, 1)
        let spineFactor = min(Double(chapterCount) / 25.0, 1.0)

        let avgChapterSize = Double(book.totalPages) / Double(chapterCount)
        let chapterQuality = max(0, 1.0 - abs(avgChapterSize - 20.0) / 80.0)

        let richness = min(1.0, Double(book.totalPages) / 500.0 + Double(chapterCount) / 50.0)

        let complexity = min(1.0,
                             (Double(fileSizeBytes ?? 0) / 5_000_000.0) * 0.5 +
                                 spineFactor * 0.5)

        let failure = min(1.0,
                          (fileSizeBytes == nil ? 0.2 : 0.0) +
                              (book.chapters.isEmpty ? 0.6 : 0.0) +
                              (complexity > 0.8 ? 0.2 : 0.0))

        return ImportAnalyticsReport(
            fileName: fileName,
            fileSizeBytes: fileSizeBytes,
            fileType: fileType,
            complexityScore: complexity,
            contentRichnessScore: richness,
            chapterQualityScore: chapterQuality,
            failureProbability: failure
        )
    }
}

// MARK: - Smart Import Enhancer

struct ImportSuggestion {
    let field: String
    let issue: String
    let suggestion: String
}

enum SmartImportEnhancer {
    static func analyze(book: Book) -> [ImportSuggestion] {
        var suggestions: [ImportSuggestion] = []

        if book.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            book.title.lowercased().contains("unknown")
        {
            suggestions.append(.init(
                field: "title",
                issue: "Low-quality or missing title",
                suggestion: "Extract metadata from OPF or sanitize filename"
            ))
        }

        if book.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            book.author.lowercased().contains("unknown")
        {
            suggestions.append(.init(
                field: "author",
                issue: "Missing or unknown author",
                suggestion: "Check EPUB creator tags or PDF metadata"
            ))
        }

        if book.title == book.fileURL.deletingPathExtension().lastPathComponent {
            suggestions.append(.init(
                field: "title",
                issue: "Filename-derived title",
                suggestion: "Replace with structured metadata if available"
            ))
        }

        return suggestions
    }
}

// MARK: - Chapter Refinement Engine

enum ChapterRefinementEngine {
    struct ChapterIssue {
        let chapterIndex: Int
        let issue: String
    }

    static func analyze(chapters: [Chapter]) -> [ChapterIssue] {
        var issues: [ChapterIssue] = []

        for (index, chapter) in chapters.enumerated() {
            let span = chapter.endPage - chapter.startPage

            if span < 2 {
                issues.append(.init(chapterIndex: index, issue: "Tiny chapter (<2 pages)"))
            }

            if span > 80 {
                issues.append(.init(chapterIndex: index, issue: "Oversized chapter (>80 pages)"))
            }

            if chapter.endPage < chapter.startPage {
                issues.append(.init(chapterIndex: index, issue: "Invalid chapter range"))
            }
        }

        return issues
    }
}

// MARK: - Import Warning System

enum ImportWarningLevel {
    case info
    case warning
    case critical
}

struct ImportWarning {
    let message: String
    let level: ImportWarningLevel
}

enum ImportWarningEngine {
    static func evaluate(book: Book) -> [ImportWarning] {
        var warnings: [ImportWarning] = []

        if book.chapters.isEmpty {
            warnings.append(.init(message: "No chapters extracted", level: .critical))
        }

        if book.totalPages <= 1 {
            warnings.append(.init(message: "Suspicious page count", level: .warning))
        }

        if book.title.lowercased().contains("unknown") {
            warnings.append(.init(message: "Missing title metadata", level: .info))
        }

        return warnings
    }
}

// MARK: - PDF text sampling (E7)

/// Bounded text sample from a PDF: enough to estimate words-per-page and
/// difficulty without reading a whole scanned document at import time.
enum PDFTextSampler {
    struct Sample {
        let text: String
        let pagesSampled: Int
        let wordCount: Int
    }

    static func sample(
        _ doc: PDFDocument,
        maxPages: Int = 24,
        maxCharacters: Int = 60_000
    ) -> Sample {
        let pages = min(max(0, maxPages), doc.pageCount)
        var collected = ""
        var sampled = 0

        for index in 0..<pages {
            guard let pageText = doc.page(at: index)?.string else { continue }
            collected += pageText + "\n"
            sampled += 1
            if collected.count >= maxCharacters { break }
        }

        let text = String(collected.prefix(maxCharacters))
        return Sample(
            text: text,
            pagesSampled: sampled,
            wordCount: text.split { $0.isWhitespace }.count
        )
    }
}

// MARK: - Page Estimation Model

// MARK: - Debug Snapshot System

struct ImportDebugSnapshot {
    let fileName: String
    let fileType: String
    let chapterCount: Int
    let spineCount: Int
    let estimatedPages: Int
    let analyticsScore: Double
    let warnings: [ImportWarning]

    func printSnapshot() {
        print("""
        ===== IMPORT SNAPSHOT =====
        File: \(fileName)
        Type: \(fileType)
        Chapters: \(chapterCount)
        Spine: \(spineCount)
        Pages: \(estimatedPages)
        Score: \(analyticsScore)
        Warnings: \(warnings.count)
        ============================
        """)
    }
}

// MARK: - Plugin Architecture

protocol ImportPlugin {
    var name: String { get }
    func execute(book: Book)
}

enum ImportPluginManager {
    static var plugins: [ImportPlugin] = []

    static func register(plugin: ImportPlugin) {
        plugins.append(plugin)
    }

    static func run(book: Book) {
        for plugin in plugins {
            plugin.execute(book: book)
        }
    }
}

// MARK: - Import Intelligence Facade (ENTRY POINT)

enum ImportIntelligenceFacade {
    static func analyze(
        book: Book,
        fileName: String,
        fileSizeBytes: Int?,
        fileType: String
    ) -> (
        analytics: ImportAnalyticsReport,
        suggestions: [ImportSuggestion],
        warnings: [ImportWarning],
        chapterIssues: [ChapterRefinementEngine.ChapterIssue]
    ) {
        return (
            analytics: ImportAnalyticsEngine.analyze(
                book: book,
                fileName: fileName,
                fileSizeBytes: fileSizeBytes,
                fileType: fileType
            ),
            suggestions: SmartImportEnhancer.analyze(book: book),
            warnings: ImportWarningEngine.evaluate(book: book),
            chapterIssues: ChapterRefinementEngine.analyze(chapters: book.chapters)
        )
    }
}
