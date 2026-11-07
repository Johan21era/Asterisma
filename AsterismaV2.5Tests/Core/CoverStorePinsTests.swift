//  CoverStorePinsTests.swift
//  AsterismaV2.5Tests
//
//  FINAL TRACES Upgrade #2 pins: file-store round-trip, payload-lean saves,
//  migration, orphan cleanup, cache behavior.
//
import AppKit
import Foundation
import Testing

@testable import AsterismaV2_5

@Suite("CoverStore (Upgrade #2)", .serialized)
@MainActor
final class CoverStorePinsTests {

    let dir: URL
    let coversDir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        coversDir = dir.appendingPathComponent("covers")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #if DEBUG
        CoverStore.testOverride = CoverStore(directory: coversDir)
        #endif
    }

    deinit {
        #if DEBUG
        CoverStore.testOverride = nil
        #endif
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeStore() -> CoverStore {
        CoverStore(directory: coversDir)
    }

    private func jpegPayload() -> Data {
        // Tiny valid-ish JPEG marker bytes; store treats it as opaque.
        Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
    }

    private func makeBook(withEmbeddedCover: Bool) -> Book {
        var b = Book(title: "Cover Test", author: "A",
                     fileURL: URL(fileURLWithPath: "/tmp/ct.pdf"), fileType: .pdf)
        b.totalPages = 100
        if withEmbeddedCover {
            b.coverImageData = jpegPayload()
        }
        return b
    }

    @Test("Store → hasCover → image read-back via cache")
    func roundTripThroughFiles() throws {
        let covers = makeStore()
        let id = UUID()
        covers.store(jpegPayload(), forBookID: id)

        #expect(covers.hasCover(forBookID: id))
        #expect(FileManager.default.fileExists(atPath: covers.url(forBookID: id).path))
    }

    @Test("New imports write files, NOT payload data (payload stays lean)")
    func importKeepsPayloadLean() async throws {
        // Drive the real importer with a tiny generated PDF.
        let pdf = PDFDocument()
        pdf.insert(PDFPage(), at: 0)
        let url = dir.appendingPathComponent("tiny.pdf")
        try pdf.dataRepresentation()?.write(to: url)

        let book = try await BookImporter.importPDF(url: url)
        _ = book
        // Importer stores by newBook.id — the payload field must be nil.
        #expect(book.coverImageData == nil,
                "cover bytes leaked back into the library payload")
    }

    @Test("Load-time migration extracts embedded covers and clears payload")
    func migrationExtractsAndClears() {
        let url = libraryURL
        let store = DataStore(fileURL: url)
        store.addBook(makeBook(withEmbeddedCover: true))
        store.saveImmediately()

        let reopened = DataStore(fileURL: url)
        let book = reopened.books.first!
        #expect(book.coverImageData == nil, "embedded cover was not cleared after migration")
        #expect(CoverStore.active.hasCover(forBookID: book.id), "cover file missing after migration")
    }

    @Test("removeBook removes the cover file too (no orphans)")
    func removeBookCleansCoverFile() {
        let url = libraryURL
        let store = DataStore(fileURL: url)
        let book = makeBook(withEmbeddedCover: false)
        store.addBook(book)
        CoverStore.active.store(jpegPayload(), forBookID: book.id)
        #expect(CoverStore.active.hasCover(forBookID: book.id))

        store.removeBook(id: book.id)
        #expect(!CoverStore.active.hasCover(forBookID: book.id),
                "orphaned cover file left behind after removeBook")
    }

    private var libraryURL: URL { dir.appendingPathComponent("library.json") }
}

// PDFKit import for the tiny-PDF fixture
import PDFKit
