//  SentinelSurfaceTests.swift
//  AsterismaV2.5Tests
//
//  The modularity pins. They answer one question: if a feature lands tomorrow
//  with a new table, does Sentinel see it without anyone editing a probe?
//
//  The proof is split:
//    * scanner output   — the generated catalog is non-empty and well-formed;
//    * policy           — a synthetic table added to the catalog is owned
//                         automatically, and removing SQL-016 exposes every
//                         table as a gap instead of a silent pass;
//    * execution        — SQL-016 reports a table the database does not have,
//                         and is silent on a fully migrated database;
//    * meta-probe       — SELF-011 raises the lost-ownership report once per
//                         required family and stays quiet on the real catalog.

import Foundation
import GRDB
import Testing

@testable import AsterismaV2_5

@Suite("Sentinel Surface Inventory", .serialized)
struct SentinelSurfaceTests {

    // MARK: - Catalog shape

    @Test("The generated catalog is complete and addressable")
    func catalogShape() {
        let catalog = SentinelSurfaceRegistry.current
        #expect(catalog.schemaVersion == 1)
        #expect(!catalog.isEmpty)
        #expect(catalog.surfaceCount >= 28)
        #expect(catalog.digest.count == 16)
        #expect(catalog.digest.allSatisfy { $0.isHexDigit })

        // Sorted output is what makes regeneration byte-stable.
        #expect(catalog.sqlTables == catalog.sqlTables.sorted())
        #expect(catalog.defaultsKeys == catalog.defaultsKeys.sorted())
        #expect(catalog.notificationNames == catalog.notificationNames.sorted())

        // The inventory must actually observe the core schema.
        for expected in ["books", "sessions", "page_times", "library_state", "book_collections", "meta"] {
            #expect(catalog.sqlTables.contains(expected), "missing \(expected)")
        }

        #expect(catalog.keys.count == catalog.surfaceCount)
        #expect(Set(catalog.keys).count == catalog.surfaceCount)
    }

    // MARK: - Policy

    @Test("Every required surface has a registered owner")
    func requiredCoverageIsComplete() {
        let report = SentinelSurfacePolicy.report(
            for: SentinelSurfaceRegistry.current,
            registeredProbeIDs: Set(SentinelProbeCatalog.descriptors.map(\.id)))
        #expect(report.isRequiredComplete)
        #expect(report.requiredCoverage == 1.0)
        #expect(report.requiredGaps.isEmpty)
        // The shipped catalog has no advisory debt: every discovered preference
        // is either owned by a real probe or explicitly waived.
        #expect(report.advisoryGaps.isEmpty, "\(report.advisoryGaps.map(\.entry.key))")
    }

