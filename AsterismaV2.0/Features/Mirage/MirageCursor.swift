import Foundation

// PR-6 — ADR-7 (countersigned 2026-10-18; amendment 1 countersigned
// 2026-11-07): the spoiler-cursor machinery.
//
// Doctrine (ADR-7 Decision 1 + Annex A.2): NO verified page→unit conversion
// exists. Amendment 1 adds exactly one verified provenance: an engine-read
// chapter boundary. The graph for chapter N is projected at the last unit of
// chapter N−1, never inside the chapter being read. Every estimate, page
// coordinate, and unverified unit index is still refused.

// Three typed failures (ADR-7 body, S9-ES-5 classes; Annex A.6):
//   CURSOR-MISSING              — no mapped identity / no position data
//   SPOILER-CURSOR-UNVERIFIED   — a cursor offered without verified evidence
//   SPOILER-PROBE-REJECTED      — a request seeking detail disclosure at all

nonisolated enum MirageCursor: Sendable, Equatable {
    /// No position data at all (Annex A.6: fail closed).
    case absent
    /// The rejected estimate (progress fraction × the edition's `max_cursor`).
    /// Present as a case ONLY so the refusals below are testable; no RT code
    /// ever constructs it in production paths (ADR-7 "Alternatives — rejected").
    case estimated(fraction: Double, maxUnitIndex: Int)
    /// An RT-native page coordinate (Annex A.1 provenance) — a different
    /// coordinate space than the ledger's `unit_index`; unverifiable by space.
    case page(page: Int, totalPages: Int)
    /// A ledger unit index. Today NOTHING can verify one (Annex A.2); only a
    /// future countersigned calibration amendment may feed this case.
    case unit(Int)
    /// Amendment 1: the last unit of the previous engine chapter, read from
    /// the engine's chapter-boundary inventory. This is the only cursor RT can
    /// prove today.
    case chapterBoundary(MirageChapterBoundaryCursor)
}

nonisolated enum MirageCursorGateError: Error, Equatable, Sendable {
    /// CURSOR-MISSING
    case missingCursor(reason: String)
    /// SPOILER-CURSOR-UNVERIFIED
    case unverifiedCursor(reason: String)
    /// SPOILER-PROBE-REJECTED
    case detailProbeRejected(reason: String)

    var pinnedCode: String {
        switch self {
        case .missingCursor: return "CURSOR-MISSING"
        case .unverifiedCursor: return "SPOILER-CURSOR-UNVERIFIED"
        case .detailProbeRejected: return "SPOILER-PROBE-REJECTED"
        }
    }
}

nonisolated enum MirageCursorGate {
    /// Annex A.3 (edition-identity requirement): a cursor is valid only against
    /// its mapped `mirageEditionID`. Unmapped book ⇒ no cursor at all.
    /// Annex A.2 (conversion): every estimate, page, and raw unit cursor is
    /// unverified — refused with `SPOILER-CURSOR-UNVERIFIED`. Amendment 1
    /// admits only a boundary cursor carrying the mapped edition id.
    static func validatedDisclosureUnits(
        for cursor: MirageCursor,
        mappedEditionID: String?
    ) throws -> Int {
        guard let mappedEditionID, !mappedEditionID.isEmpty else {
            throw MirageCursorGateError.missingCursor(
                reason: "no active Mirage identity mapping for this book (ADR-7 Annex A.3)")
        }
        switch cursor {
        case .absent:
            throw MirageCursorGateError.missingCursor(
                reason: "no position data available for the mapped edition")
        case .estimated, .page, .unit:
            throw MirageCursorGateError.unverifiedCursor(
                reason: "no verified chapter→unit calibration exists (ADR-7 Decision 1) — the cursor is refused")
        case .chapterBoundary(let boundary):
            guard boundary.editionID == mappedEditionID else {
                throw MirageCursorGateError.unverifiedCursor(
                    reason: "chapter-boundary cursor belongs to \(boundary.editionID), not \(mappedEditionID)")
            }
            return boundary.cursorUnit
        }
    }
}

/// What a detail request would have been, typed for the record. `action` is
/// one of the wire's detail-disclosure endpoints (`.projection` / `.search`);
/// only a boundary projection can be composed by the amended gate.
nonisolated struct MirageDetailRequest: Sendable, Equatable {
    let action: MirageWireAction
    let editionID: String
    let cursor: MirageCursor
}

/// The detail call-site. Amendment 1 enables exactly one action, the
/// chapter-boundary projection, and only when the gate accepts a verified
/// boundary cursor. Every other detail request still refuses before transport.
nonisolated enum MirageDetailQuery {
    static func preflight(
        _ request: MirageDetailRequest,
        mappedEditionID: String?
    ) throws -> MirageWireRequestLine {
        guard request.action == .projection else {
            throw MirageCursorGateError.detailProbeRejected(
                reason: "only the chapter-boundary projection is enabled under ADR-7 amendment 1; "
                    + "request for action \"\(request.action.rawValue)\" was never transmitted")
        }
        guard let mappedEditionID, request.editionID == mappedEditionID else {
            throw MirageCursorGateError.missingCursor(
                reason: "no active Mirage identity mapping for this book (ADR-7 Annex A.3)")
        }
        let cursorUnit = try MirageCursorGate.validatedDisclosureUnits(
            for: request.cursor, mappedEditionID: mappedEditionID)
        return MirageWireRequestLine(
            action: .projection,
            payload: .payload([
                "edition_id": .string(request.editionID),
                "cursor_unit": .int(cursorUnit),
            ]),
            id: UUID().uuidString)
    }

    static func dispatch(
        _ request: MirageDetailRequest,
        mappedEditionID: String?,
        client: MirageClient
    ) async throws -> MirageClient.Outcome {
        let line = try preflight(request, mappedEditionID: mappedEditionID)
        return try await client.perform(line.action, payload: line.payload)
    }
}
