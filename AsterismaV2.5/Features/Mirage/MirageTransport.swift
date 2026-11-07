import Foundation

// Transport seam for the Mirage stdio sidecar (ADR-2, integration PR-3).
//
// Framing contract (S2-ES-4, proven engine behavior in serve.py/mirage_sidecar.py):
//   • one compact JSON value per LF-terminated line, UTF-8, no BOM, pipes only;
//   • the transport OWNS the framing: it receives one encoded request line with NO
//     trailing newline and returns exactly one response line with NO newline;
//   • clients may never assume framing details — they encode/decode values only.
//
// The real pipe-backed implementation arrives in PR-4 and must additionally:
//   insert LF on write, strip on read, guard oversized lines, enforce read
//   timeouts, and surface spawn/EOF failures. Test doubles must honor the same
//   interface contract; `MirageProtocolConformanceTests` pins it.

nonisolated protocol MirageTransport: Sendable {
    /// Sends one request line (no newline) and awaits its response line (no newline).
    /// Throws transport-level failures (spawn failure, EOF, timeout) unchanged —
    /// the client rethrows them as-is per ADR-2 §3.
    func exchange(_ requestLine: Data) async throws -> Data
}
