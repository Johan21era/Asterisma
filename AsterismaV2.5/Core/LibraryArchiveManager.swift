//  LibraryArchiveManager.swift
//  AsterismaV2.5
//
//  P5 / Feature 1 (Data Durability Layer).
//
//  WHY
//  The audit's scalability verdict and the app's own stated goal converge on
//  one fact: years of reading history currently live in two JSON files in a
//  sandbox container, and one dead SSD erases all of it. CloudKit needs a
//  paid dev team + entitlements; this layer delivers the durability VALUE
//  backend-agnostically today:
//
//    • EXPORT — one portable .readingarchive file (JSON: books incl. covers,
//      goals/deadlines/achievements/collections, format version). Human-
//      inspectable, machine-restorable, safe to store anywhere.
//    • IMPORT — full restore with a pre-flight summary; replaces current
//      library only after explicit confirmation.
//    • AUTO-BACKUPS — on every launch, if the library changed since the last
//      snapshot, roll the previous snapshot into a dated backup. Keeps the
//      newest N=10. Runs inside DataStore's existing write path, zero UI.
//
//  Value-level archive by design: fields are copied by value into plain
//  Codable containers, so the format survives future storage-engine changes
//  (Feature 2) untouched.
//
//  SEE IT YOURSELF (non-coder): Analytics ▸ "Export Library…" saves a file;
//  wipe/reinstall the app; Analytics ▸ "Import Library…" picks that file;
//  your whole library — covers, goals, achievements, collections — returns.

import Combine
import Foundation

// MARK: - Archive Format

struct LibraryArchive: Codable {
    /// Bump on any breaking shape change; importer can branch on it forever.
    let formatVersion: Int
    let exportedAt: Date
    let appName: String

    var books: [Book]
    var libraryState: LibraryState?

    /// FINAL TRACES Upgrade #2: since covers moved OUT of the book payload
    /// into CoverStore files, archives carry them explicitly, keyed by book
    /// UUID string. Optional + decodeIfPresent so v1 archives still import.
    var covers: [String: Data]?
}

enum LibraryArchiveError: LocalizedError {
    case emptyLibrary
    case corruptArchive(String)

    var errorDescription: String? {
        switch self {
        case .emptyLibrary:
            return "Nothing to export — your library is empty."
        case .corruptArchive(let detail):
            return "That file isn't a valid AsterismaV2.5 archive: \(detail)"
        }
    }
}

// MARK: - Manager

@MainActor
final class LibraryArchiveManager: ObservableObject {
    static let shared = LibraryArchiveManager()

    static let fileExtension = "readingarchive"
    private static let formatVersion = 1
    private static let maxBackups = 10

    private init() {}

    // MARK: Export

