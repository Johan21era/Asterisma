import CryptoKit
import Foundation

// PR-5 runtime: one-book import orchestration (ADR-5 + ADR-4 + S10-ES-1).
//
// The flow is the ONLY writer of identity-map entries, and entries are born
// ONLY from a validated real `import_epub` receipt (ADR-5 Decision 3 — never a
// local hashing shortcut). Contract highlights (all source-anchored, M-023):
//   • dispatch payload = {"path": String} alone; IDs are engine-derived;
//   • receipt = {status, units, book_id, edition_id, reused, series_hint[, skipped_documents]};
//   • identical bytes ⇒ reused:true (§36.1) — the flow's idempotent path;
//   • degraded_import (P-028a) ⇒ REFUSED as mapping input (ADR-5 Decision 6);
//   • edition-gone detection via read-only `books_list` inventory absence
//     (ADR-5 Decision 5; the 28-action set has no per-edition read, so absence
//     in the inventory IS the safe not_found equivalent).
//
// Every failure is typed; nothing silently retries (S9-ES-5). The map file is
// written once, at the very end, atomically (ADR-5 Decision 1); the
// `checkCancelled` hook runs before each decisive step, so cancellation leaves
// the stratum untouched (S10-ES-1(e) — cancel-before-commit; an engine-side
// edition created before that point stays Mirage's asset, and re-importing the
// same bytes reuses it under `reused:true`).

nonisolated enum MirageImportOutcome: Sendable, Equatable {
    case linked(entry: MirageIdentityMapEntry, reused: Bool)
    /// P-028a degraded receipt: no mapping is created (ADR-5 Decision 6); the
    /// UI reports that the source file needs repair — the engine refuses it anyway.
    case degradedImport(skippedCount: Int)
    /// Pin-violating receipt or digest cross-check mismatch (fail-closed).
    case invalidReceipt(reason: String)
    /// S10-ES-1(c) failures: referent didn't resolve, vanished, or moved.
    case sourceUnavailable(reason: String)
    case notApplicableFileType(reason: String)
    case mapUnreadable(reason: String)
    /// RT-side stratum persistence fault (nothing written; state intact).
    case mapWriteFailed(reason: String)
    case engineError(MirageWireErrorPayload)
    /// Transport-level failure after the supervisor's bounded ladder was
    /// exhausted (acquireTransport threw permanentDown upward).
    case sidecarUnavailable(reason: String)
    /// Cancel-time honesty (S10-ES-1(e) post-commit disclosure): when the user
    /// cancels at the last hook (after the receipt arrived), the ENGINE HAS
    /// COMMITTED its own analysis — the map wasn't written, but Mirage's stored
    /// work stays (re-importing reuses it, `reused:true`). The UI copy must know
    /// which world the cancel happened in; it must never claim an undo.
    case cancelled(engineCommitted: Bool)
}

nonisolated enum MirageIdentityState: Sendable, Equatable {
    case notImported
    case linked(entry: MirageIdentityMapEntry)
    /// Orphans carry their pinned reason; `sourceChanged` is the drift state
    /// with the explicit re-import offer (ADR-5 Decision 4).
    case orphaned(MirageIdentityMapEntry.OrphanReason)
    case mapUnreadable(reason: String)
    /// The source cannot be hashed right now (missing/moved/failed read).
    /// Fail-closed but NOT auto-orphaned — the file may have simply been moved
    /// (regainable); a hash MISMATCH always orphans with `sourceChanged`.
    case unverifiable(reason: String)
}

nonisolated enum MirageSourceFingerprint {
    /// 1 MiB: few enough syscalls to stay fast, small enough that a 2 GB EPUB
    /// is never resident all at once.
    static let chunkBytes = 1 << 20

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Streams the file through SHA-256. `Data(contentsOf:)` would hold the
    /// whole book in memory for a digest; both the import flow and the status
    /// refresh hash library books, so the streaming form is the smooth one.
    static func sha256Hex(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: chunkBytes) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// S10-ES-1(c): stat fingerprint (size + mtime) taken pre-import, compared after.
nonisolated struct MirageFileStat: Sendable, Equatable {
    let size: Int
    let modified: Date

    static func of(_ url: URL) -> MirageFileStat? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int,
              let modified = attrs[.modificationDate] as? Date
        else { return nil }
        return MirageFileStat(size: size, modified: modified)
    }
}

/// What the flow needs to know about ONE book. Tests inject closures; the app
/// layer injects Book's own resolveURL()/fileType (borrowed referent logic —
/// the flow holds no RT persistence reference by construction).
nonisolated struct MirageImportSource: Sendable {
    let rtBookID: UUID
    let fileTypeIsEpub: Bool
    let resolveURL: @Sendable () -> URL?

    init(rtBookID: UUID, fileTypeIsEpub: Bool, resolveURL: @escaping @Sendable () -> URL?) {
        self.rtBookID = rtBookID
        self.fileTypeIsEpub = fileTypeIsEpub
        self.resolveURL = resolveURL
    }
}

