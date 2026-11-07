//  EPUBPackage.swift
//  AsterismaV2.5
//  Added as part of the EPUBReaderScreen architectural redesign.
//  See EPUB_READER_REDESIGN_PLAN.txt for the plan this implements.
//  Responsibility: open an EPUB archive exactly once per reading session,
//  keep it open (security scope + unzipped temp directory) for as long as
//  the caller needs it, hand out per-chapter file URLs on demand, and
//  guarantee the security scope and temp directory are released exactly
//  once no matter how the session ends (success, thrown error, or Task
//  cancellation mid-open). This replaces EPUBReaderScreen's previous
//  "unzip, grab a fixed text snippet, delete everything" one-shot flow.
//
//  This type has no SwiftUI/View dependency — it is pure Foundation/XML
//  resource management, usable independently of how it's displayed.
//

import Foundation
import os

#if canImport(ZIPFoundation)
    import ZIPFoundation
#endif

// MARK: - EPUBSpineItem

/// One entry in the EPUB's reading order, resolved to an actual file on disk
/// inside the package's unzipped temp directory.
struct EPUBSpineItem {
    let id: String
    let fileURL: URL
}

// MARK: - EPUBPackageError

enum EPUBPackageError: LocalizedError {
    case securityScopeUnavailable
    case cannotReadContainerXML
    case opfPathNotFound
    case cannotReadOPF
    case zipFoundationUnavailable

    var errorDescription: String? {
        switch self {
        case .securityScopeUnavailable:
            return "AsterismaV2.5 couldn't access this file. Its saved permission may have expired — try re-adding the book to your library."
        case .cannotReadContainerXML:
            return "This EPUB's container.xml could not be read. The file may be corrupted."
        case .opfPathNotFound:
            return "This EPUB's package document could not be located inside the archive."
        case .cannotReadOPF:
            return "This EPUB's package document could not be read. The file may be corrupted."
        case .zipFoundationUnavailable:
            return "This build is missing the ZIP support needed to open EPUB files."
        }
    }
}

// MARK: - EPUBPackage

