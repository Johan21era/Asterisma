import Foundation

// PR-5 runtime: the identity-map stratum (ADR-5, owner-accepted). Own file in the
// mirage/ directory, written ONLY by this feature module — never by the engine,
// never by DataStore/PersistenceWriter/Sentinel (ADR-5 Decision 1). The parent
// app's JSON store is untouched: zero schema movement, zero dependency both ways.
//
// Fail-closed doctrine (ADR-5 Decision 8): unknown schema version or malformed
// entry ⇒ the map degrades to `unreadable` (feature state `mapping-unreadable`)
// rather than guessing. An absent file is the virgin state — loaded as an empty
// map, NOT an error. Nothing here ever invents an `mirageEditionID` (ADR-5
// Decision 3 + playbook ID-SYNTH-9001): entries are born only from a real
// `import_epub` receipt.
//
// Crash-atomic writes (ADR-5 Decision 1): temp file in the same directory first,
// then an atomic replace; `save(interruption:)` exists for the PR-5 interrupt
// injection test (old-or-new, never half-written).

nonisolated enum MirageIdentityMapSchema {
    /// ADR-5 Decision 1, verbatim. A different string on disk ⇒ `unreadable`.
    static let identifier = "mirage-identity-map@1"
}

nonisolated enum MirageIdentityMapTime {
    /// Whole-second canonical timestamps: ISO-8601 storage drops sub-second
    /// precision, so values must be truncated AT CONSTRUCTION — in-memory
    /// entries then equal what an atomic round-trip reads back, and equality
    /// (e.g. the flow's idempotent short-circuit) stays meaningful across the
    /// file boundary.
    static func canonical(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }
}

nonisolated struct MirageIdentityMapEntry: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case active
        case orphaned
    }
    /// Orphan audit reasons (ADR-5 Decisions 2/4/5 + one-active invariant).
    enum OrphanReason: String, Codable, Sendable {
        case sourceChanged = "source-changed"
        case editionGone = "edition-gone"
        case superseded
    }

    let rtBookID: UUID
    let mirageBookID: String
    let mirageEditionID: String
    /// sha256 hex of the EPUB bytes at import time, taken verbatim from the
    /// engine receipt lineage (ADR-5 Decision 3: never a local-only shortcut).
    let sourceFingerprint: String
    /// Optional engine-resolved id from the receipt — diagnostic only (ADR-5).
    let sourceResumeHint: String?
    let createdAt: Date
    let updatedAt: Date
    let status: Status
    /// Nil for `active` entries; a reason is recorded for every orphan.
    let orphanedReason: OrphanReason?

    /// The receipt-derived factory — the ONLY way an active entry may be created
    /// (ADR-5 Decision 3). `status/value` mirrors the receipt's `reused` flag
    /// lineage; the flow validates `degraded_import` before ever calling this.
    static func fromReceipt(
        rtBookID: UUID,
        mirageBookID: String,
        mirageEditionID: String,
        fingerprint: String,
        resumeHint: String?,
        createdAt: Date
    ) -> MirageIdentityMapEntry {
        MirageIdentityMapEntry(
            rtBookID: rtBookID,
            mirageBookID: mirageBookID,
            mirageEditionID: mirageEditionID,
            sourceFingerprint: fingerprint,
            sourceResumeHint: resumeHint,
            createdAt: createdAt,
            updatedAt: createdAt,
            status: .active,
            orphanedReason: nil
        )
    }
}

