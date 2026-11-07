//  DataStore3.swift
//  AsterismaV2.0
//  UPGRADE LOG (v3)
//    • Added: LibraryState persistence — goals, deadlines, achievements alongside books
//    • Added: Schema version written to disk; migration path for v1→v2→v3
//    • Added: DataIntegrityValidator called on every load before publishing books
//    • Added: Automatic backup to library.json.bak on decode failure (corruption recovery)
//    • Added: Debounced save — multiple rapid updates coalesce into a single write
//    • Fixed: endAllActiveSessions — single batch save instead of N saves for N books
//    • Fixed: updateBook — O(n) scan unchanged but now also dispatches achievement detection
//    • Added: Achievement detection hook — AchievementEngine.detectAll() after significant events
//    • Added: newlyEarnedAchievements @Published so UI can animate badge awards
//    PATCHED: B5 — closeActiveSession closes ALL active PageTiming entries
//    AUDIT:   Task 9/16/17/29 — logging contracts preserved below
//
//  ROADMAP 2.1 (RA-002 / D6) — DISK WRITES MOVED OFF THE MAIN ACTOR
//    • Debounced saves encode ON the main actor (cheap, safe) but WRITE on a
//      background task. Writes are CHAINED (each waits for its predecessor), so
//      two rapid snapshots can never land out of order — the newest data always
//      wins on disk, and failure reporting stays in enqueue order.
//    • saveImmediately() remains a SYNCHRONOUS flush: it drains any queued
//      background write (via semaphore around the detached chain tail) and then
//      blocks briefly to write the current snapshot. Deliberate: the flush path
//      runs at scenePhase .background and in tests, where "the file is on disk
//      when this call returns" is the contract that matters. Only the hot
//      page-turn path got the async treatment.
//    • ROADMAP 2.2 (O-8): urls(for:).first! replaced with a guarded fallback
//      directory; addBook now reports duplicate rejection so the UI can surface it.
//
import Combine
import Foundation

// MARK: - Book file relinking

// MARK: - Note-array mutations (WP-1.4)

/// WP-1.4: pure note-array upsert backing `DataStore.upsertNote`. A note id
/// already present is replaced in place — an edit never mints a new row,
/// which is what keeps edit cycles from orphaning rows; a new id is simply
/// appended. Returns the new array.
func noteArrayByUpserting(_ note: BookNote, into notes: [BookNote]) -> [BookNote] {
    var updated = notes
    if let index = updated.firstIndex(where: { $0.id == note.id }) {
        updated[index] = note
    } else {
        updated.append(note)
    }
    return updated
}

/// WP-1.4: pure note-array delete backing `DataStore.deleteNote`. Removes
/// exactly the notes with the given id — no other element is touched — so
/// a delete can never leave an orphaned row behind. Returns the new array.
func noteArrayByDeleting(id: UUID, from notes: [BookNote]) -> [BookNote] {
    notes.filter { $0.id != id }
}

/// Recoverable failures when a user points a library entry at a new copy of
/// its source file. Every case is a message the UI can show; none are fatal.
enum BookFileRelinkError: LocalizedError {
    case bookNotFound
    case unsupportedType(String)
    case formatMismatch(expected: BookFileType, actual: BookFileType)
    case unreadable(URL)
    case bookmarkCreationFailed(URL, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .bookNotFound:
            return "This book is no longer in your library."
        case let .unsupportedType(ext):
            let suffix = ext.isEmpty ? "That file has no extension." : "Unsupported file type: .\(ext)"
            return "\(suffix) Choose an EPUB or PDF file."
        case let .formatMismatch(expected, actual):
            return "This book is a \(expected.displayName), but you chose a \(actual.displayName). " +
                "Choose a \(expected.displayName) file so the reading position stays accurate."
        case let .unreadable(url):
            return "Asterisma can't read “\(url.lastPathComponent)”. " +
                "Check that the file still exists and that you have permission to open it."
        case let .bookmarkCreationFailed(url, underlying):
            return "Asterisma couldn't save permission to read “\(url.lastPathComponent)”. " +
                "\(underlying.localizedDescription) Try choosing the file again."
        }
    }
}

/// Thread-safe observable store. All mutations happen on the main actor.
@MainActor
final class DataStore: ObservableObject {
    // MARK: - Published State

    @Published private(set) var books: [Book] = []
    @Published private(set) var libraryState: LibraryState = .init()

    /// Newly awarded achievements since the last UI observation.
    @Published private(set) var newlyEarnedAchievements: [EarnedAchievement] = []

    /// AUDIT §1.2 / TECH_DEBT D1: Release-visible persistence status.
    enum PersistenceStatus: Equatable {
        case healthy
        case degraded(String)
    }

    @Published private(set) var persistenceHealth: PersistenceStatus = .healthy

    /// The single product-visible storage fact. Unlike `persistenceHealth`,
    /// this is a state machine that recovery and Sentinel can reason about.
    @Published private(set) var storageCondition: StorageCondition =
        .healthy(engine: .json)

    /// G3B: JSON remains the default until the cutover gate. SQLite mode is
    /// exercised by tests and will become the default at G3C.
    enum StorageEngine: String {
        case json
        case sqlite
    }

    private(set) var storageEngine: StorageEngine = .json
    private var database: LibraryDatabase?
    private var databaseURL: URL?
    private var recoveryFreezeToken: LibraryFreezeToken?
    var isFrozenForRecovery: Bool { recoveryFreezeToken != nil }

    /// G6/E8: the canonical SQLite store for behavior evidence. Nil in JSON mode.
    var behaviorEvidenceDatabase: LibraryDatabase? { database }
    /// Set when the SQLite library could not be fully decoded. Ordinary writes
    /// stay paused so a partial in-memory library can never delete or overwrite
    /// records that still exist in the database.
    private var sqliteLoadFailure: String?
    private let dbWriteQueue = DispatchQueue(
        label: "readingtracker.datastore.sqlite", qos: .utility)

    private var blockedSQLiteSaveMessage: String? {
        guard let sqliteLoadFailure else { return nil }
        return "Saves are paused because the SQLite library could not be fully read " +
            "(\(sqliteLoadFailure)). Existing records were left untouched."
    }

