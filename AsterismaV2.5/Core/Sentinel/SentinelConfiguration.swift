//  SentinelConfiguration.swift
//  AsterismaV2.5
//
//  SG1 — configuration and autonomy.
//
//  The old three keys (`sentinel.enabled`, `sentinel.allowRepair`,
//  `sentinel.intervalMinutes`) remain readable and are migrated exactly as
//  §5.2 specifies: false → observe, true → autoSafe, absent → assist in
//  Release and autoSafe in Debug. The kill switch stays authoritative: a
//  disabled engine writes nothing, not even a journal line.

import Foundation

nonisolated enum SentinelAutonomy: String, Codable, CaseIterable, Sendable {
    /// A0 — kill switch. No probes, no journal, no timers.
    case off
    /// A1 — probes and issues, no mutations at all (including user-initiated).
    case observe
    /// A2 — R1 and R2 require a preview and a click. Recommended Release default.
    case assist
    /// A3 — R1 repairs run automatically after snapshot + verification;
    /// R2 still requires a click. Debug default.
    case autoSafe

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .observe: return "Observe only"
        case .assist: return "Assist"
        case .autoSafe: return "Auto-fix safe issues"
        }
    }

    var explanation: String {
        switch self {
        case .off: return "Sentinel does nothing at all: no checks, no journal, no notifications."
        case .observe: return "Sentinel checks and explains, but never changes anything."
        case .assist: return "Sentinel suggests fixes; every change needs your click and a preview."
        case .autoSafe: return "Sentinel applies provably safe, reversible normalizations on its own. Anything user-visible still asks."
        }
    }

    var isMonitoring: Bool { self != .off }

    /// A4 (auto-all) is deliberately not a case. R2/R3 are never automatic.
    func allowsAutomatic(_ risk: SentinelRiskClass) -> Bool {
        self == .autoSafe && risk == .r1
    }

    func allowsUserInitiated(_ risk: SentinelRiskClass) -> Bool {
        switch self {
        case .off, .observe:
            return false
        case .assist, .autoSafe:
            return risk != .r3
        }
    }
}

nonisolated struct SentinelQuietHours: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var startHour: Int
    var endHour: Int

    static let disabled = SentinelQuietHours(isEnabled: false, startHour: 22, endHour: 7)

    /// Handles windows that cross midnight (22 → 7).
    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard isEnabled else { return false }
        let hour = calendar.component(.hour, from: date)
        if startHour == endHour { return false }
        if startHour < endHour {
            return hour >= startHour && hour < endHour
        }
        return hour >= startHour || hour < endHour
    }

    var description: String {
        guard isEnabled else { return "Off" }
        return String(format: "%02d:00–%02d:00", startHour, endHour)
    }
}

