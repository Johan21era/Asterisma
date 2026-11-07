import Foundation

// ADR-13 (2026-10-29): the cached library inventory.
//
// The engine's read-only `books_list` is the only library-wide view on the
// wire. Fetching it once per book would scale linearly in round-trips; this
// file spends ONE read for the whole library, keeps the decoded inventory on
// disk, and uses it to reconcile every active identity link in one atomic map
// write. The index is derived data: it is always safe to delete and rebuild by
// an explicit "Scan library" gesture.
//
// Honesty rules:
//   • an absent index is `.missing`, not an empty successful scan;
//   • malformed rows refuse the whole refresh (the strict decode lives in
//     MirageStatusInventory, the same decoder the per-book status uses);
//   • the engine remains the source of truth — the index never invents a book,
//     edition, unit, or claim.

nonisolated enum MirageLibraryIndexSchema {
    static let identifier = "mirage-library-index@1"
}

nonisolated struct MirageLibraryIndexEntry: Codable, Equatable, Sendable {
    let bookID: String
    let editionID: String
    let title: String?
    let units: Int
    let claims: Int
    let maxCursor: Int

    init(_ inventory: MirageInventoryEntry) {
        bookID = inventory.bookID
        editionID = inventory.editionID
        title = inventory.title
        units = inventory.units
        claims = inventory.claims
        maxCursor = inventory.maxCursor
    }
}

nonisolated struct MirageLibraryIndexFile: Codable, Equatable, Sendable {
    let schema: String
    /// Nil means "never scanned"; an empty inventory still carries a date.
    let generatedAt: Date?
    let entries: [MirageLibraryIndexEntry]

    static let empty = MirageLibraryIndexFile(
        schema: MirageLibraryIndexSchema.identifier, generatedAt: nil, entries: [])

    var isScanned: Bool { generatedAt != nil }
    var totalUnits: Int { entries.reduce(0) { $0 + $1.units } }
    var totalClaims: Int { entries.reduce(0) { $0 + $1.claims } }

    func entry(bookID: String, editionID: String) -> MirageLibraryIndexEntry? {
        entries.first { $0.bookID == bookID && $0.editionID == editionID }
    }
}

nonisolated enum MirageLibraryIndexLoad: Equatable, Sendable {
    case missing
    case loaded(MirageLibraryIndexFile)
    case unreadable(reason: String)
}

nonisolated struct MirageLibraryIndexStore: @unchecked Sendable {
    let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL) {
        self.fileURL = fileURL
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        encoder = e
        decoder = d
    }

    func load() -> MirageLibraryIndexLoad {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .missing }
        guard let data = try? Data(contentsOf: fileURL) else {
            return .unreadable(reason: "library index present but unreadable")
        }
        guard let index = try? decoder.decode(MirageLibraryIndexFile.self, from: data) else {
            return .unreadable(reason: "library index did not decode against the pinned schema")
        }
        guard index.schema == MirageLibraryIndexSchema.identifier else {
            return .unreadable(reason: "unknown schema \"\(index.schema)\"")
        }
        return .loaded(index)
    }

    func save(_ index: MirageLibraryIndexFile, interruption: (() throws -> Void)? = nil) throws {
        let dir = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let data = try encoder.encode(index)
        let tmp = dir.appendingPathComponent(fileURL.lastPathComponent + ".tmp-\(UUID().uuidString)")
        do {
            try data.write(to: tmp)
            try interruption?()
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.moveItem(at: tmp, to: fileURL)
            } else {
                try FileManager.default.replaceItem(
                    at: fileURL, withItemAt: tmp, backupItemName: nil,
                    options: [], resultingItemURL: nil)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }
}

nonisolated enum MirageLibraryIndexError: Error, Equatable, Sendable, CustomStringConvertible {
    case engineRefused(String)
    case unexpectedShape(String)
    case indexWriteFailed(String)
    case identityUnreadable(String)
    case identityWriteFailed(String)

    var description: String {
        switch self {
        case .engineRefused(let detail):
            return "Mirage refused the read-only library inventory (Detail: \(detail))"
        case .unexpectedShape(let detail):
            return "Mirage's library inventory did not match the pinned shape (Detail: \(detail))"
        case .indexWriteFailed(let detail):
            return "The library index could not be saved (Detail: \(detail))"
        case .identityUnreadable(let detail):
            return "RT's Mirage link records could not be read safely (Detail: \(detail))"
        case .identityWriteFailed(let detail):
            return "RT could not reconcile the library links (Detail: \(detail))"
        }
    }
}

