//  SentinelProbesSurface.swift
//  AsterismaV2.5
//
//  The auto-extending layer. These two probes do not know any feature by name:
//  they read the generated surface inventory and enforce the policy around it.
//
//  SQL-016  every table in the inventory must exist, be readable, and have a
//           primary key. Adding a table to the app and regenerating the
//           manifest extends this probe with no Swift change.
//  SELF-011 every *required* surface must have a registered owner. Losing the
//           auto-probe (or a wiring mistake in a future catalog) becomes a
//           visible issue instead of a silent coverage hole.
//
//  Neither probe writes. SQL-016 opens the database read-only through the
//  shared SentinelProbeSupport handle and issues only PRAGMA/read queries.
//  Table names come from generated schema metadata, never from user content;
//  identifiers are still quoted defensively.

import Foundation
import GRDB

// MARK: - Catalog

/// The extension point for future surface families. A new generic probe is
/// added here once; regenerating the manifest then extends its inputs without
/// touching this list.
nonisolated enum SentinelSurfaceProbes {
    static let all: [any SentinelProbeV2] = [
        SQL016TableContract(),
        SELF011SurfaceCoverage(),
    ]
}

// MARK: - SQL-016

/// One contract failure, kept local so the probe's output shape stays the
/// catalog's `RawFinding`, not a new public model.
nonisolated private struct SurfaceTableContractIssue {
    var table: String
    var kind: String
}

nonisolated struct SQL016TableContract: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SQL-016", domain: .database,
        title: "A database table is missing or unkeyed",
        what: "A table in the generated surface inventory is absent, cannot be read, or has no primary key, so its rows cannot be identified reliably.",
        rootCauseKey: "sql.table-contract", tier: .t1,
        defaultSeverity: .critical, defaultImpact: .high)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let tables = Array(Set(snapshot.surfaceCatalog.sqlTables)).sorted()
        guard !tables.isEmpty else {
            throw SentinelProbeUnavailable(.insufficientData, "surface catalog is empty")
        }
        guard snapshot.databaseURL != nil else {
            throw SentinelProbeUnavailable(.databaseNotInitialized)
        }

        let issues = try SentinelProbeSupport.readDatabase(at: snapshot.databaseURL) { db -> [SurfaceTableContractIssue] in
            var issues: [SurfaceTableContractIssue] = []
            for table in tables {
                guard try SentinelProbeSupport.hasTable(table, in: db) else {
                    issues.append(SurfaceTableContractIssue(table: table, kind: "missing"))
                    continue
                }

                let primaryKeyColumns = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM pragma_table_info(?) WHERE pk > 0",
                    arguments: [table]) ?? 0
                if primaryKeyColumns == 0 {
                    issues.append(SurfaceTableContractIssue(table: table, kind: "no-primary-key"))
                }

                do {
                    _ = try Row.fetchOne(
                        db,
                        sql: "SELECT * FROM \(Self.quotedIdentifier(table)) LIMIT 1")
                } catch {
                    issues.append(SurfaceTableContractIssue(table: table, kind: "unreadable"))
                }
            }
            return issues
        }

        guard !issues.isEmpty else { return [] }
        return issues.map { issue in
            SentinelProbeSupport.finding(
                descriptor,
                subjects: [SentinelSubject(.database, issue.table)],
                evidence: [
                    SentinelProbeSupport.aggregate(
                        "evidence.sql016.contract",
                        issue.kind,
                        at: environment.now,
                        source: .sqlite),
                    SentinelProbeSupport.count(
                        "evidence.sql016.tables",
                        tables.count,
                        at: environment.now,
                        source: .sqlite),
                ],
                discriminator: issue.table,
                debug: "table=\(issue.table) contract=\(issue.kind)")
        }
    }

    /// Table names are generated schema identifiers, but a manifest can be
    /// edited by a future tool; quoting keeps a malformed name from becoming
    /// SQL instead of a reported contract failure.
    static func quotedIdentifier(_ raw: String) -> String {
        "\"" + raw.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

// MARK: - SELF-011

/// Coverage honesty at the inventory level. A required family without a live
/// owner is not a warning about data; it is a warning that Sentinel's promise
/// no longer matches its catalog.
nonisolated struct SELF011SurfaceCoverage: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SELF-011", domain: .selfAudit,
        title: "A required surface has no owner",
        what: "The generated surface inventory contains a required surface that no registered probe owns, so part of the app is currently uninspected.",
        rootCauseKey: "self.surface-coverage", tier: .t1,
        defaultSeverity: .warning, defaultImpact: .medium)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let report = SentinelSurfacePolicy.report(
            for: snapshot.surfaceCatalog,
            registeredProbeIDs: Set(SentinelProbeCatalog.descriptors.map(\.id)))
        return findings(for: report, now: environment.now)
    }

    /// Emission is separate from ownership resolution so the gap path can be
    /// tested without deleting a registered probe from the shipped catalog.
    func findings(for report: SentinelSurfaceReport, now: Date) -> [RawFinding] {
        guard !report.isRequiredComplete else { return [] }

        let grouped = Dictionary(grouping: report.requiredGaps, by: { $0.entry.family })
        return grouped.keys.sorted { $0.rawValue < $1.rawValue }.map { family in
            let gaps = grouped[family] ?? []
            let names = gaps.map(\.entry.name).sorted()
            return SentinelProbeSupport.finding(
                descriptor,
                subjects: [SentinelSubject(.subsystem, "surface-\(family.rawValue)")],
                evidence: [
                    SentinelProbeSupport.count(
                        "evidence.self011.required",
                        report.requiredEntries.count,
                        at: now,
                        source: .sentinel),
                    SentinelProbeSupport.count(
                        "evidence.self011.covered",
                        report.requiredEntries.count - report.requiredGaps.count,
                        at: now,
                        source: .sentinel),
                    SentinelProbeSupport.count(
                        "evidence.self011.advisoryGaps",
                        report.advisoryGaps.count,
                        at: now,
                        source: .sentinel),
                    SentinelProbeSupport.aggregate(
                        "evidence.self011.digest",
                        report.catalogDigest,
                        at: now,
                        source: .sentinel),
                ],
                discriminator: family.rawValue,
                debug: "family=\(family.rawValue) unowned=\(names.joined(separator: ","))")
        }
    }
}
