import Combine
import Darwin
import Foundation

// PR-4 runtime: sidecar lifecycle (ADR-2 §2/§4). One supervisor per ledger;
// MainActor-published for PR-7's status row. All pipe I/O, spawns, and teardown
// run off the main actor (PR-4 gate: no MainActor block ≥ 5 ms).
//
// Fault→state classification (fail-closed posture):
//   • transport faults (spawn/EOF/timeout/oversize/corruption) → restartable,
//     bounded by the backoff ladder, then `permanentDown`;
//   • identity faults (banner not ready, api_version drift) → terminal
//     `protocol_incompatible` masking, restarts cannot fix wrong identity.
//
// Single-instance policy: the supervisor pid file (ADR-4 stratum) blocks
// acquisition while a foreign live pid holds it; liveness is injectable.

@MainActor
final class MirageSidecarSupervisor: ObservableObject {
    nonisolated enum State: Equatable, Sendable {
        case disabled
        case handshaking
        case ready
        case protocolIncompatible(String)
        case engineUnavailable(String)
        case permanentDown(String)
    }

    /// Caller-facing blockers (typed; PR-7 maps these onto the status row).
    nonisolated enum Blocker: Error, Sendable {
        case protocolIncompatible(String)
        case engineUnavailable(String)
        case permanentDown(String)
    }

    @Published private(set) var state: State = .disabled

