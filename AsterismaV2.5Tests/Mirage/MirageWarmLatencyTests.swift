import Foundation
import Testing
@testable import AsterismaV2_5

// OPT-IN real-engine latency receipt, same gate as the smoke/import suites:
// MIRAGE_REAL_ENGINE_DIR must point at the MirageV1.0 checkout.
//
// Machinery boundary (M-024): one test process can host exactly ONE real
// sidecar spawn. Run this suite alone:
//   xcodebuild test … -only-testing:AsterismaV2.5Tests/MirageWarmLatencyTests
//   (TEST_RUNNER_MIRAGE_REAL_ENGINE_DIR=/path/to/MirageV1.0)
//
// What it measures, in order, on one lifecycle:
//   • interpreter probe (the dev-channel cold tax, memoised in the app);
//   • cold start (spawn + banner + pinned version handshake);
//   • 30 warm `health` round-trips (median and p95);
//   • first `import_epub` on a tiny real EPUB;
//   • the same bytes again (the engine's `reused:true` path).
// Thresholds are deliberately loose — this is a regression tripwire for a
// multi-second stall, not a microbenchmark.

@Suite("Mirage Warm Session Latency (opt-in)", .enabled(if: mirageRealEngineEnabled), .serialized)
@MainActor
struct MirageWarmLatencyTests {
    private func ms(_ value: Double) -> String { String(format: "%.1f", value) }

    @Test func coldStartWarmRoundTripsAndImportTimings() async throws {
        let root = try makeMirageTestTempDir("mirage-latency")
        defer { try? FileManager.default.removeItem(at: root) }
        let dbURL = root.appendingPathComponent("disposable-ledger.sqlite3")

        let probeStart = Date()
        let python = try MiragePythonLocator.shared.executableURL()
        let probeMS = Date().timeIntervalSince(probeStart) * 1000

        var config = MirageProcessTransportConfig()
        config.bannerTimeout = 25
        config.responseTimeout = 25
        let supervisor = MirageSidecarSupervisor(
            configuration: .init(
                launcher: MirageProcessLauncher(
                    executableURL: python,
                    arguments: [mirageRealEngineDir + "/examples/mirage_sidecar.py", dbURL.path]),
                pidFileURL: root.appendingPathComponent("guard.pid"),
                transportConfig: config))

        let coldStart = Date()
        let transport = try await supervisor.acquireTransport()
        let coldMS = Date().timeIntervalSince(coldStart) * 1000
        guard supervisor.state == .ready else {
            Issue.record("supervisor never reached ready: \(supervisor.state)")
            await supervisor.shutdown()
            return
        }

        let client = MirageClient(transport: transport, idProvider: { UUID().uuidString })
        var samples: [Double] = []
        for _ in 0..<30 {
            let start = Date()
            let outcome = try await client.perform(.health)
            guard case .success = outcome else {
                Issue.record("health refused: \(outcome)")
                await supervisor.shutdown()
                return
            }
            samples.append(Date().timeIntervalSince(start) * 1000)
        }
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95) - 1)]

        // Import through the same warm session, then the idempotent reuse path.
        let epubURL = try writeMinimalRealEpubFixture(workDir: root)
        let store = MirageIdentityMapStore(
            fileURL: root.appendingPathComponent("mirage/identity-map.json"))
        let flow = MirageImportFlow(environment: MirageImportEnvironment(
            store: store, acquireClient: { client }))
        let source = MirageImportSource(rtBookID: UUID(), fileTypeIsEpub: true) { epubURL }

        let importStart = Date()
        let first = await flow.performImport(source: source)
        let importMS = Date().timeIntervalSince(importStart) * 1000

        let reuseStart = Date()
        let second = await flow.performImport(source: source)
        let reuseMS = Date().timeIntervalSince(reuseStart) * 1000

        print("MIRAGE-LATENCY probe_ms=\(ms(probeMS)) cold_start_ms=\(ms(coldMS)) "
            + "warm_median_ms=\(ms(median)) warm_p95_ms=\(ms(p95)) "
            + "import_ms=\(ms(importMS)) reuse_ms=\(ms(reuseMS))")

        #expect(median < 250, "warm round-trip median \(ms(median)) ms")
        #expect(p95 < 400, "warm round-trip p95 \(ms(p95)) ms")
        if case .linked(_, _) = first {} else {
            Issue.record("first real import did not link: \(first)")
        }
        if case .linked(_, let reused) = second {
            #expect(reused, "identical bytes must come back reused:true")
        } else {
            Issue.record("re-import did not link: \(second)")
        }

        await supervisor.shutdown()
        #expect(!transport.isChildAlive())
    }
}
