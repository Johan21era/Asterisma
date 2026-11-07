import Combine
import Foundation

// ADR-13 (2026-10-29): the warm, app-scoped Mirage engine.
//
// Before this file, every gesture spawned a Python sidecar, completed one
// request, and killed it. That was safe but made library-scale work impossible:
// each book paid the cold-start handshake again. The M-027 root-cause campaign
// proved the old machinery boundary did not exist under the production path, so
// one session can now stay warm across requests.
//
// Invariants kept from the original contract:
//   • NEVER auto-run: nothing here starts the engine until an explicit start,
//     analyze, status check, or library scan gesture arrives.
//   • One engine, one request at a time: the pipe transport is single-lane, so
//     every operation passes through the in-service FIFO gate. Overlapping UI
//     gestures queue; they never interleave bytes on the pipes.
//   • Disable/warm-down deletes nothing: stopping a session is process
//     lifecycle only. The ledger, identity map, and library index stay put.
//   • Fail closed: terminal handshake states are surfaced, never masked by an
//     endless restart loop. `retry()` is the explicit reset.

nonisolated enum MirageEngineServiceError: Error, Equatable, Sendable, CustomStringConvertible {
    case disabled
    case unavailable
    case stopping

    var description: String { plainReason }

    var plainReason: String {
        switch self {
        case .disabled:
            return "Mirage analysis is turned off in Settings ▸ Mirage."
        case .unavailable:
            return "The Mirage engine isn't set up on this Mac yet (no bundled runtime; dev gate MIRAGE_REAL_ENGINE_DIR unset)."
        case .stopping:
            return "The Mirage engine is shutting down."
        }
    }
}

/// One successful library inventory refresh. `orphanedCount` is the number of
/// active identity links the engine's inventory no longer contains.
nonisolated struct MirageLibraryScanReport: Equatable, Sendable {
    let index: MirageLibraryIndexFile
    let orphanedCount: Int
}

nonisolated enum MirageLibraryScanResult: Equatable, Sendable {
    case success(MirageLibraryScanReport)
    case failure(String)
}

@MainActor
final class MirageEngineService: ObservableObject {
    static let shared = MirageEngineService()

    enum State: Equatable {
        case stopped
        case disabled
        case unavailable(String)
        case starting
        case ready
        case failed(String)

        var isWarm: Bool { self == .ready }
        var isBusy: Bool { self == .starting }
    }

    @Published private(set) var state: State = .stopped
    @Published private(set) var runtimeChannel: MirageRuntimeChannel?
    @Published private(set) var startedAt: Date?
    @Published private(set) var lastActivityAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var requestCount = 0
    @Published private(set) var stopPending = false
    /// 2.7: measured wall-clock duration of the last successful book analysis,
    /// including a comic's on-device OCR preparation. Nil until one succeeds.
    @Published private(set) var lastAnalysisSeconds: TimeInterval?
    @Published private(set) var lastAnalysisAt: Date?

    private let runtimeProvider: () -> MirageRuntime?
    private let sessionFactory: @MainActor (MirageRuntime) throws -> any MirageEngineSessionProtocol
    private let indexStore: MirageLibraryIndexStore
    private let idleInterval: TimeInterval
    private let now: () -> Date

    private var session: (any MirageEngineSessionProtocol)?
    private var idleTask: Task<Void, Never>?

    // MainActor-confined FIFO gate. `isBusy` covers the operation currently
    // holding the pipes; `waiters` are queued in arrival order.
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(
        runtimeProvider: @escaping () -> MirageRuntime? = {
            MirageRuntimeResolution.resolveRuntime()
        },
        sessionFactory: @escaping @MainActor (MirageRuntime) throws -> any MirageEngineSessionProtocol = { runtime in
            try MirageAnalyzeSession(
                engineCheckout: runtime.engineRoot,
                interpreterURL: runtime.interpreterURL)
        },
        indexStore: MirageLibraryIndexStore = MirageLibraryIndexStore(
            fileURL: MirageSupportPaths.mirageDirectory()
                .appendingPathComponent("library-index.json")),
        idleInterval: TimeInterval = 10 * 60,
        now: @escaping () -> Date = Date.init
    ) {
        self.runtimeProvider = runtimeProvider
        self.sessionFactory = sessionFactory
        self.indexStore = indexStore
        self.idleInterval = idleInterval
        self.now = now
    }

    // MARK: - Passive availability

