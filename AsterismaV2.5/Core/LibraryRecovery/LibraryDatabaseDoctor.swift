//  LibraryDatabaseDoctor.swift
//  Library Safety — Phase 2
//
//  Diagnosis runs on the preserved copy, never the live store. It answers a
//  narrow question: what can be read, and what would be lost? It does not
//  repair, vacuum, checkpoint, or choose an option.

import Foundation
import GRDB

nonisolated enum LibraryDatabaseDoctor {

    static func diagnose(
        mainURL: URL,
        now: Date = Date()
    ) -> LibraryDiagnosis {
        do {
            let connection = try LibraryReadOnlyConnection(url: mainURL)
            defer { connection.close() }
            let inspection = try connection.inspect(fullIntegrity: true)
            let foreignKeys = (try? connection.foreignKeyViolationCounts()) ?? [:]

            let books = (try? connection.readBooks()) ?? (total: 0, undecodable: 0)
            let stateDecoded = (try? connection.readStateDecoded()) ?? false
            let timings = (try? connection.samplePageTimings(limit: 1_000))
                ?? (total: 0, undecodable: 0)

            var notes: [String] = []
            if !inspection.missingTables.isEmpty {
                notes.append("missing:\(inspection.missingTables.joined(separator: ","))")
            }
            if inspection.manifest.foreignKeyViolations > 0 {
                notes.append("foreign-key:\(inspection.manifest.foreignKeyViolations)")
            }
            if books.undecodable > 0 {
                notes.append("books-undecodable:\(books.undecodable)")
            }
            if !stateDecoded {
                notes.append("state-undecodable")
            }

            return LibraryDiagnosis(
                canOpenReadOnly: true,
                quickCheck: inspection.manifest.quickCheck,
                integrityCheck: inspection.integrityMessages,
                foreignKeyViolations: foreignKeys,
                tableCounts: inspection.manifest.counts,
                missingTables: inspection.missingTables,
                unexpectedTables: inspection.unexpectedTables,
                undecodableBooks: books.undecodable,
                undecodableState: !stateDecoded,
                pageCount: inspection.manifest.pageCount,
                freelistCount: inspection.manifest.freelistCount,
                pageSize: inspection.manifest.pageSize,
                canVacuum: hasSpaceForSnapshot(at: mainURL),
                canRebuildFromPayloads: inspection.missingTables.isEmpty
                    && books.undecodable == 0
                    && stateDecoded,
                canRecoverPageTimings: timings.undecodable == 0,
                notes: notes,
                diagnosedAt: now)
        } catch {
            return LibraryDiagnosis(
                canOpenReadOnly: false,
                quickCheck: nil,
                integrityCheck: [],
                foreignKeyViolations: [:],
                tableCounts: nil,
                missingTables: [],
                unexpectedTables: [],
                undecodableBooks: 0,
                undecodableState: true,
                pageCount: nil,
                freelistCount: nil,
                pageSize: nil,
                canVacuum: false,
                canRebuildFromPayloads: false,
                canRecoverPageTimings: false,
                notes: ["unreadable"],
                diagnosedAt: now)
        }
    }

    private static func hasSpaceForSnapshot(at url: URL) -> Bool {
        do {
            try LibraryFileSync.requireSnapshotSpace(
                for: url,
                destinationDirectory: url.deletingLastPathComponent())
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Read-only decode helpers

extension LibraryReadOnlyConnection {

    func readBooks() throws -> (total: Int, undecodable: Int) {
        try queue.read { db in
            guard try tableExists(db, "books") else { return (0, 0) }
            let rows = try Row.fetchAll(
                db, sql: "SELECT payload_json FROM books")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var undecodable = 0
            for row in rows {
                let text: String = row["payload_json"]
                if (try? decoder.decode(Book.self, from: Data(text.utf8))) == nil {
                    undecodable += 1
                }
            }
            return (rows.count, undecodable)
        }
    }

    func readStateDecoded() throws -> Bool {
        try queue.read { db in
            guard try tableExists(db, "library_state") else { return false }
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT payload_json FROM library_state WHERE key = 'root'")
            else { return true }
            let text: String = row["payload_json"]
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? decoder.decode(LibraryState.self, from: Data(text.utf8))) != nil
        }
    }

    func samplePageTimings(limit: Int) throws -> (total: Int, undecodable: Int) {
        try queue.read { db in
            guard try tableExists(db, "page_times") else { return (0, 0) }
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM page_times") ?? 0
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT payload_json FROM page_times LIMIT ?",
                arguments: [limit])
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var undecodable = 0
            for row in rows {
                let text: String = row["payload_json"]
                if (try? decoder.decode(PageTiming.self, from: Data(text.utf8))) == nil {
                    undecodable += 1
                }
            }
            return (total, undecodable)
        }
    }

    private func tableExists(_ db: Database, _ name: String) throws -> Bool {
        (try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?",
            arguments: [name]) ?? 0) > 0
    }
}
