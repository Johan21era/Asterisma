import Darwin
import Foundation

// PR-4 runtime: the REAL child-process side (ADR-2 §1/§4). The committed suite
// exercises this file against disposable stub children (python -c one-liners);
// the real engine is touched only by an env-gated smoke test. No RT persistence
// dependencies; nothing here may touch the MainActor.

// MARK: - Typed RT-side transport faults (never engine codes — ADR-2 §3)

nonisolated enum MirageTransportFailure: Error, Sendable, Equatable {
    case spawnFailed(String)
    case pipeWriteFailed(String)
    case pipeReadFailed(String)
    case pipeEOFWhileAwaitingResponse
    case responseTimeout(seconds: Double)
    case oversizedLine(limitBytes: Int)
    case framingCorruption(String)
}

/// Banner-layer faults: the child is present but answered with the wrong
/// identity. Protocol problems are TERMINAL under the pinned contract —
/// restarts cannot fix them (ADR-2 §2, `protocol_incompatible` masking).
nonisolated enum MirageBannerFault: Error, Sendable, Equatable {
    case notJSON(String)
    case statusNotReady
}

// MARK: - Channel seam

/// One-shot idempotent closure primitive for `closeRead`: second and later
/// invocations are no-ops, so every call site's ordering reasoning stays local
/// (Foundation's FileHandle.close() tolerates repeat calls, but this makes the
/// guarantee explicit rather than emergent).
nonisolated final class MirageOnceCloser: @unchecked Sendable {
    private let work: @Sendable () -> Void
    private let lock = NSLock()
    private var done = false

    init(_ work: @escaping @Sendable () -> Void) { self.work = work }

    func call() {
        lock.lock()
        defer { lock.unlock() }
        if done { return }
        done = true
        work()
    }
}

/// Primitives of one spawned child. Single-lane by contract: the owning
/// transport serializes reads/writes; the owning supervisor serializes sessions.
/// `@unchecked Sendable` is the PersistenceWriter house idiom — these are tokens
/// of an already-serialized execution path, not shared mutable state.
nonisolated struct MirageChildChannels: @unchecked Sendable {
    let processIdentifier: Int32
    let write: @Sendable (Data) throws -> Void
    let readChunk: @Sendable (Int) throws -> Data // blocks; empty Data = EOF
    let isRunning: @Sendable () -> Bool
    let terminate: @Sendable () -> Void // SIGTERM
    let forceKill: @Sendable () -> Void // SIGKILL
    /// Idempotent end-of-epoch disposal (C2 forensic fix): nil the stderr drain
    /// handler FIRST, then close OUR stdout/stderr READ handles. Every call site
    /// guarantees the child is already killed+reaped and no in-flight reader
    /// exists (group-join discipline), so closing here cannot race a reader.
    /// Afterwards `readChunk` fails typed (`pipeReadFailed`) instead of blocking.
    let closeRead: @Sendable () -> Void
    /// Closes OUR pipe write end: pipe EOF surfaces only when every write fd is
    /// closed, so this is what lets blocked reads unwind after child death.
    let closeWrite: @Sendable () -> Void
    /// Bounded diagnostic tail of the child's stderr (last ~2 KB, drained).
    let stderrTail: @Sendable () -> String
}

nonisolated protocol MirageChildLauncher: Sendable {
    func launch() throws -> MirageChildChannels
}

