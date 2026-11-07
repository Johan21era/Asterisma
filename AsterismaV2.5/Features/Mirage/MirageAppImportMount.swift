import Foundation

// PR-5 app glue: bridges RT's Book (owned data) into the Mirage import flow,
// borrowing ONLY read-only referents (`Book.resolveURL()`) — it never creates
// books, never touches goals, and never writes RT's own store (ADR-6 census
// gate; the RT-side NEW-DE-5 bypass stays path-independent by construction).
//
// Engine-location policy is DEV-OPT-IN for PR-5: the same MIRAGE_REAL_ENGINE_DIR
// environment variable the opt-in test suites use. No hardcoded paths, no
// production semantics — the packaged-runtime policy belongs to ADR-3 / PR-8
// and will replace this lookup wholesale.
//
// Lifecycle doctrine (2026-10-29): ONE warm sidecar serves every Mirage
// operation in the app session, serialized by MirageEngineService. The older
// spawn-import-shutdown-per-gesture rule is retired by ADR-13; the M-027
// root-cause campaign proved the machinery boundary it guarded was not present
// under the production path. A dead child is still re-handshaken lazily, and
// `shutdown()` remains the only teardown door.

/// The app-level service needs exactly this much of a session: a serialized
/// client door, the shared identity stratum, a terminal-state reset, and a
/// clean shutdown. Tests inject a fake to prove service behavior without a
/// process spawn.
@MainActor
protocol MirageEngineSessionProtocol: AnyObject {
    var identityStore: MirageIdentityMapStore { get }
    var isChildAlive: Bool { get }
    func acquireClient() async throws -> MirageClient
    func clearTerminalState()
    func shutdown() async
}

@MainActor
final class MirageAnalyzeSession {
    /// Built lazily on first acquire: resolving the dev interpreter spawns
    /// probe processes, and a session init must never block a UI gesture with
    /// that work. Nil until used; `shutdown()` clears it.
    private(set) var supervisor: MirageSidecarSupervisor?
    private let engineCheckout: URL
    private let interpreterURL: URL?
    private let baseDirectory: URL
    private let store: MirageIdentityMapStore
    private var transport: MirageProcessTransport?

    /// True while the sidecar process is alive. A warm service can keep the
    /// session object across a child death; `acquireClient()` re-handshakes.
    var isChildAlive: Bool { transport?.isChildAlive() ?? false }

    /// The ADR-4 stratum identity-map store, exposed read-only for PR-6's
    /// status surface (it serializes its reads through the same owning flow).
    var identityStore: MirageIdentityMapStore { store }

    /// Acquires (or reuses) the session's transport and wraps it in a client —
    /// the same handshake discipline `performImport` uses.
    func acquireTransportClient() async throws -> MirageClient {
        try await acquire()
    }

    /// PR-8 (ADR-3): the launcher takes the resolved runtime's interpreter.
    /// `interpreterURL == nil` (dev channel) keeps the proven MiragePythonLocator
    /// fallback; the bundled channel passes the verified `bin/python3.12`.
    init(engineCheckout: URL, interpreterURL: URL? = nil) throws {
        // ADR-4 stratum directory — <Application Support>/Asterisma is RT's
        // same data root (DataStore3:91-95); mirage/ inside it is Mirage-write
        // territory (ledger db + identity map + pid guard). RT creates the
        // directory with an existence check before the first spawn.
        self.engineCheckout = engineCheckout
        self.interpreterURL = interpreterURL
        let base = MirageSupportPaths.mirageDirectory()
        if !FileManager.default.fileExists(atPath: base.path) {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        }
        self.baseDirectory = base
        store = MirageIdentityMapStore(
            fileURL: base.appendingPathComponent("identity-map.json"))
    }

