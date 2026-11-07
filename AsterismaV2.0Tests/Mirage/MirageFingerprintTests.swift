import Foundation
import Testing
@testable import AsterismaV2_0

// The digest is contract data (ADR-5: it is compared against the engine's
// receipt lineage), so the streaming implementation must be byte-identical to
// the in-memory one it replaced. These tests pin that, including the chunk
// boundary and the empty-file case.

@Suite("Mirage Source Fingerprint (streaming)", .serialized)
struct MirageFingerprintTests {
    @Test func streamingDigestMatchesInMemoryDigest() throws {
        let dir = try makeMirageTestTempDir("fingerprint")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("fixture.epub")

        // 3 MiB + 17 bytes: crosses the 1 MiB chunk boundary at a non-multiple.
        var data = Data(count: (1 << 20) * 3 + 17)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for index in data.indices {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            data[index] = UInt8(truncatingIfNeeded: seed >> 33)
        }
        try data.write(to: url)

        #expect(try MirageSourceFingerprint.sha256Hex(fileAt: url)
            == MirageSourceFingerprint.sha256Hex(data))
    }

    @Test func emptyFileHashesToTheEmptyDigest() throws {
        let dir = try makeMirageTestTempDir("fingerprint-empty")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("empty.epub")
        try Data().write(to: url)

        #expect(try MirageSourceFingerprint.sha256Hex(fileAt: url)
            == MirageSourceFingerprint.sha256Hex(Data()))
    }
}