/// Python resolution: Apple's /usr/bin/python3 is a shim that shells out to
/// xcrun, which refuses to run inside an App Sandbox (proven PR-4: "xcrun:
/// error: cannot be used within an App Sandbox."). RT therefore probes for a
/// REAL interpreter — validation is by EXECUTION under the current sandbox
/// posture, never by trusting paths — and memoizes the first that works.
nonisolated final class MiragePythonLocator: @unchecked Sendable {
    static let shared = MiragePythonLocator()

    static let candidatePaths: [String] = [
        // NOTE (PR-4 evidence): pointing at Python.app/Contents/MacOS/Python
        // DIRECTLY is UNSAFE — the bundle-registered interpreter makes the test
        // runner exit(0) mid-suite (LS activation semantics). bin/python3's
        // posix_spawn bootstrap survives under the sandbox.
        "/opt/homebrew/bin/python3",
        "/opt/homebrew/bin/python3.13",
        "/opt/homebrew/bin/python3.12",
        "/usr/local/bin/python3",
        "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
        "/usr/bin/python3", // Apple shim — only works outside App Sandboxes
    ]

    private let lock = NSLock()
    private var resolved: URL?
    // TEMPORARY PR-4 diagnostic: last probe's interpreter + stderr tail + ms.
    private var lastProbeInfo = "none probed"

    func lastProbeStderrTail() -> String { lastProbeInfo }

    /// Thread-safe memoized resolution; ~1s on the first call only.
    func executableURL() throws -> URL {
        lock.lock()
        if let cached = resolved {
            lock.unlock()
            return cached
        }
        lock.unlock()

        var report = ""
        let t0 = Date()
        let found = Self.candidatePaths
            .map(URL.init(fileURLWithPath:))
            .first { Self.canRun($0, report: &report) }
        let elapsed = Int(Date().timeIntervalSince(t0) * 1000)

        lock.lock()
        resolved = found
        lastProbeInfo = "probe ms=\(elapsed) found=\(found?.path ?? "NIL") \(report)"
        lock.unlock()
        guard let found else {
            throw MirageTransportFailure.spawnFailed(
                "no Python interpreter executes under the sandbox posture; tried \(Self.candidatePaths.joined(separator: ", "))")
        }
        return found
    }

    /// Off-main resolution for the app path. The probe can spawn up to six
    /// interpreters with multi-second timeouts; the first analyze gesture must
    /// never pay that on the main thread. Memoisation still makes every later
    /// call a cached return.
    func executableURLAsync() async throws -> URL {
        try await Task.detached(priority: .userInitiated) { [self] in
            try executableURL()
        }.value
    }

    /// Executes `-c "import json"` and requires a clean exit within a few seconds.
    private static func canRun(_ url: URL, report: inout String) -> Bool {
        let process = Process()
        process.executableURL = url
        process.arguments = ["-c", "import json; print('probe-ok')"]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch {
            report += "|\(url.path): RUN-ERR \(error)"
            return false
        }
        let deadline = Date().addingTimeInterval(4)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            report += "|\(url.path): HUNG-INSIDE-4s"
            return false
        }
        let tail = (try? err.fileHandleForReading.readToEnd())?
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        report += "|\(url.path): exit=\(process.terminationStatus) tail=`\(tail.prefix(200))`"
        return process.terminationStatus == 0
    }
}

/// Default launcher: a real Foundation Process with drained stderr (a full
/// stderr pipe would stall the engine mid-request — ADR-2 fault surface).
nonisolated struct MirageProcessLauncher: MirageChildLauncher {
    let executableURL: URL
    let arguments: [String]

    func launch() throws -> MirageChildChannels {
        // Process-wide SIGPIPE shield (idempotent, every launch): a write into a
        // dead child's stdin must raise EPIPE → typed pipeWriteFailed, never
        // terminate the host (proven PR-4: batched ladder runs died from the
        // default SIGPIPE action of the test runner).
        signal(SIGPIPE, SIG_IGN)

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        // Never let the embedded Python write __pycache__ into the signed app
        // bundle: it mutates sealed resources and invalidates the signature.
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Drain-and-tail (bounded): never accumulates unbounded, never stalls the
        // engine's stderr; the tail surfaces diagnostics on spawn/config faults.
        let tailLock = NSLock()
        let tailBox = NSMutableArray()
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil // EOF: stop draining
            } else {
                tailLock.lock()
                if let text = String(data: chunk, encoding: .utf8) {
                    tailBox.add(text)
                    while tailBox.count > 16 {
                        tailBox.removeObject(at: 0)
                    }
                }
                tailLock.unlock()
            }
        }

        do {
            try process.run()
        } catch {
            throw MirageTransportFailure.spawnFailed(String(describing: error))
        }

        let stdin = stdinPipe.fileHandleForWriting
        let stdout = stdoutPipe.fileHandleForReading
        let stderr = stderrPipe.fileHandleForReading
        // C2 forensic fix (PR4-DEF-ANALYSIS §6.1-D/§10): the wedge root layer is
        // Foundation's FileHandle.read(upToCount:) path on a launcher-cycled
        // pipe — probe-proven 3/3: a bare read(2) on the same pipe delivered the
        // banner while the handle-mediated read wedged forever (H2-family,
        // machinery-local; kernel delivery and pipe pairing both clean).
        // readChunk therefore uses ONE raw read(2) on the captured descriptor —
        // no FileHandle read path at all.
        let stdoutFD = stdout.fileDescriptor
        let closeRD = MirageOnceCloser {
            stderr.readabilityHandler = nil
            try? stderr.close()
            try? stdout.close()
        }
        return MirageChildChannels(
            processIdentifier: process.processIdentifier,
            write: { data in
                do { try stdin.write(contentsOf: data) }
                catch { throw MirageTransportFailure.pipeWriteFailed(String(describing: error)) }
            },
            readChunk: { size in
                var buffer = [UInt8](repeating: 0, count: max(1, size))
                while true {
                    let n = read(stdoutFD, &buffer, max(1, size))
                    if n > 0 { return Data(bytes: buffer, count: min(n, buffer.count)) }
                    if n == 0 { return Data() } // EOF
                    let e = errno
                    if e == EINTR { continue }
                    throw MirageTransportFailure.pipeReadFailed("read(2) errno=\(e)")
                }
            },
            isRunning: { process.isRunning },
            terminate: { process.terminate() },
            forceKill: {
                // Gate on Foundation's reaped-child bookkeeping: a raw
                // kill(pid, SIGKILL) is only safe while THIS process is still
                // running — after reap, the pid can be reassigned (proven PR-4:
                // batched spawns cross-killed each other's fresh children).
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            },
            closeRead: { closeRD.call() },
            closeWrite: { try? stdin.close() },
            stderrTail: {
                tailLock.lock()
                defer { tailLock.unlock() }
                return (tailBox as NSArray).compactMap { $0 as? String }.joined()
            }
        )
    }
}