    /// Resolves the interpreter off-main and builds the supervisor exactly
    /// once. The dev channel's probe is the expensive part; the bundled channel
    /// just hands over its verified interpreter.
    private func ensureSupervisor() async throws -> MirageSidecarSupervisor {
        if let supervisor { return supervisor }
        let pythonURL: URL
        if let interpreterURL {
            pythonURL = interpreterURL
        } else {
            pythonURL = try await MiragePythonLocator.shared.executableURLAsync()
        }
        var config = MirageProcessTransportConfig()
        config.bannerTimeout = 25 // import requests wait on real engine work
        config.responseTimeout = 25
        let made = MirageSidecarSupervisor(
            configuration: .init(
                launcher: MirageProcessLauncher(
                    executableURL: pythonURL,
                    arguments: ["-B",
                                engineCheckout.path + "/examples/mirage_sidecar.py",
                                baseDirectory.appendingPathComponent("mirage.sqlite3").path]),
                pidFileURL: baseDirectory.appendingPathComponent("guard.pid"),
                transportConfig: config))
        supervisor = made
        return made
    }

    /// The public serialized client door. All callers must hold the service's
    /// request gate; the pipe transport is single-lane by contract.
    func acquireClient() async throws -> MirageClient {
        try await acquire()
    }

    /// Idempotent within the session: repeated providers inside one flow see
    /// the established handshake; a dead child forces a fresh handshake epoch.
    private func acquire() async throws -> MirageClient {
        if let existingTransport = transport, existingTransport.isChildAlive() {
            return MirageClient(transport: existingTransport,
                                idProvider: { UUID().uuidString })
        }
        let supervisor = try await ensureSupervisor()
        let fresh = try await supervisor.acquireTransport()
        transport = fresh
        return MirageClient(transport: fresh, idProvider: { UUID().uuidString })
    }

    /// Runs the one-book analyze against the warm session. The caller owns the
    /// session lifetime (MirageEngineService); a failure leaves the session in
    /// place so the next request can re-handshake, and no implicit teardown is
    /// performed here.
    func performImport(
        source: MirageImportSource,
        checkCancelled: @escaping () async -> Bool = { false }
    ) async -> MirageImportOutcome {
        // Acquire first so a spawn failure types as `.sidecarUnavailable`
        // before anything else runs (the environment's provider then reuses
        // the established handshake).
        do { _ = try await acquire() }
        catch { return .sidecarUnavailable(reason: String(describing: error)) }
        let environment = MirageImportEnvironment(store: store, acquireClient: {
            try await self.acquire()
        })
        return await MirageImportFlow(environment: environment)
            .performImport(source: source, checkCancelled: checkCancelled)
    }

    /// Operator-gated reset for terminal handshake states. The next acquire
    /// performs a fresh handshake; nothing is implied about stored analyses.
    func clearTerminalState() {
        supervisor?.clearTerminalState()
    }

    func shutdown() async {
        if let supervisor { await supervisor.shutdown() }
        supervisor = nil
        transport = nil
    }
}

extension MirageAnalyzeSession: MirageEngineSessionProtocol {}

nonisolated enum MirageAppImportMount {
    /// ADR-4 stratum directory: <Application Support>/Asterisma/mirage /
    /// (the same temporary fallback when Application Support is unavailable
    /// — degraded environments keep working on a throwaway path).
    nonisolated static func mirageDirectory() -> URL {
        let base = AppIdentity.dataRootURL()
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Asterisma", isDirectory: true)
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("Asterisma-degraded", isDirectory: true)
        return base.appendingPathComponent("mirage", isDirectory: true)
    }

    /// Engine checkout discovery for PR-5: the dev-opt-in environment gate.
    static func engineCheckoutDirectory() -> URL? {
        let dir = ProcessInfo.processInfo.environment["MIRAGE_REAL_ENGINE_DIR"] ?? ""
        guard !dir.isEmpty,
              FileManager.default.fileExists(atPath: dir + "/examples/mirage_sidecar.py")
        else { return nil }
        return URL(fileURLWithPath: dir)
    }

    /// The single RT borrow (ADR-6 item 5): a Book's identity + source-kind gate
    /// + read-only referent resolver. Nothing else of the book is consumed and
    /// nothing is written back to RT's data layer.
    static func importSource(for book: Book) -> MirageImportSource {
        let snapshot = book
        let kind: MirageSourceKind
        switch snapshot.fileType {
        case .epub: kind = .epub
        case .cbz, .comic: kind = .comic
        case .pdf: kind = .unsupported
        }
        return MirageImportSource(
            rtBookID: snapshot.id,
            kind: kind,
            resolveURL: { snapshot.resolveURL() })
    }
}