    // MARK: - Private

    private let fileURL: URL
    private let stateURL: URL // separate file for LibraryState (goals/achievements)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Persists AudioContextProfile objects captured by AudioMonitorService.
    let audioProfileStore: AudioProfileStore

    /// Debounce timer: coalesces rapid updates into a single disk write.
    private var saveTimer: Timer?
    private let saveDebounceInterval: TimeInterval = 0.5

    /// FINAL TRACES #5: monotonically increasing library version. Bumped on
    /// every mutation so AnalyticsCache can key/validate cheaply.
    private(set) var analyticsEpoch: UInt64 = 0

    private func bumpEpoch() {
        analyticsEpoch &+= 1
        AnalyticsCache.shared.setEpoch(analyticsEpoch)
    }

    /// ROADMAP 2.1 (D6): tail of the serialized background-write chain.
    /// Each enqueued write awaits its predecessor, guaranteeing on-disk ordering.
    private var pendingWrite: Task<String?, Never>?

    /// Release-safe fact used by Sentinel's app-state probes. The debug-only
    /// text below stays in Debug builds; this boolean always exists.
    private(set) var lastLoadRepairNotePresent = false

    #if DEBUG
    private(set) var consoleLastSaveError: String?
    private(set) var consoleLastLoadRepairNote: String?
    #endif

    // MARK: - Init

    init(fileURL: URL? = nil,
         storageEngine requestedEngine: StorageEngine = .json,
         databaseURL: URL? = nil) {
        // Test/UI-test isolation: a process-scoped store directory overrides
        // Application Support. XCTest hosts get one automatically.
        let testStoreDir = RuntimeEnvironment.isolatedStoreDirectory
        if let testStoreDir {
            RuntimeEnvironment.ensureDirectory(testStoreDir)
        }

        // AUDIT O-8 (roadmap 2.2): was `.first!` — an empty/misbehaving domain
        // lookup crashed launch. Guarded degradation instead.
        let appSupportCandidates = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )
        let appSupportAvailable = !appSupportCandidates.isEmpty
        let appSupport = appSupportCandidates.first

        var degradedDirectoryMessage: String?

        if let appSupport {
            let dir = AppIdentity.dataRootURL()
                ?? appSupport.appendingPathComponent("Asterisma", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            if let url = fileURL {
                self.fileURL = url
                stateURL = url.deletingLastPathComponent()
                    .appendingPathComponent("library-state.json")
                audioProfileStore = AudioProfileStore(
                    directory: url.deletingLastPathComponent()
                )
            } else if let testStoreDir {
                self.fileURL = testStoreDir.appendingPathComponent("library.json")
                stateURL = testStoreDir.appendingPathComponent("library-state.json")
                audioProfileStore = AudioProfileStore(directory: testStoreDir)
            } else {
                self.fileURL = dir.appendingPathComponent("library.json")
                stateURL = dir.appendingPathComponent("library-state.json")
                audioProfileStore = AudioProfileStore(directory: dir)
            }

            // AUDIT §1.2: surface silent sandbox/directory creation failures.
            if !FileManager.default.fileExists(atPath: dir.path) {
                degradedDirectoryMessage =
                    "Data folder could not be created at \(dir.path). " +
                    "Reading progress will not be saved."
            }
        } else {
            // Degraded environment: no Application Support available. Persist to a
            // temporary directory so the session still works, loudly flagged below.
            let fallbackDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("Asterisma-degraded", isDirectory: true)
            try? FileManager.default.createDirectory(at: fallbackDir, withIntermediateDirectories: true)

            if let url = fileURL {
                self.fileURL = url
                stateURL = url.deletingLastPathComponent()
                    .appendingPathComponent("library-state.json")
                audioProfileStore = AudioProfileStore(
                    directory: url.deletingLastPathComponent()
                )
            } else if let testStoreDir {
                self.fileURL = testStoreDir.appendingPathComponent("library.json")
                stateURL = testStoreDir.appendingPathComponent("library-state.json")
                audioProfileStore = AudioProfileStore(directory: testStoreDir)
            } else {
                self.fileURL = fallbackDir.appendingPathComponent("library.json")
                stateURL = fallbackDir.appendingPathComponent("library-state.json")
                audioProfileStore = AudioProfileStore(directory: fallbackDir)
            }

            degradedDirectoryMessage =
                "Application Support is unavailable — data is being stored in a " +
                "temporary location and will not survive a restart."
        }
        _ = appSupportAvailable // documented above via candidates check; kept explicit

        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder.dateDecodingStrategy = .iso8601

        if let message = degradedDirectoryMessage {
            persistenceHealth = .degraded(message)
        }

        if requestedEngine == .sqlite {
            let url = databaseURL
                ?? self.fileURL.deletingLastPathComponent()
                    .appendingPathComponent("library.grdb.sqlite3")
            self.databaseURL = url
            if let db = try? LibraryDatabase(url: url) {
                database = db
                storageEngine = .sqlite
                storageCondition = .healthy(engine: .sqlite)
            } else {
                degradedDirectoryMessage = (degradedDirectoryMessage.map { $0 + " " } ?? "")
                    + "SQLite store could not be opened; using JSON."
                persistenceHealth = .degraded(degradedDirectoryMessage!)
                storageCondition = .degraded(
                    engine: .json,
                    code: "LR-001",
                    message: "The SQLite store could not be opened; the app is using the legacy JSON library.")
            }
        }

        if storageEngine == .sqlite, let database {
            // Only a confirmed-empty store may be bootstrapped: deleting and
            // re-importing over an unreadable state row would lose it.
            let empty = (try? database.isEmptyStore()) ?? false
            if empty, FileManager.default.fileExists(atPath: self.fileURL.path) {
                if !Self.bootstrapSQLite(
                    database: database,
                    booksURL: self.fileURL,
                    stateURL: self.stateURL) {
                    // Never strand the app on an empty DB if the legacy file
                    // cannot be imported. Fall back to the proven JSON path.
                    self.database = nil
                    storageEngine = .json
                    persistenceHealth = .degraded(
                        "SQLite migration failed; using the legacy JSON library. " +
                            "No data was deleted.")
                }
            }
            if storageEngine == .sqlite {
                loadFromDatabase(database)
            } else {
                load()
            }
        } else {
            load()
        }

        // JSON auto-backup is file-copy I/O; SQLite backups are introduced at
        // the cutover gate (VACUUM INTO). Skip the JSON copy in SQLite mode.
        if storageEngine == .json {
            let booksFile = self.fileURL   // qualify: init param shadows the property
            let stateFile = self.stateURL
            Task.detached(priority: .utility) {
                LibraryArchiveManager.performAutoBackupIfNeeded(
                    booksURL: booksFile,
                    stateURL: stateFile
                )
            }
        }

        #if DEBUG
        DeveloperConsoleRegistry.shared.register(self)
        #endif

        // P6: Sentinel read-bridge (probes read published state only).
        SentinelDataBridge.shared.attach(self)
    }

