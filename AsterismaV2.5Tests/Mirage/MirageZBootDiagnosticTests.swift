import Foundation
import Testing
@testable import AsterismaV2_5

// PR-7 root-cause probe for the M-024 machinery boundary (one spawn per test
// process): sequential REAL lifecycles in ONE process, instrumented —
// deliberately named so this suite sorts LAST in the Mirage band of an
// alphabetical census ("Z"), after every Process-spawning stub suite, so a
// census run WITH MIRAGE_BOOT_DIAGNOSTIC=1 probes the boundary exactly in the
// heavy-multi-spawn context where it was first observed.
//
// Evidence ladder to date (M-028):
//   • bare Foundation-Process double-spawn (NO RT machinery) — CLEAN;
//   • two clean supervisor lifecycles in one test — CLEAN;
//   • lifecycle 1 carrying a FULL import epoch before lifecycle 2 — CLEAN;
//   • this suite adds the two-test-case shape and the census-tail context.
// Opt-in: real engine dir + MIRAGE_BOOT_DIAGNOSTIC=1 (census never spawns).
//
// Every failure records the fault TYPE, elapsed ms, the supervisor state, the
// prior child's pid liveness (kill(pid,0)), and the launcher's stderr tail.

@Suite("Mirage Boot Diagnostic (opt-in)", .enabled(if: mirageRealEngineEnabled && ProcessInfo.processInfo.environment["MIRAGE_BOOT_DIAGNOSTIC"] == "1"), .serialized)
@MainActor
struct MirageZBootDiagnosticTests {
    /// Lifecycle 1 — the schema the original failing context exercised: full
    /// real-engine import epoch, then clean supervisor shutdown + settle.
    @Test func step0FirstEpochRunsTheCompleteImportLifecycle() async throws {
        let root = try makeMirageTestTempDir("bootdiag")
        defer { try? FileManager.default.removeItem(at: root) }
        var config = MirageProcessTransportConfig()
        config.bannerTimeout = 25
        config.responseTimeout = 25
        let supervisor = MirageSidecarSupervisor(
            configuration: .init(
                launcher: MirageProcessLauncher(
                    executableURL: try MiragePythonLocator.shared.executableURL(),
                    arguments: [mirageRealEngineDir + "/examples/mirage_sidecar.py",
                                root.appendingPathComponent("probe-step0.sqlite3").path]),
                pidFileURL: root.appendingPathComponent("guard-step0.pid"),
                transportConfig: config))
        let t0 = Date()
        let transport = try await supervisor.acquireTransport()
        let client = MirageClient(transport: transport, idProvider: { "diag-step0" })
        _ = try await client.perform(.version)
        let environment = MirageImportEnvironment(
            store: MirageIdentityMapStore(
                fileURL: root.appendingPathComponent("mirage/identity-map.json")),
            acquireClient: { client })
        let flow = MirageImportFlow(environment: environment)
        let epubURL = try writeMinimalRealEpubFixture(workDir: root)
        let source = MirageImportSource(rtBookID: UUID(), fileTypeIsEpub: true) { epubURL }
        let outcome = await flow.performImport(source: source)
        guard case .linked = outcome else {
            Issue.record("step 0 import was expected to link, got \(outcome)")
            return
        }
        print("[bootdiag] step0 ready+version+import in \(Int(-t0.timeIntervalSinceNow * 1000)) ms pid=\(transport.processIdentifier) outcome=\(outcome)")
        await supervisor.shutdown()
        print("[bootdiag] step0 done; shutdown in \(Int(-t0.timeIntervalSinceNow * 1000)) ms; child alive=\(transport.isChildAlive())")
        #expect(!transport.isChildAlive())
        try await Task.sleep(nanoseconds: 500_000_000) // reap settle + census-tail realism
    }

    /// Lifecycle 2 — a FRESH supervisor in the SAME test process, after step 0
    /// has run its full epoch. The M-024 boundary claims this banner never
    /// arrives; the evidence ladder says otherwise — this test either proves
    /// the boundary's absence or corners its trigger.
    @Test func step1SecondLifecycleSpawnsFreshInBackground() async throws {
        let root = try makeMirageTestTempDir("bootdiag")
        defer { try? FileManager.default.removeItem(at: root) }
        var config = MirageProcessTransportConfig()
        config.bannerTimeout = 25
        config.responseTimeout = 25
        let supervisor = MirageSidecarSupervisor(
            configuration: .init(
                launcher: MirageProcessLauncher(
                    executableURL: try MiragePythonLocator.shared.executableURL(),
                    arguments: [mirageRealEngineDir + "/examples/mirage_sidecar.py",
                                root.appendingPathComponent("probe-step1.sqlite3").path]),
                pidFileURL: root.appendingPathComponent("guard-step1.pid"),
                transportConfig: config))
        let t1 = Date()
        do {
            let transport = try await supervisor.acquireTransport()
            print("[bootdiag] step1 ACQUIRED in \(Int(-t1.timeIntervalSinceNow * 1000)) ms state=\(supervisor.state)")
            let gain = MirageClient(transport: transport, idProvider: { "diag-step1" })
            let outcome = try await gain.perform(.version)
            print("[bootdiag] step1 version exchange ⇒ \(outcome)")
            await supervisor.shutdown()
            #expect(!transport.isChildAlive())
        } catch {
            print("[bootdiag] step1 FAILED after \(Int(-t1.timeIntervalSinceNow * 1000)) ms: \(error)")
            print("[bootdiag] supervisor state=\(supervisor.state)")
            print("[bootdiag] python probe info: \(MiragePythonLocator.shared.lastProbeStderrTail())")
            await supervisor.shutdown()
            Issue.record("lifecycle 2 could not acquire — machinery boundary reproduced: \(error)")
        }
    }
}
