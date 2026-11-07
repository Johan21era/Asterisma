//  ComicArchive.swift
//  AsterismaV2.5
//
//  2.5 — comic container support.
//
//  A comic is a sequence of page images, not a text document. This module is
//  the one place that turns a CBZ archive or an image folder into an ordered,
//  lazily-loadable page list so the importer, the reader, and tests all agree
//  on page identity and natural reading order.
//
//  Deliberately NOT supported: CBR/CB7/CBT. Those need a RAR or 7z decoder;
//  the importer rejects them with an explicit message instead of silently
//  mis-opening a file we cannot read.

import Foundation
import ZIPFoundation

// MARK: - ComicPage

/// One bitmap page inside a comic container. `path` is stable and unique
/// within its archive/folder (archive entry path or folder-relative path),
/// so it is also the page's identity for lazy loads and SwiftUI diffing.
nonisolated struct ComicPage: Identifiable, Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case archive(entryPath: String)
        case file(URL)
    }

    let path: String
    let name: String
    /// Folder path that groups this page with its chapter neighbours. Empty
    /// for a flat archive/folder, where every page belongs to one chapter.
    let chapterPath: String
    let source: Source

    var id: String { path }
}

// MARK: - ComicArchiveError

enum ComicArchiveError: LocalizedError {
    case unsupportedContainer(String)
    case cannotOpen(URL)
    case empty(URL)
    case folderUnreadable(URL)
    case pageUnavailable(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedContainer(ext):
            let suffix = ext.isEmpty ? "That file" : ".\(ext.uppercased()) files"
            return "\(suffix) are not supported. Comic archives must be .cbz; CBR, CB7, and CBT need a RAR or 7z decoder this app does not include."
        case let .cannotOpen(url):
            return "Could not open “\(url.lastPathComponent)” as a CBZ archive."
        case let .empty(url):
            return "“\(url.lastPathComponent)” contains no readable page images (JPEG, PNG, GIF, WebP, HEIC, TIFF, BMP, or AVIF)."
        case let .folderUnreadable(url):
            return "Could not read the folder “\(url.lastPathComponent)”."
        case let .pageUnavailable(path):
            return "Comic page “\(path)” could not be read from its container."
        }
    }
}

// MARK: - ComicArchive

