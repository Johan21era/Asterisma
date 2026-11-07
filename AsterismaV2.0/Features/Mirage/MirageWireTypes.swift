import Foundation

// Mirage ↔ RT wire vocabulary.
//
// Source of truth: MirageV1.0 `serve.py` / `api/service.py` dispatcher at pinned
// SHA 81422613… (evidence docs/integration/phase1/mirage-protocol-extraction.md).
// This file encodes the PROVEN contract verbatim — no invented fields (ADR-2 §1).
// Wire shape: one compact JSON value per LF-terminated line; UTF-8, no BOM.

/// Protocol actions accepted by the Mirage engine's `run_command` dispatcher
/// (28 documented endpoints, plus the ADR-7 amendment-1 `edition_chapters`
/// read-only extension; the bare "import" alias exists engine-side but is
/// intentionally not represented — RT always sends the canonical `import_epub`).
nonisolated enum MirageWireAction: String, CaseIterable, Sendable, Encodable {
    case health = "health"
    case version = "version"
    case importEpub = "import_epub"
    case analyze = "analyze"
    case projection = "projection"
    case search = "search"
    case checkpoint = "checkpoint"
    case verifyCheckpoint = "verify_checkpoint"
    case reconstruct = "reconstruct"
    case verifyDeltas = "verify_deltas"
    case exportGraph = "export_graph"
    case citedClaims = "cited_claims"
    case neighborhood = "neighborhood"
    case edgeDetail = "edge_detail"
    case history = "history"
    case booksList = "books_list"
    /// ADR-7 amendment 1: read-only chapter-boundary inventory. Not present in
    /// the pinned 28-action engine build; the engine owner must add it before
    /// the graph can go live.
    case editionChapters = "edition_chapters"
    case editionRemove = "edition_remove"
    case bookRemove = "book_remove"
    case searchEligible = "search_eligible"
    case seriesCreate = "series_create"
    case seriesList = "series_list"
    case seriesCandidates = "series_candidates"
    case seriesAttach = "series_attach"
    case seriesDetach = "series_detach"
    case seriesReadState = "series_read_state"
    case seriesBreakdown = "series_breakdown"
    case seriesRemove = "series_remove"
    case translate = "translate"
}

/// A flexible JSON value so RT can express every payload/result shape the engine
/// documents without pinning unproven keys (M-009 P-10④: health/version/projection
/// key sets are only partially proven — decode envlopes verbatim, type later).
nonisolated enum MirageJSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([MirageJSONValue])
    case object([String: MirageJSONValue])
}

extension MirageJSONValue {
    /// Convenience for building payloads: mirrors the engine's `payload or {}`.
    nonisolated static func payload(_ fields: [String: MirageJSONValue]) -> MirageJSONValue {
        .object(fields)
    }

    /// Lookup into an object case, nil for any other shape.
    nonisolated func field(_ key: String) -> MirageJSONValue? {
        guard case .object(let map) = self else { return nil }
        return map[key]
    }
}

/// The request line RT sends. `id` is RT-generated; the engine echoes it verbatim
/// (serve.py:38-40, "the host bridge routes responses back by the id") — this is
/// proven engine behavior, not an RT invention, and is the correlation key.
nonisolated struct MirageWireRequestLine: Sendable, Encodable {
    let action: MirageWireAction
    var payload: MirageJSONValue?
    let id: String
}

/// The engine's strict error object (api/errors.py + serve.py:15-24): all four
/// keys are always present (getattr defaults fill code/status), so decode strictly.
nonisolated struct MirageWireErrorPayload: Sendable, Decodable, Equatable {
    let type: String
    let code: String
    let status: Int
    let message: String
}

/// The proven response envelope: `{"ok": true, "result": …}` or
/// `{"ok": false, "error": {type, code, status, message}}`, with the echoed `id`
/// whenever the request carried one. Decoded verbatim; unknown-command asymmetry
/// (ValidationEerror built with status 404 but code validation_error) is preserved
/// field-for-field — counter-interpretation doctrine: publish, never edit.
nonisolated struct MirageWireEnvelope: Sendable, Decodable, Equatable {
    let ok: Bool
    let id: String?
    let result: MirageJSONValue?
    let error: MirageWireErrorPayload?
}

// MARK: - JSONValue Codable (dynamic shapes)

extension MirageJSONValue {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) { self = .bool(bool); return }
        if let int = try? container.decode(Int.self) { self = .int(int); return }
        if let double = try? container.decode(Double.self) { self = .double(double); return }
        if let string = try? container.decode(String.self) { self = .string(string); return }
        if let array = try? container.decode([MirageJSONValue].self) { self = .array(array); return }
        if let object = try? container.decode([String: MirageJSONValue].self) { self = .object(object); return }
        if try container.decodeNil() { self = .null; return }
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "Unsupported Mirage JSON value"))
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