    /// P5 Feature 1: production import path. Replaces books and the FULL
    /// library state (goals, deadlines, earned achievements, collections) in
    /// one persisted transaction-ish sequence. Used by LibraryArchiveManager;
    /// distinct from debug_replaceLibrary (which resets state rather than
    /// restoring it).
    func restoreState(from archiveBooks: [Book], state: LibraryState) {
        // Preserve referential integrity on collection IDs: strip dangling.
        let validCollectionIDs = Set(state.collections.map(\.id))
        var repairedBooks = archiveBooks
        for i in repairedBooks.indices {
            repairedBooks[i].collectionIDs.removeAll { !validCollectionIDs.contains($0) }
        }
        // Drop duplicate collection names by keeping archived ids where possible.
        // An explicit archive restore is a deliberate replacement of the whole
        // library, so it also clears a load-failure save block.
        sqliteLoadFailure = nil
        books = repairedBooks
        libraryState = state
        // G1 migration: archives written by the old award loop may contain
        // duplicate badges. Keep the earliest award per kind.
        let deduped = AchievementEngine.deduplicated(libraryState.earnedAchievements)
        if deduped.removed > 0 {
            libraryState.earnedAchievements = deduped.kept
        }
        scheduleSave()
    }

    // MARK: - Public API — Books

    /// ROADMAP 2.2 (O-8): returns false when the book was rejected as a duplicate
    /// of an existing fileURL, so callers can surface the no-op instead of silence.
    @discardableResult
    func addBook(_ book: Book) -> Bool {
        if books.contains(where: { $0.fileURL == book.fileURL }) {
            return false
        }
        books.append(book)
        scheduleSave()
        detectAchievements()
        return true
    }

    func updateBook(_ book: Book) {
        guard let idx = books.firstIndex(where: { $0.id == book.id }) else {
            print("[DataStore] updateBook: book \(book.id) ('\(book.title)') not found — " +
                "update dropped. This may indicate a stale reference.")
            return
        }
        books[idx] = book
        scheduleSave()
    }

    func removeBook(id: UUID) {
        guard books.contains(where: { $0.id == id }) else { return }
        books.removeAll { $0.id == id }
        CoverStore.active.remove(forBookID: id) // FINAL TRACES #2: no orphans
        scheduleSave()
    }

    func book(id: UUID) -> Book? {
        books.first { $0.id == id }
    }

    // MARK: - Public API — Notes (WP-1.4: the single book.notes mutation path)

    /// WP-1.4: THE single mutation path for `book.notes`. Highlight creation,
    /// note edits, and re-saves all flow through here; the readers and
    /// BookDetailsView call only this and `deleteNote(id:inBook:)`. Nothing
    /// anywhere else appends to or mutates `book.notes` in place, so the
    /// persisted mirror can never diverge from the in-memory array.
    ///
    /// A note id already present is replaced in place (edits never mint
    /// rows); a new id is appended. Returns false when the book does not
    /// exist (the caller drops the note rather than orphaning it).
    @discardableResult
    func upsertNote(_ note: BookNote, inBook bookID: UUID) -> Bool {
        guard let idx = books.firstIndex(where: { $0.id == bookID }) else {
            print("[DataStore] upsertNote: book \(bookID) not found — " +
                "note \(note.id) dropped.")
            return false
        }
        let updated = noteArrayByUpserting(note, into: books[idx].notes)
        guard updated != books[idx].notes else { return true }
        books[idx].notes = updated
        scheduleSave()
        return true
    }

    /// WP-1.4: THE single delete path for a note. Removes exactly the note
    /// with that id and nothing else, so deletion can never leave a row
    /// behind. Returns false when the book or the note does not exist.
    @discardableResult
    func deleteNote(id noteID: UUID, inBook bookID: UUID) -> Bool {
        guard let idx = books.firstIndex(where: { $0.id == bookID }) else {
            print("[DataStore] deleteNote: book \(bookID) not found — " +
                "note \(noteID) delete dropped.")
            return false
        }
        let updated = noteArrayByDeleting(id: noteID, from: books[idx].notes)
        guard updated.count != books[idx].notes.count else { return false }
        books[idx].notes = updated
        scheduleSave()
        return true
    }

    /// Points an existing library entry at a replacement copy of its source
    /// file without touching progress, notes, sessions, or collections. This is
    /// the recovery path for a moved/renamed book: the old URL is only replaced
    /// after the new file is confirmed readable and a security-scoped bookmark
    /// has been created, so a failed relink leaves the entry untouched.
    @discardableResult
    func relinkBookFile(id: UUID, to url: URL) throws -> Book {
        guard var book = book(id: id) else {
            throw BookFileRelinkError.bookNotFound
        }

        let ext = url.pathExtension.lowercased()
        guard let actualType = BookFileType(rawValue: ext) else {
            throw BookFileRelinkError.unsupportedType(ext)
        }
        guard actualType == book.fileType else {
            throw BookFileRelinkError.formatMismatch(
                expected: book.fileType,
                actual: actualType
            )
        }

        let scope = url.startAccessingSecurityScopedResource()
        defer { if scope { url.stopAccessingSecurityScopedResource() } }

        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw BookFileRelinkError.unreadable(url)
        }

