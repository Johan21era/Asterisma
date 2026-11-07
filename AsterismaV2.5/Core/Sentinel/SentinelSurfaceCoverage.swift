//  SentinelSurfaceCoverage.swift
//  AsterismaV2.5
//
//  The contract that makes Sentinel modular in the only way a compiled app can
//  be: coverage is derived from a source-generated inventory, not from a human
//  remembering to add a probe.
//
//  Three planes:
//    inventory  `SentinelSurfaceRegistry.current` (generated, CI-fresh)
//    policy     this file — who owns which family, and what is allowed to be
//               unowned without opening an issue
//    execution  SQL-016 executes the table family generically; SELF-011 reports
//               when a *required* family loses its owner
//
//  Honesty rules:
//    * A family is `required` only when a generic probe really enumerates it.
//      Today that is `sql.table` via SQL-016. Defaults keys and notification
//      names are advisory: they are counted and surfaced, never claimed as
//      verified behavior.
//    * An owner is only credited when the probe id exists in the live catalog.
//      A deleted probe therefore produces a gap instead of a stale claim.
//    * Advisory debt never opens a user-facing issue. It is report metadata.

import Foundation

// MARK: - Families

nonisolated enum SentinelSurfaceFamily: String, Codable, CaseIterable, Hashable, Sendable {
    case sqlTable = "sql.table"
    case defaultsKey = "defaults.key"
    case notificationName = "notification.name"

    /// Required families must have a registered owner for every surface. Only
    /// families with a genuinely generic probe belong here.
    var isRequired: Bool {
        switch self {
        case .sqlTable: return true
        case .defaultsKey, .notificationName: return false
        }
    }

    var displayName: String {
        switch self {
        case .sqlTable: return "Database tables"
        case .defaultsKey: return "Stored preferences"
        case .notificationName: return "Notifications"
        }
    }
}

nonisolated struct SentinelSurfaceEntry: Codable, Hashable, Sendable {
    var family: SentinelSurfaceFamily
    var name: String

    var key: String { "\(family.rawValue).\(name)" }
}

// MARK: - Report

nonisolated enum SentinelSurfaceGapReason: String, Codable, Hashable, Sendable {
    case noOwner = "no-owner"
    case ownerNotRegistered = "owner-not-registered"
}

nonisolated struct SentinelSurfaceGap: Codable, Hashable, Sendable {
    var entry: SentinelSurfaceEntry
    var reason: SentinelSurfaceGapReason
    var declaredOwner: String?

    var isRequired: Bool { entry.family.isRequired }
}

nonisolated struct SentinelSurfaceReport: Sendable {
    var catalogDigest: String
    var entries: [SentinelSurfaceEntry]
    var gaps: [SentinelSurfaceGap]

    var requiredEntries: [SentinelSurfaceEntry] { entries.filter { $0.family.isRequired } }
    var requiredGaps: [SentinelSurfaceGap] { gaps.filter(\.isRequired) }
    var advisoryGaps: [SentinelSurfaceGap] { gaps.filter { !$0.isRequired } }

    var requiredCoverage: Double {
        guard !requiredEntries.isEmpty else { return 1 }
        return Double(requiredEntries.count - requiredGaps.count) / Double(requiredEntries.count)
    }

    var isRequiredComplete: Bool { requiredGaps.isEmpty }

    /// Deterministic, user-data-free sentence. Used as evidence and in the
    /// developer console; never contains a path, title, or key value.
    var summary: String {
        let coveredRequired = requiredEntries.count - requiredGaps.count
        return "surfaces=\(entries.count) required=\(coveredRequired)/\(requiredEntries.count)"
            + " advisoryGaps=\(advisoryGaps.count) digest=\(catalogDigest)"
    }
}

// MARK: - Policy

