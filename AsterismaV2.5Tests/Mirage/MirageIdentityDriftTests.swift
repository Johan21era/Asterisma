import Foundation
import Testing
@testable import AsterismaV2_5

// ADR-5 named PR-5 suites continue here: drift rules (byte-change ⇒ typed
// refusal + source-changed orphaning; edition-gone ⇒ books_list absence), the
// degraded receipt rejection, and the import-flow case matrix (duplicate,
// missing file, cancel, invalid receipts). Fake-transport doctrine holds: NO
// sidecar spawns in unit tests; receipts are service.py-pinned fixtures.
//
// "RestoreState invariance (ledger + map untouched)" is enforced structurally —
// the flow holds no RT persistence reference (data-layer census gate, M-024) —
// and behaviorally below: every refusal/cancel path leaves the map file absent
// or byte-identical.

// ---- service.py-pinned receipt fixtures (strict keys verbatim, M-023) ------

private func mirageReceiptFixture(
    id: String, fp16: String, reused: Bool, status: String = "imported", skipped: [String] = []
) -> Data {
    var fields = "\"status\":\"\(status)\",\"units\":42,"
        + "\"book_id\":\"book_\(fp16)\",\"edition_id\":\"edition_\(fp16)\","
        + "\"reused\":\(reused),\"series_hint\":null"
    if !skipped.isEmpty {
        let list = skipped.map { "\"\($0)\"" }.joined(separator: ",")
        fields += ",\"skipped_documents\":[\(list)]"
    }
    return "{\"ok\":true,\"id\":\"\(id)\",\"result\":{\(fields)}}".data(using: .utf8)!
}

private func mirageBooksListFixture(id: String, pairs: [(String, String)]) -> Data {
    // Real inventory row shape (MirageV1.0 api/service.py:505-554): every row
    // carries book_id / edition_id / units / claims / max_cursor — PR-6's strict
    // typed decode (fail-closed on missing required keys) pins that verbatim,
    // so the fixture prints the full real row (counts are presence-neutral).
    let items = pairs.map { "{\"book_id\":\"\($0.0)\",\"edition_id\":\"\($0.1)\",\"units\":42,\"claims\":7,\"max_cursor\":41}" }
        .joined(separator: ",")
    // Real wire export shape (probe-verified against MirageV1.0): the inventory
    // arrives wrapped — {"books": [...]} — never a bare array on the wire.
    return "{\"ok\":true,\"id\":\"\(id)\",\"result\":{\"books\":[\(items)]}}".data(using: .utf8)!
}

@Suite("Mirage Identity Drift + Import Flow (PR-5)", .serialized)
@MainActor
struct MirageIdentityDriftTests {
    private struct Fixture {
        let environment: MirageImportEnvironment
        let dir: URL
        let source: MirageImportSource

        var mapFileURL: URL { dir.appendingPathComponent("mirage/identity-map.json") }
        var sourceURL: URL { source.resolveURL() ?? dir.appendingPathComponent("missing.epub") }

        var mapExists: Bool { FileManager.default.fileExists(atPath: mapFileURL.path) }

        var flow: MirageImportFlow { MirageImportFlow(environment: environment) }
    }

