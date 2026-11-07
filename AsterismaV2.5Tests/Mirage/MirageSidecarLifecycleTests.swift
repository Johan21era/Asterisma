import Foundation
import Testing
@testable import AsterismaV2_5

// PR-4 suite: sidecar lifecycle against REAL stub processes (ADR-2 §4):
// bounded restarts, mid-session fault recovery, typed transport faults,
// SIGTERM→SIGKILL escalation, and the single-instance pid guard. No engine
// dependency; the real-engine smoke test at the bottom is env-gated.

@Suite("Mirage Sidecar Lifecycle (PR-4)", .serialized)
@MainActor
struct MirageSidecarLifecycleTests {
    // MARK: Helpers

    private func directTransport(mode: String) throws -> MirageProcessTransport {
        let channels = try StubSidecarLauncher(mode: mode).launch()
        return MirageProcessTransport(channels: channels, config: makeStubTransportConfig())
    }

    private func wireLine(_ action: MirageWireAction) throws -> Data {
        try JSONEncoder().encode(MirageWireRequestLine(action: action, payload: nil, id: "direct"))
    }

    // MARK: Bounded restart ladder

    @Test func permanentDownAfterBackoffLadderExhausts() async throws {
        let dir = try makeMirageTestTempDir("restart")
        defer { try? FileManager.default.removeItem(at: dir) }
        // exit-after-banner: every attempt reaches banner then EOFs on version —
        // a restartable fault all three times.
        let counter = LaunchCounter()
        let launcher = CountingLauncher(
            base: StubSidecarLauncher(mode: "exit-after-banner"), counter: counter)
        let supervisor = MirageSidecarSupervisor(configuration: makeStubSupervisorConfig(
            launcher: launcher, pidFileURL: dir.appendingPathComponent("guard.pid")))

        do {
            _ = try await supervisor.acquireTransport()
            Issue.record("acquireTransport must eventually throw")
        } catch {
            // Blocker shape is exercised via the state pin below.
        }
        #expect(counter.value == 3) // exactly the ladder, no unbounded restart
        if case .permanentDown = supervisor.state {} else {
            Issue.record("expected permanentDown, got \(supervisor.state)")
        }

        // Terminal state persists: further acquires throw without new launches.
        do {
            _ = try await supervisor.acquireTransport()
            Issue.record("acquire after permanentDown must throw")
        } catch {}
        #expect(counter.value == 3)
        await supervisor.shutdown()
    }

    // MARK: Mid-session fault → recovery

    @Test func responseTimeoutFaultLeadsToRecovery() async throws {
        let dir = try makeMirageTestTempDir("recover")
        defer { try? FileManager.default.removeItem(at: dir) }
        let counter = LaunchCounter()
        let launcher = CountingLauncher(
            base: StubSidecarLauncher(mode: "silent-after-version"), counter: counter)
        let supervisor = MirageSidecarSupervisor(configuration: makeStubSupervisorConfig(
            launcher: launcher, pidFileURL: dir.appendingPathComponent("guard.pid")))

        // Handshake (banner + version) succeeds; the stub then goes silent.
        let first = try await supervisor.acquireTransport()
        #expect(supervisor.state == .ready)
        #expect(counter.value == 1)

        // A dormant-but-alive child: request in, no answer → typed timeout,
        // and the transport's fault path force-kills the epoch.
        do {
            _ = try await first.exchange(try wireLine(.health))
            Issue.record("expected responseTimeout")
        } catch MirageTransportFailure.responseTimeout {
            // typed, as contracted
        } catch {
            Issue.record("wrong fault: \(error)")
        }
        #expect(!first.isChildAlive())

        // Next acquire re-handshakes a NEW child (bounded, not masked).
        let second = try await supervisor.acquireTransport()
        #expect(counter.value == 2)
        #expect(supervisor.state == .ready)
        #expect(second.isChildAlive())
        #expect(second.processIdentifier != first.processIdentifier)
        await supervisor.shutdown()
    }

