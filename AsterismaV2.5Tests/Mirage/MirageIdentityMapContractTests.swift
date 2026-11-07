import Foundation
import Testing
@testable import AsterismaV2_5

// ADR-5 committed contract tests (PR-5): schema pin, one-active-per-book
// invariant, crash-atomic writes under interrupt injection, fail-closed
// degradation on unknown schema / malformed entries. Serialized: the store is
// single-lane by contract; concurrency is exercised by explicit code paths.

@Suite("Mirage Identity Map Contract (PR-5)", .serialized)
@MainActor
struct MirageIdentityMapContractTests {
    private func makeStore(_ name: String, file: String = "identity-map.json") throws -> (MirageIdentityMapStore, URL) {
        let dir = try makeMirageTestTempDir(name)
        let url = dir.appendingPathComponent(file)
        return (MirageIdentityMapStore(fileURL: url), dir)
    }

    private func receiptEntry(
        _ fingerprint: String, book: String = "book_abcdef0123456789",
        edition: String = "edition_abcdef0123456789"
    ) -> MirageIdentityMapEntry {
        .fromReceipt(
            rtBookID: UUID(),
            mirageBookID: book,
            mirageEditionID: edition,
            fingerprint: fingerprint,
            resumeHint: nil,
            createdAt: Date(timeIntervalSince1970: 1_770_000_000)
        )
    }

    @Test func schemaPinRoundTripHoldsADRPinnedShape() async throws {
        let (store, dir) = try makeStore("idmap-roundtrip")
        defer { try? FileManager.default.removeItem(at: dir) }
        let entry = receiptEntry(String(repeating: "ab", count: 32))
        let map = MirageIdentityMapFile.empty.activating(entry, now: entry.createdAt)
        try store.save(map)

        // Raw document is byte-pinnable: schema verbatim, ADR-5 field names
        // present, active entries carry no orphan field.
        let raw = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(raw.contains("\"schema\" : \"mirage-identity-map@1\""))
        for pinned in ["rtBookID", "mirageBookID", "mirageEditionID", "sourceFingerprint", "createdAt", "updatedAt", "status"] {
            #expect(raw.contains("\"\(pinned)\" : "))
        }
        #expect(!raw.contains("orphanedReason")) // active ⇒ nil ⇒ omitted
        #expect(!raw.contains(".tmp-")) // no debris

        // Lossless round trip.
        guard case .loaded(let loaded) = store.load() else { Issue.record("expected loaded"); return }
        #expect(loaded == map)
        #expect(loaded.activeCount == 1)
    }

    @Test func oneActiveInvariantSupersedesPriorEntry() async throws {
        let (store, dir) = try makeStore("idmap-oneactive")
        defer { try? FileManager.default.removeItem(at: dir) }
        let book = UUID()
        let v1 = MirageIdentityMapEntry(
            rtBookID: book, mirageBookID: "book_v1", mirageEditionID: "edition_v1",
            sourceFingerprint: String(repeating: "aa", count: 32), sourceResumeHint: nil,
            createdAt: Date(), updatedAt: Date(), status: .active, orphanedReason: nil)
        let v2 = receiptEntry(String(repeating: "bb", count: 32)).letBookID(book)

        let step1 = MirageIdentityMapFile.empty.activating(v1, now: Date())
        try store.save(step1)
        let supersededTime = Date(timeIntervalSince1970: 1_770_000_500)
        let step2 = step1.activating(v2, now: supersededTime)
        try store.save(step2)

        #expect(step2.activeCount == 1)
        guard case .loaded(let loaded) = store.load() else { Issue.record("expected loaded"); return }
        let prior = loaded.entries.first { $0.mirageEditionID == "edition_v1" }
        #expect(prior?.status == .orphaned && prior?.orphanedReason == .superseded)
        #expect(loaded.activeEntry(for: book)?.mirageEditionID == v2.mirageEditionID)
    }