    /// Builds the whole test triangle: temp dir, scripted engine (asserting the
    /// `action` name on every inbound request), an EPUB-shaped source file, and
    /// a book source whose resolver points at that file. The responder receives
    /// the source file's URL so fixtures can digest-derive their own IDs without
    /// referencing the (not-yet-existing) fixture variable.
    private func makeFixture(
        _ name: String,
        expectedAction: String,
        respondSource: @escaping @Sendable (URL) throws -> Data
    ) throws -> Fixture {
        let dir = try makeMirageTestTempDir(name)
        let srcURL = dir.appendingPathComponent("source.epub")
        try Data("FAKE EPUB CACHED BYTES — identity flow fixture \(name)".utf8)
            .write(to: srcURL)
        let transport = ScriptedTransport { requestLine in
            let value = (try? JSONDecoder().decode(MirageJSONValue.self, from: requestLine)) ?? .null
            guard case .object(let fields) = value else {
                Issue.record("request line did not decode as an object")
                return Data()
            }
            guard case .string(let action) = fields["action"] ?? .null else {
                Issue.record("request line did not carry an action string")
                return Data()
            }
            #expect(action == expectedAction)
            return try respondSource(srcURL)
        }
        let client = MirageClient(transport: transport, idProvider: { "test-id" })
        let environment = MirageImportEnvironment(
            store: MirageIdentityMapStore(fileURL: dir.appendingPathComponent("mirage/identity-map.json")),
            acquireClient: { client })
        let source = MirageImportSource(rtBookID: UUID(), fileTypeIsEpub: true) { srcURL }
        return Fixture(environment: environment, dir: dir, source: source)
    }

    private func persistActiveEntry(_ fixture: Fixture, fingerprint: String, edition: String) throws {
        let map = MirageIdentityMapFile.empty.activating(
            .fromReceipt(
                rtBookID: fixture.source.rtBookID,
                mirageBookID: "book_\(String(fingerprint.prefix(16)))",
                mirageEditionID: edition,
                fingerprint: fingerprint,
                resumeHint: nil,
                createdAt: Date()),
            now: Date())
        try fixture.environment.store.save(map)
    }

    // ---- ADR-5 Decision 4: byte change ⇒ typed refusal + orphaned ----------

    @Test func bytesChangeOrphansEntryWithSourceChangedAndRefuses() async throws {
        let fixture = try makeFixture("drift-bytechange", expectedAction: "books_list") { _ in
            mirageBooksListFixture(id: "test-id", pairs: []) // never contacted on this path
        }
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        try persistActiveEntry(fixture, fingerprint: String(repeating: "ee", count: 32), edition: "edition_stale")

        // First check: hash mismatch ⇒ orphaned(source-changed) + persistence.
        let state = fixture.flow.identityState(for: fixture.source)
        #expect(state == .orphaned(.sourceChanged))
        guard case .loaded(let map) = fixture.environment.store.load() else {
            Issue.record("expected loaded map"); return
        }
        let dead = map.entries.first { $0.mirageEditionID == "edition_stale" }
        #expect(dead?.status == .orphaned && dead?.orphanedReason == .sourceChanged)

        // Post-orphan re-check: nothing active remains for the book.
        let after = fixture.flow.identityState(for: fixture.source)
        #expect(after == .notImported)
    }

    // ---- ADR-5 Decision 5: engine absence ⇒ edition-gone orphaning ---------

    @Test func editionGoneOrphansViaBooksListAbsence() async throws {
        let fixture = try makeFixture("drift-editiongone", expectedAction: "books_list") { _ in
            mirageBooksListFixture(id: "test-id", pairs: [])
        }
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let fp = try MirageSourceFingerprint.sha256Hex(fileAt: fixture.sourceURL)
        try persistActiveEntry(fixture, fingerprint: fp, edition: "edition_\(String(fp.prefix(16)))")

        let client = try await fixture.environment.acquireClient()
        let state = try await fixture.flow.engineVerifiedIdentityState(for: fixture.source, client: client)
        #expect(state == .orphaned(.editionGone))
        guard case .loaded(let map) = fixture.environment.store.load() else {
            Issue.record("expected loaded map"); return
        }
        let dead = map.entries.first { $0.status == .orphaned }
        #expect(dead?.orphanedReason == .editionGone)
    }

