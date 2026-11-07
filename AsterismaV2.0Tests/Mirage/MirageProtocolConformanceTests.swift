import Foundation
import Testing
@testable import AsterismaV2_0

// MirageProtocolConformanceTests (integration PR-3, ADR-2).
//
// Pins the wire contract between RT's typed client and the Mirage engine's
// PROVEN NDJSON dispatcher at SHA 81422613… (evidence: docs/integration/
// phase1/mirage-protocol-extraction.md). These are fake-transport tests only —
// zero process spawns, zero runtime dependency on the engine (S16-ES-1 PR-3).

@Suite struct MirageProtocolConformanceTests {

    // MARK: - Action-name census (playbook S6-ES-2 census arithmetic on the wire)

    @Test func actionSetMatchesPinnedEnginePlusAmendmentExtension() {
        let expected: [String] = [
            "health", "version", "import_epub", "analyze", "projection", "search",
            "checkpoint", "verify_checkpoint", "reconstruct", "verify_deltas",
            "export_graph", "cited_claims", "neighborhood", "edge_detail", "history",
            "books_list", "edition_remove", "book_remove", "search_eligible",
            "series_create", "series_list", "series_candidates", "series_attach",
            "series_detach", "series_read_state", "series_breakdown", "series_remove",
            "translate",
            // ADR-7 amendment 1 (2026-11-07): the one read-only extension.
            "edition_chapters",
        ]
        #expect(MirageWireAction.allCases.count == expected.count)
        for action in MirageWireAction.allCases {
            #expect(expected.contains(action.rawValue), "unmapped action \(action.rawValue)")
        }
    }

    @Test func chapterBoundaryActionIsTheSingleAmendmentExtension() {
        let pinnedV28: Set<String> = [
            "health", "version", "import_epub", "analyze", "projection", "search",
            "checkpoint", "verify_checkpoint", "reconstruct", "verify_deltas",
            "export_graph", "cited_claims", "neighborhood", "edge_detail", "history",
            "books_list", "edition_remove", "book_remove", "search_eligible",
            "series_create", "series_list", "series_candidates", "series_attach",
            "series_detach", "series_read_state", "series_breakdown", "series_remove",
            "translate",
        ]
        let actual = Set(MirageWireAction.allCases.map(\.rawValue))
        #expect(actual.subtracting(pinnedV28) == Set(["edition_chapters"]))
        #expect(MirageWireAction.editionChapters.rawValue == "edition_chapters")
    }

    // MARK: - Request-line encoding