    func exportLibrary(from store: DataStore) throws -> Data {
        guard !store.books.isEmpty else { throw LibraryArchiveError.emptyLibrary }

        // G3C: SQLite summary mode does not hold page timings in memory.
        // Rehydrate them for the archive so exports remain lossless.
        let archiveBooks = store.booksForArchive()

        // Collect covers: prefer external files, fall back to any still-
        // embedded payloads (pre-migration libraries).
        var covers: [String: Data] = [:]
        for book in archiveBooks {
            if let fileData = try? Data(contentsOf: CoverStore.active.url(forBookID: book.id)) {
                covers[book.id.uuidString] = fileData
            } else if let embedded = book.coverImageData {
                covers[book.id.uuidString] = embedded
            }
        }

        let archive = LibraryArchive(
            formatVersion: Self.formatVersion,
            exportedAt: Date(),
            appName: "AsterismaV2.5",
            books: archiveBooks,
            libraryState: store.libraryState,
            covers: covers.isEmpty ? nil : covers
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(archive)
    }

    /// Pre-flight: decode + summarize WITHOUT touching current state.
    func summarize(archiveData: Data) throws -> (bookCount: Int, sessionCount: Int, hasGoals: Bool) {
        do {
            let archive = try Self.decode(data: archiveData)
            let sessions = archive.books.reduce(0) { $0 + $1.sessions.count }
            return (archive.books.count, sessions, archive.libraryState?.goalSet != .empty)
        } catch {
            throw LibraryArchiveError.corruptArchive(error.localizedDescription)
        }
    }

    /// Full restore. Caller confirms first (UI shows the summary above).
    /// Uses DataStore.restoreState(from:state:) so books AND full library
    /// state (goals/deadlines/achievements/collections) land in one go,
    /// with dangling collection references stripped by the store itself.
    func importLibrary(_ data: Data, into store: DataStore) throws {
        let archive = try Self.decode(data: data)
        store.restoreState(
            from: archive.books,
            state: archive.libraryState ?? LibraryState()
        )
        // Restore archived covers into the external store.
        if let covers = archive.covers {
            for (idString, data) in covers {
                if let id = UUID(uuidString: idString) {
                    CoverStore.active.store(data, forBookID: id)
                }
            }
        }
        store.saveImmediately()
    }

    // MARK: - Auto-backup rotation

    /// Called by DataStore after successful loads/saves. Rolls a dated copy of
    /// the CURRENT files into Application Support/Backups/, keeping the newest
    /// `maxBackups`. Cheap: two small copies, only when content actually changed.
    ///
    /// P5 HOTFIX (stall report): converted to a nonisolated STATIC function
    /// so callers can run it on a BACKGROUND task — it previously executed
    /// file-copy I/O synchronously on the main actor during DataStore.init,
    /// stalling launch on slow disks.
    nonisolated static func performAutoBackupIfNeeded(booksURL: URL, stateURL: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: booksURL.path) else { return }

        let backupsDir = booksURL.deletingLastPathComponent()
            .appendingPathComponent("Backups", isDirectory: true)
        try? fm.createDirectory(at: backupsDir, withIntermediateDirectories: true)

        // Change detection: signature of books file mtime+size vs stored marker.
        let marker = backupsDir.appendingPathComponent(".last-backup-signature")

        // Second-resolution mtime alone can't distinguish two writes inside the
        // same second (tests do exactly this); include byte size AND a content
        // hash so identical-content rewrites are skipped but real changes never are.
        let attrs = (try? fm.attributesOfItem(atPath: booksURL.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.stringValue ?? "?"
        var contentHash = "?"
        if let data = try? Data(contentsOf: booksURL) {
            // FNV-1a — cheap, stable, no crypto import needed for change detection.
            var hash: UInt64 = 0xcbf29ce484222325
            for byte in data {
                hash ^= UInt64(byte)
                hash = hash &* 0x100000001b3
            }
            contentHash = String(hash, radix: 16)
        }
        let signature = booksURL.lastPathComponent + "|" + size + "|" + contentHash

        if let existing = try? String(contentsOf: marker, encoding: .utf8),
           existing == signature {
            return // unchanged since last snapshot
        }

        // Second-resolution stamps can collide (two changes inside one second,
        // e.g. rapid saves); uniquify instead of letting copyItem fail.
        var stamp = Self.backupTimestampFormatter.string(from: Date())
        while fm.fileExists(atPath: backupsDir.appendingPathComponent("library-\(stamp).json").path) {
            stamp += "-x"
        }
        let backupFile = backupsDir.appendingPathComponent("library-\(stamp).json")

        do {
            try fm.copyItem(at: booksURL, to: backupFile)
            // State rides along when present.
            if fm.fileExists(atPath: stateURL.path) {
                try? fm.copyItem(
                    at: stateURL,
                    to: backupsDir.appendingPathComponent("library-state-\(stamp).json")
                )
            }
            try signature.write(to: marker, atomically: true, encoding: .utf8)
            pruneOldBackups(in: backupsDir)
        } catch {
            print("[ArchiveManager] auto-backup failed: \(error)")
        }
    }

    private nonisolated static func pruneOldBackups(in dir: URL) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.creationDateKey]
        ) else { return }

        let backups = contents
            .filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("library-") }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return da > db
            }

        guard backups.count > Self.maxBackups else { return }
        for stale in backups.dropFirst(Self.maxBackups) {
            try? fm.removeItem(at: stale)
            // Remove the matching library-state sidecar if present.
            let stateSidecar = stale.deletingLastPathComponent()
                .appendingPathComponent(
                    stale.deletingPathExtension().lastPathComponent
                        .replacingOccurrences(of: "library-", with: "library-state-")
                        + ".json"
                )
            try? fm.removeItem(at: stateSidecar)
        }
    }

    // MARK: - Decode helper

    nonisolated private static func decode(data: Data) throws -> LibraryArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LibraryArchive.self, from: data)
    }

    private static let backupTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f
    }()
}