    @Test func presentEditionKeepsActiveLinkInPositiveControl() async throws {
        let fixture = try makeFixture("drift-present", expectedAction: "books_list") { src in
            let fp = try MirageSourceFingerprint.sha256Hex(fileAt: src)
            return mirageBooksListFixture(id: "test-id", pairs: [
                ("book_\(String(fp.prefix(16)))", "edition_\(String(fp.prefix(16)))"),
            ])
        }
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let fp = try MirageSourceFingerprint.sha256Hex(fileAt: fixture.sourceURL)
        try persistActiveEntry(fixture, fingerprint: fp, edition: "edition_\(String(fp.prefix(16)))")

        let client = try await fixture.environment.acquireClient()
        let state = try await fixture.flow.engineVerifiedIdentityState(for: fixture.source, client: client)
        guard case .linked(let entry) = state else {
            Issue.record("expected linked, got \(state)"); return
        }
        #expect(entry.sourceFingerprint == fp)
    }

    // ---- ADR-5 Decision 6: degraded receipts never map ----------------------

    @Test func degradedReceiptIsRefusedAndMapsNothing() async throws {
        let fixture = try makeFixture("drift-degraded", expectedAction: "import_epub") { _ in
            mirageReceiptFixture(id: "test-id", fp16: "deadbeefdeadbeef", reused: false,
                                 status: "degraded_import", skipped: ["malformed spine 3"])
        }
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let outcome = await fixture.flow.performImport(source: fixture.source)
        guard case .degradedImport(let skipped) = outcome else {
            Issue.record("expected degradedImport, got \(outcome)"); return
        }
        #expect(skipped == 1)
        #expect(!fixture.mapExists) // no mapping input from a degraded receipt
    }

    // ---- Import-flow case matrix -------------------------------------------

    @Test func freshImportPersistsEntryAndRoundTrips() async throws {
        let fixture = try makeFixture("flow-fresh", expectedAction: "import_epub") { src in
            let fp = try MirageSourceFingerprint.sha256Hex(fileAt: src)
            return mirageReceiptFixture(id: "test-id", fp16: String(fp.prefix(16)), reused: false)
        }
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let outcome = await fixture.flow.performImport(source: fixture.source)
        guard case .linked(let entry, let reused) = outcome else {
            Issue.record("expected linked, got \(outcome)"); return
        }
        #expect(reused == false)
        let fp = try MirageSourceFingerprint.sha256Hex(fileAt: fixture.sourceURL)
        #expect(entry.rtBookID == fixture.source.rtBookID)
        #expect(entry.mirageEditionID == "edition_\(String(fp.prefix(16)))")
        #expect(entry.mirageBookID == "book_\(String(fp.prefix(16)))")
        #expect(entry.sourceFingerprint == fp) // full 64-char digest, not the id suffix
        #expect(entry.status == .active)
        #expect(entry.orphanedReason == nil)

        guard case .loaded(let map) = fixture.environment.store.load() else {
            Issue.record("expected loaded map"); return
        }
        #expect(map.activeEntry(for: fixture.source.rtBookID)?.sourceFingerprint == fp)
    }

    @Test func duplicateImportIsIdempotentWithoutAnotherWrite() async throws {
        let fixture = try makeFixture("flow-duplicate", expectedAction: "import_epub") { src in
            let fp = try MirageSourceFingerprint.sha256Hex(fileAt: src)
            return mirageReceiptFixture(id: "test-id", fp16: String(fp.prefix(16)), reused: true)
        }
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        guard case .linked(let first, _) = await fixture.flow.performImport(source: fixture.source) else {
            Issue.record("expected first linked"); return
        }
        let bytesBefore = try Data(contentsOf: fixture.mapFileURL)

        // Same bytes again: engine says reused:true; RT must NOT append or
        // supersede — the live entry IS the mapping (engine memory untouched).
        guard case .linked(let again, let reused) = await fixture.flow.performImport(source: fixture.source) else {
            Issue.record("expected second linked"); return
        }
        #expect(reused == true)
        #expect(again == first)
        let bytesAfter = try Data(contentsOf: fixture.mapFileURL)
        #expect(bytesAfter == bytesBefore)
        guard case .loaded(let map) = fixture.environment.store.load() else {
            Issue.record("expected loaded map"); return
        }
        #expect(map.entries.count == 1)
    }

