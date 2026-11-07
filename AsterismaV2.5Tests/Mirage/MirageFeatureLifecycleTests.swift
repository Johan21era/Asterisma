import Foundation
import Testing
@testable import AsterismaV2_5

// PR-7 (§16 PR-7 gate): settings/lifecycle pins.
//   • enable/disable semantics — one honest switch; default ON (engine gate
//     governs real availability separately);
//   • a DISABLED feature never spawns — the status runner and the analyze
//     flow both gate on the flag (defense in depth);
//   • DISABLE DELETES NOTHING — the verified property of this PR: identity
//     stratum bytes and the map store survive any enable/disable cycle
//     untouched; there is no deletion path in MirageSettings at all.
//
// Serialized: these pins write/remove `mirage.enabled` in the standard
// defaults domain and must not race other suites that touch the same key.
// (No other Mirage suite touches it — the serialization is future-proofing.)

@Suite("Mirage Feature Lifecycle (PR-7)", .serialized)
@MainActor
struct MirageFeatureLifecycleTests {
    private func setEnabled(_ value: Bool?) {
        if let value {
            UserDefaults.standard.set(value, forKey: MirageSettings.enabledKey)
        } else {
            UserDefaults.standard.removeObject(forKey: MirageSettings.enabledKey)
        }
    }

    @Test func defaultIsEnabledWhenPreferenceAbsent() {
        setEnabled(nil)
        #expect(MirageSettings.isEnabled)
        setEnabled(false)
        #expect(!MirageSettings.isEnabled)
        setEnabled(true)
        #expect(MirageSettings.isEnabled)
        setEnabled(nil)
        #expect(MirageSettings.isEnabled)
    }

    @Test func disabledFeatureNeverRunsTheStatusRunner() async {
        let counting = CountingRunnerForLifecycle()
        let controller = MirageStatusController(
            book: lifecycleBook(),
            localStatus: MirageAnalysisStatus(linkState: .notImported, channel: .localMap),
            runner: { _, _ in
                await counting.call()
                return MirageAnalysisStatus(
                    linkState: .linked(entry: lifecycleEntry(), counts: nil),
                    channel: .engineVerified)
            })

        setEnabled(false)
        await controller.refreshEngineStatus()
        #expect(counting.callCount == 0)
        #expect(controller.engineStatus == nil,
                "disabled feature: nothing ran, so nothing was verified")
        #expect(!controller.checking)

        // Re-enabling restores the explicit gesture's semantics — one run.
        setEnabled(true)
        await controller.refreshEngineStatus()
        #expect(counting.callCount == 1)
        setEnabled(nil)
    }

    @Test func disableDeletesNothingInTheStratum() throws {
        let dir = try makeMirageTestTempDir("lifecycle-nodelete")
        defer { try? FileManager.default.removeItem(at: dir) }
        let mapURL = dir.appendingPathComponent("mirage/identity-map.json")
        let store = MirageIdentityMapStore(fileURL: mapURL)
        try store.save(MirageIdentityMapFile.empty.activating(lifecycleEntry(), now: Date()))
        let beforeMap = try Data(contentsOf: mapURL)

        try Data("side-artifact-preserved".utf8)
            .write(to: dir.appendingPathComponent("sentinel.side"))
        let beforeSide = try Data(contentsOf: dir.appendingPathComponent("sentinel.side"))

        // The PR's own enable/disable cycle — the ONLY thing the switch does:
        setEnabled(true)
        _ = MirageSettings.isEnabled
        setEnabled(false)
        _ = MirageSettings.isEnabled
        setEnabled(true)
        setEnabled(nil)

        #expect(try Data(contentsOf: mapURL) == beforeMap,
                "the identity stratum survived the disable cycle byte-identically")
        #expect(try Data(contentsOf: dir.appendingPathComponent("sentinel.side")) == beforeSide)
        guard case .loaded(let map) = store.load(), map.activeCount == 1 else {
            Issue.record("the stratum must still load intact after disable cycles"); return
        }
        setEnabled(nil)
    }

    @Test func disabledCopyIsHonestAboutNothingBeingDeleted() {
        #expect(MirageSettingsCopy.disabledHeadline == "Mirage analysis is turned off")
        #expect(MirageSettingsCopy.disabledDetail.contains("Settings ▸ Mirage"))
        #expect(MirageSettingsCopy.disabledDetail.contains("Nothing was deleted"))
        #expect(!MirageSettingsCopy.disabledDetail.lowercased().contains("erase"))
        #expect(!MirageSettingsCopy.disabledDetail.lowercased().contains("remove"))
    }

    // ---- fixtures -----------------------------------------------------------

    private func lifecycleBook() -> Book {
        Book(title: "Feature Lifecycle Fixture",
             author: "Fixture Author",
             fileURL: FileManager.default.temporaryDirectory
                 .appendingPathComponent("feature-lifecycle-fixture.epub"),
             fileType: .epub,
             totalPages: 10,
             currentPage: 3)
    }

    private func lifecycleEntry() -> MirageIdentityMapEntry {
        MirageIdentityMapEntry.fromReceipt(
            rtBookID: UUID(),
            mirageBookID: "book_0123456789abcdef",
            mirageEditionID: "edition_0123456789abcdef",
            fingerprint: String(repeating: "ab", count: 32),
            resumeHint: nil,
            createdAt: MirageIdentityMapTime.canonical(Date()))
    }
}

/// Counting runner shared by the disable pin (scoped here; the PR-6 suite's
/// CountingRunner is private to its own file).
final class CountingRunnerForLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    func call() async {
        lock.lock(); calls += 1; lock.unlock()
    }
}
