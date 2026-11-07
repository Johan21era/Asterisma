import Foundation
import Testing
@testable import AsterismaV2_0

// ADR-7 (countersigned 2026-10-18) — status surface pins: the books_list
// decode is verbatim against the engine's inventory row (service.py:505-554;
// no invented fields, refusal on missing required keys), engine verification
// consumes exactly ONE read-only books_list per refresh, unmapped books never
// touch the wire, and the A.7 transduction renders RT's read state in RT's own
// words with NO Mirage declaration transmitted.
//
// Fake-transport doctrine holds (no sidecar spawns in unit tests).

@Suite("Mirage Status Surface (PR-6)", .serialized)
@MainActor
struct MirageStatusSurfaceTests {
    // ---- Inventory decode: verbatim keys, fail-closed shapes ----------------

    @Test func decodesRealInventoryRowIncludingNullOptionalKeys() throws {
        let row: MirageJSONValue = .payload([
            "book_id": .string("book_0123456789abcdef"),
            "title": .string("A Drifting Title Guess"),
            "edition_id": .string("edition_0123456789abcdef"),
            "units": .int(311),
            "claims": .int(19),
            "max_cursor": .int(310),
            "first_entity_id": .null,          // engine emits None pre-analysis-book
            "created_at": .string("2026-10-18T20:00:00Z"),
        ])
        let entry = try #require(MirageInventoryEntry.decode(row))
        #expect(entry.bookID == "book_0123456789abcdef")
        #expect(entry.editionID == "edition_0123456789abcdef")
        #expect(entry.units == 311)
        #expect(entry.claims == 19)
        #expect(entry.maxCursor == 310)
        #expect(entry.firstEntityID == nil)
        #expect(entry.title == "A Drifting Title Guess")
    }

    @Test func refusesRowMissingRequiredKeys() {
        let shapeless: MirageJSONValue = .payload([
            "book_id": .string("book_0123456789abcdef"),
            "edition_id": .string("edition_0123456789abcdef"),
        ])
        #expect(MirageInventoryEntry.decode(shapeless) == nil)
    }

    @Test func refusesBareArrayAndUnexpectedWraps() {
        let bareArray: MirageJSONValue = .array([])
        #expect(MirageStatusInventory.decodeBooksListResult(bareArray) == nil)
        let wrongWrap: MirageJSONValue = .payload(["inventory": .array([])])
        #expect(MirageStatusInventory.decodeBooksListResult(wrongWrap) == nil)
    }

    @Test func decodesTheWholeRealWrap() throws {
        let wrapped: MirageJSONValue = .payload([
            "books": .array([
                .payload([
                    "book_id": .string("book_0123456789abcdef"),
                    "edition_id": .string("edition_0123456789abcdef"),
                    "units": .int(12), "claims": .int(3), "max_cursor": .int(11),
                ]),
            ])
        ])
        let books = try #require(MirageStatusInventory.decodeBooksListResult(wrapped))
        #expect(books.count == 1)
        #expect(books.first?.units == 12)
    }

    // ---- Engine verification: ONE books_list, both semantics ---------------

    private struct EngineFixture {
        let dir: URL
        let environment: MirageImportEnvironment
        let client: MirageClient
        let source: MirageImportSource

        var flow: MirageImportFlow { MirageImportFlow(environment: environment) }
    }

    /// Transport that records every action it served, answering books_list with
    /// the given row (or an empty inventory when nil).
    private final class RecordingBooksListTransport: MirageTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var servedActions: [String] = []
        private var inventoryRow: String?

        var actionsServed: [String] {
            lock.lock(); defer { lock.unlock() }
            return servedActions
        }

        init(inventoryRow: String? = nil) {
            self.inventoryRow = inventoryRow
        }

        func setInventoryRow(_ row: String?) {
            lock.lock(); inventoryRow = row; lock.unlock()
        }

