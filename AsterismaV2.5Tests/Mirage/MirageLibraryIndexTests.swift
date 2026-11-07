import Foundation
import Testing
@testable import AsterismaV2_5

// ADR-13 pins: one read-only books_list refreshes the whole cached index, the
// strict inventory decode refuses malformed rows, and identity links whose
// edition vanished are reconciled in one atomic map write.

@Suite("Mirage Library Index (ADR-13)", .serialized)
@MainActor
struct MirageLibraryIndexTests {
    private func entry(
        _ rtBookID: UUID,
        book: String,
        edition: String
    ) -> MirageIdentityMapEntry {
        .fromReceipt(
            rtBookID: rtBookID,
            mirageBookID: book,
            mirageEditionID: edition,
            fingerprint: String(repeating: "ab", count: 32),
            resumeHint: nil,
            createdAt: Date(timeIntervalSince1970: 1_770_000_000))
    }

    private func makeFixture() throws -> (URL, MirageIdentityMapStore, MirageLibraryIndexStore, MirageClient, InventoryTransport) {
        let dir = try makeMirageTestTempDir("library-index")
        let identity = MirageIdentityMapStore(
            fileURL: dir.appendingPathComponent("mirage/identity-map.json"))
        let index = MirageLibraryIndexStore(
            fileURL: dir.appendingPathComponent("mirage/library-index.json"))
        let transport = InventoryTransport()
        return (dir, identity, index, MirageClient(transport: transport), transport)
    }

    @Test func oneScanCachesEveryRowAndOrphansMissingEditions() async throws {
        let (dir, identity, indexStore, client, transport) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }

        let kept = entry(UUID(), book: "book_kept", edition: "edition_kept")
        let gone = entry(UUID(), book: "book_gone", edition: "edition_gone")
        try identity.save(
            MirageIdentityMapFile.empty
                .activating(kept, now: kept.createdAt)
                .activating(gone, now: gone.createdAt))

        transport.books = [
            #"{"book_id":"book_kept","edition_id":"edition_kept","units":12,"claims":3,"max_cursor":11,"title":"Kept"}"#,
            #"{"book_id":"book_other","edition_id":"edition_other","units":1,"claims":0,"max_cursor":1}"#,
        ]

        let report = try await MirageLibraryIndex.refresh(
            client: client, identityStore: identity, indexStore: indexStore)

        #expect(report.orphanedCount == 1)
        #expect(report.index.entries.count == 2)
        #expect(report.index.totalUnits == 13)
        #expect(report.index.totalClaims == 3)
        #expect(report.index.entry(bookID: "book_kept", editionID: "edition_kept")?.units == 12)
        #expect(report.index.generatedAt != nil)

        guard case .loaded(let saved) = indexStore.load() else {
            Issue.record("the scan receipt must be persisted")
            return
        }
        #expect(saved == report.index)

        guard case .loaded(let map) = identity.load() else {
            Issue.record("identity map must remain readable")
            return
        }
        #expect(map.activeCount == 1)
        #expect(map.activeEntry(for: kept.rtBookID) != nil)
        let orphan = map.entries.first { $0.rtBookID == gone.rtBookID }
        #expect(orphan?.status == .orphaned)
        #expect(orphan?.orphanedReason == .editionGone)

        // A second identical scan must not churn the map file.
        let mapBytes = try Data(contentsOf: identity.fileURL)
        _ = try await MirageLibraryIndex.refresh(
            client: client, identityStore: identity, indexStore: indexStore)
        #expect(try Data(contentsOf: identity.fileURL) == mapBytes)
    }

    @Test func malformedInventoryRefusesTheWholeScan() async throws {
        let (dir, identity, indexStore, client, transport) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        transport.books = [#"{"book_id":"book_missing_fields"}"#]

        do {
            _ = try await MirageLibraryIndex.refresh(
                client: client, identityStore: identity, indexStore: indexStore)
            Issue.record("a malformed row must refuse the whole inventory")
        } catch let error as MirageLibraryIndexError {
            guard case .unexpectedShape = error else {
                Issue.record("wrong refusal: \(error)")
                return
            }
        }
        #expect(indexStore.load() == .missing, "nothing is cached from a refused scan")
    }

    @Test func absentIndexIsMissingAndWrongSchemaIsUnreadable() throws {
        let dir = try makeMirageTestTempDir("library-index-store")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("mirage/library-index.json")
        let store = MirageLibraryIndexStore(fileURL: url)

        #expect(store.load() == .missing)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        try #"{"schema":"mirage-library-index@9","entries":[]}"#
            .write(to: url, atomically: true, encoding: .utf8)
        guard case .unreadable(let reason) = store.load() else {
            Issue.record("unknown schema must not decode as data")
            return
        }
        #expect(reason.contains("unknown schema"))
    }

    @Test func atomicIndexSaveLeavesOldBytesOnInjectedFailure() throws {
        let dir = try makeMirageTestTempDir("library-index-atomic")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MirageLibraryIndexStore(
            fileURL: dir.appendingPathComponent("mirage/library-index.json"))
        let first = MirageLibraryIndexFile(
            schema: MirageLibraryIndexSchema.identifier,
            generatedAt: Date(timeIntervalSince1970: 1),
            entries: [])
        try store.save(first)
        let before = try Data(contentsOf: store.fileURL)

        struct Injected: Error {}
        do {
            try store.save(MirageLibraryIndexFile(
                schema: MirageLibraryIndexSchema.identifier,
                generatedAt: Date(timeIntervalSince1970: 2),
                entries: [])) { throw Injected() }
            Issue.record("the interruption hook must propagate")
        } catch {}

        #expect(try Data(contentsOf: store.fileURL) == before)
        guard case .loaded(let loaded) = store.load() else {
            Issue.record("old index must remain readable")
            return
        }
        #expect(loaded == first)
    }
}

// MARK: - Fake inventory transport

private final class InventoryTransport: MirageTransport, @unchecked Sendable {
    var books: [String] = []

    func exchange(_ requestLine: Data) async throws -> Data {
        let value = (try? JSONDecoder().decode(MirageJSONValue.self, from: requestLine)) ?? .null
        let id: String
        if let field = value.field("id"), case .string(let text) = field {
            id = text
        } else {
            id = "missing-id"
        }
        let action: String
        if let field = value.field("action"), case .string(let text) = field {
            action = text
        } else {
            action = "unknown"
        }
        guard action == "books_list" else {
            return Data(#"{"ok":false,"id":"\#(id)","error":{"type":"ValidationError","code":"validation_error","status":404,"message":"unexpected action"}}"#.utf8)
        }
        let rows = books.joined(separator: ",")
        return Data(
            #"{"ok":true,"id":"\#(id)","result":{"books":[\#(rows)]}}"#.utf8)
    }
}