        let bookmark: Data
        do {
            bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw BookFileRelinkError.bookmarkCreationFailed(url, underlying: error)
        }

        book.fileURL = url
        book.bookmarkData = bookmark
        updateBook(book)
        return book
    }

    /// G3C: archive export needs the full page-timing rows even in SQLite
    /// summary mode. Explicit archives are allowed to pay this cost.
    /// Sentinel S2: a consistent pre-repair snapshot. Returns false if the
    /// snapshot could not be made; callers must then skip mutation entirely.
    func createSafetySnapshot() -> Bool {
        guard !isFrozenForRecovery else { return false }
        guard storageEngine == .sqlite, let database else {
            // JSON mode retains its existing rotation path.
            LibraryArchiveManager.performAutoBackupIfNeeded(
                booksURL: fileURL, stateURL: stateURL)
            return true
        }
        let dir = fileURL.deletingLastPathComponent()
            .appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let dest = dir.appendingPathComponent(
            "sentinel-pre-repair-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).sqlite3")
        do {
            let manifest = try dbWriteQueue.sync {
                try database.makeConsistentSnapshot(to: dest)
            }
            try LibraryBackupManifestStore.write(manifest, for: dest)
            _ = LibraryBackupCatalog.prune(directory: dir)
            return true
        } catch {
            print("[DataStore] Sentinel safety snapshot failed: \(error)")
            return false
        }
    }

    // MARK: - Recovery host (Phase 0 skeleton)

    func currentStorageCondition() -> StorageCondition {
        storageCondition
    }

    func liveDatabaseURL() -> URL? {
        databaseURL
    }

    func memorySnapshotData() -> Data? {
        let snapshot = LibraryMemorySnapshot(
            schemaVersion: LibraryMemorySnapshot.currentSchemaVersion,
            capturedAt: Date(),
            books: books,
            state: libraryState)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(snapshot)
    }

    /// Drain queued writes, close the only SQLite connection, and publish the
    /// frozen state. The books stay in memory so the UI does not turn into an
    /// empty library while diagnosis runs on a copy.
    func freezeForRecovery(incidentID: String) async throws -> LibraryFreezeToken {
        guard storageEngine == .sqlite else { throw LibraryRecoveryHostError.notSQLite }
        guard recoveryFreezeToken == nil else { throw LibraryRecoveryHostError.alreadyFrozen }
        guard let database, let databaseURL else { throw LibraryRecoveryHostError.noDatabaseURL }

        saveTimer?.invalidate()
        saveTimer = nil

        do {
            try dbWriteQueue.sync { try database.close() }
        } catch {
            throw LibraryRecoveryHostError.closeFailed(error.localizedDescription)
        }

        self.database = nil
        let token = LibraryFreezeToken(
            id: UUID().uuidString,
            incidentID: incidentID,
            engine: .sqlite,
            databasePath: databaseURL.path,
            createdAt: Date())
        recoveryFreezeToken = token
        storageCondition = .recovering(incidentID: incidentID)
        return token
    }

    /// Reopen the live store after recovery. The in-memory library is replaced
    /// only after both books and state decode successfully from the new file.
    func reopenAfterRecovery(token: LibraryFreezeToken) async throws {
        guard let active = recoveryFreezeToken else {
            throw LibraryRecoveryHostError.notFrozen
        }
        guard active == token else { throw LibraryRecoveryHostError.tokenMismatch }
        guard let databaseURL else { throw LibraryRecoveryHostError.noDatabaseURL }

        do {
            let fresh = try LibraryDatabase(url: databaseURL)
            let loadedBooks = try fresh.loadBooks()
            let loadedState = try fresh.loadState()
            database = fresh
            books = loadedBooks
            libraryState = loadedState
            storageEngine = .sqlite
            sqliteLoadFailure = nil
            recoveryFreezeToken = nil
            persistenceHealth = .healthy
            storageCondition = .healthy(engine: .sqlite)
            scheduleSQLiteBackupIfNeeded(fresh)
        } catch {
            storageCondition = .readOnly(
                engine: .sqlite,
                code: "LR-020",
                message: "The recovered store could not be verified; the app remains read-only.")
            throw LibraryRecoveryHostError.reopenFailed(error.localizedDescription)
        }
    }

    /// Checkpoint through the live pool, never through a second connection.
    func performCheckpoint() async -> Bool {
        guard storageEngine == .sqlite,
              !isFrozenForRecovery,
              let database else { return false }
        return await withCheckedContinuation { continuation in
            dbWriteQueue.async {
                do {
                    try database.checkpoint()
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    /// Test teardown only: close the SQLite pool before deleting its temp dir.
    func closeStorageForTesting() {
        guard storageEngine == .sqlite else { return }
        dbWriteQueue.sync { try? database?.close() }
        database = nil
    }

    /// Owner testing: erase the complete app-owned data root and start with a
    /// fresh, empty store. App preferences and window layout are not touched.
    ///
    /// The root contains the SQLite library, JSON artifacts, covers, backups,
    /// weather/audio/behavior records, Sentinel journals, and Mirage's stratum.
    /// Deleting it is the cleanest possible reset; all in-memory caches and
    /// publishers are reset here so the UI cannot show stale objects.
    func eraseAllUserData() throws {
        saveTimer?.invalidate()
        saveTimer = nil
        pendingWrite = nil

        if storageEngine == .sqlite, let database {
            // Drain queued writes before closing the pool.
            dbWriteQueue.sync { try? database.close() }
            self.database = nil
        } else {
            PersistenceWriter.shared.drainSync()
        }

        let root = fileURL.deletingLastPathComponent()
        let fm = FileManager.default
        if fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        books = []
        libraryState = LibraryState()
        newlyEarnedAchievements = []
        sqliteLoadFailure = nil
        persistenceHealth = .healthy
        bumpEpoch()
        AnalyticsCache.shared.invalidate()
        URLCache.shared.removeAllCachedResponses()

        if storageEngine == .sqlite {
            let dbURL = root.appendingPathComponent("library.grdb.sqlite3")
            do {
                let fresh = try LibraryDatabase(url: dbURL)
                database = fresh
                try fresh.saveAll(books: [], state: LibraryState())
            } catch {
                database = nil
                storageEngine = .json
                persistenceHealth = .degraded(
                    "Data was erased, but the fresh SQLite store could not be created: \(error.localizedDescription)")
            }
        }

        if storageEngine == .json {
            saveImmediately()
        }

        CoverStore.active.removeAll()
        audioProfileStore.removeAll()
    }

    func booksForArchive() -> [Book] {
        guard storageEngine == .sqlite, let database else { return books }
        return books.map { book in
            var copy = book
            copy.sessions = book.sessions.map { session in
                var s = session
                s.pageTimes = (try? database.pageTimings(forSessionID: s.id)) ?? []
                return s
            }
            return copy
        }
    }

    // MARK: - Public API — Library State

    func updateGoalSet(_ goalSet: ReadingGoalSet) {
        libraryState.goalSet = goalSet
        saveLibraryState()
    }

    /// Sentinel SG3: the one audited entry point for a whole-state repair.
    /// Callers must have re-read the expected state and verified it matches
    /// before calling; this method validates the new value and persists along
    /// the normal path, never by touching files.
    func updateLibraryState(_ state: LibraryState) {
        var normalized = state
        if normalized.schemaVersion != .current {
            normalized.schemaVersion = .current
        }
        libraryState = normalized
        saveLibraryState()
    }

    func addDeadline(_ deadline: BookDeadline) {
        libraryState.deadlines.removeAll { $0.bookID == deadline.bookID }
        libraryState.deadlines.append(deadline)
        saveLibraryState()
    }

    func removeDeadline(bookID: UUID) {
        libraryState.deadlines.removeAll { $0.bookID == bookID }
        saveLibraryState()
    }

    #if DEBUG
    /// LIVE-TEST LT-8: replaces the entire library in one shot (addBook's
    /// fileURL dedupe would silently block repeat demo installs).
    ///
    /// P6-HOTFIX (freeze report): rapid persona switches (#1 → #2 → #4…)
    /// stacked N pending chained writes of ~100k-timing payloads. Each new
    /// switch INVALIDATES prior queued work and flushes synchronously before
    /// swapping — so back-to-back installs can never interleave half-written
    /// snapshots or queue an unbounded chain.
    func debug_replaceLibrary(with newBooks: [Book]) {
        books = newBooks
        // LT-8 v2: a persona switch is a FULL identity switch — goals, deadlines,
        // earned achievements, and collections reset with the library so two
        // profiles can never blend their histories.
        libraryState = LibraryState()

        detectAchievements() // recompute for the fresh identity

        // P6-HOTFIX v2: encode of ~185k page-timings ON MAIN was itself a
        // multi-second stall during rapid persona hops. Kick ONE immediate
        // chained write: encode happens here (unavoidable snapshot semantics),
        // but the DISK WRITE runs detached in the existing chain — and the
        // debounce coalesces any rapid-fire follow-up swaps behind it.
        scheduleSave()
    }
    #endif

    // MARK: - Public API — Collections (Progressive Filtering model layer)

    @discardableResult
    func addCollection(name: String) -> BookCollection {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let collection = BookCollection(name: trimmed.isEmpty ? "Untitled Collection" : trimmed)
        libraryState.collections.append(collection)
        saveLibraryState()
        return collection
    }

    func renameCollection(id: UUID, to newName: String) {
        guard let idx = libraryState.collections.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        libraryState.collections[idx].name = trimmed
        saveLibraryState()
    }

    /// Removes a collection AND strips its id from every book — referential
    /// integrity, so no Book carries a dangling collectionIDs entry.
    func removeCollection(id: UUID) {
        guard libraryState.collections.contains(where: { $0.id == id }) else { return }
        libraryState.collections.removeAll { $0.id == id }
        var mutated = false
        for i in books.indices where books[i].collectionIDs.contains(id) {
            books[i].collectionIDs.removeAll { $0 == id }
            mutated = true
        }
        if mutated { scheduleSave() }
        saveLibraryState()
    }

    /// Sets one book's membership in one collection.
    func setBook(_ bookID: UUID, membershipIn collectionID: UUID, isMember: Bool) {
        guard let bIdx = books.firstIndex(where: { $0.id == bookID }) else { return }
        if isMember {
            guard !books[bIdx].collectionIDs.contains(collectionID) else { return }
            books[bIdx].collectionIDs.append(collectionID)
        } else {
            guard books[bIdx].collectionIDs.contains(collectionID) else { return }
            books[bIdx].collectionIDs.removeAll { $0 == collectionID }
        }
        scheduleSave()
    }

    func clearNewAchievements() {
        newlyEarnedAchievements = []
    }

    /// AUDIT §2.2: removes a single achievement from the unseen-toast queue
    /// after its toast finished displaying (or was tapped).
    func markAchievementToastShown(id: UUID) {
        newlyEarnedAchievements.removeAll { $0.id == id }
    }

    // MARK: - Public API — Audio Context

    func attachAudioContext(to sessionID: UUID, profile: AudioContextProfile) {
        audioProfileStore.save(profile: profile)

        for i in books.indices {
            for j in books[i].sessions.indices
                where books[i].sessions[j].id == sessionID
            {
                books[i].sessions[j].audioContextProfileID = profile.id
                scheduleSave() // debounced — coalesces with the endSession save
                return
            }
        }
        print("[DataStore] attachAudioContext: session \(sessionID.uuidString.prefix(8)) " +
            "not found — profile saved to store but session reference not updated.")
    }

    func audioContextProfile(for sessionID: UUID) -> AudioContextProfile? {
        audioProfileStore.fetch(sessionID: sessionID)
    }

    func allAudioProfiles() -> [AudioContextProfile] {
        audioProfileStore.fetchAll()
    }

    // MARK: - Session Helpers

    func startSession(bookID: UUID, onPage page: Int) {
        guard var book = book(id: bookID) else { return }

        if let existingID = book.activeSessionID {
            print("[DataStore] Warning: startSession called while session \(existingID) " +
                "is active for book \(bookID) — closing previous session.")
        }

        // G1 FIX: an open session found at startSession is usually a crash
        // survivor. Clamp its end to the last real page activity (plus grace)
        // instead of stamping "now", which turned the crash+idle gap into
        // reading time.
        closeActiveSession(for: &book, clampToLastActivity: true)

        var session = ReadingSession(bookID: bookID, startPage: page, endPage: page)
        let timing = PageTiming(pageNumber: page)
        session.pageTimes = [timing]
        book.sessions.append(session)
        book.activeSessionID = session.id
        book.currentPage = page
        updateBook(book)
    }

    func recordPageTurn(bookID: UUID, newPage: Int) {
        guard var book = book(id: bookID) else { return }
        guard let activeSessionID = book.activeSessionID else { return }
        guard let sIdx = book.sessions.firstIndex(where: { $0.id == activeSessionID }) else { return }

        let now = Date()

        if let pIdx = book.sessions[sIdx].pageTimes.indices.last,
           book.sessions[sIdx].pageTimes[pIdx].isActive
        {
            book.sessions[sIdx].pageTimes[pIdx].endTime = now
        }

        let timing = PageTiming(pageNumber: newPage, startTime: now)
        book.sessions[sIdx].pageTimes.append(timing)
        book.sessions[sIdx].endPage = newPage
        book.currentPage = newPage

        updateBook(book)
    }

    func endSession(bookID: UUID) {
        guard var book = book(id: bookID) else { return }
        closeActiveSession(for: &book)
        updateBook(book)
        detectAchievements()
    }

    /// Batch close — single scheduleSave() call instead of one per book.
    func endAllActiveSessions() {
        var anyChanged = false
        for i in books.indices where books[i].activeSessionID != nil {
            closeActiveSession(for: &books[i])
            anyChanged = true
        }
        if anyChanged {
            scheduleSave()
            detectAchievements()
        }
    }

    // MARK: - Achievement Detection

    private func detectAchievements() {
        let (allEarned, newly) = AchievementEngine.detectAll(
            books: books,
            goalSet: libraryState.goalSet,
            existing: libraryState.earnedAchievements
        )
        if !newly.isEmpty {
            libraryState.earnedAchievements = allEarned
            newlyEarnedAchievements.append(contentsOf: newly)
            saveLibraryState()
        }
    }

    // MARK: - Private Helpers

    /// B5 FIX: Close ALL active PageTiming entries in the session, not just the last.
    /// G1: when `clampToLastActivity` is true (crash-recovery path), end at the
    /// last evidence of activity plus a short grace, never at "now".
    private func closeActiveSession(
        for book: inout Book,
        clampToLastActivity: Bool = false
    ) {
        guard let activeSessionID = book.activeSessionID else { return }
        guard let sIdx = book.sessions.firstIndex(where: { $0.id == activeSessionID }) else { return }

        let now = Date()
        let lastActivity = book.sessions[sIdx].pageTimes
            .compactMap { $0.endTime ?? $0.startTime }
            .max() ?? book.sessions[sIdx].startTime
        let effectiveEnd = clampToLastActivity
            ? min(now, lastActivity.addingTimeInterval(300))
            : now

        for pIdx in book.sessions[sIdx].pageTimes.indices
            where book.sessions[sIdx].pageTimes[pIdx].isActive
        {
            book.sessions[sIdx].pageTimes[pIdx].endTime = effectiveEnd
        }

        book.sessions[sIdx].endTime = effectiveEnd
        book.activeSessionID = nil
    }

    // MARK: - Persistence

    private func load() {
        loadBooks()
        loadLibraryState()
        migrateEmbeddedCoversToFiles()
    }

    /// G3C bootstrap: import legacy JSON/state into an empty SQLite DB.
    /// The JSON files are intentionally left in place until the cutover is
    /// verified; a later launch sees a non-empty DB and will not re-import.
    private static func bootstrapSQLite(
        database: LibraryDatabase,
        booksURL: URL,
        stateURL: URL
    ) -> Bool {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let booksData = try Data(contentsOf: booksURL)
            let books = try decoder.decode([Book].self, from: booksData)
            let state: LibraryState
            if let stateData = try? Data(contentsOf: stateURL) {
                state = (try? decoder.decode(LibraryState.self, from: stateData)) ?? LibraryState()
            } else {
                state = LibraryState()
            }
            try database.importLibrary(books: books, state: state)
            print("[DataStore] Migrated \(books.count) legacy book(s) into SQLite.")
            return true
        } catch {
            print("[DataStore] SQLite bootstrap failed: \(error)")
            return false
        }
    }

    /// G3B: SQLite summary load. Sessions arrive without per-page rows; the
    /// cached speed fields keep analytics exact.
    private func loadFromDatabase(_ db: LibraryDatabase) {
        guard !isFrozenForRecovery else { return }
        do {
            // Decode both halves before publishing either: a state failure must
            // not leave a half-loaded library readable by the UI.
            let loadedBooks = try db.loadBooks()
            let loadedState = try db.loadState()
            books = loadedBooks
            libraryState = loadedState
            sqliteLoadFailure = nil
            storageCondition = .healthy(engine: .sqlite)

            let deduped = AchievementEngine.deduplicated(libraryState.earnedAchievements)
            if deduped.removed > 0 {
                libraryState.earnedAchievements = deduped.kept
                try? db.saveAll(books: books, state: libraryState)
            }

            migrateEmbeddedCoversToFiles()
            scheduleSQLiteBackupIfNeeded(db)
        } catch {
            books = []
            libraryState = LibraryState()
            sqliteLoadFailure = error.localizedDescription
            persistenceHealth = .degraded(
                blockedSQLiteSaveMessage
                    ?? ("SQLite library could not be read. Existing records were left untouched."))
            storageCondition = .readOnly(
                engine: .sqlite,
                code: "LR-002",
                message: "The SQLite library could not be fully read. Saves are paused; existing records were left untouched.")
        }
    }

    /// One consistent SQLite snapshot per day, newest 10 kept. Runs off-main.
    private func scheduleSQLiteBackupIfNeeded(_ db: LibraryDatabase) {
        // Test hosts and UI tests use disposable stores; never spend I/O or
        // race teardown with a backup there.
        guard RuntimeEnvironment.isolatedStoreDirectory == nil else { return }
        let dir = fileURL.deletingLastPathComponent()
            .appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let marker = dir.appendingPathComponent(".last-sqlite-backup")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: marker.path),
           let date = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(date) < 86_400 {
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let dest = dir.appendingPathComponent(
            "library-\(formatter.string(from: Date())).sqlite3")
        Task.detached(priority: .utility) {
            do {
                let manifest = try db.makeConsistentSnapshot(to: dest)
                try LibraryBackupManifestStore.write(manifest, for: dest)
                try? Data().write(to: marker, options: .atomic)
                _ = LibraryBackupCatalog.prune(directory: dir)
            } catch {
                print("[DataStore] SQLite backup failed: \(error)")
            }
        }
    }

    /// FINAL TRACES Upgrade #2: one-time per-book extraction of embedded
    /// cover payloads to the external CoverStore, clearing the payload field
    /// so saves stop carrying image bytes. Idempotent.
    private func migrateEmbeddedCoversToFiles() {
        var migrated = 0
        for i in books.indices where books[i].coverImageData != nil {
            let id = books[i].id
            let data = books[i].coverImageData!
            if CoverStore.active.migrateEmbedded(data, forBookID: id) {
                migrated += 1
            }
            books[i].coverImageData = nil
        }
        if migrated > 0 {
            print("[DataStore] Migrated \(migrated) embedded cover(s) to CoverStore.")
            scheduleSave()
        }
    }

    private func loadBooks() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try decoder.decode([Book].self, from: data)

            let (repaired, report) = DataIntegrityValidator.validate(decoded)
            books = repaired
            lastLoadRepairNotePresent = !report.isClean

            // AUDIT §3.3: never re-persist books that still contain unrepaired
            // errors — surface instead of overwriting the last-good file.
            if report.hasUnrepairableErrors {
                persistenceHealth = .degraded(
                    "Library loaded with unrepaired issues. " +
                        "\(report.summary) Auto-save skipped to protect the existing file."
                )
                lastLoadRepairNotePresent = true
                #if DEBUG
                consoleLastLoadRepairNote = report.summary
                #endif
            } else if !report.isClean {
                lastLoadRepairNotePresent = true
                #if DEBUG
                consoleLastLoadRepairNote = report.summary
                #endif
                save()
            }
        } catch {
            print("[DataStore] Load error at \(fileURL.path): \(error)")
            backupCorruptFile(at: fileURL)
            books = []
            persistenceHealth = .degraded(
                "Library file could not be read and was backed up to library.bak.json. " +
                    "Starting with an empty library — check disk space and permissions."
            )
        }
    }

    private func loadLibraryState() {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return }
        do {
            let data = try Data(contentsOf: stateURL)
            libraryState = try decoder.decode(LibraryState.self, from: data)
            // G1 migration: collapse duplicate achievement records written by
            // the old per-session award loop (one badge per kind, earliest kept).
            let deduped = AchievementEngine.deduplicated(libraryState.earnedAchievements)
            if deduped.removed > 0 {
                libraryState.earnedAchievements = deduped.kept
                saveLibraryState()
                #if DEBUG
                print("[DataStore] Deduplicated \(deduped.removed) stale achievement record(s).")
                #endif
            }
        } catch {
            print("[DataStore] LibraryState load error at \(stateURL.path): \(error)")
            // AUDIT F-04 Gate A: back up the unreadable file BEFORE resetting.
            backupCorruptFile(at: stateURL)
            libraryState = LibraryState()
            let bakName = stateURL.deletingPathExtension()
                .appendingPathExtension("bak.json").lastPathComponent
            persistenceHealth = .degraded(
                "Goals & achievements file could not be read and was backed up to " +
                    bakName + ". Starting fresh — check disk space and permissions."
            )
        }
    }

    /// Debounced save. Multiple rapid calls within 0.5s coalesce into one.
    func scheduleSave() {
        bumpEpoch() // FINAL TRACES #5: any mutation invalidates derived data
        guard !isFrozenForRecovery else { return }
        if let message = blockedSQLiteSaveMessage {
            persistenceHealth = .degraded(message)
            return
        }
        saveTimer?.invalidate()
        let timer = Timer(timeInterval: saveDebounceInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.save()
            }
        }
        // AUDIT §3.1: `.common` mode keeps the debounced save alive during
        // window resize/control tracking.
        RunLoop.main.add(timer, forMode: .common)
        saveTimer = timer
    }

    /// Immediate (non-debounced) save — SYNCHRONOUS by contract.
    ///
    /// ROADMAP 2.1 (D6): drains any queued background write first (so this flush
    /// cannot be overtaken by an older snapshot), then blocks briefly to write
    /// current values. Callers — scenePhase teardown and tests — depend on
    /// "file is on disk when this returns."
    func saveImmediately() {
        saveTimer?.invalidate()
        saveTimer = nil
        guard !isFrozenForRecovery else { return }

        if storageEngine == .sqlite, let database {
            if let message = blockedSQLiteSaveMessage {
                persistenceHealth = .degraded(message)
                return
            }
            let booksSnapshot = books
            let stateSnapshot = libraryState
            do {
                try dbWriteQueue.sync {
                    try database.saveAll(books: booksSnapshot, state: stateSnapshot)
                }
                persistenceHealth = .healthy
                storageCondition = .healthy(engine: .sqlite)
            } catch {
                persistenceHealth = .degraded(
                    "Library could not be saved to SQLite: \(error.localizedDescription)")
                storageCondition = .failed(
                    engine: .sqlite,
                    code: "LR-030",
                    message: "The library could not be saved. Existing records were left untouched.")
                #if DEBUG
                consoleLastSaveError = error.localizedDescription
                #endif
            }
            return
        }

        // FINAL TRACES #4: owned serial queue makes draining a one-liner
        // barrier — no detached-hop semaphore dance.
        if pendingWrite != nil {
            PersistenceWriter.shared.drainSync()
            pendingWrite = nil
        }

        do {
            let data = try encoder.encode(books)
            try data.write(to: fileURL, options: .atomic)
            try encoder.encode(libraryState).write(to: stateURL, options: .atomic)
            persistenceHealth = .healthy
        } catch {
            print("[DataStore] Immediate save error at \(fileURL.path): \(error)")
            persistenceHealth = .degraded("Library could not be saved: \(error.localizedDescription)")
            #if DEBUG
            consoleLastSaveError = error.localizedDescription
            #endif
        }
    }

    /// P6-HOTFIX v3: ENCODING also moved off-main. The snapshot VALUES are
    /// captured synchronously (cheap), but JSONEncoder.encode of a huge books
    /// array (~185k page-timings after a Winter-Romantic-style install) ran
    /// 1-3+ s on main. The encode now happens inside the same detached task as
    /// the write; ordering is still strictly chained.
    private func save() {
        guard !isFrozenForRecovery else { return }
        if storageEngine == .sqlite, let database {
            if let message = blockedSQLiteSaveMessage {
                persistenceHealth = .degraded(message)
                return
            }
            let booksSnapshot = books
            let stateSnapshot = libraryState
            dbWriteQueue.async { [weak self] in
                do {
                    try database.saveAll(books: booksSnapshot, state: stateSnapshot)
                } catch {
                    Task { @MainActor [weak self] in
                        self?.markWriteFailed("\(error)", context: "SQLite library")
                    }
                }
            }
            return
        }

        let booksSnapshot = books   // value copy of the array (COW handles cost)
        let url = fileURL
        enqueueWrite(
            encode: { try Self.sharedJSONEncoder.encode(booksSnapshot) },
            to: url,
            failureContext: "Library"
        )
    }

    private func saveLibraryState() {
        guard !isFrozenForRecovery else { return }
        if storageEngine == .sqlite {
            // SQLite writes books+state together; coalesce through the debounce.
            scheduleSave()
            return
        }
        let stateSnapshot = libraryState
        let url = stateURL
        enqueueWrite(
            encode: { try Self.sharedJSONEncoder.encode(stateSnapshot) },
            to: url,
            failureContext: "Goals & achievements"
        )
    }

    /// Nonisolated shared encoder: date/format config only, no mutable state.
    private nonisolated static let sharedJSONEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    /// Chains encode+write in ONE detached task behind every previously
    /// enqueued one. Strict on-disk ordering preserved.
    private func enqueueWrite(
        encode: @escaping @Sendable () throws -> Data,
        to url: URL,
        failureContext: String
    ) {
        let filePath = url.path

        // FINAL TRACES #4 (safe slice): writes now flow through the owned
        // serial PersistenceWriter actor instead of an ad-hoc detached chain.
        // Same FIFO ordering; a single owned executor that future DB stores
        // can adopt without cross-thread handle issues.
        let write = PersistenceWriter.shared.enqueue(
            encode: encode,
            write: { data in try data.write(to: url, options: .atomic) }
        )
        pendingWrite = write

        // Observe completion on the main actor WITHOUT blocking it.
        Task { [weak self] in
            guard let self else { return }
            if let message = await write.value {
                self.markWriteFailed("\(message) (\(filePath))", context: failureContext)
            } else {
                self.markWriteSucceeded()
            }
        }
    }

    private func markWriteSucceeded() {
        guard !isFrozenForRecovery else { return }
        persistenceHealth = .healthy
        if storageEngine == .sqlite {
            storageCondition = .healthy(engine: .sqlite)
        }
    }

    private func markWriteFailed(_ message: String, context: String) {
        guard !isFrozenForRecovery else { return }
        print("[DataStore] \(context) save error: \(message)")
        persistenceHealth = .degraded("\(context) could not be saved: \(message)")
        storageCondition = .failed(
            engine: storageEngine == .sqlite ? .sqlite : .json,
            code: "LR-031",
            message: "\(context) could not be saved.")
        #if DEBUG
        consoleLastSaveError = message
        #endif
    }

    /// Copies a corrupt file to a .bak sidecar so data isn't silently destroyed.
    private func backupCorruptFile(at url: URL) {
        let bakURL = url.deletingPathExtension().appendingPathExtension("bak.json")
        try? FileManager.default.copyItem(at: url, to: bakURL)
        print("[DataStore] Corrupt file backed up to \(bakURL.path)")
    }
}

