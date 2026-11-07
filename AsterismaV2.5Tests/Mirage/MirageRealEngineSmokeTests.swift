import Foundation
import Testing
@testable import AsterismaV2_5

// PR-4 suite: OPT-IN real-engine smoke (ADR-2 doctrine — the committed suites
// never depend on the engine). The suite only ENABLES when MIRAGE_REAL_ENGINE_DIR
// points at the MirageV1.0 checkout; otherwise it reports skipped wholesale.
// This toolchain's Swift Testing removed the runtime `Skip` entity, so
// `.enabled(if:)` is the sanctioned gate.
//
// One-off verification: xcodebuild test … TEST_RUNNER_MIRAGE_REAL_ENGINE_DIR=/path
// Asserts the REAL engine passes the pinned handshake and one health round-trip
// against a DISPOSABLE ledger (never the real one).

nonisolated let mirageRealEngineDir = ProcessInfo.processInfo.environment["MIRAGE_REAL_ENGINE_DIR"] ?? ""
nonisolated let mirageRealEngineEnabled =
    !mirageRealEngineDir.isEmpty
    && FileManager.default.fileExists(atPath: mirageRealEngineDir + "/examples/mirage_sidecar.py")

@Suite("Mirage Real Engine Smoke (opt-in)", .enabled(if: mirageRealEngineEnabled))
@MainActor
struct MirageRealEngineSmokeTests {
    @Test func realEngineHandshakeAndHealth() async throws {
        // Disposable ledger in temp; removed with the supervisor at the end.
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirage-smoke-\(UUID().uuidString)-library.db")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let workDir = try makeMirageTestTempDir("smoke")
        defer { try? FileManager.default.removeItem(at: workDir) }

        var config = MirageProcessTransportConfig()
        config.bannerTimeout = 25 // cold-start import bill on a real engine
        config.responseTimeout = 25
        let configuration = MirageSidecarSupervisor.Configuration(
            launcher: MirageProcessLauncher(
                executableURL: try MiragePythonLocator.shared.executableURL(),
                arguments: [mirageRealEngineDir + "/examples/mirage_sidecar.py", dbURL.path]),
            pidFileURL: workDir.appendingPathComponent("guard.pid"),
            transportConfig: config)

        let supervisor = MirageSidecarSupervisor(configuration: configuration)
        let transport = try await supervisor.acquireTransport()
        #expect(supervisor.state == .ready)
        #expect(transport.isChildAlive())

        // One real round-trip: health answers through the pinned envelope.
        let client = MirageClient(transport: transport, idProvider: { UUID().uuidString })
        let outcome = try await client.perform(.health)
        guard case .success(.object(let fields)) = outcome else {
            Issue.record("real engine health must return a success object, got \(outcome)")
            await supervisor.shutdown()
            return
        }
        // Source-verified (MirageV1.0 api/service.py:67-72): the `health` action
        // returns service.health() itself — `status` is "ready", same payload as
        // the startup banner (serve.py:48). An earlier session's invented
        // "ok" literal failed here; the engine contract is the authority.
        #expect(fields["status"] == .string("ready"))

        await supervisor.shutdown()
        #expect(!transport.isChildAlive())
        #expect(!FileManager.default.fileExists(atPath: workDir.appendingPathComponent("guard.pid").path))
    }
}
