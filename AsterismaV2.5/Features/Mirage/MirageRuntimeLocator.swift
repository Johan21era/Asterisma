import CryptoKit
import Foundation

// PR-8 (ADR-3, direction countersigned 2026-10-18): the packaged runtime.
//
// Resolution ladder — replaces the PR-5 dev gate as the PRODUCTION lookup:
//   1. BUNDLED channel: <app Resources>/mirage-runtime/ must contain the
//      pinned layout (bin/python3.12 + examples/mirage_sidecar.py +
//      src/miragev10/ + RUNTIME-MANIFEST.json) and the manifest's two file
//      bindings must verify against the files' SHA-256s — an unverifiable
//      manifest is NOT a runtime (fail-closed shapes, S9-ES-5). The engine
//      tree-digest binding is staging-side truth (recomputing a whole tree
//      digest per cold-start is not reasonable) — documented, owner-owned.
//   2. DEV channel: the `MIRAGE_REAL_ENGINE_DIR` gate, exactly as PR-5
//      pinned it (unchanged for development). The interpreter stays with the
//      proven MiragePythonLocator resolution at spawn time (nil here means
//      exactly that — the session falls back).
//   3. otherwise: no runtime — callers render the honest unavailable copy.
//
// The spawn contract is unchanged: same interpreter invocation
// `<interpreter> <engine>/examples/mirage_sidecar.py <ledger>`, same NDJSON
// wire, same banner/handshake pins, same one-lifecycle-per-gesture doctrine.

nonisolated enum MirageRuntimeChannel: String, Sendable, Equatable {
    case bundled
    case dev
}

nonisolated struct MirageRuntime: Sendable, Equatable {
    let channel: MirageRuntimeChannel
    /// The real interpreter binary. Bundled: the verified `bin/python3.12`
    /// (the symlink alias `python3` points at it). Dev: nil — the session
    /// resolves via MiragePythonLocator, the proven dev path.
    let interpreterURL: URL?
    /// The engine root: holds `examples/mirage_sidecar.py` (+ its verbatim
    /// `src/miragev10` companion tree for the pinned sys.path bootstrap,
    /// mirage_sidecar.py:22-23).
    let engineRoot: URL
    /// Present only on the bundled channel (a verified manifest).
    let manifest: MirageRuntimeManifest?

    var sidecarScriptURL: URL {
        engineRoot.appendingPathComponent("examples/mirage_sidecar.py")
    }
}

/// Strict decode of RUNTIME-MANIFEST.json (staged by scripts/stage-mirage-runtime.sh).
nonisolated struct MirageRuntimeManifest: Sendable, Equatable {
    let engineVersion: String
    let engineCheckoutSHA: String
    let interpreter: String
    let interpreterSHA256: String
    let bindings: [String: String]

    static func decode(_ data: Data) -> MirageRuntimeManifest? {
        guard let value = try? JSONDecoder().decode(MirageJSONValue.self, from: data),
              case .object(let fields) = value,
              case .string(let engineVersion)? = fields["engine_version"],
              case .string(let checkoutSHA)? = fields["engine_checkout_sha"],
              case .string(let interpreter)? = fields["interpreter"],
              case .string(let interpreterSHA)? = fields["interpreter_sha256"],
              case .object(let rawBindings)? = fields["bindings"]
        else { return nil }
        var bindings: [String: String] = [:]
        for (key, wire) in rawBindings {
            guard case .string(let sha) = wire else { return nil }
            bindings[key] = sha
        }
        return MirageRuntimeManifest(
            engineVersion: engineVersion, engineCheckoutSHA: checkoutSHA,
            interpreter: interpreter, interpreterSHA256: interpreterSHA,
            bindings: bindings)
    }
}

nonisolated enum MirageRuntimeLocator {
    /// The candidate bundle root as it will look inside a built app:
    /// Resources/mirage-runtime/. Tests inject other roots.
    static func bundledResourceRoot(bundle: Bundle = .main) -> URL? {
        bundle.resourceURL?.appendingPathComponent("mirage-runtime", isDirectory: true)
    }

    /// The ladder, with both candidates injectable for tests.
    static func channel(
        bundleResourceRoot: URL?,
        devEngineDirectory: String?
    ) -> MirageRuntime? {
        if let root = bundleResourceRoot, let runtime = bundledRuntime(at: root) {
            return runtime
        }
        if let dev = MirageDevChannel.engineDirectory(provided: devEngineDirectory) {
            return MirageRuntime(channel: .dev, interpreterURL: nil,
                                 engineRoot: dev, manifest: nil)
        }
        return nil
    }

    /// The bundled channel's full verification (layout + manifest + spot-checks).
    static func bundledRuntime(at root: URL) -> MirageRuntime? {
        let interpreter = root.appendingPathComponent("bin/python3.12")
        let sidecar = root.appendingPathComponent("examples/mirage_sidecar.py")
        let package = root.appendingPathComponent("src/miragev10")
        let manifestURL = root.appendingPathComponent("RUNTIME-MANIFEST.json")
        guard FileManager.default.fileExists(atPath: interpreter.path),
              FileManager.default.fileExists(atPath: sidecar.path),
              FileManager.default.fileExists(atPath: package.path),
              let data = try? Data(contentsOf: manifestURL),
              let manifest = MirageRuntimeManifest.decode(data),
              manifest.bindings["bin/python3.12"] == sha256Hex(of: interpreter),
              manifest.bindings["examples/mirage_sidecar.py"] == sha256Hex(of: sidecar)
        else { return nil }
        return MirageRuntime(channel: .bundled, interpreterURL: interpreter,
                             engineRoot: root, manifest: manifest)
    }

    /// sha256 hex of a file; nil when unreadable (manifest can't verify then).
    static func sha256Hex(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// The dev channel's engine gate, kept as its own namespace so the bundled
/// ladder and the dev gate stay independently testable. Semantics are the
/// PR-5 gate verbatim: non-empty dir AND the sidecar script present.
nonisolated enum MirageDevChannel {
    static func engineDirectory(provided: String?) -> URL? {
        let dir = provided ?? ""
        guard !dir.isEmpty,
              FileManager.default.fileExists(atPath: dir + "/examples/mirage_sidecar.py")
        else { return nil }
        return URL(fileURLWithPath: dir)
    }
}

nonisolated enum MirageRuntimeResolution {
    /// The app-side sugar: Bundle.main for the bundled candidate, the dev-gate
    /// environment for the dev candidate. Production call sites use this.
    static func resolveRuntime(
        bundleResourceRoot: URL? = MirageRuntimeLocator.bundledResourceRoot(bundle: .main),
        devEngineDirectory: String? = ProcessInfo.processInfo.environment["MIRAGE_REAL_ENGINE_DIR"]
    ) -> MirageRuntime? {
        MirageRuntimeLocator.channel(
            bundleResourceRoot: bundleResourceRoot,
            devEngineDirectory: devEngineDirectory)
    }
}
