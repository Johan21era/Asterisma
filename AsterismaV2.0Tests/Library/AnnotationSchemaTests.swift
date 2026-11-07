//  AnnotationSchemaTests.swift
//  WP-1.1 pins: annotation domain and schema. A legacy note payload decodes
//  with the new fields nil, both anchor shapes round-trip through JSON, and a
//  SQLite save/reopen preserves the new note fields (payload payload path plus
//  the flat parity columns).

import Foundation
import GRDB
import Testing
@testable import AsterismaV2_0

@Suite("WP-1.1 · Annotation schema")
final class AnnotationSchemaTests {

    private func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WP11-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 1. A legacy BookNote JSON payload (only pre-P1.1 keys) decodes with all
    /// new fields `nil` — every pre-P1.1 note survives the schema extension.
    @Test("Legacy note payload decodes with new fields nil")
    func legacyNoteDecodesWithNilNewFields() throws {
        let bookID = UUID().uuidString
        let legacyJSON = """
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "bookID": "\(bookID)",
              "createdAt": "2025-01-02T03:04:05Z",
              "modifiedAt": "2025-01-02T03:04:05Z",
              "pageNumber": 7,
              "text": "Editorial note from an older build",
              "tag": "Highlight"
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let note = try decoder.decode(BookNote.self, from: Data(legacyJSON.utf8))

        #expect(note.text == "Editorial note from an older build")
        #expect(note.pageNumber == 7)
        #expect(note.tag == .highlight)
        #expect(note.selectedText == nil)
        #expect(note.color == nil)
        #expect(note.anchor == nil)

        // Absent-key tolerance must hold with the app's own encoder/decoder
        // framing too: a legacy note re-encoded today and re-decoded keeps
        // nil for every new field.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let reencoded = try encoder.encode(note)
        let roundTripped = try decoder.decode(BookNote.self, from: reencoded)
        #expect(roundTripped.selectedText == nil)
        #expect(roundTripped.color == nil)
        #expect(roundTripped.anchor == nil)
    }

    /// 2. EPUB anchor round-trips through JSONEncoder/JSONDecoder.
    @Test("EPUB anchor round-trips through JSON")
    func epubAnchorRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let anchor = BookNoteAnchor.epub(
            chapterIndex: 3,
            cfi: "epubcfi(/6/8[ch01]!/4/2/16/1:42)",
            pageInChapter: nil)
        let data = try encoder.encode(anchor)
        let decoded = try decoder.decode(BookNoteAnchor.self, from: data)

        guard case let .epub(chapterIndex, cfi, pageInChapter) = decoded else {
            Issue.record("Expected .epub anchor, got \(decoded)")
            return
        }
        #expect(chapterIndex == 3)
        #expect(cfi == "epubcfi(/6/8[ch01]!/4/2/16/1:42)")
        #expect(pageInChapter == nil)

        // The paged variant must also survive.
        let paged = BookNoteAnchor.epub(chapterIndex: 0, cfi: "epubcfi(/6/2!)", pageInChapter: 12)
        let decodedPaged = try decoder.decode(BookNoteAnchor.self, from: try encoder.encode(paged))
        #expect(decodedPaged == paged)
    }

    /// 3. PDF anchor round-trips, including normalized rect values.
    @Test("PDF anchor round-trips through JSON")
    func pdfAnchorRoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let anchor = BookNoteAnchor.pdf(
            pageIndex: 14,
            rect: NormalizedRect(x: 0.125, y: 0.375, width: 0.5, height: 0.0625))
        let data = try encoder.encode(anchor)
        let decoded = try decoder.decode(BookNoteAnchor.self, from: data)

        guard case let .pdf(pageIndex, rect) = decoded else {
            Issue.record("Expected .pdf anchor, got \(decoded)")
            return
        }
        #expect(pageIndex == 14)
        #expect(rect.x == 0.125)
        #expect(rect.y == 0.375)
        #expect(rect.width == 0.5)
        #expect(rect.height == 0.0625)
        #expect(decoded == anchor)
    }

    /// 4. A SQLite library save/reopen preserves selectedText, color, and both
    /// anchor shapes — through the authoritative payload path and through the
    /// flat parity columns.
    @Test("SQLite save/reopen preserves annotation fields")
    func sqliteSaveReopenPreservesAnnotationFields() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("annotations.sqlite3")

        let bookID = UUID()
        let epubNote = BookNote(
            bookID: bookID,
            text: "Why does this hold?",
            tag: .question,
            selectedText: "the measured boundary",
            color: .green,
            anchor: .epub(
                chapterIndex: 2,
                cfi: "epubcfi(/6/6[ch02]!/4/10:7)",
                pageInChapter: 5))
        let pdfNote = BookNote(
            bookID: bookID,
            text: "Definition worth keeping",
            tag: .quote,
            selectedText: "A steady state is…",
            color: .purple,
            anchor: .pdf(pageIndex: 9, rect: NormalizedRect(x: 0.25, y: 0.5, width: 0.75, height: 0.25)))
        // A plain editorial note with no annotation fields stays exactly nil.
        let plainNote = BookNote(bookID: bookID, text: "ordinary note", tag: .idea)

        var book = Book(
            title: "Annotation carrier",
            author: "A",
            fileURL: URL(fileURLWithPath: "/tmp/wp11.epub"),
            fileType: .epub,
            totalPages: 120)
        book.id = bookID
        book.notes = [epubNote, pdfNote, plainNote]

        let first = try LibraryDatabase(url: dbURL)
        try first.saveAll(books: [book], state: LibraryState())
        try first.close()

        let second = try LibraryDatabase(url: dbURL)
        defer { try? second.close() }
        let reloaded = try #require(try second.loadBooks().first)
        #expect(reloaded.notes.count == 3)

        let reloadedByID = Dictionary(uniqueKeysWithValues: reloaded.notes.map { ($0.id, $0) })
        let reloadedEpub = try #require(reloadedByID[epubNote.id])
        #expect(reloadedEpub.selectedText == "the measured boundary")
        #expect(reloadedEpub.color == .green)
        #expect(reloadedEpub.anchor == epubNote.anchor)
        #expect(reloadedEpub.pageNumber == nil)

        let reloadedPDF = try #require(reloadedByID[pdfNote.id])
        #expect(reloadedPDF.selectedText == "A steady state is…")
        #expect(reloadedPDF.color == .purple)
        #expect(reloadedPDF.anchor == pdfNote.anchor)
        #expect(reloadedPDF.tag == .quote)

        let reloadedPlain = try #require(reloadedByID[plainNote.id])
        #expect(reloadedPlain.selectedText == nil)
        #expect(reloadedPlain.color == nil)
        #expect(reloadedPlain.anchor == nil)

        // Flat parity columns: every saved note row carries the new values,
        // and the anchor_json text decodes back to the same anchor.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let rows = try second.pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, selected_text, color, anchor_json
                    FROM notes WHERE book_id = ? ORDER BY id
                    """,
                arguments: [bookID.uuidString])
        }
        #expect(rows.count == 3)
        for row in rows {
            let id: String = row["id"]
            let expected = try #require(reloadedByID[UUID(uuidString: id)!])
            let selectedText: String? = row["selected_text"]
            let color: String? = row["color"]
            let anchorText: String? = row["anchor_json"]
            #expect(selectedText == expected.selectedText)
            #expect(color == expected.color?.rawValue)
            switch (anchorText, expected.anchor) {
            case (nil, nil):
                break
            case let (text?, expectedAnchor?):
                let decodedAnchor = try LibraryDatabase.decodeAnchor(
                    from: text, with: decoder)
                #expect(decodedAnchor == expectedAnchor)
            default:
                Issue.record("anchor_json and note.anchor disagree for \(id)")
            }
        }

        // The v2 migration added the three nullable columns to the notes table.
        let annotationColumns = try second.pool.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT name FROM pragma_table_info('notes')
                    WHERE name IN ('selected_text', 'color', 'anchor_json')
                    """)
        }
        #expect(annotationColumns.sorted() == ["anchor_json", "color", "selected_text"])
    }

    /// 5. Existing tag values still decode; `.quote` is available.
    @Test("Existing tags decode and .quote is available")
    func tagsDecodeAndQuoteExists() {
        let allRawValues: [String] = BookNote.NoteTag.allCases.map(\.rawValue)
        #expect(allRawValues.contains("General"))
        #expect(allRawValues.contains("Highlight"))
        #expect(allRawValues.contains("Question"))
        #expect(allRawValues.contains("Idea"))
        #expect(allRawValues.contains("Vocabulary"))
        #expect(allRawValues.contains("Quote"))
        #expect(BookNote.NoteTag(rawValue: "Vocabulary") == .vocabulary)
        #expect(BookNote.NoteTag(rawValue: "Quote") == .quote)

        let legacyJSON = """
            {
              "id": "22222222-2222-2222-2222-222222222222",
              "bookID": "33333333-3333-3333-3333-333333333333",
              "createdAt": "2025-01-02T03:04:05Z",
              "modifiedAt": "2025-01-02T03:04:05Z",
              "text": "t",
              "tag": "Question"
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let note = try? decoder.decode(BookNote.self, from: Data(legacyJSON.utf8))
        #expect(note?.tag == .question)

        // The AnnotationColor palette is exactly the WP-1.1 set.
        #expect(AnnotationColor.allCases == [.yellow, .green, .blue, .pink, .purple])
    }

    /// 6. CR-1 finding 6: a duplicated note id must not abort the whole library
    /// save. The mirror writes notes with `INSERT OR REPLACE`, so the last
    /// write for an id wins and exactly one row survives — a corrupt payload
    /// costs one note, never the library.
    @Test("A duplicated note id saves without aborting the library")
    func duplicateNoteIDDoesNotAbortSave() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("duplicate-notes.sqlite3")

        let bookID = UUID()
        let sharedID = UUID()
        var book = Book(
            title: "Duplicate carrier",
            author: "A",
            fileURL: URL(fileURLWithPath: "/tmp/wp11-dup.epub"),
            fileType: .epub,
            totalPages: 10)
        book.id = bookID
        book.notes = [
            BookNote(id: sharedID, bookID: bookID, text: "first", tag: .general),
            BookNote(id: sharedID, bookID: bookID, text: "second", tag: .general),
        ]

        let first = try LibraryDatabase(url: dbURL)
        try first.saveAll(books: [book], state: LibraryState())
        try first.close()

        let second = try LibraryDatabase(url: dbURL)
        defer { try? second.close() }
        let reloaded = try #require(try second.loadBooks().first)
        #expect(reloaded.notes.count == 1)
        #expect(reloaded.notes.first?.id == sharedID)
        #expect(reloaded.notes.first?.text == "second")
    }
}
