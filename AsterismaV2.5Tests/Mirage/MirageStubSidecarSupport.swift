import Foundation
import Testing
@testable import AsterismaV2_5

// Disposable stub sidecar for the PR-4 suites (ADR-2 test doctrine: the
// committed suite never depends on the real engine; an opt-in real-engine smoke
// test is env-gated at the bottom of MirageSidecarLifecycleTests).
//
// Each stub is a REAL Process — /usr/bin/python3 -c <script> <mode> — so the
// pipe transport, framing, timeout races, teardown escalation, and pid handling
// are exercised against genuine OS plumbing with zero engine dependency.
//
// NOTE: the script below is flush-left ON PURPOSE — python indentation must
// survive verbatim, and Swift strips multiline-string indentation to the
// closing delimiter's column.

nonisolated enum StubSidecarScript {
    static let source: String = """
import json, signal, sys, time

mode = sys.argv[1]

if mode == "ignore-term":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)

# Banner (stdout line 1 — the proven health payload). Junk/nostatus modes
# REPLACE it instead of appending to it.
if mode == "banner-junk":
    sys.stdout.write("NOT-JSON-AT-ALL\\n")
    sys.stdout.flush()
elif mode == "banner-nostatus":
    print(json.dumps({"foo": "bar"}), flush=True)
else:
    print(json.dumps({"status": "ready"}), flush=True)

def respond(request, result):
    print(json.dumps({"ok": True, "id": request.get("id"), "result": result}), flush=True)

def loop(handler):
    # readline() (NOT `for line in sys.stdin`, which buffers on pipes).
    while True:
        line = sys.stdin.readline()
        if not line:
            break
        handler(json.loads(line))

def oversize_handler(request):
    sys.stdout.write("x" * 200 + "\\n")
    sys.stdout.flush()

def silent_handler(request):
    if request.get("action") == "version":
        respond(request, {"api_version": "1.0.0"})
    else:
        time.sleep(60)

if mode in ("echo", "ignore-term"):
    loop(lambda request: respond(request, {}))
elif mode == "version-ok":
    loop(lambda request: respond(request, {"api_version": "1.0.0"}))
elif mode == "version-drift":
    loop(lambda request: respond(request, {"api_version": "2.0.0"}))
elif mode == "silent-after-version":
    loop(silent_handler)
elif mode == "stubborn":
    loop(lambda request: None)
elif mode == "oversize":
    loop(oversize_handler)
elif mode == "exit-after-banner":
    sys.exit(0)
elif mode == "crash-on-request":
    sys.stdin.readline()
    sys.exit(9)
"""
}

/// Launches one stub child playing the scripted role for `mode`. The
/// interpreter is RESOLVED (App-Sandbox-safe), never the xcrun-shimmed one.
nonisolated struct StubSidecarLauncher: MirageChildLauncher {
    let mode: String

    func launch() throws -> MirageChildChannels {
        try MirageProcessLauncher(
            executableURL: MiragePythonLocator.shared.executableURL(),
            // `-u`: unbuffered stdio — under the app's sandbox posture, a child
            // that stays alive in a read() hoards even flush=True'd writes
            // (proven PR-4); NDJSON line framing requires per-line delivery.
            arguments: ["-u", "-c", StubSidecarScript.source, mode]
        ).launch()
    }
}

// MARK: - Launch counter (bounded-restart pinning)

nonisolated final class LaunchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

nonisolated struct CountingLauncher: MirageChildLauncher {
    let base: any MirageChildLauncher
    let counter: LaunchCounter

    func launch() throws -> MirageChildChannels {
        counter.increment()
        return try base.launch()
    }
}

// MARK: - Shared PR-4 test fixtures

nonisolated func makeStubTransportConfig() -> MirageProcessTransportConfig {
    var config = MirageProcessTransportConfig()
    config.bannerTimeout = 6      // cold python spawn can take ~1s
    config.responseTimeout = 1.5  // timeout races assert within seconds
    config.lineSizeLimitBytes = 120 // deliberately small so the cap machinery runs
    config.readChunkBytes = 1024
    return config
}

nonisolated func makeStubSupervisorConfig(
    launcher: any MirageChildLauncher,
    pidFileURL: URL,
    restartBackoff: [TimeInterval] = [0.05, 0.05, 0.05]
) -> MirageSidecarSupervisor.Configuration {
    .init(
        launcher: launcher,
        pidFileURL: pidFileURL,
        transportConfig: makeStubTransportConfig(),
        restartBackoff: restartBackoff,
        teardownGrace: 0.3)
}

nonisolated func makeMirageTestTempDir(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mirage-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

nonisolated func mirageTestHex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

/// Poll until `condition` holds or the timeout elapses (records an issue, never hangs).
nonisolated func waitUntil(
    _ condition: @escaping @Sendable () -> Bool,
    timeout: TimeInterval = 3
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    Issue.record("condition not met within \(timeout)s (stub support)")
}

