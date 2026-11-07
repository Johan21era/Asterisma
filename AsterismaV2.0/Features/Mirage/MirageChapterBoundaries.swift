import Foundation

// ADR-7 amendment 1 (countersigned 2026-11-07): the ONLY new spoiler-sensitive
// read is a read-only chapter-boundary inventory. It carries no prose, claims,
// entities, or evidence — just the unit range each EPUB spine chapter owns.
//
// The graph therefore has a deliberately conservative cursor:
//
//     graph for chapter N  =  projection at the LAST unit of chapter N-1
//
// Chapter 1 has no earlier boundary, so its graph is unavailable. This is the
// price of never disclosing the chapter the reader is currently inside. A
// future calibration may add within-chapter precision; this amendment does not.

nonisolated struct MirageChapterBoundary: Equatable, Sendable {
    /// Engine spine chapter number, 1-based (Mirage ingestion/epub.py).
    let chapterIndex: Int
    let firstUnitIndex: Int
    let lastUnitIndex: Int
    let unitCount: Int
}

nonisolated struct MirageChapterMap: Equatable, Sendable {
    let editionID: String
    let chapters: [MirageChapterBoundary]

    /// Strict decode of the amendment's engine result:
    /// `{edition_id, chapters: [{chapter_index, first_unit_index,
    /// last_unit_index, unit_count}]}`. Any gap, overlap, impossible range, or
    /// duplicate chapter refuses the whole map (fail closed).
    static func decode(_ wire: MirageJSONValue) -> MirageChapterMap? {
        guard case .object(let fields) = wire,
              case .string(let editionID)? = fields["edition_id"],
              !editionID.isEmpty,
              case .array(let rows)? = fields["chapters"],
              !rows.isEmpty
        else { return nil }

        var chapters: [MirageChapterBoundary] = []
        for row in rows {
            guard case .object(let values) = row,
                  case .int(let chapterIndex)? = values["chapter_index"],
                  case .int(let firstUnitIndex)? = values["first_unit_index"],
                  case .int(let lastUnitIndex)? = values["last_unit_index"],
                  case .int(let unitCount)? = values["unit_count"],
                  chapterIndex > 0,
                  firstUnitIndex >= 0,
                  lastUnitIndex >= firstUnitIndex,
                  unitCount > 0,
                  unitCount == lastUnitIndex - firstUnitIndex + 1
            else { return nil }
            chapters.append(MirageChapterBoundary(
                chapterIndex: chapterIndex,
                firstUnitIndex: firstUnitIndex,
                lastUnitIndex: lastUnitIndex,
                unitCount: unitCount))
        }

        chapters.sort { $0.chapterIndex < $1.chapterIndex }
        for pair in zip(chapters, chapters.dropFirst()) {
            guard pair.0.chapterIndex < pair.1.chapterIndex,
                  pair.0.lastUnitIndex < pair.1.firstUnitIndex
            else { return nil }
        }
        return MirageChapterMap(editionID: editionID, chapters: chapters)
    }

    /// The cursor for an RT chapter index (0-based). RT chapter N maps to
    /// engine chapter N+1; its safe graph boundary is the last unit of engine
    /// chapter N. Returns nil for the first chapter, missing boundaries, or
    /// any map that does not cover the requested chapter.
    func safeCursor(forRTChapterIndex index: Int) -> MirageChapterBoundaryCursor? {
        guard index > 0 else { return nil }
        guard let previous = chapters.first(where: { $0.chapterIndex == index }) else {
            return nil
        }
        return MirageChapterBoundaryCursor(
            editionID: editionID,
            rtChapterIndex: index,
            previousChapterIndex: previous.chapterIndex,
            cursorUnit: previous.lastUnitIndex,
            previousChapterUnitCount: previous.unitCount)
    }
}

/// A cursor whose provenance is the engine's boundary read, not an estimate.
/// The validation is intentionally shape-level; the proof is the engine result
/// this value is only constructed from (`MirageChapterMap.safeCursor`).
nonisolated struct MirageChapterBoundaryCursor: Codable, Equatable, Sendable {
    let editionID: String
    let rtChapterIndex: Int
    let previousChapterIndex: Int
    let cursorUnit: Int
    let previousChapterUnitCount: Int

    init?(
        editionID: String,
        rtChapterIndex: Int,
        previousChapterIndex: Int,
        cursorUnit: Int,
        previousChapterUnitCount: Int
    ) {
        guard !editionID.isEmpty,
              rtChapterIndex > 0,
              previousChapterIndex > 0,
              previousChapterIndex == rtChapterIndex,
              cursorUnit >= 0,
              previousChapterUnitCount > 0
        else { return nil }
        self.editionID = editionID
        self.rtChapterIndex = rtChapterIndex
        self.previousChapterIndex = previousChapterIndex
        self.cursorUnit = cursorUnit
        self.previousChapterUnitCount = previousChapterUnitCount
    }
}
