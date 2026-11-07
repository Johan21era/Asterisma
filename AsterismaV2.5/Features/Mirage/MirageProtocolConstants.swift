import CryptoKit
import Foundation

// Pinned integration contract values (S14-ES-2: min/max + refuse-on-mismatch
// declared in RT's own constants). The sidecar wire has NO version field
// (M-009 P-10① — proven absent in serve.py/mirage_sidecar.py), so pinning is
// operational: these constants ARE what the handshake asserts against.

nonisolated enum MirageProtocolConstants {
    /// Engine `version` action → `api_version`, proven at SHA 81422613…
    /// (pinned engine-side by tests/test_public_api.py:120).
    static let minSupportedAPIVersion = "1.0.0"
    static let maxSupportedAPIVersion = "1.0.0"

    /// Ledger schema RT is built against (Mirage storage/schema.py:3).
    static let expectedLedgerSchema = "ledger@0.0.10"

    /// S0-ES-6(b): RT pins a handshake contract signature — SHA-256 over the
    /// canonical proven handshake fields. Recomputed from the engine's answer at
    /// handshake; any mismatch masks the feature (`protocol_incompatible`).
    static func handshakeSignature(apiVersion: String) -> Data {
        let payload = Data("mirage-ndjson-s|api_version=\(apiVersion)".utf8)
        return Data(SHA256.hash(data: payload))
    }

    static func versionIsSupported(_ version: String) -> Bool {
        let min = SemVer(minSupportedAPIVersion)
        let max = SemVer(maxSupportedAPIVersion)
        guard let candidate = SemVer(version), let min, let max else { return false }
        return min <= candidate && candidate <= max
    }

    /// Minimal MAJOR.MINOR.PATCH triple for range comparison.
    nonisolated struct SemVer: Comparable {
        let major: Int
        let minor: Int
        let patch: Int

        init?(_ string: String) {
            let parts = string.split(separator: ".")
            guard parts.count == 3,
                  let major = Int(parts[0]),
                  let minor = Int(parts[1]),
                  let patch = Int(parts[2]) else { return nil }
            self.major = major
            self.minor = minor
            self.patch = patch
        }

        static func < (lhs: SemVer, rhs: SemVer) -> Bool {
            (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
    }
}
