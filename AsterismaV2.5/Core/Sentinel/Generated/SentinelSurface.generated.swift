//  SentinelSurface.generated.swift
//  AsterismaV2.5
//
//  GENERATED FILE — do not edit by hand.
//  Regenerate: ./scripts/sentinel-surface.py --write
//  Freshness:  ./scripts/verify-sentinel-surface.sh
//
//  Source-derived surface inventory: 28 surfaces
//  (15 tables, 8 defaults keys, 5 notification names).
//  SQL-016 and SELF-011 read this catalog; nothing here is hand-maintained.

import Foundation

/// The declarative surfaces Sentinel can own without knowing what a feature is
/// called. Regenerated from source; treated as immutable at runtime.
nonisolated struct SentinelSurfaceCatalog: Codable, Hashable, Sendable {
    var schemaVersion: Int
    var digest: String
    var sqlTables: [String]
    var defaultsKeys: [String]
    var notificationNames: [String]

    static let empty = SentinelSurfaceCatalog(
        schemaVersion: 1,
        digest: "empty",
        sqlTables: [],
        defaultsKeys: [],
        notificationNames: [])

    var surfaceCount: Int {
        sqlTables.count + defaultsKeys.count + notificationNames.count
    }

    var isEmpty: Bool { surfaceCount == 0 }

    /// Every surface as a stable `<family>.<name>` key. Used by the coverage
    /// policy so a gap is addressable in tests and reports.
    var keys: [String] {
        sqlTables.map { "sql.table.\($0)" }
            + defaultsKeys.map { "defaults.key.\($0)" }
            + notificationNames.map { "notification.name.\($0)" }
    }
}

nonisolated enum SentinelSurfaceRegistry {
    /// Generated from source at commit checkout. Never mutated at runtime.
    static let current = SentinelSurfaceCatalog(
        schemaVersion: 1,
        digest: "6c3230edd3a9d253",
        sqlTables: [
            "achievements",
            "application_sessions",
            "audio_profiles",
            "behavior_events",
            "book_collections",
            "books",
            "collections",
            "device_state_events",
            "inactivity_records",
            "library_state",
            "meta",
            "notes",
            "page_times",
            "sessions",
            "weather_snapshots",
        ],
        defaultsKeys: [
            "mirage.enabled",
            "sentinel.autonomy.v2",
            "sentinel.cadenceMinutes",
            "sentinel.card.allClearDay",
            "wks_lat",
            "wks_lon",
            "wks_manual_lat",
            "wks_manual_lon",
        ],
        notificationNames: [
            "com.apple.screenIsLocked",
            "com.apple.screenIsUnlocked",
            "library.incident.didChange",
            "library.recovery.didChange",
            "sentinel.runtime.didUpdate",
        ])
}