/// A live handle to one opened EPUB archive. Holds the security-scoped
/// access and the unzipped temp directory open for as long as it exists;
/// `close()` (or deinit, as a safety net) releases both, exactly once.
///
/// Explicitly `nonisolated`: this project's build settings default every
/// type to @MainActor isolation unless it opts out (SWIFT_DEFAULT_ACTOR_
/// ISOLATION = MainActor — see the original review's C3 note on
/// BookImporter.swift for the same concern). Without opting out here,
/// `open(book:)`'s unzip + XML parse — genuinely slow for a large book —
/// would silently run on the main actor despite being called from a Task,
/// defeating the entire point of doing this work asynchronously. Safe to
/// mark `@unchecked Sendable`: every stored property is immutable after
/// init except `cleanup`, which protects its own mutable state with a lock.
final nonisolated class EPUBPackage: @unchecked Sendable {
    let title: String
    let author: String
    private let spineItems: [EPUBSpineItem]
    let rootDirectory: URL
    private let cleanup: OpenCleanup
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Asterisma",
        category: "EPUBPackage"
    )

    var chapterCount: Int {
        spineItems.count
    }

    /// Indices of spine items that contain actual reading text. Cover pages,
    /// title-page images, and other image-only documents are omitted so they
    /// do not appear as blank "logo" pages in the reader.
    func readableChapterIndices(minimumTextCharacters: Int = 60) -> [Int] {
        var result: [Int] = []
        for (index, item) in spineItems.enumerated() {
            guard let data = try? Data(contentsOf: item.fileURL),
                  let html = String(data: data, encoding: .utf8)
            else { continue }

            let text = html
                .replacingOccurrences(
                    of: "<script[\\s\\S]*?</script>", with: " ",
                    options: .regularExpression)
                .replacingOccurrences(
                    of: "<style[\\s\\S]*?</style>", with: " ",
                    options: .regularExpression)
                .replacingOccurrences(
                    of: "<[^>]+>", with: " ",
                    options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if text.count >= minimumTextCharacters {
                result.append(index)
            }
        }
        return result.isEmpty ? Array(spineItems.indices) : result
    }

    /// The directory a WKWebView must be granted read access to, so a
    /// chapter's relative references (images, stylesheets) resolve.
    var allowedReadRoot: URL {
        rootDirectory
    }

    func fileURL(forChapterAt index: Int) -> URL? {
        guard spineItems.indices.contains(index) else { return nil }
        return spineItems[index].fileURL
    }

    private init(
        title: String,
        author: String,
        spineItems: [EPUBSpineItem],
        rootDirectory: URL,
        cleanup: OpenCleanup
    ) {
        self.title = title
        self.author = author
        self.spineItems = spineItems
        self.rootDirectory = rootDirectory
        self.cleanup = cleanup
    }

    /// Releases the security scope and deletes the temp directory. Safe to
    /// call more than once, and safe to call even if a cancellation during
    /// `open(book:)` already released everything — only the first call to
    /// either path has any effect.
    func close() {
        cleanup.runOnce()
        logger.debug("EPUBPackage closed")
    }

    deinit {
        cleanup.runOnce()
    }

    // MARK: - Opening

    /// Opens `book`'s EPUB file: resolves its security-scoped bookmark,
    /// starts access, unzips to a fresh temp directory, and parses the OPF
    /// package document for title/author/reading order.
    ///
    /// Cancellation-safe: if the calling Task is cancelled at any point
    /// during this call — including mid-unzip or mid-parse — the security
    /// scope and any partially-created temp directory are still released
    /// before this function returns/throws. Nobody ever receives a live
    /// `EPUBPackage` in that case, so cleanup must happen in here; there is
    /// no other owner to call `close()` on a package that never got made.
    static func open(book: Book) async throws -> EPUBPackage {
        guard let resolvedURL = book.resolveURL() else {
            throw EPUBPackageError.securityScopeUnavailable
        }

        guard resolvedURL.startAccessingSecurityScopedResource() else {
            throw EPUBPackageError.securityScopeUnavailable
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cleanup = OpenCleanup(sourceURL: resolvedURL, tempDirectory: tempDir)

        var succeeded = false
        defer {
            // Covers: any thrown error below, and the (rare) case where
            // withTaskCancellationHandler's operation closure unwinds
            // without onCancel having fired first. runOnce() is idempotent,
            // so this can never double-release anything onCancel already did.
            if !succeeded {
                cleanup.runOnce()
            }
        }

        return try await withTaskCancellationHandler(
            operation: {
                try FileManager.default.createDirectory(
                    at: tempDir, withIntermediateDirectories: true
                )

                // Some EPUBs (notably iBooks exports) are unzipped package
                // directories with a .epub extension. Parse those in place;
                // only zip archives need the temporary extraction directory.
                let isDirectory = (try? resolvedURL.resourceValues(
                    forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                let contentRoot: URL
                if isDirectory {
                    contentRoot = resolvedURL
                } else {
                    try unzip(at: resolvedURL, to: tempDir)
                    contentRoot = tempDir
                }
                try Task.checkCancellation()

                let containerURL = contentRoot.appendingPathComponent("META-INF/container.xml")
                let opfURL = try findOPFURL(containerURL: containerURL, baseDir: contentRoot)
                let parsed = try parseOPF(opfURL: opfURL, baseDir: contentRoot)
                try Task.checkCancellation()

                let package = EPUBPackage(
                    title: parsed.title,
                    author: parsed.author,
                    spineItems: parsed.spineItems,
                    rootDirectory: contentRoot,
                    cleanup: cleanup
                )
                succeeded = true
                return package
            },
            onCancel: {
                // Fires synchronously the moment cancellation is requested,
                // even while `operation` is still suspended mid-unzip or
                // mid-parse. Guaranteed to run exactly one real release even
                // if the operation closure above also reaches its own
                // `defer` — see OpenCleanup.
                cleanup.runOnce()
            }
        )
    }

    // MARK: - Idempotent cleanup

    /// Releases a security scope and removes a temp directory exactly once,
    /// even when called from two places that could race (the cancellation
    /// handler and the normal failure path both call this during `open`).
    /// `nonisolated` for the same reason as EPUBPackage itself — this must
    /// be callable synchronously from `deinit` and from whatever arbitrary
    /// executor `withTaskCancellationHandler`'s onCancel fires on, neither
    /// of which can `await` a main-actor hop.
    private final nonisolated class OpenCleanup: @unchecked Sendable {
        private let lock = NSLock()
        private var didRun = false
        private let sourceURL: URL
        private let tempDirectory: URL

        init(sourceURL: URL, tempDirectory: URL) {
            self.sourceURL = sourceURL
            self.tempDirectory = tempDirectory
        }

        func runOnce() {
            lock.lock()
            defer { lock.unlock() }
            guard !didRun else { return }
            didRun = true
            sourceURL.stopAccessingSecurityScopedResource()
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    // MARK: - Parsing (ported from the previous EPUBReaderScreen implementation)

    private static func unzip(at source: URL, to destination: URL) throws {
        #if canImport(ZIPFoundation)
            try FileManager.default.unzipItem(at: source, to: destination)
        #else
            throw EPUBPackageError.zipFoundationUnavailable
        #endif
    }

    private static func findOPFURL(containerURL: URL, baseDir: URL) throws -> URL {
        guard let data = try? Data(contentsOf: containerURL) else {
            throw EPUBPackageError.cannotReadContainerXML
        }
        let xml = try XMLDocument(data: data, options: [])
        guard let opfPath = try xml.nodes(forXPath: "//@full-path").first?.stringValue else {
            throw EPUBPackageError.opfPathNotFound
        }
        return baseDir.appendingPathComponent(opfPath)
    }

    private struct ParsedOPF {
        var title: String
        var author: String
        var spineItems: [EPUBSpineItem]
    }

    private static func parseOPF(opfURL: URL, baseDir _: URL) throws -> ParsedOPF {
        guard let data = try? Data(contentsOf: opfURL) else {
            throw EPUBPackageError.cannotReadOPF
        }

        let xml = try XMLDocument(data: data, options: [])
        let opfDir = opfURL.deletingLastPathComponent()
        let title = (try? xml.nodes(forXPath: "//*[local-name()='title']").first?.stringValue) ?? "Unknown Title"
        let creator = (try? xml.nodes(forXPath: "//*[local-name()='creator']").first?.stringValue) ?? "Unknown Author"

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

        var spineItems: [EPUBSpineItem] = []
        if let refs = try? xml.nodes(forXPath: "//*[local-name()='itemref']/@idref") {
            for ref in refs {
                guard let idref = ref.stringValue, let href = manifest[idref] else { continue }
                spineItems.append(EPUBSpineItem(id: idref, fileURL: href))
            }
        }

        return ParsedOPF(title: title, author: creator, spineItems: spineItems)
    }
}