nonisolated struct MirageImportEnvironment: Sendable {
    let store: MirageIdentityMapStore
    /// App glue: acquire the supervisor's transport and wrap it in a client.
    let acquireClient: @Sendable () async throws -> MirageClient

    init(store: MirageIdentityMapStore, acquireClient: @escaping @Sendable () async throws -> MirageClient) {
        self.store = store
        self.acquireClient = acquireClient
    }
}

nonisolated struct MirageImportFlow: Sendable {
    let environment: MirageImportEnvironment

    /// One user-driven import. Returns a typed outcome; the stratum file is
    /// touched only on the final commit path (see S10-ES-1(e) note above).
    func performImport(
        source: MirageImportSource?,
        checkCancelled: @Sendable () async -> Bool = { false }
    ) async -> MirageImportOutcome {
        guard let source else { return .cancelled(engineCommitted: false) }

        // 1 · Stratum state precedes everything (fail-closed degrade door).
        let map: MirageIdentityMapFile
        switch environment.store.load() {
        case .loaded(let m): map = m
        case .unreadable(let reason): return .mapUnreadable(reason: reason)
        }
        if await checkCancelled() { return .cancelled(engineCommitted: false) } // before dispatch

        // 2 · Pre-flight: file-type gate, then referent existence + stat (c).
        guard source.fileTypeIsEpub else {
            return .notApplicableFileType(reason: "only EPUB books can be analyzed with Mirage")
        }
        guard let url = source.resolveURL() else {
            return .sourceUnavailable(reason: "the book's source file could not be located")
        }
        guard let statBefore = MirageFileStat.of(url) else {
            return .sourceUnavailable(reason: "the book's source file is not readable")
        }
        let fingerprint: String
        do { fingerprint = try MirageSourceFingerprint.sha256Hex(fileAt: url) }
        catch { return .sourceUnavailable(reason: "the book's source file could not be read") }
        if await checkCancelled() { return .cancelled(engineCommitted: false) } // before dispatch

        // 3 · One dispatch; the child reads the file (M-023).
        let client: MirageClient
        do { client = try await environment.acquireClient() }
        catch { return .sidecarUnavailable(reason: String(describing: error)) }
        let wireOutcome: MirageClient.Outcome
        do {
            wireOutcome = try await client.perform(
                .importEpub, payload: MirageJSONValue.payload(["path": .string(url.path)]))
        } catch {
            return .sidecarUnavailable(reason: String(describing: error))
        }
        guard case .success(let result) = wireOutcome else {
            if case .engineError(let payload) = wireOutcome { return .engineError(payload) }
            return .invalidReceipt(reason: "unexpected outcome shape")
        }
        if await checkCancelled() { return .cancelled(engineCommitted: true) } // after receipt ⇒ engine committed

        // 4 · Receipt validation against the M-023 pin.
        guard case .object(let fields) = result else {
            return .invalidReceipt(reason: "ok envelope result is not an object")
        }
        guard case .string(let status)? = fields["status"] else {
            return .invalidReceipt(reason: "receipt is missing \"status\"")
        }
        if status == "degraded_import" {
            var skipped = 0
            if case .array(let list)? = fields["skipped_documents"] { skipped = list.count }
            return .degradedImport(skippedCount: skipped) // ADR-5 Decision 6: refused
        }
        guard status == "imported" else {
            return .invalidReceipt(reason: "unexpected receipt status \"\(status)\"")
        }
        guard case .string(let mirageBookID)? = fields["book_id"],
              case .string(let mirageEditionID)? = fields["edition_id"],
              case .bool(let reused)? = fields["reused"] else {
            return .invalidReceipt(reason: "receipt is missing pinned keys")
        }

        // 5 · Digest cross-check: the engine derives edition IDs from the
        // source digest; RT hashed the same bytes it handed over — a suffix
        // mismatch proves the source changed mid-flight (fail closed, no write).
        guard mirageEditionID.hasSuffix(String(fingerprint.prefix(16))) else {
            return .invalidReceipt(
                reason: "receipt edition id does not match the source digest — source changed during import")
        }

        // 6 · Post-stat coherence (S10-ES-1(c)).
        guard MirageFileStat.of(url) == statBefore else {
            return .sourceUnavailable(reason: "the book's source file changed during import")
        }

        // Idempotent short-circuit: the book is already actively mapped to the
        // same edition with a matching fingerprint ⇒ no stratum write at all.

        if await checkCancelled() { return .cancelled(engineCommitted: true) } // commit-adjacent gate
        if let existing = map.activeEntry(for: source.rtBookID),
           existing.mirageEditionID == mirageEditionID,
           existing.sourceFingerprint == fingerprint {
            return .linked(entry: existing, reused: reused)
        }

        // 7 · Commit — the only stratum write (temp file + atomic replace).
        let entry = MirageIdentityMapEntry.fromReceipt(
            rtBookID: source.rtBookID,
            mirageBookID: mirageBookID,
            mirageEditionID: mirageEditionID,
            fingerprint: fingerprint,
            resumeHint: nil,
            createdAt: MirageIdentityMapTime.canonical(Date()))
        do {
            try environment.store.save(map.activating(entry, now: entry.createdAt))
        } catch {
            return .mapWriteFailed(reason: String(describing: error))
        }
        return .linked(entry: entry, reused: reused)
    }

    /// Map-side identity check (no engine contact): ADR-5's fingerprint rules.
    func identityState(for source: MirageImportSource) -> MirageIdentityState {
        switch environment.store.load() {
        case .loaded(let map):
            guard let entry = map.activeEntry(for: source.rtBookID) else { return .notImported }
            guard let url = source.resolveURL() else {
                return .unverifiable(reason: "the book's source file could not be located")
            }
            guard let fingerprint = try? MirageSourceFingerprint.sha256Hex(fileAt: url) else {
                return .unverifiable(reason: "the book's source file could not be read for verification")
            }
            if fingerprint == entry.sourceFingerprint { return .linked(entry: entry) }
            // ADR-5 Decision 4: mismatch ⇒ typed refusal + orphan source-changed.
            do {
                try environment.store.save(
                    map.orphaning(rtBookID: source.rtBookID, reason: .sourceChanged,
                                  now: MirageIdentityMapTime.canonical(Date())))
            } catch {
                return .unverifiable(reason: "identity-map write failed: \(error)")
            }
            return .orphaned(.sourceChanged)
        case .unreadable(let reason):
            return .mapUnreadable(reason: reason)
        }
    }

    /// Engine-side presence check (ADR-5 Decision 5) for a linked book:
    /// absence of the mapped (book, edition) pair in read-only `books_list` IS
    /// the not_found equivalent (no per-edition read exists in the 28-action
    /// set). Transport faults propagate — callers mask via the supervisor's
    /// `engineUnavailable` umbrella, same posture as queries.
    func engineVerifiedIdentityState(
        for source: MirageImportSource,
        client: MirageClient
    ) async throws -> MirageIdentityState {
        try await engineVerifiedIdentityAndInventory(for: source, client: client).identity
    }

    /// PR-6 (ADR-7): the SAME read-only books_list serves BOTH the identity
    /// semantics above AND the matched inventory counts row — exactly ONE wire
    /// exchange per engine-verified status refresh (S10-ES-4 pin-1 discipline:
    /// the only action a status check serves is `books_list`). Row decode is
    /// strictly typed (MirageInventoryEntry): ANY malformed row refuses the
    /// whole list — a shape-tightening over the PR-5 presence scan, fail-closed.
    func engineVerifiedIdentityAndInventory(
        for source: MirageImportSource,
        client: MirageClient
    ) async throws -> (identity: MirageIdentityState, counts: MirageInventoryEntry?) {
        switch environment.store.load() {
        case .loaded(let map):
            guard let entry = map.activeEntry(for: source.rtBookID) else {
                return (.notImported, nil)
            }
            let outcome = try await client.perform(.booksList)
            guard case .success(let result) = outcome else {
                if case .engineError(let payload) = outcome {
                    return (.unverifiable(reason: "books_list refused: \(payload)"), nil)
                }
                return (.unverifiable(reason: "books_list returned an unexpected shape"), nil)
            }
            // Real-engine wire export (verified against MirageV1.0): the list is
            // wrapped — {"books": [...]} — so a service-level list[dict] return
            // does NOT surface bare on the wire.
            guard case .object(let wrapped) = result,
                  case .array(let books)? = wrapped["books"] else {
                return (.unverifiable(reason: "books_list result lacks the books inventory"), nil)
            }
            var decoded: [MirageInventoryEntry] = []
            for row in books {
                guard let typed = MirageInventoryEntry.decode(row) else {
                    return (.unverifiable(reason: "books_list contained an unexpected inventory row"), nil)
                }
                decoded.append(typed)
            }
            let matched = decoded.first { $0.bookID == entry.mirageBookID && $0.editionID == entry.mirageEditionID }
            if matched != nil {
                return (.linked(entry: entry), matched)
            }
            do {
                try environment.store.save(
                    map.orphaning(rtBookID: source.rtBookID, reason: .editionGone,
                                  now: MirageIdentityMapTime.canonical(Date())))
            } catch {
                return (.unverifiable(reason: "identity-map write failed: \(error)"), nil)
            }
            return (.orphaned(.editionGone), nil)
        case .unreadable(let reason):
            return (.mapUnreadable(reason: reason), nil)
        }
    }
}
