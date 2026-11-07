//  SentinelSnapshot.swift
//  AsterismaV2.5
//
//  SG2 — the immutable view every probe reads.
//
//  A snapshot is captured once per cycle with a generation number. Probes get
//  values and read-only URLs, never a live store. That is what makes "probe a
//  torn state" structurally impossible and lets the runtime abort safely if
//  the library changes mid-cycle.
//
//  The `books` array is copied by Swift's copy-on-write: capturing it is cheap
//  even for a large library, and a later mutation in the app cannot alter the
//  snapshot's view.

import Foundation

nonisolated enum SentinelPersistenceKind: String, Codable, Sendable {
    case healthy
    case degraded
    case unknown
}

/// Facts about the journal that SELF probes need without reading it from a
/// probe (which would recurse).
nonisolated struct SentinelJournalFacts: Codable, Hashable, Sendable {
    var exists: Bool
    var byteSize: Int64
    var segmentCount: Int
    var corruptLines: Int
    var lastEntryAt: Date?
    var lastCycleDuration: TimeInterval?
    var lastCycleProbeCount: Int
    var consecutiveFailuresByProbe: [String: Int]
    var lastCycleOverranBudget: Bool

    static let empty = SentinelJournalFacts(
        exists: false, byteSize: 0, segmentCount: 0, corruptLines: 0,
        lastEntryAt: nil, lastCycleDuration: nil, lastCycleProbeCount: 0,
        consecutiveFailuresByProbe: [:], lastCycleOverranBudget: false)
}

/// App-level flags that live in UserDefaults. Captured on the main actor so
/// probes never need to touch defaults themselves.
nonisolated struct SentinelAppFlags: Codable, Hashable, Sendable {
    var selectedBookID: String?
    var demoModeActive: Bool
    var notificationPermissionGranted: Bool
    var notificationPermissionRequested: Bool
    var launchFailureCount: Int
    var onboardingDismissed: Bool
    var storageEngine: String
    var lastLoadRepairNotePresent: Bool

    static let empty = SentinelAppFlags(
        selectedBookID: nil, demoModeActive: false,
        notificationPermissionGranted: false, notificationPermissionRequested: false,
        launchFailureCount: 0, onboardingDismissed: false,
        storageEngine: "json", lastLoadRepairNotePresent: false)
}

nonisolated enum SentinelDefaultsKey {
    static let selectedBookID = "selectedBookID"
    static let demoMode = "demo.mode.active"
    static let notificationPermission = "app.notifications.permissionGranted"
    static let notificationRequested = "app.notifications.requested"
    static let launchFailureCount = "app.launch.failureCount"
    static let onboardingDismissed = "app.onboarding.dismissed"
    static let storageEngine = "storage.engine"
}

