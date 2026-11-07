//  SchemaEvolutionTests.swift
//  AsterismaV2.5Tests
//
//  Phase 1 regression battery — pins AUDIT F-04 (Gates A + B).
//
//  Defect class being pinned: synthesized Decodable made every field ever added
//  mandatory (genre/notes/isFavorite/collectionIDs on Book; collections on
//  LibraryState), so pre-v3/v4 files failed decode wholesale — and the state-file
//  failure path reset goals/achievements history WITHOUT a backup, letting the
//  next save overwrite it permanently.

import Foundation
import Testing

@testable import AsterismaV2_5

@Suite("Schema Evolution — F-04 regression pins")
@MainActor
struct SchemaEvolutionTests {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Gate B: legacy Book JSON decodes with defaults

    @Test("F-04B: Book JSON lacking v3/v4 keys decodes with current defaults")
    func legacyBookDecodes() throws {
        // Hand-built "old schema" payload: only the original v1-era fields.
        let legacy: [String: Any] = [
            "id": UUID().uuidString,
            "title": "An Old Import",
            "author": "Someone",
            "fileURL": "/tmp/old.epub",
            "fileType": "epub",
            "totalPages": 300,
            "currentPage": 42,
            "isCompleted": false,
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let book = try decoder.decode(Book.self, from: data)

        #expect(book.title == "An Old Import")
        #expect(book.totalPages == 300)
        #expect(book.currentPage == 42)
        #expect(book.genre == .unknown)          // v3 default applied
        #expect(book.notes.isEmpty)              // v3 default applied
        #expect(book.isFavorite == false)        // v4 default applied
        #expect(book.collectionIDs.isEmpty)      // v4 default applied
        #expect(book.series == nil)
    }

    @Test("F-04B: modern round-trip remains lossless through custom decoder")
    func modernRoundTripLossless() throws {
        var book = Book(title: "Modern", author: "A",
                        fileURL: URL(fileURLWithPath: "/tmp/m.pdf"), fileType: .pdf)
        book.totalPages = 100
        book.currentPage = 10
        book.genre = .fantasy
        book.isFavorite = true
        book.series = "The Series"
        book.collectionIDs = [UUID()]

        let data = try encoder.encode([book])
        let decoded = try decoder.decode([Book].self, from: data)

        #expect(decoded.count == 1)
        #expect(decoded[0].id == book.id)
        #expect(decoded[0].genre == .fantasy)
        #expect(decoded[0].isFavorite == true)
        #expect(decoded[0].series == "The Series")
        #expect(decoded[0].collectionIDs == book.collectionIDs)
    }

    // MARK: - Gate B: LibraryState tolerates missing fields

    @Test("F-04B: LibraryState without collections/schemaVersion decodes with defaults")
    func legacyStateDecodes() throws {
        let legacy: [String: Any] = [
            "goalSet": ["dailyPageTarget": 20] as [String: Any],
            "deadlines": [] as [Any],
            "earnedAchievements": [] as [Any],
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        let state = try decoder.decode(LibraryState.self, from: data)

        #expect(state.schemaVersion == .current)     // version-less file accepted
        #expect(state.collections.isEmpty)           // v4 default applied
        #expect(state.goalSet.dailyPageTarget == 20) // real content preserved
    }

    // MARK: - Gate A: unreadable state file is backed up before reset

    @Test("F-04A: corrupt library-state.json → .bak created, original bytes preserved")
    func corruptStateFileIsBackedUp() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let stateURL = dir.appendingPathComponent("library-state.json")
        let original = Data("not json {{{".utf8)
        try original.write(to: stateURL)

        let store = DataStore(fileURL: dir.appendingPathComponent("library.json"))

        // The reset happened (fresh state), but…
        #if DEBUG
        if case .degraded = store.persistenceHealth {
            // expected
        } else {
            Issue.record("corrupt state file must degrade persistenceHealth")
        }
        #endif

        // …the user's old bytes survive in the backup.
        let bakURL = dir.appendingPathComponent("library-state.bak.json")
        #expect(FileManager.default.fileExists(atPath: bakURL.path))
        #expect(try Data(contentsOf: bakURL) == original)
    }
}