nonisolated struct MirageIdentityMapFile: Codable, Equatable, Sendable {
    let schema: String
    let entries: [MirageIdentityMapEntry]

    static let empty = MirageIdentityMapFile(schema: MirageIdentityMapSchema.identifier, entries: [])

    /// ADR-5 Decision 2: one `active` per `rtBookID` at a time. Activating a new
    /// entry orphans any prior active for the same book (reason `superseded`).
    func activating(_ fresh: MirageIdentityMapEntry, now: Date) -> MirageIdentityMapFile {
        var entries = entries.map { entry -> MirageIdentityMapEntry in
            guard entry.rtBookID == fresh.rtBookID, entry.status == .active else { return entry }
            return MirageIdentityMapEntry(
                rtBookID: entry.rtBookID,
                mirageBookID: entry.mirageBookID,
                mirageEditionID: entry.mirageEditionID,
                sourceFingerprint: entry.sourceFingerprint,
                sourceResumeHint: entry.sourceResumeHint,
                createdAt: entry.createdAt,
                updatedAt: now,
                status: .orphaned,
                orphanedReason: .superseded
            )
        }
        entries.append(fresh)
        return MirageIdentityMapFile(schema: schema, entries: entries)
    }

    /// ADR-5 Decisions 4/5: the mapped target went missing or changed engine-side
    /// ⇒ the entry is orphaned with the given reason; no auto-cleanup, no repair.
    func orphaning(rtBookID: UUID, reason: MirageIdentityMapEntry.OrphanReason, now: Date) -> MirageIdentityMapFile {
        MirageIdentityMapFile(
            schema: schema,
            entries: entries.map { entry -> MirageIdentityMapEntry in
                guard entry.rtBookID == rtBookID, entry.status == .active else { return entry }
                return MirageIdentityMapEntry(
                    rtBookID: entry.rtBookID,
                    mirageBookID: entry.mirageBookID,
                    mirageEditionID: entry.mirageEditionID,
                    sourceFingerprint: entry.sourceFingerprint,
                    sourceResumeHint: entry.sourceResumeHint,
                    createdAt: entry.createdAt,
                    updatedAt: now,
                    status: .orphaned,
                    orphanedReason: reason
                )
            }
        )
    }

    func activeEntry(for rtBookID: UUID) -> MirageIdentityMapEntry? {
        entries.first { $0.rtBookID == rtBookID && $0.status == .active }
    }

    var activeCount: Int { entries.filter { $0.status == .active }.count }
}

nonisolated enum MirageIdentityMapLoad: Equatable, Sendable {
    /// Absent file ⇒ the virginal empty map (not an error, not degradation).
    case loaded(MirageIdentityMapFile)
    /// Fail-closed degrade (ADR-5 Decision 8): malformed, wrong/unknown schema.
    case unreadable(reason: String)
}

nonisolated struct MirageIdentityMapStore: @unchecked Sendable {
    /// “…/Asterisma/mirage/identity-map.json” under ADR-4 Decision 1's directory.
    /// UNCHECKED SENDABLE (house idiom, mirrors MirageChildChannels): single-lane
    /// by contract — the owning import flow serializes its use; nothing here runs
    /// concurrently in the app.
    let fileURL: URL
    /// RFC3339 timestamps (ADR-5 Decision 1's versioned JSON), sorted keys for a
    /// byte-pinnable document on every write.
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL) {
        self.fileURL = fileURL
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        self.encoder = e
        self.decoder = d
    }

    func load() -> MirageIdentityMapLoad {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .loaded(.empty) }
        guard let data = try? Data(contentsOf: fileURL) else {
            return .unreadable(reason: "map file present but unreadable")
        }
        guard let map = try? decoder.decode(MirageIdentityMapFile.self, from: data) else {
            return .unreadable(reason: "map file did not decode against the pinned schema")
        }
        guard map.schema == MirageIdentityMapSchema.identifier else {
            return .unreadable(reason: "unknown schema \"\(map.schema)\"")
        }
        return .loaded(map)
    }

    /// Atomic save: directory ensured with an existence check (ADR-4 style), the
    /// encoded document staged to a same-directory temp file, `interruption` given
    /// a throw-point BEFORE the rename (the PR-5 contract test injects here), then
    /// an atomic replace. A throw leaves the previous file byte-identical —
    /// old-or-new, never half-written.
    func save(_ map: MirageIdentityMapFile, interruption: (() throws -> Void)? = nil) throws {
        let dir = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        }
        let data = try encoder.encode(map)
        let tmp = dir.appendingPathComponent(fileURL.lastPathComponent + ".tmp-\(UUID().uuidString)")
        do {
            try data.write(to: tmp)
            try interruption?()
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                // First write ever: a plain move inside the same directory is
                // already atomic; `replaceItem` reserves itself for swaps.
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