nonisolated enum SentinelSurfacePolicy {

    /// Families whose every member is enumerated by one generic probe.
    static let automaticOwners: [SentinelSurfaceFamily: [String]] = [
        .sqlTable: ["SQL-016"],
    ]

    /// Exact surface → probe ids. Only true claims belong here: each id must
    /// actually read the surface. Additions should cite the probe's behavior
    /// in its `what` string.
    static let explicitOwners: [String: [String]] = [
        // SELF-009 reads the autonomy switch to detect a cycle running while off.
        "defaults.key.sentinel.autonomy.v2": ["SELF-009"],
        // APP-006 reads the configured cadence.
        "defaults.key.sentinel.cadenceMinutes": ["APP-006"],
        // MIR-004 reads the enable switch before judging the runtime.
        "defaults.key.mirage.enabled": ["MIR-004"],
        // WX-007 reads all four stored coordinates.
        "defaults.key.wks_lat": ["WX-007"],
        "defaults.key.wks_lon": ["WX-007"],
        "defaults.key.wks_manual_lat": ["WX-007"],
        "defaults.key.wks_manual_lon": ["WX-007"],
    ]

    /// Entries intentionally left unowned. A waiver needs a reason so future
    /// readers can tell a decision from an oversight. Waived surfaces are not
    /// reported as gaps.
    static let waivers: [String: String] = [
        // UI-only "all clear was shown today" marker; not a data invariant and
        // a probe reading it would race the launch card that owns it.
        "defaults.key.sentinel.card.allClearDay": "launch-card UI state, not a data invariant",
        // AppKit delivery names. A probe cannot observe delivery without
        // participating in the notification, which would change behavior.
        "notification.name.com.apple.screenIsLocked": "system notification, observe-only",
        "notification.name.com.apple.screenIsUnlocked": "system notification, observe-only",
        "notification.name.library.incident.didChange": "UI refresh signal, no persisted state",
        "notification.name.library.recovery.didChange": "UI refresh signal, no persisted state",
        "notification.name.sentinel.runtime.didUpdate": "UI refresh signal, no persisted state",
    ]

    static func entries(in catalog: SentinelSurfaceCatalog) -> [SentinelSurfaceEntry] {
        catalog.sqlTables.map { SentinelSurfaceEntry(family: .sqlTable, name: $0) }
            + catalog.defaultsKeys.map { SentinelSurfaceEntry(family: .defaultsKey, name: $0) }
            + catalog.notificationNames.map { SentinelSurfaceEntry(family: .notificationName, name: $0) }
    }

    /// Owners for an entry that are actually registered. A declared owner that
    /// is absent from the catalog yields a `.ownerNotRegistered` gap, never a
    /// silent pass.
    static func registeredOwners(
        for entry: SentinelSurfaceEntry,
        registeredProbeIDs: Set<String>
    ) -> [String] {
        let declared = automaticOwners[entry.family] ?? []
            + (explicitOwners[entry.key] ?? [])
        return Array(Set(declared)).sorted().filter(registeredProbeIDs.contains)
    }

    static func report(
        for catalog: SentinelSurfaceCatalog,
        registeredProbeIDs: Set<String>
    ) -> SentinelSurfaceReport {
        let entries = entries(in: catalog).sorted { $0.key < $1.key }
        var gaps: [SentinelSurfaceGap] = []

        for entry in entries {
            if waivers[entry.key] != nil { continue }

            let declared = (automaticOwners[entry.family] ?? [])
                + (explicitOwners[entry.key] ?? [])
            let registered = registeredOwners(for: entry, registeredProbeIDs: registeredProbeIDs)

            if !declared.isEmpty && registered.isEmpty {
                gaps.append(SentinelSurfaceGap(
                    entry: entry,
                    reason: .ownerNotRegistered,
                    declaredOwner: declared.sorted().first))
            } else if declared.isEmpty {
                gaps.append(SentinelSurfaceGap(
                    entry: entry,
                    reason: .noOwner,
                    declaredOwner: nil))
            }
        }

        return SentinelSurfaceReport(
            catalogDigest: catalog.digest,
            entries: entries,
            gaps: gaps)
    }
}