    @Test func crashOnRequestRaisesTypedEOF() async throws {
        let transport = try directTransport(mode: "crash-on-request")
        _ = try await transport.awaitBanner()
        do {
            _ = try await transport.exchange(try wireLine(.health))
            Issue.record("expected pipe EOF")
        } catch MirageTransportFailure.pipeEOFWhileAwaitingResponse {
            // typed, as contracted
        } catch {
            Issue.record("wrong fault: \(error)")
        }
        #expect(!transport.isChildAlive())
    }

    @Test func oversizedLineRaisesTypedFaultAndKillsChild() async throws {
        let transport = try directTransport(mode: "oversize")
        _ = try await transport.awaitBanner()
        do {
            _ = try await transport.exchange(try wireLine(.health))
            Issue.record("expected oversizedLine")
        } catch MirageTransportFailure.oversizedLine {
            // typed, as contracted
        } catch {
            Issue.record("wrong fault: \(error)")
        }
        #expect(!transport.isChildAlive())
    }

    @Test func neverRespondingChildTimesOutAndIsReaped() async throws {
        let transport = try directTransport(mode: "stubborn")
        _ = try await transport.awaitBanner()
        do {
            _ = try await transport.exchange(try wireLine(.health))
            Issue.record("expected responseTimeout")
        } catch MirageTransportFailure.responseTimeout {
            // typed, as contracted
        } catch {
            Issue.record("wrong fault: \(error)")
        }
        #expect(!transport.isChildAlive())
    }

    // MARK: Teardown escalation

    @Test func sigtermEscalatesToSigkillWhenIgnored() async throws {
        let transport = try directTransport(mode: "ignore-term")
        _ = try await transport.awaitBanner()
        #expect(transport.isChildAlive())
        await transport.teardown(grace: 0.3, suspend: { seconds in
            try await Task.sleep(nanoseconds: UInt64((seconds * 1_000_000_000).rounded()))
        })
        #expect(!transport.isChildAlive()) // SIGKILL escalation fired
    }

    @Test func compliantChildShutdownHonorsSigterm() async throws {
        let transport = try directTransport(mode: "echo")
        _ = try await transport.awaitBanner()
        await transport.teardown(grace: 0.3, suspend: { seconds in
            try await Task.sleep(nanoseconds: UInt64((seconds * 1_000_000_000).rounded()))
        })
        #expect(!transport.isChildAlive()) // TERM respected, no escalation needed
    }

    // MARK: Single-instance pid guard

    @Test func foreignPidGuardBlocksThenReleases() async throws {
        let dir = try makeMirageTestTempDir("pidguard")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidFileURL = dir.appendingPathComponent("guard.pid")
        try Data("999999999\n".utf8).write(to: pidFileURL)

        var blocked = makeStubSupervisorConfig(
            launcher: StubSidecarLauncher(mode: "version-ok"), pidFileURL: pidFileURL)
        blocked.isPidAlive = { _ in true } // simulated foreign holder
        let counter = LaunchCounter()
        blocked.launcher = CountingLauncher(
            base: StubSidecarLauncher(mode: "version-ok"), counter: counter)
        let blocker = MirageSidecarSupervisor(configuration: blocked)

        do {
            _ = try await blocker.acquireTransport()
            Issue.record("acquire must be blocked by the foreign pid")
        } catch {}
        if case .engineUnavailable = blocker.state {} else {
            Issue.record("expected engineUnavailable, got \(blocker.state)")
        }
        #expect(counter.value == 0) // blocked BEFORE any spawn

        // Default liveness probe: the fake pid is dead → guard releases.
        let supervisor = MirageSidecarSupervisor(configuration: makeStubSupervisorConfig(
            launcher: StubSidecarLauncher(mode: "version-ok"), pidFileURL: pidFileURL))
        let transport = try await supervisor.acquireTransport()
        #expect(supervisor.state == .ready)
        let pidText = try String(contentsOf: pidFileURL, encoding: .utf8)
        #expect(Int(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) == Int(transport.processIdentifier))
        await supervisor.shutdown()
        #expect(!FileManager.default.fileExists(atPath: pidFileURL.path))
    }
}