    /// Resolves the runtime ladder without spawning anything. Settings calls
    /// this on appear so the availability row is honest even before a gesture.
    func refreshRuntimeAvailability() {
        guard MirageSettings.isEnabled else {
            state = .disabled
            return
        }
        // A warm session already proved a runtime existed; keep its channel
        // visible rather than letting a transient resource lookup contradict it.
        if session != nil, state == .ready { return }
        if let runtime = runtimeProvider() {
            runtimeChannel = runtime.channel
            switch state {
            case .disabled, .unavailable:
                state = .stopped
            case .stopped, .starting, .ready, .failed:
                break
            }
        } else {
            runtimeChannel = nil
            state = .unavailable(MirageEngineServiceError.unavailable.plainReason)
        }
    }

    // MARK: - Explicit lifecycle gestures

    /// Starts and handshakes the engine without sending a book request. Keeps
    /// the process warm for the next explicit gesture.
    func start() async {
        guard MirageSettings.isEnabled else {
            state = .disabled
            return
        }
        do {
            try await withEngine { _, _ in () }
        } catch {
            // `withEngine` already classified the failure for the status row.
        }
    }

    /// Idle, disable, and scene-background teardown. If a request is in flight,
    /// the stop is deferred until that request releases the pipes.
    func stop() async {
        cancelIdleStop()
        stopPending = true
        if isBusy { return }
        await finishPendingStop()
    }

    /// Explicit reset after a terminal handshake fault. Never automatic.
    func retry() async {
        guard MirageSettings.isEnabled else {
            state = .disabled
            return
        }
        session?.clearTerminalState()
        lastError = nil
        if case .failed = state { state = .stopped }
        if case .unavailable = state { state = .stopped }
        await start()
    }

    // MARK: - Engine operations

    /// The ONLY door to engine work. The operation receives the leased client
    /// and the shared identity store; the gate guarantees no two operations
    /// overlap on the transport.
    func withEngine<T>(
        _ operation: @MainActor (MirageClient, MirageIdentityMapStore) async throws -> T
    ) async throws -> T {
        guard MirageSettings.isEnabled else {
            state = .disabled
            throw MirageEngineServiceError.disabled
        }
        guard !stopPending else {
            throw MirageEngineServiceError.stopping
        }
        cancelIdleStop()
        await acquireSlot()
        defer {
            releaseSlot()
            if stopPending {
                Task { [weak self] in await self?.finishPendingStop() }
            } else {
                scheduleIdleStopIfIdle()
            }
        }

        let session = try ensureSession()
        let client: MirageClient
        do {
            client = try await session.acquireClient()
        } catch {
            registerFailure(error)
            throw error
        }

        state = .ready
        lastError = nil
        startedAt = startedAt ?? now()
        requestCount += 1
        lastActivityAt = now()

        do {
            return try await operation(client, session.identityStore)
        } catch {
            // Transport/protocol faults mean the session state is suspect.
            // Domain errors (index write failure, etc.) must not mask a healthy
            // engine as failed.
            if error is MirageTransportFailure
                || error is MirageSidecarSupervisor.Blocker
                || error is MirageClient.Fault {
                registerFailure(error)
            }
            throw error
        }
    }

    /// One explicit book analysis through the warm session.
    func analyze(
        source: MirageImportSource,
        checkCancelled: @escaping () async -> Bool = { false }
    ) async -> MirageImportOutcome {
        guard MirageSettings.isEnabled else {
            state = .disabled
            return .sidecarUnavailable(
                reason: MirageEngineServiceError.disabled.plainReason)
        }
        let analysisStarted = now()
        do {
            // A bookmark-resolved URL needs an active security scope for the
            // whole operation: the bridge reads page images, and the flow then
            // re-reads the same source for its identity fingerprint.
            let sourceURL = source.resolveURL()
            let scopeHeld = sourceURL?.startAccessingSecurityScopedResource() ?? false
            defer {
                if scopeHeld { sourceURL?.stopAccessingSecurityScopedResource() }
            }

            // 2.6: comics are not text documents. Build (or reuse) the
            // deterministic OCR text edition BEFORE taking the engine's
            // request gate — recognition takes minutes on a volume and must
            // never block the warm session.
            var preparedComicEdition: URL?
            if source.kind == .comic {
                guard let comicURL = sourceURL else {
                    return .sourceUnavailable(
                        reason: "the comic's source file could not be located")
                }
                do {
                    let edition = try await ComicMirageBridge.prepareEdition(
                        comicURL: comicURL,
                        checkCancelled: checkCancelled)
                    preparedComicEdition = edition.url
                } catch let error as ComicMirageBridgeError {
                    return error.outcome
                } catch is CancellationError {
                    return .cancelled(engineCommitted: false)
                } catch {
                    return .analysisPreparationFailed(
                        reason: error.localizedDescription)
                }
            }

            let outcome = try await withEngine { client, store in
                let environment = MirageImportEnvironment(
                    store: store, acquireClient: { client })
                return await MirageImportFlow(environment: environment)
                    .performImport(
                        source: source,
                        preparedComicEdition: preparedComicEdition,
                        checkCancelled: checkCancelled)
            }
            if case .sidecarUnavailable(let reason) = outcome {
                noteFailure(reason)
            }
            if case .linked(let entry, _) = outcome {
                // A re-analysis can change the ledger projection at the same
                // edition id; old graph snapshots must not survive it.
                MirageGraphCache.shared.clear(editionID: entry.mirageEditionID)
                let finished = now()
                lastAnalysisSeconds = finished.timeIntervalSince(analysisStarted)
                lastAnalysisAt = finished
            }
            return outcome
        } catch {
            return .sidecarUnavailable(reason: String(describing: error))
        }
    }

