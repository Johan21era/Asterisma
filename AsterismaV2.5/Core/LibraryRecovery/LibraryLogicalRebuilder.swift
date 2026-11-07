//  LibraryLogicalRebuilder.swift
//  Library Safety — Phase 5
//
//  Rebuild uses the payloads that already exist: books, state, and page-times.
//  It never invents missing rows, never merges duplicate books, and reports the
//  rows it could not carry before the result is offered for a swap.

import Foundation
import GRDB

nonisolated struct LibraryRebuildResult: Sendable {
    var url: URL
    var manifest: LibrarySnapshotManifest
    var sourceCounts: LibraryTableCounts
    var rebuiltCounts: LibraryTableCounts
    var stateDecoded: Bool
    var skippedBooks: Int
    var lostRows: Int
    var notes: [String]
}

nonisolated enum LibraryRebuildError: LocalizedError, Equatable {
    case destinationExists(String)
    case unreadableSource(String)
    case noRecoverablePayloads
    case rebuildFailed(String)

    var errorDescription: String? {
        switch self {
        case let .destinationExists(path):
            return "A rebuilt store already exists at \(path)."
        case let .unreadableSource(message):
            return "The source could not be read for rebuild: \(message)"
        case .noRecoverablePayloads:
            return "No books or library state could be decoded."
        case let .rebuildFailed(message):
            return "The logical rebuild failed: \(message)"
        }
    }
}

nonisolated enum LibraryLogicalRebuilder {

    static func rebuild(
        sourceURL: URL,
        destination: URL,
        now: Date = Date()
    ) throws -> LibraryRebuildResult {
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw LibraryRebuildError.destinationExists(destination.path)
        }

        let connection: LibraryReadOnlyConnection
        do {
            connection = try LibraryReadOnlyConnection(url: sourceURL)
        } catch {
            throw LibraryRebuildError.unreadableSource(error.localizedDescription)
        }
        defer { connection.close() }

        let sourceCounts: LibraryTableCounts
        let books: [Book]
        let state: LibraryState
        let stateDecoded: Bool
        let skippedBooks: Int
        do {
            sourceCounts = try connection.inspect().manifest.counts
            books = try connection.recoverBooks()
            let stateResult = try connection.recoverState()
            state = stateResult.state
            stateDecoded = stateResult.decoded
            skippedBooks = max(0, sourceCounts.books - books.count)
        } catch {
            throw LibraryRebuildError.unreadableSource(error.localizedDescription)
        }

        guard !books.isEmpty || stateDecoded else {
            throw LibraryRebuildError.noRecoverablePayloads
        }

        do {
            let destinationDatabase = try LibraryDatabase(url: destination)
            try destinationDatabase.saveAll(books: books, state: state)
            try destinationDatabase.close()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw LibraryRebuildError.rebuildFailed(error.localizedDescription)
        }

        do {
            let inspection = try LibraryDatabase.inspectSnapshot(
                at: destination, fullIntegrity: true)
            let rebuilt = inspection.manifest.counts
            let sourceTotal = sourceCounts.totalRows
            let rebuiltTotal = rebuilt.totalRows
            let lost = max(0, sourceTotal - rebuiltTotal)
            var notes: [String] = []
            if !stateDecoded { notes.append("state-not-recovered") }
            if skippedBooks > 0 { notes.append("books-skipped:\(skippedBooks)") }
            if lost > 0 { notes.append("rows-not-carried:\(lost)") }
            return LibraryRebuildResult(
                url: destination,
                manifest: inspection.manifest,
                sourceCounts: sourceCounts,
                rebuiltCounts: rebuilt,
                stateDecoded: stateDecoded,
                skippedBooks: skippedBooks,
                lostRows: lost,
                notes: notes)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw LibraryRebuildError.rebuildFailed(error.localizedDescription)
        }
    }
}

// MARK: - Recover from payloads

extension LibraryReadOnlyConnection {

    /// Reads books, attaches their page timings from the timing table, and
    /// skips only rows that cannot be decoded. The skipped count is evidence.
    func recoverBooks() throws -> [Book] {
        try queue.read { db in
            guard try tableExists(db, "books") else { return [] }
            let rows = try Row.fetchAll(
                db, sql: "SELECT payload_json FROM books ORDER BY date_added")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var books: [Book] = []
            for row in rows {
                let text: String = row["payload_json"]
                guard let book = try? decoder.decode(Book.self, from: Data(text.utf8)) else {
                    continue
                }
                books.append(book)
            }
            guard !books.isEmpty, try tableExists(db, "page_times") else { return books }

            var timingsBySession: [UUID: [PageTiming]] = [:]
            let timingRows = try Row.fetchAll(
                db,
                sql: "SELECT session_id, payload_json FROM page_times ORDER BY idx")
            for row in timingRows {
                let sessionID: String = row["session_id"]
                let text: String = row["payload_json"]
                guard let id = UUID(uuidString: sessionID),
                      let timing = try? decoder.decode(PageTiming.self, from: Data(text.utf8))
                else { continue }
                timingsBySession[id, default: []].append(timing)
            }

            for bookIndex in books.indices {
                for sessionIndex in books[bookIndex].sessions.indices {
                    let id = books[bookIndex].sessions[sessionIndex].id
                    if let timings = timingsBySession[id] {
                        books[bookIndex].sessions[sessionIndex].pageTimes = timings
                    }
                }
            }
            return books
        }
    }

    /// Missing or unreadable state is not fatal: it is reported and replaced by
    /// the app's default state. The caller must show that loss before swap.
    func recoverState() throws -> (state: LibraryState, decoded: Bool) {
        try queue.read { db in
            guard try tableExists(db, "library_state") else {
                return (LibraryState(), false)
            }
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT payload_json FROM library_state WHERE key = 'root'")
            else {
                return (LibraryState(), true)
            }
            let text: String = row["payload_json"]
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let state = try? decoder.decode(LibraryState.self, from: Data(text.utf8)) else {
                return (LibraryState(), false)
            }
            return (state, true)
        }
    }

    private func tableExists(_ db: Database, _ name: String) throws -> Bool {
        (try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?",
            arguments: [name]) ?? 0) > 0
    }
}
