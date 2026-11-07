import Foundation

// 2.7 — the spoiler-safe analysis report.
//
// ADR-7 keeps claim text, evidence, entities, and graph detail behind the
// countersigned spoiler gate. This report deliberately stays on the safe side
// of that boundary: it reads only engine-attested inventory facts (units and
// claims) plus RT's own identity/link state. It never queries the engine, never
// promotes a count into RT's library, and never renders analysis content.
//
// The report exists to make Mirage's analysis measurable at library scale:
// coverage, indexed editions, claim density, paused links, and links that the
// last read-only scan did not see. Numbers without provenance are avoided; the
// UI labels every figure as an engine-attested inventory fact.

nonisolated struct MirageAnalysisReport: Equatable, Sendable {
    let analyzableCount: Int
    let linkedCount: Int
    let indexedEditionCount: Int
    let totalUnits: Int
    let totalClaims: Int
    let zeroClaimEditionCount: Int
    let unindexedLinkedCount: Int
    let pausedBookCount: Int
    let scannedAt: Date?

    init(
        analyzableBookIDs: Set<UUID>,
        identityMap: MirageIdentityMapFile?,
        index: MirageLibraryIndexFile
    ) {
        analyzableCount = analyzableBookIDs.count
        let entries = identityMap?.entries ?? []
        // Coverage is derived, never supplied: only an ACTIVE entry counts.
        // A caller cannot inflate the number with a stale or orphaned link.
        linkedCount = Set(entries.filter {
            $0.status == .active && analyzableBookIDs.contains($0.rtBookID)
        }.map(\.rtBookID)).count
        indexedEditionCount = index.entries.count
        totalUnits = index.totalUnits
        totalClaims = index.totalClaims
        zeroClaimEditionCount = index.entries.filter { $0.claims == 0 }.count
        scannedAt = index.generatedAt

        let paused = Set(entries.filter {
            $0.status == .orphaned && analyzableBookIDs.contains($0.rtBookID)
        }.map(\.rtBookID))
        pausedBookCount = paused.count

        // "Unindexed" is only meaningful after a real scan. A never-scanned
        // index is missing evidence, not evidence of a missing edition.
        guard index.isScanned else {
            unindexedLinkedCount = 0
            return
        }
        let indexed = Set(index.entries.map {
            MirageIdentityLinkKey(bookID: $0.bookID, editionID: $0.editionID)
        })
        let activeLinked = Set(entries.compactMap { entry -> MirageIdentityLinkKey? in
            guard entry.status == .active,
                  analyzableBookIDs.contains(entry.rtBookID) else { return nil }
            return MirageIdentityLinkKey(
                bookID: entry.mirageBookID,
                editionID: entry.mirageEditionID)
        })
        unindexedLinkedCount = activeLinked.subtracting(indexed).count
    }

    var coverageFraction: Double {
        guard analyzableCount > 0 else { return 0 }
        return Double(linkedCount) / Double(analyzableCount)
    }

    var coveragePercent: Int {
        Int((coverageFraction * 100).rounded())
    }

    var averageUnitsPerEdition: Double? {
        guard indexedEditionCount > 0 else { return nil }
        return Double(totalUnits) / Double(indexedEditionCount)
    }

    var averageClaimsPerEdition: Double? {
        guard indexedEditionCount > 0 else { return nil }
        return Double(totalClaims) / Double(indexedEditionCount)
    }

    var claimsPerUnit: Double? {
        guard totalUnits > 0 else { return nil }
        return Double(totalClaims) / Double(totalUnits)
    }

    /// A measured coverage statement, never a quality judgment. "Complete"
    /// means every analyzable book has a link, not that the analysis is good.
    var coverageLine: String {
        if analyzableCount == 0 {
            return "No EPUB or comic books are in this library yet."
        }
        if linkedCount == 0 {
            return "Mirage has no analysis links in this library yet."
        }
        if linkedCount == analyzableCount {
            return "Every analyzable book has a Mirage link."
        }
        return "\(linkedCount) of \(analyzableCount) analyzable books have a Mirage link."
    }

    /// The honest one-line strength summary: coverage and engine-attested
    /// volume only. It never implies reading quality or extraction accuracy.
    var summaryLine: String {
        guard indexedEditionCount > 0 else { return coverageLine }
        let units = totalUnits.formatted()
        let claims = totalClaims.formatted()
        return "\(coverageLine) The last scan saw \(indexedEditionCount) edition\(indexedEditionCount == 1 ? "" : "s"), \(units) unit\(totalUnits == 1 ? "" : "s"), and \(claims) claim\(totalClaims == 1 ? "" : "s")."
    }
}