    /// Read-only verification through the same warm session. Exactly one
    /// `books_list` crosses the wire when the book is linked.
    func verify(
        source: MirageImportSource,
        checkCancelled: @escaping () async -> Bool = { false }
    ) async -> MirageAnalysisStatus {
        guard MirageSettings.isEnabled else {
            return MirageAnalysisStatus(
                linkState: .unverifiable(reason: MirageEngineServiceError.disabled.plainReason),
                channel: .engineVerified)
        }
        do {
            return try await withEngine { client, store in
                if await checkCancelled() {
                    return MirageAnalysisStatus(
                        linkState: .checkCancelled, channel: .engineVerified)
                }
                let flow = MirageImportFlow(environment: MirageImportEnvironment(
                    store: store, acquireClient: { client }))
                return try await MirageAnalysisStatus.fromEngineVerified(
                    flow: flow, source: source, client: client,
                    checkCancelled: checkCancelled)
            }
        } catch {
            return MirageAnalysisStatus(
                linkState: .unverifiable(reason: String(describing: error)),
                channel: .engineVerified)
        }
    }

    /// One read-only `books_list` refreshes the entire library index and
    /// reconciles every active identity link in a single map write.
    func scanLibrary() async -> MirageLibraryScanResult {
        guard MirageSettings.isEnabled else {
            return .failure(MirageEngineServiceError.disabled.plainReason)
        }
        do {
            let report = try await withEngine { client, store in
                try await MirageLibraryIndex.refresh(
                    client: client, identityStore: store, indexStore: indexStore)
            }
            return .success(report)
        } catch {
            return .failure(String(describing: error))
        }
    }

    // MARK: - Session + gate internals

    private func ensureSession() throws -> any MirageEngineSessionProtocol {
        if let session { return session }
        guard let runtime = runtimeProvider() else {
            let reason = MirageEngineServiceError.unavailable.plainReason
            state = .unavailable(reason)
            throw MirageEngineServiceError.unavailable
        }
        state = .starting
        do {
            let fresh = try sessionFactory(runtime)
            session = fresh
            runtimeChannel = runtime.channel
            startedAt = now()
            return fresh
        } catch {
            registerFailure(error)
            throw error
        }
    }

    private func acquireSlot() async {
        if !isBusy {
            isBusy = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func releaseSlot() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    private func finishPendingStop() async {
        guard stopPending, !isBusy else { return }
        stopPending = false
        let live = session
        session = nil
        state = .stopped
        startedAt = nil
        lastActivityAt = nil
        await live?.shutdown()
    }

    private func registerFailure(_ error: Error) {
        let reason = String(describing: error)
        lastError = reason
        state = .failed(reason)
    }

    /// Flow-level failures that did not throw (the import flow types transport
    /// failure as an outcome). Only transport/tooling reasons should fail the
    /// row; a refused book is not an engine outage.
    private func noteFailure(_ reason: String) {
        let lowered = reason.lowercased()
        let transportShaped = lowered.contains("transport")
            || lowered.contains("sidecar")
            || lowered.contains("pipe")
            || lowered.contains("timeout")
            || lowered.contains("engine is not available")
            || lowered.contains("engine isn't set up")
            || lowered.contains("turned off")
        guard transportShaped else { return }
        lastError = reason
        state = .failed(reason)
    }

    // MARK: - Idle warm-down

    private func scheduleIdleStopIfIdle() {
        guard session != nil, !isBusy, !stopPending, idleInterval > 0 else { return }
        cancelIdleStop()
        let seconds = idleInterval
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.stopIfIdle()
        }
    }

    private func stopIfIdle() async {
        guard !isBusy, !stopPending, session != nil else { return }
        if let last = lastActivityAt,
           now().timeIntervalSince(last) < idleInterval {
            scheduleIdleStopIfIdle()
            return
        }
        await stop()
    }

    private func cancelIdleStop() {
        idleTask?.cancel()
        idleTask = nil
    }
}
