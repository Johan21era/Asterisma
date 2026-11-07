import CryptoKit
import Foundation
import Testing
@testable import AsterismaV2_5

// PR-8 (ADR-3): the packaged-runtime pins. The staging script
// (scripts/stage-mirage-runtime.sh) materializes the real bundle; these tests
// pin the SWIFT side: strict manifest decode, SHA-256 spot-checks, the
// fail-closed bundled verification, and the resolution ladder
// (bundled → dev gate → nothing). No processes are spawned here — the staged
// bundle's spawn smoke lives in the clean-machine script + tonight's
// operator rehearsal (M-028).

@Suite("Mirage Bundled Runtime (PR-8)", .serialized)
struct MirageBundledRuntimeTests {
    // ---- Manifest decode: strict keys, fail-closed shapes ------------------

    @Test func decodesManifestWithTheStagedKeys() throws {
        let data = manifestFixture(
            engineVersion: "MirageV1.0-81422613deadbeef",
            interpreterSHA: "abc123",
            bindings: ["bin/python3.12": "digest-a",
                       "examples/mirage_sidecar.py": "digest-b"])
        let manifest = try #require(MirageRuntimeManifest.decode(data))
        #expect(manifest.engineVersion == "MirageV1.0-81422613deadbeef")
        #expect(manifest.interpreter == "cpython-3.12.7+20241002-aarch64-apple-darwin")
        #expect(manifest.bindings["bin/python3.12"] == "digest-a")
    }

    @Test func refusesManifestWithMissingOrWrongTypedKeys() {
        let missing: MirageJSONValue = .payload([
            "engine_version": .string("x"),
            "engine_checkout_sha": .string("x"),
            // interpreter key absent
            "interpreter_sha256": .string("x"),
            "bindings": .object([:]),
        ])
        #expect(MirageRuntimeManifest.decode(toData(missing)) == nil)
        let wrongType: MirageJSONValue = .payload([
            "engine_version": .int(3), // wrong type
            "engine_checkout_sha": .string("x"),
            "interpreter": .string("x"),
            "interpreter_sha256": .string("x"),
            "bindings": .object([:]),
        ])
        #expect(MirageRuntimeManifest.decode(toData(wrongType)) == nil)
        let nonStringBinding: MirageJSONValue = .payload([
            "engine_version": .string("x"),
            "engine_checkout_sha": .string("x"),
            "interpreter": .string("x"),
            "interpreter_sha256": .string("x"),
            "bindings": .object(["bin/python3.12": .int(7)]),
        ])
        #expect(MirageRuntimeManifest.decode(toData(nonStringBinding)) == nil)
    }

    // ---- The actual app host must carry the runtime (G2B) -------------------

    /// The 47 MB runtime is staged locally, not committed. A clean CI checkout
    /// intentionally builds without it (the embed phase warns and continues),
    /// so this app-host assertion is meaningful only when the resource is
    /// actually present. The synthetic runtime-contract tests below still run
    /// everywhere.
    private static var hasStagedRuntime: Bool {
        guard let resources = Bundle.main.resourceURL else { return false }
        return FileManager.default.fileExists(
            atPath: resources
                .appendingPathComponent("mirage-runtime/RUNTIME-MANIFEST.json")
                .path
        )
    }

