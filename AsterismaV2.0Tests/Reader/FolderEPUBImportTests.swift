//  FolderEPUBImportTests.swift
//  AsterismaV2.0
//
//  Regression pin for owner-test failure F3 (2026-10-24): EPUBs exported by
//  iBooks can be unzipped package directories with a .epub extension. macOS
//  reports them as packages/directories, so the old open panel grayed them out
//  and the importer tried to unzip a directory. Both paths now support them.

import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import AsterismaV2_0

@Suite("Folder-form EPUB import")
struct FolderEPUBImportTests {
    @Test("An unzipped .epub directory imports and opens")
    func unzippedEPUBDirectoryImports() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let package = root.appendingPathComponent("Folder Book.epub", isDirectory: true)
        let metaInf = package.appendingPathComponent("META-INF", isDirectory: true)
        let oebps = package.appendingPathComponent("OEBPS", isDirectory: true)
        try FileManager.default.createDirectory(at: metaInf, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: oebps, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let container = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """
        try container.write(
            to: metaInf.appendingPathComponent("container.xml"),
            atomically: true, encoding: .utf8)

        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>Folder Book</dc:title>
            <dc:creator>Test Author</dc:creator>
            <dc:language>en</dc:language>
          </metadata>
          <manifest>
            <item id="ch1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="ch1"/>
          </spine>
        </package>
        """
        try opf.write(
            to: oebps.appendingPathComponent("content.opf"),
            atomically: true, encoding: .utf8)

        let chapter = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml">
          <head><title>One</title></head>
          <body><p>Hello from an unzipped EPUB folder.</p></body>
        </html>
        """
        try chapter.write(
            to: oebps.appendingPathComponent("chapter1.xhtml"),
            atomically: true, encoding: .utf8)

        let book = try await BookImporter.importEPUB(url: package)
        #expect(book.title == "Folder Book")
        #expect(book.author == "Test Author")
        #expect(book.fileType == .epub)
        #expect(book.chapters.count == 1)
        #expect(book.fileURL == package)

        // The reader path must also accept the directory form.
        let opened = try await EPUBPackage.open(book: book)
        #expect(opened.chapterCount == 1)
        opened.close()
    }

    @Test("Ordinary folders are rejected as empty comic folders")
    func ordinaryFolderRejected() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        do {
            _ = try await BookImporter.importBook(from: folder)
            Issue.record("An ordinary folder must not import")
        } catch let error as ImportError {
            #expect(error.errorDescription?.contains("no readable page images") == true)
        }
    }

    @Test("Picker admits books, EPUB packages, and comic folders")
    @MainActor
    func pickerDoesNotAdmitOrdinaryFolders() {
        let panel = NSOpenPanel()
        BookImportPanel.configure(panel)
        // 2.5: folders are selectable because a webcomic can be an image folder.
        #expect(panel.canChooseDirectories == true)
        #expect(panel.canChooseFiles == true)
        #expect(panel.treatsFilePackagesAsDirectories == false)
        #expect(panel.allowedContentTypes.contains { $0.identifier == "com.apple.ibooks.epub" })
        #expect(panel.allowedContentTypes.contains(.pdf))
        #expect(panel.allowedContentTypes.contains(.epub))
    }
}
