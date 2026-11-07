//  LibraryDatabase.swift
//  Bedrock G3A — GRDB/SQLite foundation.
//
//  This is deliberately additive: the existing JSON DataStore remains the
//  default until G3B/G3C prove parity. The database is the future normalized
//  core: books, sessions, page_times, library state, notes, collections,
//  achievements, weather, audio, and (later) behavior evidence.
//
//  G3A keeps a full Book payload in `books.payload_json` as the parity source
//  of truth, while ALSO writing normalized session/page_timing rows. G3B
//  switches reads to summaries + on-demand sessions and SQL aggregates.

import Foundation
import GRDB

/// A record that exists in the database but cannot be decoded. Loading fails
/// closed instead of omitting the row so callers never mistake corruption for
/// an empty or shortened library.
enum LibraryDatabaseError: LocalizedError, Equatable {
    case undecodableBook(id: String, underlying: String)
    case undecodableLibraryState(underlying: String)

    var errorDescription: String? {
        switch self {
        case let .undecodableBook(id, underlying):
            return "Book record \(id) could not be decoded: \(underlying)"
        case let .undecodableLibraryState(underlying):
            return "Library state could not be decoded: \(underlying)"
        }
    }
}

nonisolated final class LibraryDatabase: @unchecked Sendable {
    let pool: DatabasePool
    let dbURL: URL

    init(url: URL) throws {
        dbURL = url
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        pool = try DatabasePool(path: url.path, configuration: config)
        try Self.migrator.migrate(pool)
    }

    // MARK: - Schema

    static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "books") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("author", .text).notNull()
                t.column("date_added", .double).notNull()
                t.column("payload_json", .text).notNull()
                t.column("updated_at", .double).notNull()
            }

            try db.create(table: "sessions") { t in
                t.column("id", .text).primaryKey()
                t.column("book_id", .text).notNull()
                    .references("books", onDelete: .cascade)
                t.column("start_time", .double).notNull()
                t.column("end_time", .double)
                t.column("start_page", .integer).notNull()
                t.column("end_page", .integer).notNull()
                t.column("audio_profile_id", .text)
                t.column("payload_json", .text).notNull()
            }
            try db.create(index: "idx_sessions_book", on: "sessions", columns: ["book_id"])
            try db.create(index: "idx_sessions_start", on: "sessions", columns: ["start_time"])

            try db.create(table: "page_times") { t in
                t.column("id", .text).primaryKey()
                t.column("session_id", .text).notNull()
                    .references("sessions", onDelete: .cascade)
                t.column("idx", .integer).notNull()
                t.column("page_number", .integer).notNull()
                t.column("start_time", .double).notNull()
                t.column("end_time", .double)
                t.column("payload_json", .text).notNull()
            }
            try db.create(index: "idx_page_times_session", on: "page_times", columns: ["session_id"])
            try db.create(index: "idx_page_times_start", on: "page_times", columns: ["start_time"])

            try db.create(table: "library_state") { t in
                t.column("key", .text).primaryKey()
                t.column("payload_json", .text).notNull()
            }

            try db.create(table: "collections") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("date_created", .double).notNull()
            }
            try db.create(table: "book_collections") { t in
                t.column("book_id", .text).notNull()
                    .references("books", onDelete: .cascade)
                t.column("collection_id", .text).notNull()
                    .references("collections", onDelete: .cascade)
                t.primaryKey(["book_id", "collection_id"])
            }

            try db.create(table: "notes") { t in
                t.column("id", .text).primaryKey()
                t.column("book_id", .text).notNull()
                    .references("books", onDelete: .cascade)
                t.column("page_number", .integer)
                t.column("text", .text).notNull()
                t.column("tag", .text).notNull()
                t.column("created_at", .double).notNull()
                t.column("modified_at", .double).notNull()
            }
            try db.create(index: "idx_notes_book", on: "notes", columns: ["book_id"])

            try db.create(table: "achievements") { t in
                t.column("id", .text).primaryKey()
                t.column("kind", .text).notNull().unique()
                t.column("earned_at", .double).notNull()
                t.column("book_id", .text)
            }

            try db.create(table: "weather_snapshots") { t in
                t.column("id", .text).primaryKey()
                t.column("timestamp", .double).notNull()
                t.column("session_id", .text)
                t.column("temperature_celsius", .double).notNull()
                t.column("feels_like_celsius", .double).notNull()
                t.column("humidity", .double).notNull()
                t.column("pressure", .double).notNull()
                t.column("cloud_cover", .double).notNull()
                t.column("visibility_km", .double).notNull()
                t.column("wind_speed_kph", .double).notNull()
                t.column("precipitation_mm", .double).notNull()
                t.column("snowfall_mm", .double).notNull()
                t.column("condition", .text).notNull()
                t.column("season", .text).notNull()
                t.column("day_period", .text).notNull()
                t.column("payload_json", .text).notNull()
            }
            try db.create(index: "idx_weather_timestamp", on: "weather_snapshots", columns: ["timestamp"])
            try db.create(index: "idx_weather_session", on: "weather_snapshots", columns: ["session_id"])

            try db.create(table: "audio_profiles") { t in
                t.column("id", .text).primaryKey()
                t.column("session_id", .text)
                t.column("payload_json", .text).notNull()
            }

            try db.create(table: "behavior_events") { t in
                t.column("id", .text).primaryKey()
                t.column("timestamp", .double).notNull()
                t.column("type", .text).notNull()
                t.column("payload_json", .text).notNull()
            }
            try db.create(index: "idx_behavior_timestamp", on: "behavior_events", columns: ["timestamp"])

            try db.create(table: "application_sessions") { t in
                t.column("id", .text).primaryKey()
                t.column("start_time", .double).notNull()
                t.column("end_time", .double)
                t.column("payload_json", .text).notNull()
            }

            try db.create(table: "inactivity_records") { t in
                t.column("id", .text).primaryKey()
                t.column("start_time", .double).notNull()
                t.column("end_time", .double)
                t.column("payload_json", .text).notNull()
            }

            try db.create(table: "device_state_events") { t in
                t.column("id", .text).primaryKey()
                t.column("timestamp", .double).notNull()
                t.column("payload_json", .text).notNull()
            }

            try db.create(table: "meta") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }
        }

        // WP-1.1: annotation highlights/quotes. All columns are nullable so a
        // v1 store migrates with no data change: every pre-P1.1 note keeps its
        // NULL columns until the next save writes them.
        migrator.registerMigration("v2") { db in
            try db.alter(table: "notes") { t in
                t.add(column: "selected_text", .text)
                t.add(column: "color", .text)
                t.add(column: "anchor_json", .text)
            }
        }

        return migrator
    }()

    // MARK: - WP-1.1 anchor helpers

    /// Encode a note's anchor as UTF-8 JSON text for the `anchor_json` column.
    /// JSON text keeps the flat column queryable/inspectable in SQL while
    /// `books.payload_json` remains the authoritative load path.
    static func anchorJSON(for note: BookNote, with encoder: JSONEncoder) throws -> String? {
        guard let anchor = note.anchor else { return nil }
        return String(decoding: try encoder.encode(anchor), as: UTF8.self)
    }

    /// Decode an `anchor_json` column value back into a `BookNoteAnchor`.
    static func decodeAnchor(
        from text: String,
        with decoder: JSONDecoder
    ) throws -> BookNoteAnchor {
        try decoder.decode(BookNoteAnchor.self, from: Data(text.utf8))
    }

    // MARK: - Import / parity source

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Replace the whole library in one transaction. G3A parity path.
    func importLibrary(books: [Book], state: LibraryState) throws {
        let enc = Self.encoder()
        try pool.write { db in
            try db.execute(sql: "DELETE FROM book_collections")
            try db.execute(sql: "DELETE FROM notes")
            try db.execute(sql: "DELETE FROM achievements")
            try db.execute(sql: "DELETE FROM page_times")
            try db.execute(sql: "DELETE FROM sessions")
            try db.execute(sql: "DELETE FROM books")
            try db.execute(sql: "DELETE FROM collections")
            try db.execute(sql: "DELETE FROM library_state")

            let validCollectionIDs = Set(state.collections.map(\.id))
            // Collections must exist before book_collections references them.
            for collection in state.collections {
                try db.execute(
                    sql: "INSERT INTO collections (id, name, date_created) VALUES (?, ?, ?)",
                    arguments: [
                        collection.id.uuidString, collection.name,
                        collection.dateCreated.timeIntervalSince1970,
                    ])
            }

            for book in books {
                let payload = try enc.encode(Self.summary(of: book))
                let payloadString = String(decoding: payload, as: UTF8.self)
                try db.execute(
                    sql: """
                        INSERT INTO books
                        (id, title, author, date_added, payload_json, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        book.id.uuidString, book.title, book.author,
                        book.dateAdded.timeIntervalSince1970, payloadString,
                        Date().timeIntervalSince1970,
                    ])

                for session in book.sessions {
                    let sPayload = try enc.encode(Self.summary(of: session))
                    try db.execute(
                        sql: """
                            INSERT INTO sessions
                            (id, book_id, start_time, end_time, start_page, end_page,
                             audio_profile_id, payload_json)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            session.id.uuidString, book.id.uuidString,
                            session.startTime.timeIntervalSince1970,
                            session.endTime?.timeIntervalSince1970,
                            session.startPage, session.endPage,
                            session.audioContextProfileID?.uuidString,
                            String(decoding: sPayload, as: UTF8.self),
                        ])

                    for (idx, timing) in session.pageTimes.enumerated() {
                        let tPayload = try enc.encode(timing)
                        try db.execute(
                            sql: """
                                INSERT INTO page_times
                                (id, session_id, idx, page_number, start_time, end_time, payload_json)
                                VALUES (?, ?, ?, ?, ?, ?, ?)
                                """,
                            arguments: [
                                timing.id.uuidString, session.id.uuidString, idx,
                                timing.pageNumber,
                                timing.startTime.timeIntervalSince1970,
                                timing.endTime?.timeIntervalSince1970,
                                String(decoding: tPayload, as: UTF8.self),
                            ])
                    }
                }

                for note in book.notes {
                    try db.execute(
                        sql: """
                            INSERT OR REPLACE INTO notes
                            (id, book_id, page_number, text, tag, selected_text,
                             color, anchor_json, created_at, modified_at)
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            note.id.uuidString, book.id.uuidString, note.pageNumber,
                            note.text, note.tag.rawValue,
                            note.selectedText,
                            note.color?.rawValue,
                            try Self.anchorJSON(for: note, with: enc),
                            note.createdAt.timeIntervalSince1970,
                            note.modifiedAt.timeIntervalSince1970,
                        ])
                }

                for collectionID in book.collectionIDs
                    where validCollectionIDs.contains(collectionID) {
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO book_collections (book_id, collection_id) VALUES (?, ?)",
                        arguments: [book.id.uuidString, collectionID.uuidString])
                }
            }

            for achievement in state.earnedAchievements {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO achievements (id, kind, earned_at, book_id)
                        VALUES (?, ?, ?, ?)
                        """,
                    arguments: [
                        achievement.id.uuidString, achievement.kind.rawValue,
                        achievement.earnedAt.timeIntervalSince1970,
                        achievement.relatedBookID?.uuidString,
                    ])
            }

            let stateData = try enc.encode(state)
            try db.execute(
                sql: "INSERT INTO library_state (key, payload_json) VALUES (?, ?)",
                arguments: ["root", String(decoding: stateData, as: UTF8.self)])
        }
    }

    // MARK: - Summary helpers

    private static func summary(of book: Book) -> Book {
        var copy = book
        if copy.cachedSecondsPerPage == nil {
            copy.cachedSecondsPerPage = AnalyticsEngine.readingSpeed(for: book)
        }
        copy.sessions = book.sessions.map { summary(of: $0) }
        return copy
    }

    private static func summary(of session: ReadingSession) -> ReadingSession {
        var copy = session
        if copy.cachedAverageSecondsPerPage == nil {
            copy.cachedAverageSecondsPerPage = copy.averageSecondsPerPage
        }
        copy.pageTimes = []
        return copy
    }

    // MARK: - Write-through summary mode (G3B)

    /// Upsert all books/state without rewriting the 138k page-timing rows that
    /// are already stored. Only sessions that currently carry pageTimes in
    /// memory (the active/current session) replace their page_times rows.
    func saveAll(books: [Book], state: LibraryState) throws {
        let enc = Self.encoder()
        try pool.write { db in
            let liveIDs = Set(books.map(\.id.uuidString))
            let existing = try String.fetchAll(db, sql: "SELECT id FROM books")
            for id in existing where !liveIDs.contains(id) {
                try db.execute(sql: "DELETE FROM books WHERE id = ?", arguments: [id])
            }
            // State first: collections must exist before book_collections.
            try writeState(state, db: db, enc: enc)
            let validCollectionIDs = Set(state.collections.map(\.id))
            for book in books {
                try writeBook(book, db: db, enc: enc,
                              validCollectionIDs: validCollectionIDs)
            }
        }
    }

    private func writeBook(
        _ book: Book,
        db: Database,
        enc: JSONEncoder,
        validCollectionIDs: Set<UUID>
    ) throws {
        // CR-1 finding 6: a payload with two notes sharing an id used to abort
        // the whole library save on the notes primary key. Normalize once
        // here, keeping the last write per id, so the authoritative payload
        // and the flat rows agree and a duplicate costs one note, not the
        // library.
        var book = book
        var seenNoteIDs = Set<UUID>()
        book.notes = book.notes.reversed()
            .filter { seenNoteIDs.insert($0.id).inserted }
            .reversed()
        let payload = try enc.encode(Self.summary(of: book))
        try db.execute(
            sql: """
                INSERT INTO books (id, title, author, date_added, payload_json, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  title=excluded.title, author=excluded.author,
                  date_added=excluded.date_added, payload_json=excluded.payload_json,
                  updated_at=excluded.updated_at
                """,
            arguments: [
                book.id.uuidString, book.title, book.author,
                book.dateAdded.timeIntervalSince1970,
                String(decoding: payload, as: UTF8.self),
                Date().timeIntervalSince1970,
            ])

        let newSessionIDs = Set(book.sessions.map(\.id.uuidString))
        let oldSessionIDs = try String.fetchAll(
            db, sql: "SELECT id FROM sessions WHERE book_id = ?",
            arguments: [book.id.uuidString])
        for old in oldSessionIDs where !newSessionIDs.contains(old) {
            try db.execute(sql: "DELETE FROM sessions WHERE id = ?", arguments: [old])
        }

        for session in book.sessions {
            let sPayload = try enc.encode(Self.summary(of: session))
            try db.execute(
                sql: """
                    INSERT INTO sessions
                    (id, book_id, start_time, end_time, start_page, end_page,
                     audio_profile_id, payload_json)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                      start_time=excluded.start_time, end_time=excluded.end_time,
                      start_page=excluded.start_page, end_page=excluded.end_page,
                      audio_profile_id=excluded.audio_profile_id,
                      payload_json=excluded.payload_json
                    """,
                arguments: [
                    session.id.uuidString, book.id.uuidString,
                    session.startTime.timeIntervalSince1970,
                    session.endTime?.timeIntervalSince1970,
                    session.startPage, session.endPage,
                    session.audioContextProfileID?.uuidString,
                    String(decoding: sPayload, as: UTF8.self),
                ])

            if !session.pageTimes.isEmpty {
                try db.execute(
                    sql: "DELETE FROM page_times WHERE session_id = ?",
                    arguments: [session.id.uuidString])
                for (idx, timing) in session.pageTimes.enumerated() {
                    let tPayload = try enc.encode(timing)
                    try db.execute(
                        sql: """
                            INSERT INTO page_times
                            (id, session_id, idx, page_number, start_time, end_time, payload_json)
                            VALUES (?, ?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [
                            timing.id.uuidString, session.id.uuidString, idx,
                            timing.pageNumber,
                            timing.startTime.timeIntervalSince1970,
                            timing.endTime?.timeIntervalSince1970,
                            String(decoding: tPayload, as: UTF8.self),
                        ])
                }
            }
        }

        try db.execute(sql: "DELETE FROM notes WHERE book_id = ?", arguments: [book.id.uuidString])
        for note in book.notes {
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO notes
                    (id, book_id, page_number, text, tag, selected_text,
                     color, anchor_json, created_at, modified_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    note.id.uuidString, book.id.uuidString, note.pageNumber,
                    note.text, note.tag.rawValue,
                    note.selectedText,
                    note.color?.rawValue,
                    try Self.anchorJSON(for: note, with: enc),
                    note.createdAt.timeIntervalSince1970,
                    note.modifiedAt.timeIntervalSince1970,
                ])
        }

        try db.execute(sql: "DELETE FROM book_collections WHERE book_id = ?",
                       arguments: [book.id.uuidString])
        for collectionID in book.collectionIDs
            where validCollectionIDs.contains(collectionID) {
            try db.execute(
                sql: "INSERT OR IGNORE INTO book_collections (book_id, collection_id) VALUES (?, ?)",
                arguments: [book.id.uuidString, collectionID.uuidString])
        }
    }

    private func writeState(_ state: LibraryState, db: Database, enc: JSONEncoder) throws {
        try db.execute(sql: "DELETE FROM collections")
        for collection in state.collections {
            try db.execute(
                sql: "INSERT INTO collections (id, name, date_created) VALUES (?, ?, ?)",
                arguments: [
                    collection.id.uuidString, collection.name,
                    collection.dateCreated.timeIntervalSince1970,
                ])
        }
        try db.execute(sql: "DELETE FROM achievements")
        for achievement in state.earnedAchievements {
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO achievements (id, kind, earned_at, book_id)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [
                    achievement.id.uuidString, achievement.kind.rawValue,
                    achievement.earnedAt.timeIntervalSince1970,
                    achievement.relatedBookID?.uuidString,
                ])
        }
        let stateData = try enc.encode(state)
        try db.execute(
            sql: """
                INSERT INTO library_state (key, payload_json) VALUES ('root', ?)
                ON CONFLICT(key) DO UPDATE SET payload_json=excluded.payload_json
                """,
            arguments: [String(decoding: stateData, as: UTF8.self)])
    }

    func deleteBook(id: UUID) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM books WHERE id = ?", arguments: [id.uuidString])
        }
    }

    func pageTimings(forSessionID id: UUID) throws -> [PageTiming] {
        let dec = Self.decoder()
        return try pool.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT payload_json FROM page_times WHERE session_id = ? ORDER BY idx",
                arguments: [id.uuidString])
                .compactMap { row -> PageTiming? in
                    let text: String = row["payload_json"]
                    return try? dec.decode(PageTiming.self, from: Data(text.utf8))
                }
        }
    }

    /// G3A parity read: full Book payloads (sessions included), no lazy loading.
    /// Any undecodable row fails the whole load: a partially decoded library
    /// must never be presented as complete (or later persisted over the row).
    func loadBooks() throws -> [Book] {
        let dec = Self.decoder()
        return try pool.read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT id, payload_json FROM books ORDER BY date_added")
            return try rows.map { row in
                let id: String = row["id"]
                let text: String = row["payload_json"]
                do {
                    return try dec.decode(Book.self, from: Data(text.utf8))
                } catch {
                    throw LibraryDatabaseError.undecodableBook(
                        id: id, underlying: String(describing: error))
                }
            }
        }
    }

    /// A missing root row is a legitimate fresh store. A root row that exists
    /// but cannot be decoded is corruption and must not become `LibraryState()`.
    func loadState() throws -> LibraryState {
        let dec = Self.decoder()
        return try pool.read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT payload_json FROM library_state WHERE key = ?", arguments: ["root"])
            else {
                return LibraryState()
            }
            let text: String = row["payload_json"]
            do {
                return try dec.decode(LibraryState.self, from: Data(text.utf8))
            } catch {
                throw LibraryDatabaseError.undecodableLibraryState(
                    underlying: String(describing: error))
            }
        }
    }

    func close() throws {
        try pool.close()
    }

    /// Compatibility name for the one consistent snapshot API. The old
    /// checkpoint-then-copy implementation is intentionally gone: a write that
    /// landed after the checkpoint could be absent from the copied main file.
    @available(*, deprecated, message: "Use makeConsistentSnapshot(to:)")
    @discardableResult
    func backup(to destination: URL) throws -> LibrarySnapshotManifest {
        try makeConsistentSnapshot(to: destination)
    }

    /// True only when no books and no library state exist. Bootstrap uses this
    /// instead of a book count alone so a store holding an unreadable state row
    /// is never treated as empty and replaced by a legacy import.
    func isEmptyStore() throws -> Bool {
        try pool.read { db in
            let books = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM books") ?? 0
            let state = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM library_state") ?? 0
            return books == 0 && state == 0
        }
    }

    func counts() throws -> (books: Int, sessions: Int, pageTimes: Int) {
        try pool.read { db in
            let books = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM books") ?? 0
            let sessions = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sessions") ?? 0
            let pageTimes = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM page_times") ?? 0
            return (books, sessions, pageTimes)
        }
    }

    /// Read-only inspection for a snapshot that already exists on disk.
    static func inspectSnapshot(
        at url: URL,
        fullIntegrity: Bool = false
    ) throws -> LibrarySnapshotInspection {
        let connection = try LibraryReadOnlyConnection(url: url)
        defer { connection.close() }
        return try connection.inspect(fullIntegrity: fullIntegrity)
    }
}
