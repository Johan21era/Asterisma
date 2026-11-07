import CryptoKit
import Foundation
import Testing
@testable import AsterismaV2_5

// PR-4 suite: the handshake pin (S0-ES-6(b) / S14-ES-2). The wire carries NO
// version field (M-009 P-10①), so pinning is operational: RT computes a
// SHA-256 contract signature over the proven handshake field at handshake time
// and masks the feature on any mismatch. Identity faults are terminal — the
// state pin (not the message string) is the contract.

@Suite("Mirage Handshake Pin (PR-4)", .serialized)
@MainActor
struct MirageHandshakePinTests {
    // MARK: Signature pin

    @Test func contractSignaturePinMatchesProvenField() {
        let expectedHex = "baa71df13f58495c0113a760ec4ac4a21bc2edccdc92cc4598f95059abc26899"
        // Recompute over the proven canonical string, verbatim (ADR-2 §2).
        let recomputed = Data(SHA256.hash(data: Data("mirage-ndjson-s|api_version=1.0.0".utf8)))
        #expect(mirageTestHex(recomputed) == expectedHex)

        // The production pin function agrees bit-for-bit.
        let pinned = MirageProtocolConstants.handshakeSignature(apiVersion: "1.0.0")
        #expect(mirageTestHex(pinned) == expectedHex)
    }

    @Test func versionRangeIsPinnedExactly() {
        #expect(MirageProtocolConstants.versionIsSupported("1.0.0") == true)
        #expect(MirageProtocolConstants.versionIsSupported("1.0") == false)
        #expect(MirageProtocolConstants.versionIsSupported("0.9.9") == false)
        #expect(MirageProtocolConstants.versionIsSupported("1.0.1") == false)
        #expect(MirageProtocolConstants.versionIsSupported("garbage") == false)
        #expect(MirageProtocolConstants.versionIsSupported("2.0.0") == false)
    }

    // MARK: Banner-mask paths (terminal — exactly one launch, no restarts)

    /// Acquires expecting failure, then pins the masking state case.
    private func assertMasked(_ supervisor: MirageSidecarSupervisor) async {
        do {
            _ = try await supervisor.acquireTransport()
            Issue.record("acquireTransport must fail for incompatible identity")
        } catch {
            // Blocker payloads are diagnostics; the STATE case is the contract.
        }
        if case .protocolIncompatible = supervisor.state {} else {
            Issue.record("expected protocolIncompatible, got \(supervisor.state)")
        }
    }

    @Test func bannerNotJSONMasksFeatureWithNoRestart() async throws {
        let dir = try makeMirageTestTempDir("pinjunk")
        defer { try? FileManager.default.removeItem(at: dir) }
        let counter = LaunchCounter()
        let launcher = CountingLauncher(base: StubSidecarLauncher(mode: "banner-junk"), counter: counter)
        let supervisor = MirageSidecarSupervisor(configuration: makeStubSupervisorConfig(
            launcher: launcher, pidFileURL: dir.appendingPathComponent("guard.pid")))
        await assertMasked(supervisor)
        #expect(counter.value == 1) // identity faults never restart
        await supervisor.shutdown()
    }

    @Test func bannerWithoutStatusMasksFeature() async throws {
        let dir = try makeMirageTestTempDir("pinnostatus")
        defer { try? FileManager.default.removeItem(at: dir) }
        let counter = LaunchCounter()
        let launcher = CountingLauncher(base: StubSidecarLauncher(mode: "banner-nostatus"), counter: counter)
        let supervisor = MirageSidecarSupervisor(configuration: makeStubSupervisorConfig(
            launcher: launcher, pidFileURL: dir.appendingPathComponent("guard.pid")))
        await assertMasked(supervisor)
        #expect(counter.value == 1)
        await supervisor.shutdown()
    }

    @Test func versionDriftMasksFeature() async throws {
        let dir = try makeMirageTestTempDir("pindrift")
        defer { try? FileManager.default.removeItem(at: dir) }
        let counter = LaunchCounter()
        let launcher = CountingLauncher(base: StubSidecarLauncher(mode: "version-drift"), counter: counter)
        let supervisor = MirageSidecarSupervisor(configuration: makeStubSupervisorConfig(
            launcher: launcher, pidFileURL: dir.appendingPathComponent("guard.pid")))
        await assertMasked(supervisor)
        #expect(counter.value == 1)
        await supervisor.shutdown()
    }

    // MARK: Ready path

    @Test func pinnedVersionHandshakesToReadyAndServes() async throws {
        let dir = try makeMirageTestTempDir("pinready")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFileURL = dir.appendingPathComponent("guard.pid")
        let supervisor = MirageSidecarSupervisor(configuration: makeStubSupervisorConfig(
            launcher: StubSidecarLauncher(mode: "version-ok"), pidFileURL: pidFileURL))

        let transport = try await supervisor.acquireTransport()
        #expect(supervisor.state == .ready)
        #expect(transport.isChildAlive())

        // API level: a fresh client on the acquired transport must round-trip.
        // Stub contract (StubSidecarScript, mode "version-ok"): every line is
        // answered with an ok-envelope whose result carries the handshake-
        // pinned api_version. The engine's REAL health result is richer — this
        // pin asserts round-trip + id correlation, not the stub's vocabulary.
        let client = MirageClient(transport: transport, idProvider: { UUID().uuidString })
        let outcome = try await client.perform(.health)
        guard case .success(.object(let fields)) = outcome else {
            Issue.record("health must return a success object, got \(outcome)")
            await supervisor.shutdown()
            return
        }
        #expect(fields == ["api_version": MirageJSONValue.string("1.0.0")])

        // The pid file now names OUR child.
        let pidText = try String(contentsOf: pidFileURL, encoding: .utf8)
        #expect(Int(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) == Int(transport.processIdentifier))

        await supervisor.shutdown()
        #expect(supervisor.state == .disabled)
        #expect(!transport.isChildAlive())
        #expect(!FileManager.default.fileExists(atPath: pidFileURL.path))
    }
}
