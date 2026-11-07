import Foundation
import Testing
@testable import AsterismaV2_5

// ADR-7 amendment 1 (countersigned 2026-11-07) — probe pins:
//
//   * the amendment opens exactly one path: a projection whose cursor came
//     from the engine's chapter-boundary inventory and whose edition matches;
//   * every estimate, page coordinate, raw unit, and every non-projection
//     detail action still refuses at preflight;
//   * a refusal never contacts the transport. A verified boundary does.

@Suite("Mirage Spoiler Probe Refusals (PR-6 + amendment 1)", .serialized)
struct MirageSpoilerProbeTests {
    /// A transport whose job is to PROVE it never gets contacted: any call
    /// records an issue and increments a counter (both assertions each test).
    private final class ProbeTripwireTransport: MirageTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var exchanges = 0

        var exchangeCount: Int {
            lock.lock(); defer { lock.unlock() }
            return exchanges
        }

        func exchange(_ requestLine: Data) async throws -> Data {
            lock.lock(); exchanges += 1; lock.unlock()
            Issue.record("TRANSPORT CONTACTED BY A DETAIL PROBE — ADR-7 violation")
            return Data()
        }
    }

    private final class BoundaryRecordingTransport: MirageTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var captured: [Data] = []

        var requests: [Data] {
            lock.lock(); defer { lock.unlock() }
            return captured
        }

        func exchange(_ requestLine: Data) async throws -> Data {
            lock.lock(); captured.append(requestLine); lock.unlock()
            return Data(#"{"ok": true, "id": "graph-1", "result": {}}"#.utf8)
        }
    }

    private func probe(
        _ action: MirageWireAction, cursor: MirageCursor,
        edition: String = "edition_0123456789abcdef"
    ) -> MirageDetailRequest {
        MirageDetailRequest(action: action, editionID: edition, cursor: cursor)
    }

    private func verifiedBoundary(
        edition: String = "edition_0123456789abcdef"
    ) throws -> MirageChapterBoundaryCursor {
        try #require(MirageChapterBoundaryCursor(
            editionID: edition,
            rtChapterIndex: 2,
            previousChapterIndex: 2,
            cursorUnit: 23,
            previousChapterUnitCount: 12))
    }

    @Test func projectionProbeRejectedForEveryUnverifiedCursorShape() throws {
        let edition = "edition_0123456789abcdef"
        for cursor in [MirageCursor.absent, .estimated(fraction: 0.5, maxUnitIndex: 9),
                       .page(page: 1, totalPages: 9), .unit(9)] {
            switch cursor {
            case .absent:
                #expect(throws: MirageCursorGateError.missingCursor(
                    reason: "no position data available for the mapped edition")
                ) {
                    _ = try MirageDetailQuery.preflight(
                        probe(.projection, cursor: cursor), mappedEditionID: edition)
                }
            case .estimated, .page, .unit:
                #expect(throws: MirageCursorGateError.unverifiedCursor(
                    reason: "no verified chapter→unit calibration exists (ADR-7 Decision 1) — the cursor is refused")
                ) {
                    _ = try MirageDetailQuery.preflight(
                        probe(.projection, cursor: cursor), mappedEditionID: edition)
                }
            case .chapterBoundary:
                Issue.record("chapter-boundary cursor is not an unverified shape")
            }
        }
    }

    @Test func searchProbeRejectedWithoutAnyMappingOrCursor() throws {
        let request = probe(.search, cursor: .absent, edition: "edition_unmapped_0000")
        #expect(throws: MirageCursorGateError.detailProbeRejected(
            reason: "only the chapter-boundary projection is enabled under ADR-7 amendment 1; "
                + "request for action \"search\" was never transmitted")
        ) {
            _ = try MirageDetailQuery.preflight(request, mappedEditionID: nil)
        }
    }

    @Test func dispatchNeverTouchesTheTransportForUnverifiedWork() async throws {
        let tripwire = ProbeTripwireTransport()
        let client = MirageClient(transport: tripwire, idProvider: { "test-id" })
        let probes: [(MirageWireAction, String)] = [
            (.search, "SPOILER-PROBE-REJECTED"),
            (.projection, "CURSOR-MISSING"),
        ]
        for (action, expectedCode) in probes {
            do {
                _ = try await MirageDetailQuery.dispatch(
                    probe(action, cursor: .unit(11)), mappedEditionID: nil, client: client)
                Issue.record("dispatch returned — it must refuse when unverified")
            } catch let gate as MirageCursorGateError {
                #expect(gate.pinnedCode == expectedCode)
            } catch {
                Issue.record("unexpected error type from dispatch: \(error)")
            }
        }
        #expect(tripwire.exchangeCount == 0)
    }

    @Test func verifiedBoundaryPreflightComposesOnlyProjection() throws {
        let edition = "edition_0123456789abcdef"
        let cursor = try verifiedBoundary(edition: edition)
        let request = MirageDetailRequest(
            action: .projection,
            editionID: edition,
            cursor: .chapterBoundary(cursor))
        let line = try MirageDetailQuery.preflight(
            request, mappedEditionID: edition)
        #expect(line.action == .projection)
        #expect(line.payload?.field("edition_id") == .string(edition))
        #expect(line.payload?.field("cursor_unit") == .int(23))
    }

    @Test func verifiedBoundaryDispatchIsTheOnlyDetailTransmission() async throws {
        let edition = "edition_0123456789abcdef"
        let cursor = try verifiedBoundary(edition: edition)
        let transport = BoundaryRecordingTransport()
        let client = MirageClient(transport: transport, idProvider: { "graph-1" })
        let outcome = try await MirageDetailQuery.dispatch(
            MirageDetailRequest(
                action: .projection,
                editionID: edition,
                cursor: .chapterBoundary(cursor)),
            mappedEditionID: edition,
            client: client)
        guard case .success = outcome else {
            Issue.record("expected a successful boundary projection")
            return
        }
        #expect(transport.requests.count == 1)
        let request = try #require(transport.requests.first)
        let object = try #require(
            JSONSerialization.jsonObject(with: request) as? [String: Any])
        #expect(object["action"] as? String == "projection")
        let payload = try #require(object["payload"] as? [String: Any])
        #expect(payload["edition_id"] as? String == edition)
        #expect(payload["cursor_unit"] as? Int == 23)
    }
}