    nonisolated struct Configuration: Sendable {
        var launcher: any MirageChildLauncher
        /// Where the supervisor pid file lives (ADR-4 stratum).
        var pidFileURL: URL
        var transportConfig: MirageProcessTransportConfig
        /// Sleeps BETWEEN failed attempts: entries 0…n-2 fire before retries,
        /// attempt count is exactly `count` — the ladder never restarts forever,
        /// and its final value is the reserved post-`.permanentDown` manual-retry
        /// horizon for PR-7 ("≤3 attempts with 2/4/8 s backoff", ADR-2 §4).
        var restartBackoff: [TimeInterval]
        var teardownGrace: TimeInterval
        /// Test-injectable sleep (fake clocks replace real waits).
        var suspend: @Sendable (TimeInterval) async throws -> Void
        /// Test-injectable liveness probe; default `kill(pid, 0)` is best-effort
        /// (zombies answer 0 too — RT reaps its own children via Foundation).
        var isPidAlive: @Sendable (Int) async -> Bool

        init(
            launcher: any MirageChildLauncher,
            pidFileURL: URL,
            transportConfig: MirageProcessTransportConfig = MirageProcessTransportConfig(),
            restartBackoff: [TimeInterval] = [2, 4, 8],
            teardownGrace: TimeInterval = 5,
            suspend: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
                try await Task.sleep(nanoseconds: UInt64((seconds * 1_000_000_000).rounded()))
            },
            isPidAlive: @escaping @Sendable (Int) async -> Bool = { pid in
                kill(Int32(clamping: pid), 0) == 0
            }
        ) {
            self.launcher = launcher
            self.pidFileURL = pidFileURL
            self.transportConfig = transportConfig
            self.restartBackoff = restartBackoff
            self.teardownGrace = teardownGrace
            self.suspend = suspend
            self.isPidAlive = isPidAlive
        }
    }

    private let configuration: Configuration
    private var activeTransport: MirageProcessTransport?

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Brings the sidecar to `.ready` under the pinned handshake and returns the
    /// live transport. Idempotent; re-handshakes after any child death; throws
    /// `Blocker` for every caller-facing masking condition.
    func acquireTransport() async throws -> MirageProcessTransport {
        if state == .ready {
            if let active = activeTransport, active.isChildAlive() {
                return active
            }
            // Child died mid-session: its epoch is over — re-handshake.
            activeTransport = nil
        }
        switch state {
        case .protocolIncompatible(let reason):
            throw Blocker.protocolIncompatible(reason)
        case .permanentDown(let reason):
            throw Blocker.permanentDown(reason)
        case .disabled, .handshaking, .engineUnavailable, .ready:
            break
        }

        // Single-instance policy (ADR-4): a live foreign pid blocks acquisition.
        // Unparsable pid content cannot be owned by anyone → fail open.
        if let existingPid = try? readPidFile(),
           await configuration.isPidAlive(existingPid) {
            let reason = "another Mirage sidecar instance holds the ledger (pid \(existingPid))"
            state = .engineUnavailable(reason)
            throw Blocker.engineUnavailable(reason)
        }

        state = .handshaking
        var lastReason = "unknown"
        for attemptIndex in 0..<configuration.restartBackoff.count {
            if attemptIndex > 0 {
                try await configuration.suspend(configuration.restartBackoff[attemptIndex - 1])
            }
            do {
                let transport = try await spawnAndHandshake()
                activeTransport = transport
                state = .ready
                return transport
            } catch MirageSidecarAttemptFailure.restartable(let reason) {
                lastReason = reason
                state = .engineUnavailable(reason)
            } catch MirageSidecarAttemptFailure.terminal(let reason) {
                state = .protocolIncompatible(reason)
                throw Blocker.protocolIncompatible(reason)
            }
        }
        state = .permanentDown(lastReason)
        throw Blocker.permanentDown(lastReason)
    }

    /// Operator/user-gated recovery hook for PR-7: clears terminal states so the
    /// NEXT acquire handshakes again. Terminal faults are never auto-cleared.
    func clearTerminalState() {
        switch state {
        case .protocolIncompatible, .permanentDown:
            state = .disabled
        case .disabled, .handshaking, .ready, .engineUnavailable:
            break
        }
    }

    /// SIGTERM→grace→SIGKILL teardown, pid-file removal, state reset. Idempotent.
    func shutdown() async {
        if let transport = activeTransport {
            await transport.teardown(
                grace: configuration.teardownGrace, suspend: configuration.suspend)
        }
        activeTransport = nil
        removePidFile()
        state = .disabled
    }

    // MARK: - Handshake attempt

    private func spawnAndHandshake() async throws -> MirageProcessTransport {
        let channels: MirageChildChannels
        do {
            channels = try configuration.launcher.launch()
        } catch {
            throw MirageSidecarAttemptFailure.restartable(describe(error))
        }
        let transport = MirageProcessTransport(
            channels: channels, config: configuration.transportConfig)
        do {
            // Banner (stdout line 1): the engine's bare health payload — NOT an
            // ok-envelope (serve.py:48 prints it before any request exists).
            let banner = try await transport.awaitBanner()
            guard banner.field("status") == .string("ready") else {
                throw MirageSidecarAttemptFailure.terminal(
                    "banner status is not ready — engine identity mismatch")
            }

            // Pinned handshake: `version` answered with `api_version` inside the
            // pinned range AND a recomputed contract signature matching the pin
            // (S0-ES-6(b) / MirageProtocolConstants).
            let client = MirageClient(transport: transport, idProvider: { "rt-handshake" })
            let outcome = try await client.perform(.version)
            switch outcome {
            case .success(let result):
                guard case .string(let version)? = result.field("api_version") else {
                    throw MirageSidecarAttemptFailure.terminal("version result missing api_version")
                }
                guard MirageProtocolConstants.versionIsSupported(version),
                      MirageProtocolConstants.handshakeSignature(apiVersion: version)
                          == MirageProtocolConstants.handshakeSignature(
                              apiVersion: MirageProtocolConstants.minSupportedAPIVersion)
                else {
                    throw MirageSidecarAttemptFailure.terminal(
                        "api_version \(version) outside pinned range")
                }
            case .engineError(let engineError):
                throw MirageSidecarAttemptFailure.terminal(
                    "version refused (\(engineError.code)/\(engineError.status))")
            }

            writePidFile(Int(channels.processIdentifier))
            return transport
        } catch {
            await transport.teardown(
                grace: configuration.teardownGrace, suspend: configuration.suspend)
            switch error {
            case MirageSidecarAttemptFailure.terminal(let reason):
                throw MirageSidecarAttemptFailure.terminal(reason)
            case is MirageBannerFault:
                throw MirageSidecarAttemptFailure.terminal(describe(error))
            case is MirageClient.Fault:
                // Structural wire faults DURING the handshake (unparsable
                // envelope, correlation mismatch, envelope-shape violation)
                // prove protocol misbehavior: mask, do not restart.
                throw MirageSidecarAttemptFailure.terminal(describe(error))
            default:
                throw MirageSidecarAttemptFailure.restartable(describe(error))
            }
        }
    }

    // MARK: - Pid file (ADR-4 stratum)

    private func readPidFile() throws -> Int? {
        let data = try Data(contentsOf: configuration.pidFileURL)
        guard let text = String(data: data, encoding: .utf8),
              let pid = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return pid
    }

    private func writePidFile(_ pid: Int) {
        // Fail-soft on purpose: the file is a best-effort cross-instance guard;
        // a write failure must not break an otherwise-successful handshake.
        try? Data("\(pid)".utf8).write(to: configuration.pidFileURL, options: .atomic)
    }

    private func removePidFile() {
        try? FileManager.default.removeItem(at: configuration.pidFileURL)
    }
}

// MARK: - Attempt classification

/// One handshake attempt's verdict: restartable faults feed the bounded backoff
/// ladder; terminal faults mask the feature immediately (no restart can help).
nonisolated enum MirageSidecarAttemptFailure: Error, Sendable {
    case restartable(String)
    case terminal(String)
}

nonisolated private func describe(_ error: Error) -> String {
    String(describing: error)
}