    @Test(.enabled(if: hasStagedRuntime))
    func appHostContainsVerifiedBundledRuntime() throws {
        let root = try #require(
            MirageRuntimeLocator.bundledResourceRoot(bundle: .main),
            "app host has no resource root")
        let runtime = try #require(
            MirageRuntimeLocator.bundledRuntime(at: root),
            "app host does not carry a verified mirage-runtime")
        #expect(runtime.channel == .bundled)
        #expect(runtime.manifest?.engineCheckoutSHA.hasPrefix("81422613") == true)
    }

    // ---- sha256Hex sanity ---------------------------------------------------

    @Test func sha256HexRoundTripsTheFileDigest() throws {
        let dir = try makeMirageTestTempDir("bundle-sha")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("payload.bin")
        let payload = Data("staged-runtime-payload-bytes".utf8)
        try payload.write(to: file)
        let expected = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        #expect(MirageRuntimeLocator.sha256Hex(of: file) == expected)
    }

    // ---- Bundled verification: layout + spot-checked bindings ---------------

    @Test func bundledRuntimeResolvesWhenBindingsVerify() throws {
        let root = try syntheticBundle(tamperSidecarDigest: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try #require(MirageRuntimeLocator.bundledRuntime(at: root))
        #expect(runtime.channel == .bundled)
        #expect(runtime.manifest?.engineVersion == syntheticEngineVersion)
        #expect(runtime.interpreterURL?.lastPathComponent == "python3.12")
        #expect(runtime.sidecarScriptURL.lastPathComponent == "mirage_sidecar.py")
    }

    @Test func bundledRuntimeRefusesTamperedSidecarDigest() throws {
        let root = try syntheticBundle(tamperSidecarDigest: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(MirageRuntimeLocator.bundledRuntime(at: root) == nil,
                "a tampered binding is NOT a runtime — fail closed")
    }

    @Test func bundledRuntimeRefusesMissingManifestOrInterpreter() throws {
        let root = try syntheticBundle(tamperSidecarDigest: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: root.appendingPathComponent("RUNTIME-MANIFEST.json"))
        #expect(MirageRuntimeLocator.bundledRuntime(at: root) == nil)

        let root2 = try syntheticBundle(tamperSidecarDigest: false)
        defer { try? FileManager.default.removeItem(at: root2) }
        try FileManager.default.removeItem(at: root2.appendingPathComponent("bin/python3.12"))
        #expect(MirageRuntimeLocator.bundledRuntime(at: root2) == nil)
    }

    // ---- The resolution ladder ------------------------------------------------

    @Test func ladderPrefersVerifiedBundledOverDev() throws {
        let root = try syntheticBundle(tamperSidecarDigest: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let devDir = try makeMirageTestTempDir("bundle-dev")
        defer { try? FileManager.default.removeItem(at: devDir) }
        try createDevLayout(at: devDir)

        let runtime = try #require(MirageRuntimeLocator.channel(
            bundleResourceRoot: root,
            devEngineDirectory: devDir.path))
        #expect(runtime.channel == .bundled)
        #expect(runtime.manifest != nil)
        #expect(runtime.interpreterURL != nil)
    }

    @Test func ladderFallsToDevWhenBundleUnverified() throws {
        let root = try syntheticBundle(tamperSidecarDigest: true) // tampered ⇒ unusable
        defer { try? FileManager.default.removeItem(at: root) }
        let devDir = try makeMirageTestTempDir("bundle-dev")
        defer { try? FileManager.default.removeItem(at: devDir) }
        try createDevLayout(at: devDir)

        let runtime = try #require(MirageRuntimeLocator.channel(
            bundleResourceRoot: root,
            devEngineDirectory: devDir.path))
        #expect(runtime.channel == .dev)
        #expect(runtime.manifest == nil)
        #expect(runtime.interpreterURL == nil, "dev channel keeps the locator fallback")
        #expect(runtime.engineRoot.path == devDir.path)
    }

    @Test func nothingAvailableWhenBothCandidatesFail() throws {
        let empty = try makeMirageTestTempDir("bundle-empty")
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(MirageRuntimeLocator.channel(
            bundleResourceRoot: empty,       // dir exists but is not a runtime
            devEngineDirectory: nil) == nil)
        #expect(MirageRuntimeLocator.channel(
            bundleResourceRoot: nil,
            devEngineDirectory: "/nonexistent/engine-dir") == nil)
    }

    // ---- fixtures ------------------------------------------------------------

    private let syntheticEngineVersion = "MirageV1.0-test-pinned-sha"

    private func toData(_ value: MirageJSONValue) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    private func manifestFixture(
        engineVersion: String, interpreterSHA: String, bindings: [String: String]
    ) -> Data {
        let bindingPairs = bindings.map { "\"\($0.key)\":\"\($0.value)\"" }.joined(separator: ",")
        return """
        {"engine_version":"\(engineVersion)",
         "engine_checkout_sha":"testsha",
         "interpreter":"cpython-3.12.7+20241002-aarch64-apple-darwin",
         "interpreter_sha256":"\(interpreterSHA)",
         "bindings":{\(bindingPairs)}}
        """.data(using: .utf8)!
    }

    /// Builds a full synthetic bundle layout with REAL digests in the manifest
    /// (or a deliberately wrong sidecar digest when tampering is requested).
    private func syntheticBundle(tamperSidecarDigest: Bool) throws -> URL {
        let root = try makeMirageTestTempDir("bundle-root")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("examples"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src/miragev10"), withIntermediateDirectories: true)
        let py = root.appendingPathComponent("bin/python3.12")
        let sidecar = root.appendingPathComponent("examples/mirage_sidecar.py")
        try Data("stub-python-binary".utf8).write(to: py)
        try Data("stub-sidecar-script".utf8).write(to: sidecar)
        let pyDigest = try #require(MirageRuntimeLocator.sha256Hex(of: py))
        var sidecarDigest = try #require(MirageRuntimeLocator.sha256Hex(of: sidecar))
        if tamperSidecarDigest { sidecarDigest = String(repeating: "0", count: 64) }
        let manifest = manifestFixture(
            engineVersion: syntheticEngineVersion, interpreterSHA: "fedcba",
            bindings: ["bin/python3.12": pyDigest,
                       "examples/mirage_sidecar.py": sidecarDigest,
                       "src/miragev10 (tree digest)": "staging-side-truth"])
        try manifest.write(to: root.appendingPathComponent("RUNTIME-MANIFEST.json"))
        return root
    }

    private func createDevLayout(at dir: URL) throws {
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("examples"), withIntermediateDirectories: true)
        try Data("#!/usr/bin/env python3\n".utf8)
            .write(to: dir.appendingPathComponent("examples/mirage_sidecar.py"))
    }
}