// MARK: - Configuration

nonisolated struct MirageProcessTransportConfig: Sendable {
    var responseTimeout: TimeInterval = 20
    var bannerTimeout: TimeInterval = 10
    var lineSizeLimitBytes: Int = 16 * 1024 * 1024
    var readChunkBytes: Int = 8192
}

// MARK: - Pipe transport

// Single-lane lineBuffer mutation is serialized by the transport's own contract
// (exchanges never overlap); @unchecked mirrors PersistenceWriter.swift:18-25.
final nonisolated class MirageProcessTransport: MirageTransport, @unchecked Sendable {
    /// Underlying child pid (diagnostics + pid-file assertions; not wire state).
    let processIdentifier: Int32

    private let channels: MirageChildChannels
    private let config: MirageProcessTransportConfig
    /// Bytes received but not yet consumed by a completed line. Single-lane by
    /// transport contract (exchanges never overlap), so plain mutation is safe;
    /// a timeout epoch discards it with the rest of the epoch (fail-closed).
    nonisolated(unsafe) private var pendingBytes = Data()

    init(channels: MirageChildChannels, config: MirageProcessTransportConfig) {
        self.channels = channels
        self.config = config
        self.processIdentifier = channels.processIdentifier
    }

    func isChildAlive() -> Bool { channels.isRunning() }

    /// Reads stdout line 1 — the engine's health payload dict, NOT an ok-envelope
    /// (serve.py:48 prints `service.health()`, flush, before any request).
    func awaitBanner() async throws -> MirageJSONValue {
        let line = try await readCommandLine(timeout: config.bannerTimeout)
        guard let fragment = try? JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed]),
              !(fragment is NSNull) else {
            throw MirageBannerFault.notJSON("banner line of \(line.count) bytes did not parse as JSON")
        }
        return MirageJSONValue.from(fragment)
    }

    /// One request line in (LF added here), one response line out (LF stripped).
    /// Any mid-session fault ends this transport epoch: the child is force-killed
    /// so the supervisor's bounded restart policy drives recovery (ADR-2 §4).
    func exchange(_ requestLine: Data) async throws -> Data {
        do {
            try channels.write(requestLine + Data([0x0A]))
            return try await readCommandLine(timeout: config.responseTimeout)
        } catch {
            channels.forceKill()
            channels.closeWrite()
            await waitForReap(limitSeconds: 1.0)
            channels.closeRead() // epoch over: dispose read handles (idempotent)
            throw error
        }
    }

    /// SIGTERM → poll ≤ grace → SIGKILL (ADR-2 §4.5). Injected `suspend` replaces
    /// sleeps in tests (fake clocks for timing windows — RT testing doctrine).
    func teardown(grace: TimeInterval, suspend: @escaping @Sendable (TimeInterval) async throws -> Void) async {
        if channels.isRunning() {
            channels.terminate()
            let deadline = Date().addingTimeInterval(grace)
            while channels.isRunning() && Date() < deadline {
                try? await suspend(0.05)
            }
            if channels.isRunning() {
                channels.forceKill()
            }
            await waitForReap(limitSeconds: 1.0)
        }
        // Close our pipe write end: with the child gone this surfaces EOF to any
        // remaining blocked reader (pipe EOF requires every write fd closed).
        channels.closeWrite()
        // Epoch disposal (C2): our read handles die with the epoch, not with an
        // ARC-timed dealloc — idempotent, safe after the kill+reap above.
        channels.closeRead()
    }

    private func waitForReap(limitSeconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(limitSeconds)
        while channels.isRunning() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Races a blocking line reader against a sleep. On timeout the child is
    /// killed AND our write end is closed BEFORE awaiting the reader, so the
    /// blocked read unwinds on EOF promptly — a task group reaps every child
    /// task, so the loser must be able to finish (fail-closed: a late response
    /// is discarded either way).
    private func readCommandLine(timeout: TimeInterval) async throws -> Data {
        let channels = self.channels
        let chunkBytes = config.readChunkBytes
        let limit = config.lineSizeLimitBytes
        let pending = pendingBytes
        let nanoseconds = UInt64((timeout * 1_000_000_000).rounded())
        return try await withThrowingTaskGroup(
            of: (line: Data, leftover: Data)?.self
        ) { group -> Data in
            group.addTask {
                try await Self.bridgedReadLine(
                    channels: channels, chunkBytes: chunkBytes, limit: limit, pending: pending)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: nanoseconds)
                return nil // deadline won
            }
            switch try await group.next() {
            case .some(.some(let result)): // reader won
                group.cancelAll()
                pendingBytes = result.leftover
                return result.line
            case .some(.none): // deadline won
                channels.forceKill()
                channels.closeWrite()
                do { _ = try await group.next() } catch {} // reap the blocked reader
                channels.closeRead() // epoch over: dispose read handles (idempotent)
                pendingBytes = Data() // epoch ends: discard partial stream state
                throw MirageTransportFailure.responseTimeout(seconds: timeout)
            case .none:
                pendingBytes = Data()
                throw MirageTransportFailure.framingCorruption("task group drained prematurely")
            }
        }
    }

    /// Blocking reads must NEVER run on the Swift cooperative pool: concurrent
    /// tests pin pool threads by blocking in read(2), and pool starvation then
    /// prevents the timeout sleepers from ever firing (deadlock). Run each read
    /// on its own detached Foundation Thread and bridge via continuation.
    private static func bridgedReadLine(
        channels: MirageChildChannels, chunkBytes: Int, limit: Int, pending: Data
    ) async throws -> (line: Data, leftover: Data) {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                do {
                    let result = try Self.blockingReadLine(
                        channels: channels, chunkBytes: chunkBytes, limit: limit, pending: pending)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Line reader over the byte stream. Multi-line chunks are legal (the
    /// engine flushes per line; two flushed lines can land in one chunk):
    /// extra bytes after the first LF are PARKED for the next read, not fatal.
    private static func blockingReadLine(
        channels: MirageChildChannels, chunkBytes: Int, limit: Int, pending: Data
    ) throws -> (line: Data, leftover: Data) {
        var accumulated = pending
        while true {
            let chunk = try channels.readChunk(chunkBytes)
            if chunk.isEmpty {
                if accumulated.isEmpty {
                    throw MirageTransportFailure.pipeEOFWhileAwaitingResponse
                }
                throw MirageTransportFailure.framingCorruption(
                    "EOF inside line; \(accumulated.count) bytes truncated")
            }
            accumulated.append(chunk)
            if let newlineAt = accumulated.firstIndex(of: 0x0A) {
                let line = accumulated.subdata(in: accumulated.startIndex..<newlineAt)
                // Line cap is a PER-LINE guarantee, not a chunk artifact: a
                // complete line that exceeds the limit faults even when its LF
                // arrived inside the same read chunk (proven PR-4: Foundation
                // chunking masked this; raw read(2) surfaced it).
                if line.count > limit {
                    throw MirageTransportFailure.oversizedLine(limitBytes: limit)
                }
                let leftover = accumulated.subdata(
                    in: accumulated.index(after: newlineAt)..<accumulated.endIndex)
                return (line, leftover)
            }
            if accumulated.count > limit {
                throw MirageTransportFailure.oversizedLine(limitBytes: limit)
            }
        }
    }
}

// MARK: - JSONSerialization fragment → JSONValue conversion

extension MirageJSONValue {
    nonisolated static func from(_ fragment: Any) -> MirageJSONValue {
        switch fragment {
        case is NSNull:
            return .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            if number == NSNumber(value: number.intValue) {
                return .int(number.intValue)
            }
            return .double(number.doubleValue)
        case let string as String:
            return .string(string)
        case let array as [Any]:
            return .array(array.map(MirageJSONValue.from))
        case let dictionary as [String: Any]:
            return .object(dictionary.mapValues(MirageJSONValue.from))
        default:
            return .null
        }
    }
}