    @Test func missingSourceIsTypedAndWritesNothing() async throws {
        let fixture = try makeFixture("flow-missingsrc", expectedAction: "import_epub") { _ in
            Data() // unreachable
        }
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        // A mapping must exist first — `unverifiable` is the state of a LINKED
        // book whose source can't be hashed; an unmapped book is `notImported`
        // regardless of the file (ADR-5 wording).
        let fp = try MirageSourceFingerprint.sha256Hex(fileAt: fixture.sourceURL)
        try persistActiveEntry(fixture, fingerprint: fp, edition: "edition_\(String(fp.prefix(16)))")
        let missing = MirageImportSource(rtBookID: fixture.source.rtBookID, fileTypeIsEpub: true) { nil }

        // Import path with the referent gone mid-flow: typed, no stratum write.
        let outcome = await fixture.flow.performImport(source: missing)
        guard case .sourceUnavailable = outcome else {
            Issue.record("expected sourceUnavailable, got \(outcome)"); return
        }

        // Read path: fail-closed but regainable — NOT auto-orphaned.
        let state = fixture.flow.identityState(for: missing)
        guard case .unverifiable = state else {
            Issue.record("expected unverifiable, got \(state)"); return
        }
        guard case .loaded(let map) = fixture.environment.store.load() else {
            Issue.record("expected loaded map"); return
        }
        #expect(map.activeEntry(for: fixture.source.rtBookID) != nil) // still mapped
    }

    @Test func cancelBeforeCommitLeavesStratumUntouched() async throws {
        let fixture = try makeFixture("flow-cancel", expectedAction: "import_epub") { _ in
            Data() // unreachable: the cancel hook fires before any dispatch
        }
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let outcome = await fixture.flow.performImport(source: fixture.source, checkCancelled: { true })
        guard case .cancelled(let engineCommitted) = outcome else {
            Issue.record("expected cancelled, got \(outcome)"); return
        }
        // First hook fires pre-dispatch: the engine never heard the request.
        #expect(engineCommitted == false)
        #expect(!fixture.mapExists)
    }

    @Test func digestMismatchRefusesSilentMapping() async throws {
        let fixture = try makeFixture("flow-digestmismatch", expectedAction: "import_epub") { _ in
            mirageReceiptFixture(id: "test-id", fp16: "0000000000000000", reused: false) // wrong lineage
        }
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let outcome = await fixture.flow.performImport(source: fixture.source)
        guard case .invalidReceipt(let reason) = outcome else {
            Issue.record("expected invalidReceipt, got \(outcome)"); return
        }
        #expect(reason.contains("does not match"))
        #expect(!fixture.mapExists) // fail closed: source changed mid-flight
    }

    @Test func mapUnreadableBlocksImportFailClosed() async throws {
        let fixture = try makeFixture("flow-unreadable", expectedAction: "import_epub") { _ in
            Data() // unreachable
        }
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        // The mirage/ directory exists only after a first save; create it as the
        // scenario owner would observe it (hand-deleted ledger + a broken map).
        try FileManager.default.createDirectory(
            at: fixture.mapFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try "{ not a map".write(to: fixture.mapFileURL, atomically: true, encoding: .utf8)
        let outcome = await fixture.flow.performImport(source: fixture.source)
        guard case .mapUnreadable = outcome else {
            Issue.record("expected mapUnreadable, got \(outcome)"); return
        }
    }

    @Test func nonEpubBookIsTypedNotApplicable() async throws {
        let fixture = try makeFixture("flow-pdf", expectedAction: "import_epub") { _ in
            Data() // unreachable
        }
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        let pdf = MirageImportSource(rtBookID: fixture.source.rtBookID, fileTypeIsEpub: false) {
            fixture.sourceURL
        }
        let outcome = await fixture.flow.performImport(source: pdf)
        guard case .notApplicableFileType = outcome else {
            Issue.record("expected notApplicableFileType, got \(outcome)"); return
        }
        #expect(!fixture.mapExists)
    }
}