    @Test("A table added after generation is covered with no new probe")
    func newTableIsOwnedAutomatically() {
        var catalog = SentinelSurfaceRegistry.current
        catalog.sqlTables.append("feature_2099_events")
        catalog.sqlTables.sort()

        let report = SentinelSurfacePolicy.report(
            for: catalog,
            registeredProbeIDs: Set(SentinelProbeCatalog.descriptors.map(\.id)))

        #expect(report.isRequiredComplete)
        #expect(report.entries.contains { $0.key == "sql.table.feature_2099_events" })
        #expect(SentinelSurfacePolicy.registeredOwners(
            for: SentinelSurfaceEntry(family: .sqlTable, name: "feature_2099_events"),
            registeredProbeIDs: Set(SentinelProbeCatalog.descriptors.map(\.id))) == ["SQL-016"])
    }

    @Test("Losing the auto-probe turns every table into a required gap")
    func lostOwnerIsDetected() {
        let allIDs = Set(SentinelProbeCatalog.descriptors.map(\.id))
        var withoutAutoProbe = allIDs
        withoutAutoProbe.remove("SQL-016")

        let report = SentinelSurfacePolicy.report(
            for: SentinelSurfaceRegistry.current,
            registeredProbeIDs: withoutAutoProbe)

        #expect(!report.isRequiredComplete)
        #expect(report.requiredCoverage == 0)
        #expect(report.requiredGaps.count == SentinelSurfaceRegistry.current.sqlTables.count)
        #expect(report.requiredGaps.allSatisfy { $0.reason == .ownerNotRegistered })
        #expect(report.requiredGaps.allSatisfy { $0.declaredOwner == "SQL-016" })
    }

    @Test("An unknown preference is counted but never raised as an issue")
    func advisoryDebtIsVisible() {
        var catalog = SentinelSurfaceRegistry.current
        catalog.defaultsKeys.append("feature_2099.optIn")
        catalog.defaultsKeys.sort()

        let report = SentinelSurfacePolicy.report(
            for: catalog,
            registeredProbeIDs: Set(SentinelProbeCatalog.descriptors.map(\.id)))

        #expect(report.isRequiredComplete)
        #expect(report.advisoryGaps.count == 1)
        #expect(report.advisoryGaps[0].entry.key == "defaults.key.feature_2099.optIn")
        #expect(report.advisoryGaps[0].reason == .noOwner)
    }

    @Test("A waiver is a decision, not a gap")
    func waiversAreNotGaps() {
        let report = SentinelSurfacePolicy.report(
            for: SentinelSurfaceRegistry.current,
            registeredProbeIDs: Set(SentinelProbeCatalog.descriptors.map(\.id)))
        let waived = SentinelSurfacePolicy.waivers.keys
        #expect(!waived.isEmpty)
        #expect(report.gaps.allSatisfy { !waived.contains($0.entry.key) })
    }

    // MARK: - SQL-016 execution

    private func migratedSnapshot(
        root: SentinelTempRoot,
        catalog: SentinelSurfaceCatalog = SentinelSurfaceRegistry.current
    ) throws -> SentinelSnapshot {
        let url = root.url.appendingPathComponent("library.grdb.sqlite3")
        _ = try LibraryDatabase(url: url)
        return SentinelSnapshot.fixture(
            books: [],
            state: LibraryState(),
            dataRoot: root.url,
            now: sentinelTestNow,
            defaults: UserDefaults(suiteName: "sentinel.surface.\(UUID().uuidString)")!,
            surfaceCatalog: catalog)
    }

    private func environment(_ root: SentinelTempRoot) -> SentinelEnvironment {
        SentinelEnvironment.test(
            clock: TestSentinelClock(sentinelTestNow),
            dataRoot: root.url,
            tempRoot: root.url,
            isDebug: true)
    }

    @Test("SQL-016 is silent on a fully migrated database")
    func tableContractIsSilentOnMigratedDatabase() async throws {
        let root = SentinelTempRoot()
        defer { root.remove() }
        let snapshot = try migratedSnapshot(root: root)

        let findings = try await SQL016TableContract().run(
            snapshot: snapshot,
            environment: environment(root))
        let details = findings.compactMap(\.debugDetail).joined(separator: ", ")
        #expect(findings.isEmpty, "\(details)")
    }

    @Test("SQL-016 names a table that the schema does not contain")
    func tableContractCatchesNewSurface() async throws {
        let root = SentinelTempRoot()
        defer { root.remove() }
        var catalog = SentinelSurfaceRegistry.current
        catalog.sqlTables.append("feature_2099_events")
        catalog.sqlTables.sort()
        let snapshot = try migratedSnapshot(root: root, catalog: catalog)

        let findings = try await SQL016TableContract().run(
            snapshot: snapshot,
            environment: environment(root))

        let subject = SentinelSubject(.database, "feature_2099_events")
        let match = findings.first { $0.subjects.contains(subject) }
        #expect(match != nil)
        #expect(match?.evidence.contains { $0.safeValue == "missing" } == true)
        #expect(match?.probeID == "SQL-016")
        #expect(match?.severity == .critical)
        // The pre-existing tables are not collateral damage.
        #expect(findings.count == 1)
    }

    @Test("SQL-016 skips, rather than passes, with no database")
    func tableContractSkipsWithoutDatabase() async {
        let root = SentinelTempRoot()
        defer { root.remove() }
        let snapshot = SentinelSnapshot.fixture(
            books: [],
            state: LibraryState(),
            dataRoot: root.url,
            now: sentinelTestNow,
            defaults: UserDefaults(suiteName: "sentinel.surface.none.\(UUID().uuidString)")!,
            surfaceCatalog: SentinelSurfaceRegistry.current)

        await #expect(throws: SentinelProbeUnavailable.self) {
            _ = try await SQL016TableContract().run(
                snapshot: snapshot,
                environment: environment(root))
        }
    }

    // MARK: - SELF-011

    @Test("SELF-011 is silent for the shipped catalog")
    func coverageProbeIsSilent() async throws {
        let root = SentinelTempRoot()
        defer { root.remove() }
        let snapshot = SentinelSnapshot.fixture(
            books: [],
            state: LibraryState(),
            dataRoot: root.url,
            now: sentinelTestNow,
            defaults: UserDefaults(suiteName: "sentinel.surface.quiet.\(UUID().uuidString)")!,
            surfaceCatalog: SentinelSurfaceRegistry.current)

        let findings = try await SELF011SurfaceCoverage().run(
            snapshot: snapshot,
            environment: environment(root))
        #expect(findings.isEmpty)
    }

    @Test("SELF-011 emits one finding per required family when ownership is lost")
    func coverageProbeEmitsPerFamily() {
        let allIDs = Set(SentinelProbeCatalog.descriptors.map(\.id))
        var withoutAutoProbe = allIDs
        withoutAutoProbe.remove("SQL-016")
        let report = SentinelSurfacePolicy.report(
            for: SentinelSurfaceRegistry.current,
            registeredProbeIDs: withoutAutoProbe)

        let findings = SELF011SurfaceCoverage().findings(for: report, now: sentinelTestNow)
        #expect(findings.count == 1)
        #expect(findings[0].discriminator == SentinelSurfaceFamily.sqlTable.rawValue)
        #expect(findings[0].evidence.contains {
            $0.labelKey == "evidence.self011.covered" && $0.safeValue == "0"
        })
        #expect(findings[0].debugDetail?.contains("books") == true)
    }
}