nonisolated enum MirageSupportPaths {
    /// Single source of the ADR-4 stratum path. (Kept as its own namespace so
    /// the status surface and the session share the EXACT directory semantics.)
    nonisolated static func mirageDirectory() -> URL {
        MirageAppImportMount.mirageDirectory()
    }
}

// ---- plain-language outcome copy (S10-ES-1 honesty doctrine) ----------------
//
// Rules baked into every line below: never claim an undo that didn't happen
// (.cancelled(engineCommitted:) says exactly which world the cancel happened
// in — owner-approved wording, 2026-10-18); never imply the RT store changed
// (it never does); never invent numbers the receipt didn't give.

nonisolated enum MirageOutcomeCopy {
    static func headline(_ outcome: MirageImportOutcome) -> String {
        switch outcome {
        case .linked(_, false): return "Mirage analyzed this book"
        case .linked(_, true): return "This book was already analyzed"
        case .degradedImport: return "Mirage refused this book's file"
        case .invalidReceipt: return "The analysis answer didn't match what RT expected"
        case .sourceUnavailable: return "The book's file could not be read"
        case .notApplicableFileType: return "This file can't be analyzed with Mirage"
        case .analysisPreparationFailed: return "Mirage could not prepare this book for analysis"
        case .mapUnreadable: return "RT's Mirage records could not be read safely"
        case .mapWriteFailed: return "RT could not record the link safely"
        case .engineError: return "Mirage's engine refused this request"
        case .sidecarUnavailable: return "Mirage's engine is not available"
        case .cancelled(let engineCommitted):
            return engineCommitted
                ? "Canceled after Mirage stored its work"
                : "Canceled — nothing was run"
        }
    }

    static func detail(_ outcome: MirageImportOutcome) -> String {
        switch outcome {
        case .linked(_, false):
            return "Mirage stored its analysis of this book on this Mac. RT's library and your goals were not touched — Mirage keeps its own files."
        case .linked(_, true):
            return "Mirage reused the analysis it had already stored — nothing was run twice."
        case .degradedImport(let skipped):
            return "\(skipped) section\(skipped == 1 ? "" : "s") of this file could not be read safely, so Mirage kept nothing from it and RT recorded no link. Repairing the source file may help."
        case .invalidReceipt(let reason):
            return "Nothing was linked and no settings changed. (Detail: \(reason))"
        case .sourceUnavailable(let reason):
            return "\(reason). Nothing was linked."
        case .notApplicableFileType(let reason):
            return reason
        case .analysisPreparationFailed(let reason):
            return "\(reason) Nothing was linked."
        case .mapUnreadable(let reason):
            return "To stay safe, Mirage analysis is paused for this book until the records file is repaired. (Detail: \(reason))"
        case .mapWriteFailed(let reason):
            return "Nothing partial was saved — the link was not recorded. You can try again. (Detail: \(reason))"
        case .engineError(let payload):
            return "Mirage's engine answered with an error, so no link was recorded. (Detail: \(payload))"
        case .sidecarUnavailable(let reason):
            if reason.contains("turned off") {
                return "Mirage analysis is turned off in Settings ▸ Mirage, so nothing was analyzed and no link was recorded."
            }
            let setupShaped = reason.contains("MIRAGE_REAL_ENGINE_DIR")
                || reason.contains("isn't set up")
                || reason.contains("no bundled runtime")
            return setupShaped
                ? "The Mirage engine isn't set up on this Mac yet. RT will bundle it in a future release — nothing else was affected."
                : "Mirage's engine could not be reached, so nothing was analyzed and no link was recorded. (Detail: \(reason))"
        case .cancelled(let engineCommitted):
            return engineCommitted
                ? "Mirage has already stored its analysis of this book, and that stays. RT just didn't record the link — analyze it again anytime and Mirage will reuse that stored work."
                : "You canceled before Mirage did anything. Nothing was run, and nothing was linked."
        }
    }
}