    @Test func interruptionInjectionLeavesOldFileAndNoDebris() async throws {
        let (store, dir) = try makeStore("idmap-atomic")
        defer { try? FileManager.default.removeItem(at: dir) }
        let v1 = MirageIdentityMapFile.empty.activating(receiptEntry(String(repeating: "cc", count: 32)), now: Date())
        try store.save(v1)
        let bytesBefore = try Data(contentsOf: store.fileURL)

        let interrupted = MirageIdentityMapFile.empty.activating(
            receiptEntry(String(repeating: "dd", count: 32)), now: Date())
        do {
            try store.save(interrupted) {
                struct Injected: Error {}
                throw Injected()
            }
            Issue.record("interuption hook must propagate")
        } catch {
            // typed injection propagates — by design
        }

        // Old-or-new guarantee: the previous file is intact, byte-identical.
        let bytesAfter = try Data(contentsOf: store.fileURL)
        #expect(bytesAfter == bytesBefore)
        guard case .loaded(let loaded) = store.load() else { Issue.record("expected loaded"); return }
        #expect(loaded == v1)

        // No debris: the failed temp staging file must be gone.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!leftovers.contains { $0.contains(".tmp-") })
    }

    @Test func failSafeDegradesOnUnknownSchemaAndMalformed() async throws {
        // (a) newer/unknown schema string ⇒ unreadable (fail-closed)
        let (storeA, dirA) = try makeStore("idmap-schema2")
        defer { try? FileManager.default.removeItem(at: dirA) }
        try "{\"schema\":\"mirage-identity-map@2\",\"entries\":[]}".write(
            to: storeA.fileURL, atomically: true, encoding: .utf8)
        guard case .unreadable(let reasonA) = storeA.load() else { Issue.record("expected unreadable"); return }
        #expect(reasonA.contains("unknown schema"))

        // (b) malformed JSON ⇒ unreadable
        let (storeB, dirB) = try makeStore("idmap-badjson")
        defer { try? FileManager.default.removeItem(at: dirB) }
        try "{ not json at all".write(to: storeB.fileURL, atomically: true, encoding: .utf8)
        guard case .unreadable = storeB.load() else { Issue.record("expected unreadable"); return }

        // (c) right schema, malformed entry ⇒ unreadable
        let (storeC, dirC) = try makeStore("idmap-badentry")
        defer { try? FileManager.default.removeItem(at: dirC) }
        try "{\"schema\":\"mirage-identity-map@1\",\"entries\":[{\"rtBookID\":\"not-a-uuid\"}]}".write(
            to: storeC.fileURL, atomically: true, encoding: .utf8)
        guard case .unreadable = storeC.load() else { Issue.record("expected unreadable"); return }

        // (d) absent file ⇒ virgin empty map, NOT degradation
        let (storeD, dirD) = try makeStore("idmap-virgin")
        defer { try? FileManager.default.removeItem(at: dirD) }
        guard case .loaded(let empty) = storeD.load() else { Issue.record("expected loaded"); return }
        #expect(empty == .empty)
    }

    @Test func orphanTransitionsCarryPinnedReasons() async throws {
        let (store, dir) = try makeStore("idmap-orphan")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bookA = UUID()
        let bookB = UUID()
        var map = MirageIdentityMapFile.empty
            .activating(receiptEntry(String(repeating: "ee", count: 32)).letBookID(bookA), now: Date())
            .activating(receiptEntry(String(repeating: "ff", count: 32)).letBookID(bookB), now: Date())
        try store.save(map)

        let t = Date(timeIntervalSince1970: 1_770_000_900)
        map = map.orphaning(rtBookID: bookA, reason: .sourceChanged, now: t)
        map = map.orphaning(rtBookID: bookB, reason: .editionGone, now: t)
        try store.save(map)

        guard case .loaded(let loaded) = store.load() else { Issue.record("expected loaded"); return }
        #expect(loaded.activeCount == 0)
        #expect(loaded.entries.first { $0.rtBookID == bookA }?.orphanedReason == .sourceChanged)
        #expect(loaded.entries.first { $0.rtBookID == bookB }?.orphanedReason == .editionGone)
    }
}

private extension MirageIdentityMapEntry {
    /// Test convenience: re-target a receipt factory entry at a pinned rtBookID.
    func letBookID(_ id: UUID) -> MirageIdentityMapEntry {
        MirageIdentityMapEntry(
            rtBookID: id, mirageBookID: mirageBookID, mirageEditionID: mirageEditionID,
            sourceFingerprint: sourceFingerprint, sourceResumeHint: sourceResumeHint,
            createdAt: createdAt, updatedAt: updatedAt, status: status, orphanedReason: orphanedReason)
    }
}