        func exchange(_ requestLine: Data) async throws -> Data {
            let value = (try? JSONDecoder().decode(MirageJSONValue.self, from: requestLine)) ?? .null
            var action = ""
            if case .object(let fields) = value,
               case .string(let a)? = fields["action"] { action = a }
            lock.lock(); servedActions.append(action)
            let row = inventoryRow
            inventoryRow = nil
            lock.unlock()
            #expect(action == "books_list")
            guard let marker = value.field("id"), case .string(let id) = marker else {
                Issue.record("request line lacked an id")
                return Data()
            }
            let payload = "{\"ok\":true,\"id\":\"\(id)\",\"result\":{\"books\":[\(row ?? "")]}}"
            return payload.data(using: .utf8)!
        }
    }

    private func makeEngineFixture(
        inventoryRow: String?
    ) throws -> (EngineFixture, RecordingBooksListTransport) {
        let dir = try makeMirageTestTempDir("status-surface")
        let srcURL = dir.appendingPathComponent("source.epub")
        try Data("STATUS FIXTURE EPUB BYTES — MirageStatusSurfaceTests".utf8).write(to: srcURL)
        let transport = RecordingBooksListTransport(inventoryRow: inventoryRow)
        let client = MirageClient(transport: transport, idProvider: { "test-id" })
        let environment = MirageImportEnvironment(
            store: MirageIdentityMapStore(fileURL: dir.appendingPathComponent("mirage/identity-map.json")),
            acquireClient: { client })
        let source = MirageImportSource(rtBookID: UUID(), fileTypeIsEpub: true) { srcURL }
        return (EngineFixture(dir: dir, environment: environment, client: client, source: source),
                transport)
    }

    private func persistActiveEntry(
        _ fixture: EngineFixture,
        edition: String
    ) throws -> MirageIdentityMapEntry {
        let file = fixture.source.resolveURL()!
        let fingerprint = try MirageSourceFingerprint.sha256Hex(fileAt: file)
        let entry = MirageIdentityMapEntry.fromReceipt(
            rtBookID: fixture.source.rtBookID,
            mirageBookID: "book_\(String(fingerprint.prefix(16)))",
            mirageEditionID: edition,
            fingerprint: fingerprint,
            resumeHint: nil,
            createdAt: MirageIdentityMapTime.canonical(Date()))
        try fixture.environment.store.save(
            MirageIdentityMapFile.empty.activating(entry, now: entry.createdAt))
        return entry
    }

    @Test func linkedBookGetsIdentityAndCountsFromOneBooksList() async throws {
        let (fixture, transport) = try makeEngineFixture(inventoryRow: nil)
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let entry = try persistActiveEntry(fixture, edition: "edition_linked0000000")
        // The fixture row carries the ENTRY's receipt-derived IDs verbatim —
        // the presence check matches on BOTH book_id and edition_id.
        transport.setInventoryRow(
            "{\"book_id\":\"\(entry.mirageBookID)\",\"edition_id\":\"\(entry.mirageEditionID)\","
            + "\"units\":77,\"claims\":5,\"max_cursor\":76}")

        let pair = try await fixture.flow.engineVerifiedIdentityAndInventory(
            for: fixture.source, client: fixture.client)
        guard case .linked(let linked) = pair.identity else {
            Issue.record("expected linked identity, got \(pair.identity)"); return
        }
        #expect(linked.mirageEditionID == "edition_linked0000000")
        #expect(pair.counts?.units == 77)
        #expect(pair.counts?.claims == 5)
        // S10-ES-4 pin 1 discipline: the ONLY action served across a whole
        // engine-verified status refresh is the read-only inventory.
        #expect(transport.actionsServed == ["books_list"], "served: \(transport.actionsServed)")
    }

    @Test func absentInventoryRowOrphansAndCarriesNoCounts() async throws {
        let (fixture, transport) = try makeEngineFixture(inventoryRow: nil)
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        _ = try persistActiveEntry(fixture, edition: "edition_gone00000000")

        let pair = try await fixture.flow.engineVerifiedIdentityAndInventory(
            for: fixture.source, client: fixture.client)
        #expect(pair.identity == .orphaned(.editionGone))
        #expect(pair.counts == nil)
        #expect(transport.actionsServed == ["books_list"])
        guard case .loaded(let map) = fixture.environment.store.load() else { return }
        let dead = map.entries.first { $0.mirageEditionID == "edition_gone00000000" }
        #expect(dead?.status == .orphaned && dead?.orphanedReason == .editionGone)
    }

    @Test func unmappedBookNeverTouchesTheWire() async throws {
        let (fixture, transport) = try makeEngineFixture(
            inventoryRow: "{\"book_id\":\"b\",\"edition_id\":\"e\",\"units\":1,\"claims\":1,\"max_cursor\":1}")
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        let status = try await MirageAnalysisStatus.fromEngineVerified(
            flow: fixture.flow, source: fixture.source, client: fixture.client,
            checkCancelled: { false })
        #expect(status.linkState == .notImported)
        #expect(status.channel == .engineVerified)
        #expect(transport.actionsServed.isEmpty,
                "no linked identity ⇒ no wire traffic, ever (ADR-7 Annex A.3)")
    }

    // ---- Local status: map only, zero engine --------------------------------

    @Test func localStatusReadsTheMapWithoutEngineContact() throws {
        let dir = try makeMirageTestTempDir("local-status")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MirageIdentityMapStore(
            fileURL: dir.appendingPathComponent("mirage/identity-map.json"))
        let source = MirageImportSource(rtBookID: UUID(), fileTypeIsEpub: true) { nil }

        // Virgin map (absent file) ⇒ notImported, and NO exception paths taken.
        let virgin = MirageStatusSurface.localStatus(store: store, source: source)
        #expect(virgin.linkState == .notImported)
        #expect(virgin.channel == .localMap)

        // An active entry whose source cannot resolve ⇒ unverifiable (fail
        // closed locally — no engine to consult).
        let entry = MirageIdentityMapEntry.fromReceipt(
            rtBookID: source.rtBookID, mirageBookID: "book_ffffffffffffffff",
            mirageEditionID: "edition_ffffffffffffffff", fingerprint: String(repeating: "ff", count: 32),
            resumeHint: nil, createdAt: MirageIdentityMapTime.canonical(Date()))
        try store.save(MirageIdentityMapFile.empty.activating(entry, now: entry.createdAt))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("nonexistent.epub"))
        let stuck = MirageStatusSurface.localStatus(store: store, source: source)
        guard case .unverifiable = stuck.linkState else {
            Issue.record("expected unverifiable, got \(stuck.linkState)"); return
        }
        #expect(stuck.channel == .localMap)
    }

    // ---- A.7 transduction rendering (RT's own words; nothing transmitted) ---

    @Test func transductionRendersAllThreeRTStatesWithoutMirageWrites() {
        let finished = MirageStatusCopy.readStateLine(
            isCompleted: true, isInProgress: false, currentPage: 240, totalPages: 240)
        #expect(finished.hasPrefix("Read state: you've finished this book in RT."))
        let reading = MirageStatusCopy.readStateLine(
            isCompleted: false, isInProgress: true, currentPage: 77, totalPages: 240)
        #expect(reading.contains("page 77 of 240"))
        let unstarted = MirageStatusCopy.readStateLine(
            isCompleted: false, isInProgress: false, currentPage: 0, totalPages: 240)
        #expect(unstarted.hasPrefix("Read state: you haven't started this book in RT."))
        for line in [finished, reading, unstarted] {
            #expect(line.contains("No state was sent to Mirage."))
        }
        // The table's engine vocabulary stays validated-but-unuseable today:
        // the reading@cursor value is UNPRODUCIBLE (ADR-7 Annex A.2/A.7) — the
        // rendered line never names a Mirage unit cursor.
        #expect(!reading.lowercased().contains("cursor"))
    }

    @Test func countsLineAndNotesCarryProvenanceLabelsAndPinnedHonesty() {
        let counts = MirageInventoryEntry(
            bookID: "book_0123456789abcdef", title: nil,
            editionID: "edition_0123456789abcdef",
            units: 311, claims: 19, maxCursor: 310, firstEntityID: nil, createdAt: nil)
        let line = MirageStatusCopy.countsLine(counts)
        #expect(line?.contains("311") == true && line?.contains("19") == true)
        #expect(line?.contains("engine-attested") == true)
        #expect(line?.contains("read-only") == true)
        #expect(MirageStatusCopy.detailDisabledNote.contains("ADR-7"))
    }

    // ---- Map-only open path: no file read, no hash, no engine --------------

    @Test func mapOnlyStatusNeverResolvesTheSourceFile() throws {
        let dir = try makeMirageTestTempDir("map-only")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MirageIdentityMapStore(
            fileURL: dir.appendingPathComponent("mirage/identity-map.json"))
        let counter = MirageSourceResolutionCounter()
        let source = MirageImportSource(rtBookID: UUID(), fileTypeIsEpub: true) {
            counter.record()
            return nil
        }
        let entry = MirageIdentityMapEntry.fromReceipt(
            rtBookID: source.rtBookID, mirageBookID: "book_map_only",
            mirageEditionID: "edition_map_only",
            fingerprint: String(repeating: "cd", count: 32),
            resumeHint: nil, createdAt: MirageIdentityMapTime.canonical(Date()))
        try store.save(MirageIdentityMapFile.empty.activating(entry, now: entry.createdAt))

        let status = MirageStatusSurface.mapOnlyStatus(store: store, source: source)
        guard case .linked(let linked, let counts) = status.linkState else {
            Issue.record("expected linked from the map alone, got \(status.linkState)"); return
        }
        #expect(linked == entry)
        #expect(counts == nil)
        #expect(counter.count == 0, "opening the sheet must never read the book file")
    }

    @Test func localRefreshHashesOffTheOpenPathAndOrphansSourceChanges() async throws {
        let dir = try makeMirageTestTempDir("local-refresh")
        defer { try? FileManager.default.removeItem(at: dir) }
        let epubURL = dir.appendingPathComponent("local-refresh.epub")
        try Data("LOCAL STATUS FIXTURE v1".utf8).write(to: epubURL)
        let book = Book(title: "Refresh Fixture", author: "Fixture",
                        fileURL: epubURL, fileType: .epub,
                        totalPages: 10, currentPage: 1)
        let store = MirageIdentityMapStore(
            fileURL: dir.appendingPathComponent("mirage/identity-map.json"))
        let fingerprint = try MirageSourceFingerprint.sha256Hex(fileAt: epubURL)
        let entry = MirageIdentityMapEntry.fromReceipt(
            rtBookID: book.id, mirageBookID: "book_refresh",
            mirageEditionID: "edition_refresh", fingerprint: fingerprint,
            resumeHint: nil, createdAt: MirageIdentityMapTime.canonical(Date()))
        try store.save(MirageIdentityMapFile.empty.activating(entry, now: entry.createdAt))

        let source = MirageAppImportMount.importSource(for: book)
        let initial = MirageStatusSurface.mapOnlyStatus(store: store, source: source)
        guard case .linked(let loaded, let counts) = initial.linkState else {
            Issue.record("map-only init should see the link, got \(initial.linkState)"); return
        }
        #expect(loaded == entry)
        #expect(counts == nil)

        let controller = MirageStatusController(
            book: book, localStatus: initial, store: store,
            runner: { _, _ in initial })
        await controller.refreshLocalStatus()
        guard case .linked(_, _) = controller.localStatus.linkState else {
            Issue.record("a matching file must stay linked, got \(controller.localStatus.linkState)")
            return
        }

        try Data("LOCAL STATUS FIXTURE v2 — changed".utf8).write(to: epubURL)
        await controller.refreshLocalStatus()
        guard case .orphaned(let reason) = controller.localStatus.linkState else {
            Issue.record("a changed file must orphan, got \(controller.localStatus.linkState)")
            return
        }
        #expect(reason == MirageIdentityMapEntry.OrphanReason.sourceChanged.rawValue)
    }
}

/// Counts source-resolution attempts so the open path can prove it never
/// touches the file. A lock box keeps the @Sendable closure legal.
private final class MirageSourceResolutionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func record() {
        lock.lock(); calls += 1; lock.unlock()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return calls
    }
}