nonisolated enum MirageLibraryIndex {
    /// ONE read-only `books_list`, one cached index save, one identity-map
    /// reconciliation write. No import, no deletion, no engine mutation.
    static func refresh(
        client: MirageClient,
        identityStore: MirageIdentityMapStore,
        indexStore: MirageLibraryIndexStore,
        now: Date = Date()
    ) async throws -> MirageLibraryScanReport {
        let outcome = try await client.perform(.booksList)
        let result: MirageJSONValue
        switch outcome {
        case .success(let value):
            result = value
        case .engineError(let payload):
            throw MirageLibraryIndexError.engineRefused(String(describing: payload))
        }

        guard let inventory = MirageStatusInventory.decodeBooksListResult(result) else {
            throw MirageLibraryIndexError.unexpectedShape(
                "books_list result lacked the pinned {\"books\": [...]} inventory")
        }

        let generatedAt = MirageIdentityMapTime.canonical(now)
        let present = Set(inventory.map {
            MirageIdentityLinkKey(bookID: $0.bookID, editionID: $0.editionID)
        })

        // Reconcile the identity stratum FIRST. A scan that cannot read RT's
        // link records must leave no half-written cached inventory behind.
        var orphanedCount = 0
        switch identityStore.load() {
        case .loaded(let map):
            let missing = Set(map.entries.compactMap { entry -> UUID? in
                guard entry.status == .active else { return nil }
                let key = MirageIdentityLinkKey(
                    bookID: entry.mirageBookID, editionID: entry.mirageEditionID)
                return present.contains(key) ? nil : entry.rtBookID
            })
            if !missing.isEmpty {
                let reconciled = map.orphaning(
                    rtBookIDs: missing, reason: .editionGone, now: generatedAt)
                do {
                    try identityStore.save(reconciled)
                } catch {
                    throw MirageLibraryIndexError.identityWriteFailed(String(describing: error))
                }
                orphanedCount = missing.count
            }
        case .unreadable(let reason):
            throw MirageLibraryIndexError.identityUnreadable(reason)
        }

        let index = MirageLibraryIndexFile(
            schema: MirageLibraryIndexSchema.identifier,
            generatedAt: generatedAt,
            entries: inventory.map(MirageLibraryIndexEntry.init))
        do {
            try indexStore.save(index)
        } catch {
            throw MirageLibraryIndexError.indexWriteFailed(String(describing: error))
        }

        return MirageLibraryScanReport(index: index, orphanedCount: orphanedCount)
    }
}

/// Engine-side identity key used only for presence reconciliation.
nonisolated struct MirageIdentityLinkKey: Hashable, Sendable {
    let bookID: String
    let editionID: String
}

extension MirageIdentityMapFile {
    /// One atomic transition for every active link whose engine-side edition is
    /// absent from a fresh inventory. Returns `self` unchanged when nothing
    /// matches, so callers can skip a redundant disk write.
    func orphaning(
        rtBookIDs: Set<UUID>,
        reason: MirageIdentityMapEntry.OrphanReason,
        now: Date
    ) -> MirageIdentityMapFile {
        guard !rtBookIDs.isEmpty else { return self }
        return MirageIdentityMapFile(
            schema: schema,
            entries: entries.map { entry -> MirageIdentityMapEntry in
                guard rtBookIDs.contains(entry.rtBookID), entry.status == .active else {
                    return entry
                }
                return MirageIdentityMapEntry(
                    rtBookID: entry.rtBookID,
                    mirageBookID: entry.mirageBookID,
                    mirageEditionID: entry.mirageEditionID,
                    sourceFingerprint: entry.sourceFingerprint,
                    sourceResumeHint: entry.sourceResumeHint,
                    createdAt: entry.createdAt,
                    updatedAt: now,
                    status: .orphaned,
                    orphanedReason: reason)
            })
    }
}

nonisolated enum MirageIdentitySnapshot {
    /// Active links without hashing book files. Used by Settings coverage and
    /// batch planning; unreadable records degrade to an empty set and the
    /// caller renders the honest map-unreadable state separately.
    static func activeBookIDs(store: MirageIdentityMapStore) -> Set<UUID> {
        guard case .loaded(let map) = store.load() else { return [] }
        return Set(map.entries.filter { $0.status == .active }.map(\.rtBookID))
    }
}