nonisolated struct SentinelSnapshot: @unchecked Sendable {
    var generation: UInt64
    var capturedAt: Date
    var books: [Book]
    var libraryState: LibraryState
    var persistenceKind: SentinelPersistenceKind
    var persistenceReason: String?
    var dataRoot: URL?
    var backupsRoot: URL?
    var coversRoot: URL?
    var databaseURL: URL?
    var journalFacts: SentinelJournalFacts
    var appFlags: SentinelAppFlags
    var tempRoot: URL
    var defaults: UserDefaults
    var isDebug: Bool
    var appVersion: String
    /// Source-derived inventory captured with the snapshot. Injectable so a
    /// test can prove that a surface added after the generator ran is visible
    /// to SELF-011 without editing any probe.
    var surfaceCatalog: SentinelSurfaceCatalog

    // MARK: Derived paths (all optional; probes must skip when absent)

    var weatherDatabaseURL: URL? {
        dataRoot?.appendingPathComponent("weather_snapshots.sqlite3")
    }

    var audioProfilesURL: URL? {
        dataRoot?.appendingPathComponent("audio-profiles.json")
    }

    var behaviorEvidenceURL: URL? {
        dataRoot?.appendingPathComponent("behavior-evidence.json")
    }

    var mirageDirectory: URL? {
        dataRoot?.appendingPathComponent("Mirage", isDirectory: true)
    }

    var mirageIdentityMapURL: URL? {
        mirageDirectory?.appendingPathComponent("identity-map.json")
    }

    var mirageGuardPIDURL: URL? {
        mirageDirectory?.appendingPathComponent("guard.pid")
    }

    var mirageDatabaseURL: URL? {
        mirageDirectory?.appendingPathComponent("mirage.sqlite3")
    }

    var jsonLibraryURL: URL? {
        dataRoot?.appendingPathComponent("library.json")
    }

    var jsonStateURL: URL? {
        dataRoot?.appendingPathComponent("library-state.json")
    }

    var sqliteInUse: Bool {
        guard let databaseURL else { return false }
        return FileManager.default.fileExists(atPath: databaseURL.path)
    }

    var booksByID: [UUID: Book] {
        Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0) })
    }

    var sessionIDs: Set<UUID> {
        Set(books.flatMap { $0.sessions.map(\.id) })
    }

    // MARK: Capture

    @MainActor
    static func capture(
        store: DataStore,
        environment: SentinelEnvironment,
        journalFacts: SentinelJournalFacts,
        defaults: UserDefaults
    ) -> SentinelSnapshot {
        let root = AppIdentity.dataRootURL()
        let engine: String
        switch store.storageEngine {
        case .json: engine = "json"
        case .sqlite: engine = "sqlite"
        }

        let flags = SentinelAppFlags(
            selectedBookID: defaults.string(forKey: SentinelDefaultsKey.selectedBookID),
            demoModeActive: defaults.bool(forKey: SentinelDefaultsKey.demoMode),
            notificationPermissionGranted: defaults.bool(forKey: SentinelDefaultsKey.notificationPermission),
            notificationPermissionRequested: defaults.bool(forKey: SentinelDefaultsKey.notificationRequested),
            launchFailureCount: defaults.integer(forKey: SentinelDefaultsKey.launchFailureCount),
            onboardingDismissed: defaults.bool(forKey: SentinelDefaultsKey.onboardingDismissed),
            storageEngine: engine,
            lastLoadRepairNotePresent: store.lastLoadRepairNotePresent)

        return SentinelSnapshot(
            generation: store.analyticsEpoch,
            capturedAt: environment.now,
            books: store.books,
            libraryState: store.libraryState,
            persistenceKind: {
                switch store.persistenceHealth {
                case .healthy: return .healthy
                case .degraded: return .degraded
                }
            }(),
            persistenceReason: {
                switch store.persistenceHealth {
                case .healthy: return nil
                case .degraded(let reason): return reason
                }
            }(),
            dataRoot: root,
            backupsRoot: root?.appendingPathComponent("Backups", isDirectory: true),
            coversRoot: root?.appendingPathComponent("covers", isDirectory: true),
            databaseURL: root?.appendingPathComponent("library.grdb.sqlite3"),
            journalFacts: journalFacts,
            appFlags: flags,
            tempRoot: environment.tempRoot,
            defaults: defaults,
            isDebug: environment.isDebug,
            appVersion: environment.appVersion,
            surfaceCatalog: SentinelSurfaceRegistry.current)
    }

    /// Fixture initializer for tests and probe contract suites.
    static func fixture(
        books: [Book] = [],
        state: LibraryState = LibraryState(),
        dataRoot: URL? = nil,
        generation: UInt64 = 1,
        now: Date = Date(timeIntervalSince1970: 1_767_225_600),
        persistence: SentinelPersistenceKind = .healthy,
        defaults: UserDefaults = UserDefaults(suiteName: "sentinel.fixture") ?? .standard,
        appFlags: SentinelAppFlags = .empty,
        journalFacts: SentinelJournalFacts = .empty,
        isDebug: Bool = true,
        surfaceCatalog: SentinelSurfaceCatalog = SentinelSurfaceRegistry.current
    ) -> SentinelSnapshot {
        SentinelSnapshot(
            generation: generation,
            capturedAt: now,
            books: books,
            libraryState: state,
            persistenceKind: persistence,
            persistenceReason: nil,
            dataRoot: dataRoot,
            backupsRoot: dataRoot?.appendingPathComponent("Backups", isDirectory: true),
            coversRoot: dataRoot?.appendingPathComponent("covers", isDirectory: true),
            databaseURL: dataRoot?.appendingPathComponent("library.grdb.sqlite3"),
            journalFacts: journalFacts,
            appFlags: appFlags,
            tempRoot: FileManager.default.temporaryDirectory,
            defaults: defaults,
            isDebug: isDebug,
            appVersion: "test",
            surfaceCatalog: surfaceCatalog)
    }
}
