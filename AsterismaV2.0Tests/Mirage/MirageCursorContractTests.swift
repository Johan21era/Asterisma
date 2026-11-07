import Foundation
import Testing
@testable import AsterismaV2_0

// ADR-7 (countersigned 2026-10-18; amendment 1 countersigned 2026-11-07) —
// cursor contract pins: estimates, page coordinates, and raw unit indexes are
// still refused; the amendment accepts exactly one provenance, a boundary
// cursor whose edition matches the mapped edition. Pure value-level: no
// transport, no processes.

@Suite("Mirage Cursor Contract (PR-6 + amendment 1)", .serialized)
struct MirageCursorContractTests {
    // ---- ADR-7 Decision 1 + Annex A.2: unverified cursors are refused ------

    @Test func everyUnverifiedCursorIsRefused() throws {
        let edition = "edition_0123456789abcdef"
        let offered: [MirageCursor] = [
            .estimated(fraction: 0.42, maxUnitIndex: 311),
            .page(page: 77, totalPages: 240),
            .unit(143), // even a well-formed unit index cannot be verified by RT
        ]
        for cursor in offered {
            #expect(throws: MirageCursorGateError.unverifiedCursor(
                reason: "no verified chapter→unit calibration exists (ADR-7 Decision 1) — the cursor is refused")
            ) {
                _ = try MirageCursorGate.validatedDisclosureUnits(
                    for: cursor, mappedEditionID: edition)
            }
        }
    }

    @Test func absentCursorFailsClosedAsMissing() {
        #expect(throws: MirageCursorGateError.missingCursor(
            reason: "no position data available for the mapped edition")
        ) {
            _ = try MirageCursorGate.validatedDisclosureUnits(
                for: .absent, mappedEditionID: "edition_0123456789abcdef")
        }
    }

    // ---- Annex A.3: edition-identity requirement precedes everything --------

    @Test func noMappedEditionMeansNoCursorAtAll() {
        for cursor in MirageCursor.allTestShapes {
            #expect(throws: MirageCursorGateError.missingCursor(
                reason: "no active Mirage identity mapping for this book (ADR-7 Annex A.3)"))
            {
                _ = try MirageCursorGate.validatedDisclosureUnits(
                    for: cursor, mappedEditionID: nil)
            }
            #expect(throws: MirageCursorGateError.missingCursor(
                reason: "no active Mirage identity mapping for this book (ADR-7 Annex A.3)"))
            {
                _ = try MirageCursorGate.validatedDisclosureUnits(
                    for: cursor, mappedEditionID: "")
            }
        }
    }

    // ---- Amendment 1: exactly one verified provenance ----------------------

    @Test func verifiedBoundaryIsAcceptedOnlyForItsMappedEdition() throws {
        let edition = "edition_0123456789abcdef"
        let cursor = try #require(MirageChapterBoundaryCursor(
            editionID: edition,
            rtChapterIndex: 2,
            previousChapterIndex: 2,
            cursorUnit: 23,
            previousChapterUnitCount: 12))

        #expect(try MirageCursorGate.validatedDisclosureUnits(
            for: .chapterBoundary(cursor), mappedEditionID: edition) == 23)

        #expect(throws: MirageCursorGateError.unverifiedCursor(
            reason: "chapter-boundary cursor belongs to \(edition), not edition_other")
        ) {
            _ = try MirageCursorGate.validatedDisclosureUnits(
                for: .chapterBoundary(cursor), mappedEditionID: "edition_other")
        }

        #expect(throws: MirageCursorGateError.missingCursor(
            reason: "no active Mirage identity mapping for this book (ADR-7 Annex A.3)")
        ) {
            _ = try MirageCursorGate.validatedDisclosureUnits(
                for: .chapterBoundary(cursor), mappedEditionID: nil)
        }
    }

    @Test func boundaryCursorRejectsImpossibleShapes() {
        #expect(MirageChapterBoundaryCursor(
            editionID: "", rtChapterIndex: 1, previousChapterIndex: 1,
            cursorUnit: 0, previousChapterUnitCount: 1) == nil)
        #expect(MirageChapterBoundaryCursor(
            editionID: "e", rtChapterIndex: 0, previousChapterIndex: 0,
            cursorUnit: 0, previousChapterUnitCount: 1) == nil)
        #expect(MirageChapterBoundaryCursor(
            editionID: "e", rtChapterIndex: 2, previousChapterIndex: 1,
            cursorUnit: 0, previousChapterUnitCount: 1) == nil)
        #expect(MirageChapterBoundaryCursor(
            editionID: "e", rtChapterIndex: 1, previousChapterIndex: 1,
            cursorUnit: -1, previousChapterUnitCount: 1) == nil)
        #expect(MirageChapterBoundaryCursor(
            editionID: "e", rtChapterIndex: 1, previousChapterIndex: 1,
            cursorUnit: 0, previousChapterUnitCount: 0) == nil)
    }

    // ---- Pinned S9-ES-5 failure codes ---------------------------------------

    @Test func failureCodesCarryTheirPinnedNames() {
        #expect(MirageCursorGateError.missingCursor(reason: "x").pinnedCode == "CURSOR-MISSING")
        #expect(MirageCursorGateError.unverifiedCursor(reason: "x").pinnedCode == "SPOILER-CURSOR-UNVERIFIED")
        #expect(MirageCursorGateError.detailProbeRejected(reason: "x").pinnedCode == "SPOILER-PROBE-REJECTED")
    }
}

private extension MirageCursor {
    static var allTestShapes: [MirageCursor] {
        [.absent, .estimated(fraction: 0.1, maxUnitIndex: 10), .page(page: 2, totalPages: 9), .unit(1)]
    }
}