    @Test func requestLineEncodesExactlyIdActionAndPayload() throws {
        let request = MirageWireRequestLine(
            action: .projection,
            payload: .payload(["edition_id": .string("edition_abc"), "cursor_unit": .int(4)]),
            id: "req-1")
        let data = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["id"] as? String == "req-1")
        #expect(object["action"] as? String == "projection")
        #expect(object["payload"] as? [String: Any] != nil)
        #expect(Set(object.keys) == Set(["id", "action", "payload"]))
    }

    @Test func omittedPayloadStaysOmitted() throws {
        let request = MirageWireRequestLine(action: .version, payload: nil, id: "req-2")
        let data = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == Set(["id", "action"]))
    }

    // MARK: - Envelope decoding (verbatim engine shapes)

    @Test func successEnvelopeDecodesWithResultVerbatim() throws {
        let line = #"{"id": "req-3", "ok": true, "result": {"api_version": "1.0.0"}}"#
        let envelope = try JSONDecoder().decode(
            MirageWireEnvelope.self,
            from: Data(line.utf8))
        #expect(envelope.ok)
        #expect(envelope.id == "req-3")
        #expect(envelope.error == nil)
        #expect(envelope.result?.field("api_version") == .string("1.0.0"))
    }

    @Test func engineErrorEnvelopePreservesAsymmetricCodeStatusPair() throws {
        // Unknown command raises ValidationError built with status 404 while the
        // mapper keeps code "validation_error" (service.py:997) — the pair passes
        // through untouched (publish, never edit).
        let line = ##"""
{"ok": false, "id": "req-4", "error": {"type": "ValidationError",
"code": "validation_error", "status": 404, "message": "unknown command: bogus"}}
"""##
        let envelope = try JSONDecoder().decode(
            MirageWireEnvelope.self,
            from: Data(line.utf8))
        #expect(!envelope.ok)
        let error = try #require(envelope.error)
        #expect(error == MirageWireErrorPayload(
            type: "ValidationError", code: "validation_error", status: 404,
            message: "unknown command: bogus"))
    }

    // MARK: - Client correlation + outcomes (ScriptedTransport double)

    @Test func clientCorrelatesEchoedIdAndYieldsSuccess() async throws {
        let client = MirageClient(transport: ScriptedTransport { requestLine in
            #expect(!requestLine.isEmpty)
            #expect(requestLine.last != UInt8(ascii: "\n"), "transport receives unframed lines")
            return Data(#"{"ok": true, "id": "pinned-id", "result": {"status": "ready"}}"#.utf8)
        }, idProvider: { "pinned-id" })
        let outcome = try await client.perform(.health)
        guard case .success(let value) = outcome else {
            Issue.record("expected success outcome")
            return
        }
        #expect(value.field("status") == .string("ready"))
    }

    @Test func engineErrorResponseSurfacesVerbatimPayload() async throws {
        let client = MirageClient(transport: ScriptedTransport { _ in
            Data(##"{"ok": false, "id": "x", "error": {"type": "NotFoundError", "code": "not_found", "status": 404, "message": "unknown edition"}}"##.utf8)
        }, idProvider: { "x" })
        let outcome = try await client.perform(.projection, payload: .payload(["edition_id": .string("edition_x"), "cursor_unit": .int(1)]))
        guard case .engineError(let error) = outcome else {
            Issue.record("expected engine error outcome")
            return
        }
        #expect(error.code == "not_found")
        #expect(error.status == 404)
    }

    @Test func mismatchedEchoedIdFailsTyped() async throws {
        let client = MirageClient(transport: ScriptedTransport { _ in
            Data(#"{"ok": true, "id": "wrong", "result": {}}"#.utf8)
        }, idProvider: { "expected" })
        await #expect(throws: MirageClient.Fault.correlationFailure(expected: "expected", received: "wrong")) {
            _ = try await client.perform(.version)
        }
    }

    @Test func missingEchoedIdFailsTyped() async throws {
        let client = MirageClient(transport: ScriptedTransport { _ in
            Data(#"{"ok": true, "result": {}}"#.utf8)
        }, idProvider: { "expected" })
        do {
            _ = try await client.perform(.version)
            Issue.record("missing id must fail correlation")
        } catch let fault as MirageClient.Fault {
            #expect(fault == .correlationFailure(expected: "expected", received: nil))
        }
    }

    // MARK: - Framing corruption (S2-ES-4: one JSON value per line)

    @Test func multiValueLineIsTypedUnparsable() async throws {
        try await assertUnparsableLine(#"{"ok": true, "id": "x", "result": {}}{"ok": true}"#)
    }

    @Test func arrayLineIsTypedUnparsable() async throws {
        try await assertUnparsableLine(#"[{"ok": true}]"#)
    }

    @Test func bareScalarLineIsTypedUnparsable() async throws {
        try await assertUnparsableLine(#""just a string""#)
    }

    @Test func brokenJSONLineIsTypedUnparsable() async throws {
        try await assertUnparsableLine(#"{"ok": true, "id": "x", "result": {"unclosed"#)
    }

    private func assertUnparsableLine(_ line: String) async throws {
        let client = MirageClient(transport: ScriptedTransport { _ in Data(line.utf8) },
                                  idProvider: { "x" })
        do {
            _ = try await client.perform(.version)
            Issue.record("corrupt line must raise responseUnparsable")
        } catch let fault as MirageClient.Fault {
            guard case .responseUnparsable = fault else {
                Issue.record("wrong fault \(fault)")
                return
            }
        }
    }

    // MARK: - Transport failures rethrow unchanged (ADR-2 §3)

    struct ProbeTransportFailure: Error, Sendable, Equatable {}

    @Test func transportFailureRethrowsUnchanged() async throws {
        let client = MirageClient(transport: ScriptedTransport { _ in
            throw ProbeTransportFailure()
        }, idProvider: { "x" })
        await #expect(throws: ProbeTransportFailure()) {
            _ = try await client.perform(.version)
        }
    }
}

/// Minimal scripted double honoring the transport framing contract (no newline
/// in, no newline out). Assertions inside the closure fail the test on violation.
nonisolated struct ScriptedTransport: MirageTransport {
    private let respond: @Sendable (Data) throws -> Data

    init(respond: @escaping @Sendable (Data) throws -> Data) {
        self.respond = respond
    }

    func exchange(_ requestLine: Data) async throws -> Data {
        try respond(requestLine)
    }
}