// MARK: - Recovery host

extension DataStore: LibraryRecoveryHost {}

// MARK: - Developer Console

#if DEBUG
extension DataStore: DeveloperConsoleObservable {
    static var consoleIdentity: ConsoleSubsystemIdentity {
        ConsoleSubsystemIdentity(
            id: "data-store",
            displayName: "Data Store",
            category: .manager,
            purpose: "Owns the book library and reading-goal state, and is the only thing that reads or writes library.json / library-state.json on disk."
        )
    }

    var consoleSnapshot: ConsoleSubsystemSnapshot {
        var warnings: [String] = []
        var errors: [String] = []
        if let repairNote = consoleLastLoadRepairNote {
            warnings.append("Last load required a repair: \(repairNote)")
        }
        if let saveError = consoleLastSaveError {
            errors.append("Last save failed: \(saveError)")
        }

        return ConsoleSubsystemSnapshot(
            identity: Self.consoleIdentity,
            status: consoleLastSaveError != nil ? .error : (consoleLastLoadRepairNote != nil ? .warning : .healthy),
            currentActivity: "Holding \(books.count) book(s), \(newlyEarnedAchievements.count) unseen achievement toast(s)",
            lastUpdated: Date(),
            warnings: warnings,
            errors: errors,
            metrics: [
                "Books in library": "\(books.count)",
                "Reading goals set": libraryState.goalSet == .empty ? "No" : "Yes",
                "Deadlines tracked": "\(libraryState.deadlines.count)",
                "Earned achievements": "\(libraryState.earnedAchievements.count)",
            ]
        )
    }
}
#endif
