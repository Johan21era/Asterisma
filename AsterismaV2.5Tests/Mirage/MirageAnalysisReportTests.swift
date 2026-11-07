import Foundation
import Testing
@testable import AsterismaV2_5

// 2.7 — the analysis report is derived data. These pins prove the arithmetic,
// the analyzable-book boundary, orphan accounting, and the rule that a
// never-scanned index cannot claim a link is unindexed.

@Suite("Mirage Analysis Report (2.7)")
struct MirageAnalysisReportTests {
    private func entry(
        book: UUID,
        mirageBookID: String,
        editionID: String,
        status: MirageIdentityMapEntry.Status = .active,
        reason: MirageIdentityMapEntry.OrphanReason? = nil
    ) -> MirageIdentityMapEntry {
        MirageIdentityMapEntry(
            rtBookID: book,
            mirageBookID: mirageBookID,
            mirageEditionID: editionID,
            sourceFingerprint: String(repeating: "ab", count: 32),
            sourceResumeHint: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            status: status,
            orphanedReason: reason)
    }

    private func inventory(
        bookID: String,
        editionID: String,
        units: Int,
        claims: Int
    ) -> MirageInventoryEntry {
        MirageInventoryEntry(
            bookID: bookID,
            title: nil,
            editionID: editionID,
            units: units,
            claims: claims,
            maxCursor: max(0, units - 1),
            firstEntityID: nil,
            createdAt: nil)
    }

    @Test func emptyLibraryReportsZeroWithoutInventingAverages() {
        let report = MirageAnalysisReport(
            analyzableBookIDs: [],
            identityMap: .empty,
            index: .empty)

        #expect(report.analyzableCount == 0)
        #expect(report.linkedCount == 0)
        #expect(report.coveragePercent == 0)
        #expect(report.indexedEditionCount == 0)
        #expect(report.averageUnitsPerEdition == nil)
        #expect(report.averageClaimsPerEdition == nil)
        #expect(report.claimsPerUnit == nil)
        #expect(report.coverageLine == "No EPUB or comic books are in this library yet.")
    }

    @Test func coverageAndDensityCountOnlyAnalyzableBooks() {
        let a = UUID(), b = UUID()
        let map = MirageIdentityMapFile.empty
            .activating(entry(book: a, mirageBookID: "book_a", editionID: "edition_a"),
                        now: Date(timeIntervalSince1970: 1_700_000_000))
            .activating(entry(book: b, mirageBookID: "book_b", editionID: "edition_b"),
                        now: Date(timeIntervalSince1970: 1_700_000_000))
        let index = MirageLibraryIndexFile(
            schema: MirageLibraryIndexSchema.identifier,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            entries: [
                MirageLibraryIndexEntry(inventory(
                    bookID: "book_a", editionID: "edition_a", units: 10, claims: 2)),
                MirageLibraryIndexEntry(inventory(
                    bookID: "book_b", editionID: "edition_b", units: 20, claims: 0))
            ])

        let report = MirageAnalysisReport(
            analyzableBookIDs: [a, b, UUID()],
            identityMap: map,
            index: index)

        #expect(report.analyzableCount == 3)
        #expect(report.linkedCount == 2, "a link outside the analyzable set never inflates coverage")
        #expect(report.coveragePercent == 67)
        #expect(report.indexedEditionCount == 2)
        #expect(report.totalUnits == 30)
        #expect(report.totalClaims == 2)
        #expect(report.zeroClaimEditionCount == 1)
        #expect(report.averageUnitsPerEdition == 15)
        #expect(report.averageClaimsPerEdition == 1)
        #expect(report.claimsPerUnit == 2.0 / 30.0)
        #expect(report.unindexedLinkedCount == 0)
        #expect(report.pausedBookCount == 0)
    }

    @Test func scannedIndexFlagsUnindexedAndPausedLinks() {
        let a = UUID(), b = UUID(), c = UUID()
        let map = MirageIdentityMapFile.empty
            .activating(entry(book: a, mirageBookID: "book_a", editionID: "edition_a"),
                        now: Date(timeIntervalSince1970: 1_700_000_000))
            .activating(entry(book: b, mirageBookID: "book_b", editionID: "edition_b",
                              status: .orphaned, reason: .editionGone),
                        now: Date(timeIntervalSince1970: 1_700_000_000))
            .activating(entry(book: c, mirageBookID: "book_c", editionID: "edition_c",
                              status: .orphaned, reason: .sourceChanged),
                        now: Date(timeIntervalSince1970: 1_700_000_000))
        let index = MirageLibraryIndexFile(
            schema: MirageLibraryIndexSchema.identifier,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            entries: [
                MirageLibraryIndexEntry(inventory(
                    bookID: "book_a", editionID: "edition_a", units: 8, claims: 3))
            ])

        let report = MirageAnalysisReport(
            analyzableBookIDs: [a, b, c],
            identityMap: map,
            index: index)

        #expect(report.linkedCount == 1, "orphaned links are not active coverage")
        #expect(report.unindexedLinkedCount == 0, "the one active link is in the scan")
        #expect(report.pausedBookCount == 2, "both orphaned books are counted once each")
        #expect(report.indexedEditionCount == 1)
        #expect(report.totalUnits == 8)
        #expect(report.totalClaims == 3)

        // A second active link absent from the scan is the reconciliation case.
        let d = UUID()
        let mapWithD = map.activating(
            entry(book: d, mirageBookID: "book_d", editionID: "edition_d"),
            now: Date(timeIntervalSince1970: 1_700_000_000))
        let withD = MirageAnalysisReport(
            analyzableBookIDs: [a, b, c, d],
            identityMap: mapWithD,
            index: index)
        #expect(withD.linkedCount == 2)
        #expect(withD.unindexedLinkedCount == 1)
        #expect(withD.coveragePercent == 50)
    }

    @Test func neverScannedIndexNeverClaimsALinkIsUnindexed() {
        let a = UUID()
        let map = MirageIdentityMapFile.empty.activating(
            entry(book: a, mirageBookID: "book_a", editionID: "edition_a"),
            now: Date(timeIntervalSince1970: 1_700_000_000))
        let report = MirageAnalysisReport(
            analyzableBookIDs: [a],
            identityMap: map,
            index: .empty)

        #expect(report.scannedAt == nil)
        #expect(report.unindexedLinkedCount == 0,
                "no scan is missing evidence, not proof of a missing edition")
        #expect(report.indexedEditionCount == 0)
        #expect(report.summaryLine == "Every analyzable book has a Mirage link.")
    }
}