/// An opened comic container. Holds the ZIP archive handle for CBZ and plain
/// file URLs for folders. Page reads are serialized through a lock because a
/// single ZIPFoundation archive is not safe for concurrent extraction.
final nonisolated class ComicArchive: @unchecked Sendable {
    enum Kind: String, Sendable {
        case cbz
        case folder
    }

    let rootURL: URL
    let kind: Kind
    let pages: [ComicPage]

    private let zipArchive: Archive?
    private let lock = NSLock()

    /// The model format this container maps to.
    var fileType: BookFileType {
        kind == .cbz ? .cbz : .comic
    }

    private init(rootURL: URL, kind: Kind, pages: [ComicPage], zipArchive: Archive?) {
        self.rootURL = rootURL
        self.kind = kind
        self.pages = pages
        self.zipArchive = zipArchive
    }

    // MARK: Opening

    /// Opens a CBZ file or an image folder. Format detection is structural:
    /// directories are folders, everything else must be a `.cbz`.
    static func open(url: URL) throws -> ComicArchive {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        if isDirectory {
            return try openFolder(url: url)
        }

        let ext = url.pathExtension.lowercased()
        guard ext == "cbz" else {
            throw ComicArchiveError.unsupportedContainer(ext)
        }
        return try openCBZ(url: url)
    }

    private static func openFolder(url: URL) throws -> ComicArchive {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw ComicArchiveError.folderUnreadable(url)
        }

        var pages: [ComicPage] = []
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            guard let relative = relativePath(of: fileURL, under: url) else { continue }
            guard isComicImagePath(relative), !isJunkPath(relative) else { continue }
            pages.append(ComicPage(
                path: relative,
                name: fileURL.lastPathComponent,
                chapterPath: chapterPath(for: relative),
                source: .file(fileURL)
            ))
        }

        guard !pages.isEmpty else { throw ComicArchiveError.empty(url) }
        pages.sort { sortsBefore($0.path, $1.path) }
        return ComicArchive(rootURL: url, kind: .folder, pages: pages, zipArchive: nil)
    }

    private static func openCBZ(url: URL) throws -> ComicArchive {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw ComicArchiveError.cannotOpen(url)
        }

        var pages: [ComicPage] = []
        for entry in archive {
            guard entry.type == .file else { continue }
            let path = entry.path
            guard isComicImagePath(path), !isJunkPath(path) else { continue }
            pages.append(ComicPage(
                path: path,
                name: (path as NSString).lastPathComponent,
                chapterPath: chapterPath(for: path),
                source: .archive(entryPath: path)
            ))
        }

        guard !pages.isEmpty else { throw ComicArchiveError.empty(url) }
        pages.sort { sortsBefore($0.path, $1.path) }
        return ComicArchive(rootURL: url, kind: .cbz, pages: pages, zipArchive: archive)
    }

    // MARK: Page reads

    /// Loads the encoded bytes for one page. CBZ extraction is serialized:
    /// entries can be stored or deflated, and ZIPFoundation's archive handle
    /// must not be extracted from two tasks at once.
    func data(for page: ComicPage) throws -> Data {
        switch page.source {
        case let .file(url):
            return try Data(contentsOf: url)

        case let .archive(entryPath):
            lock.lock()
            defer { lock.unlock() }
            guard let zipArchive, let entry = zipArchive[entryPath] else {
                throw ComicArchiveError.pageUnavailable(page.path)
            }
            var data = Data()
            _ = try zipArchive.extract(entry) { data.append($0) }
            return data
        }
    }

    // MARK: ComicInfo.xml

    /// Raw ComicInfo.xml bytes when the container carries the de-facto comic
    /// metadata file. The lookup is case-insensitive because real archives are
    /// inconsistent, and macOS resource-fork twins are ignored. The shallowest
    /// match wins when an archive carries several copies.
    func comicInfoData() -> Data? {
        switch kind {
        case .folder:
            let rootEntries = (try? FileManager.default.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            guard let match = rootEntries.first(where: {
                $0.lastPathComponent.lowercased() == "comicinfo.xml"
            }) else { return nil }
            return try? Data(contentsOf: match)

        case .cbz:
            lock.lock()
            defer { lock.unlock() }
            guard let zipArchive else { return nil }
            let candidates = zipArchive
                .filter { entry in
                    entry.type == .file
                        && !Self.isJunkPath(entry.path)
                        && (entry.path as NSString).lastPathComponent.lowercased() == "comicinfo.xml"
                }
                .sorted { lhs, rhs in
                    let lhsDepth = lhs.path.split(separator: "/").count
                    let rhsDepth = rhs.path.split(separator: "/").count
                    if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
                    return lhs.path < rhs.path
                }
            guard let entry = candidates.first else { return nil }
            var data = Data()
            do {
                _ = try zipArchive.extract(entry) { data.append($0) }
                return data
            } catch {
                return nil
            }
        }
    }

    /// Parsed metadata, or nil when the container has no readable
    /// ComicInfo.xml. A malformed file is a metadata miss, never an import
    /// failure: the pages are still perfectly readable.
    func comicMetadata() -> ComicMetadata? {
        guard let data = comicInfoData() else { return nil }
        return ComicMetadata.parse(data: data)
    }

    func page(at index: Int) -> ComicPage? {
        pages.indices.contains(index) ? pages[index] : nil
    }

    // MARK: Ordering helpers

    /// Extensions NSImage can decode on supported macOS versions. AVIF is
    /// included because macOS 13+ decodes it; if a particular image fails,
    /// the reader marks that page unreadable rather than failing the book.
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "avif",
    ]

    static func isComicImagePath(_ path: String) -> Bool {
        imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Finder-like natural order: page 2 before page 10, chapter 2 before
    /// chapter 10, with case-insensitive comparison and a deterministic
    /// tie-break for paths that compare equal.
    static func sortsBefore(_ lhs: String, _ rhs: String) -> Bool {
        let result = lhs.compare(
            rhs,
            options: [.numeric, .caseInsensitive],
            range: nil,
            locale: Locale(identifier: "en_US_POSIX")
        )
        if result == .orderedSame {
            return lhs < rhs
        }
        return result == .orderedAscending
    }

    private static func chapterPath(for relativePath: String) -> String {
        let parent = (relativePath as NSString).deletingLastPathComponent
        return parent == "." ? "" : parent
    }

    private static func relativePath(of fileURL: URL, under root: URL) -> String? {
        let rootComponents = root.standardizedFileURL.pathComponents
        let fileComponents = fileURL.standardizedFileURL.pathComponents
        guard fileComponents.count > rootComponents.count,
              Array(fileComponents.prefix(rootComponents.count)) == rootComponents
        else { return nil }
        return fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    /// Skips macOS resource-fork folders and dotfiles at any depth. A CBZ
    /// produced on macOS commonly carries `__MACOSX/._page.jpg` twins.
    private static func isJunkPath(_ path: String) -> Bool {
        path.split(separator: "/").contains { component in
            let name = String(component)
            return name.hasPrefix(".") || name == "__MACOSX"
        }
    }
}

// MARK: - ComicChapterBuilder

/// Groups naturally-ordered pages into contiguous chapters by their folder.
/// A flat archive becomes one "Pages" chapter; `Chapter 1/001.jpg` and
/// `Chapter 2/001.jpg` become two chapters with correct page ranges.
enum ComicChapterBuilder {
    static func chapters(from pages: [ComicPage]) -> [Chapter] {
        guard !pages.isEmpty else { return [] }

        var result: [Chapter] = []
        var currentPath = pages[0].chapterPath
        var start = 0

        func appendChapter(path: String, start: Int, end: Int) {
            let lastComponent = (path as NSString).lastPathComponent
            let title = lastComponent.isEmpty ? "Pages" : lastComponent
            result.append(Chapter(
                title: title,
                index: result.count,
                startPage: start,
                endPage: end
            ))
        }

        for (index, page) in pages.enumerated() where index > 0 {
            if page.chapterPath != currentPath {
                appendChapter(path: currentPath, start: start, end: index - 1)
                currentPath = page.chapterPath
                start = index
            }
        }
        appendChapter(path: currentPath, start: start, end: pages.count - 1)
        return result
    }
}