nonisolated struct SentinelConfiguration: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var autonomy: SentinelAutonomy
    var cadenceMinutes: Int
    var deepCadenceHours: Int
    var quietHours: SentinelQuietHours
    var disabledDomains: Set<SentinelDomain>
    var keepDebugDetail: Bool
    var journalMaxSegments: Int
    var undoWindowDays: Int
    var lowDiskThresholdBytes: Int64
    var orphanSessionAge: TimeInterval
    var maximumIssuesPerCycle: Int
    var notificationsEnabled: Bool
    var menuBarEnabled: Bool

    static let `default` = SentinelConfiguration(
        schemaVersion: currentSchemaVersion,
        autonomy: .assist,
        cadenceMinutes: 15,
        deepCadenceHours: 24,
        quietHours: .disabled,
        disabledDomains: [],
        keepDebugDetail: false,
        journalMaxSegments: 4,
        undoWindowDays: 14,
        lowDiskThresholdBytes: 500 * 1_000_000,
        orphanSessionAge: 24 * 3600,
        maximumIssuesPerCycle: 500,
        notificationsEnabled: false,
        menuBarEnabled: false
    )

    static func debugDefault() -> SentinelConfiguration {
        var config = SentinelConfiguration.default
        config.autonomy = .autoSafe
        return config
    }

    // MARK: - Keys

    enum Keys {
        static let autonomy = "sentinel.autonomy.v2"
        static let cadenceMinutes = "sentinel.cadenceMinutes"
        static let deepCadenceHours = "sentinel.deepCadenceHours.v2"
        static let quietHoursEnabled = "sentinel.quietHours.enabled"
        static let quietStart = "sentinel.quietHours.start"
        static let quietEnd = "sentinel.quietHours.end"
        static let disabledDomains = "sentinel.disabledDomains.v2"
        static let keepDebugDetail = "sentinel.keepDebugDetail"
        static let journalMaxSegments = "sentinel.journalMaxSegments"
        static let undoWindowDays = "sentinel.undoWindowDays"
        static let lowDiskThresholdBytes = "sentinel.lowDiskThresholdBytes"
        static let orphanSessionAge = "sentinel.orphanSessionAge"
        static let notificationsEnabled = "sentinel.notificationsEnabled"
        static let menuBarEnabled = "sentinel.menuBarEnabled"
        static let schemaVersion = "sentinel.config.schemaVersion"

        // Legacy (SG0 and earlier).
        static let legacyEnabled = "sentinel.enabled"
        static let legacyAllowRepair = "sentinel.allowRepair"
        static let legacyInterval = "sentinel.intervalMinutes"
    }

    // MARK: - Load / migrate

    static func load(from defaults: UserDefaults, isDebug: Bool) -> SentinelConfiguration {
        var config = isDebug ? debugDefault() : .default

        if defaults.object(forKey: Keys.legacyEnabled) as? Bool == false {
            config.autonomy = .off
        } else if let raw = defaults.string(forKey: Keys.autonomy),
                  let decoded = SentinelAutonomy(rawValue: raw) {
            config.autonomy = decoded
        } else if defaults.object(forKey: Keys.legacyAllowRepair) != nil {
            config.autonomy = defaults.bool(forKey: Keys.legacyAllowRepair) ? .autoSafe : .observe
        }

        let legacyInterval = defaults.integer(forKey: Keys.legacyInterval)
        let cadence = defaults.integer(forKey: Keys.cadenceMinutes)
        if cadence > 0 {
            config.cadenceMinutes = max(1, cadence)
        } else if legacyInterval > 0 {
            config.cadenceMinutes = max(1, legacyInterval)
        }

        let deep = defaults.integer(forKey: Keys.deepCadenceHours)
        if deep > 0 { config.deepCadenceHours = deep }

        if defaults.object(forKey: Keys.quietHoursEnabled) != nil {
            let start = defaults.object(forKey: Keys.quietStart) != nil ? defaults.integer(forKey: Keys.quietStart) : 22
            let end = defaults.object(forKey: Keys.quietEnd) != nil ? defaults.integer(forKey: Keys.quietEnd) : 7
            config.quietHours = SentinelQuietHours(
                isEnabled: defaults.bool(forKey: Keys.quietHoursEnabled),
                startHour: max(0, min(23, start)),
                endHour: max(0, min(23, end))
            )
        }

        if let rawDomains = defaults.array(forKey: Keys.disabledDomains) as? [String] {
            config.disabledDomains = Set(rawDomains.compactMap(SentinelDomain.init(rawValue:)))
        }

        if defaults.object(forKey: Keys.keepDebugDetail) != nil {
            config.keepDebugDetail = defaults.bool(forKey: Keys.keepDebugDetail)
        }
        if defaults.integer(forKey: Keys.journalMaxSegments) > 0 {
            config.journalMaxSegments = max(1, defaults.integer(forKey: Keys.journalMaxSegments))
        }
        if defaults.integer(forKey: Keys.undoWindowDays) > 0 {
            config.undoWindowDays = max(1, defaults.integer(forKey: Keys.undoWindowDays))
        }
        if defaults.object(forKey: Keys.lowDiskThresholdBytes) != nil {
            config.lowDiskThresholdBytes = max(50_000_000, Int64(defaults.double(forKey: Keys.lowDiskThresholdBytes)))
        }
        if defaults.object(forKey: Keys.orphanSessionAge) != nil {
            config.orphanSessionAge = max(3600, defaults.double(forKey: Keys.orphanSessionAge))
        }
        if defaults.object(forKey: Keys.notificationsEnabled) != nil {
            config.notificationsEnabled = defaults.bool(forKey: Keys.notificationsEnabled)
        }
        if defaults.object(forKey: Keys.menuBarEnabled) != nil {
            config.menuBarEnabled = defaults.bool(forKey: Keys.menuBarEnabled)
        }

        config.clamp()
        return config
    }

    func save(to defaults: UserDefaults) {
        var clamped = self
        clamped.clamp()
        defaults.set(clamped.autonomy.rawValue, forKey: Keys.autonomy)
        defaults.set(clamped.cadenceMinutes, forKey: Keys.cadenceMinutes)
        defaults.set(clamped.deepCadenceHours, forKey: Keys.deepCadenceHours)
        defaults.set(clamped.quietHours.isEnabled, forKey: Keys.quietHoursEnabled)
        defaults.set(clamped.quietHours.startHour, forKey: Keys.quietStart)
        defaults.set(clamped.quietHours.endHour, forKey: Keys.quietEnd)
        defaults.set(clamped.disabledDomains.map(\.rawValue).sorted(), forKey: Keys.disabledDomains)
        defaults.set(clamped.keepDebugDetail, forKey: Keys.keepDebugDetail)
        defaults.set(clamped.journalMaxSegments, forKey: Keys.journalMaxSegments)
        defaults.set(clamped.undoWindowDays, forKey: Keys.undoWindowDays)
        defaults.set(Double(clamped.lowDiskThresholdBytes), forKey: Keys.lowDiskThresholdBytes)
        defaults.set(clamped.orphanSessionAge, forKey: Keys.orphanSessionAge)
        defaults.set(clamped.notificationsEnabled, forKey: Keys.notificationsEnabled)
        defaults.set(clamped.menuBarEnabled, forKey: Keys.menuBarEnabled)
        defaults.set(SentinelConfiguration.currentSchemaVersion, forKey: Keys.schemaVersion)
    }

    mutating func clamp() {
        cadenceMinutes = max(1, min(240, cadenceMinutes))
        deepCadenceHours = max(1, min(168, deepCadenceHours))
        journalMaxSegments = max(1, min(12, journalMaxSegments))
        undoWindowDays = max(1, min(90, undoWindowDays))
        lowDiskThresholdBytes = max(50_000_000, lowDiskThresholdBytes)
        orphanSessionAge = max(3600, orphanSessionAge)
        maximumIssuesPerCycle = max(50, min(5_000, maximumIssuesPerCycle))
        schemaVersion = SentinelConfiguration.currentSchemaVersion
    }

    func isEnabled(for domain: SentinelDomain) -> Bool {
        !disabledDomains.contains(domain)
    }
}
