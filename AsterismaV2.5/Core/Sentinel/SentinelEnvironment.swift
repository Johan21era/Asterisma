//  SentinelEnvironment.swift
//  AsterismaV2.5
//
//  SG1 — injected time and filesystem facts (L12: deterministic), plus the
//  one and only write scope Sentinel owns (`<dataRoot>/Sentinel/`).
//
//  Probes never call Date() or read disk capacity directly: they ask the
//  environment. That is what makes them reproducible in tests and makes clock
//  jump and disk thresholds testable without waiting.

import Foundation

// MARK: - Clock

nonisolated protocol SentinelClock: Sendable {
    var now: Date { get }
}

nonisolated struct SystemSentinelClock: SentinelClock {
    var now: Date { Date() }
}

/// Deterministic clock for tests and for replaying fixtures at a fixed date.
nonisolated final class TestSentinelClock: SentinelClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_767_225_600)) { // 2026-01-01T00:00:00Z
        current = start
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }

    func set(_ date: Date) {
        lock.lock()
        current = date
        lock.unlock()
    }
}

// MARK: - Paths

nonisolated struct SentinelPaths: Hashable, Sendable {
    /// `<dataRoot>/Sentinel`. Sentinel writes nowhere else.
    let root: URL

    var stateFile: URL { root.appendingPathComponent("state.json") }
    var stateBackup: URL { root.appendingPathComponent("state.backup.json") }
    var journalDirectory: URL { root.appendingPathComponent("journal", isDirectory: true) }
    var quarantineDirectory: URL { root.appendingPathComponent("quarantine", isDirectory: true) }
    var undoDirectory: URL { root.appendingPathComponent("undo", isDirectory: true) }
    var debugDirectory: URL { root.appendingPathComponent("debug", isDirectory: true) }
    var archiveDirectory: URL { root.appendingPathComponent("archive", isDirectory: true) }
    var reportsDirectory: URL { root.appendingPathComponent("reports", isDirectory: true) }

    /// The only paths a write capability is ever granted for.
    var writeScopeURLs: [URL] {
        [root, journalDirectory, quarantineDirectory, undoDirectory, debugDirectory, archiveDirectory, reportsDirectory]
    }

    static func standard(dataRoot: URL) -> SentinelPaths {
        SentinelPaths(root: dataRoot.appendingPathComponent("Sentinel", isDirectory: true))
    }

    @discardableResult
    func ensureDirectories(fileManager: FileManager = .default) -> Bool {
        var ok = true
        for url in writeScopeURLs {
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                ok = false
            }
        }
        return ok
    }

    /// True when `url` is inside this scope. Uses standardized paths and
    /// rejects `..` traversal after resolution. Symlinks are resolved by the
    /// caller where relevant; repairs never write through links.
    func contains(_ url: URL) -> Bool {
        let scope = root.standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        return candidate == scope || candidate.hasPrefix(scope + "/")
    }
}

// MARK: - Environment

nonisolated struct SentinelEnvironment: Sendable {
    var clock: any SentinelClock
    var dataRoot: URL?
    var backupRoot: URL?
    var tempRoot: URL
    var isDebug: Bool
    var appVersion: String
    /// Injected so disk-capacity tests do not depend on the test machine.
    var capacityProvider: @Sendable (URL) -> Int64?
    /// Bundle identifier guard for APP-007 (test-store leakage).
    var bundleIdentifier: String
    /// Configured staleness threshold for orphan sessions. The runtime sets
    /// this from `SentinelConfiguration` before each cycle.
    var orphanSessionAge: TimeInterval = 24 * 3600

    var now: Date { clock.now }

    var paths: SentinelPaths? {
        dataRoot.map(SentinelPaths.standard(dataRoot:))
    }

    static func live(dataRoot: URL?, backupRoot: URL?, isDebug: Bool) -> SentinelEnvironment {
        SentinelEnvironment(
            clock: SystemSentinelClock(),
            dataRoot: dataRoot,
            backupRoot: backupRoot,
            tempRoot: FileManager.default.temporaryDirectory,
            isDebug: isDebug,
            appVersion: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev",
            capacityProvider: { url in
                (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                    .volumeAvailableCapacityForImportantUsage
            },
            bundleIdentifier: AppIdentity.bundleIdentifier
        )
    }

    static func test(
        clock: SentinelClock = TestSentinelClock(),
        dataRoot: URL?,
        backupRoot: URL? = nil,
        tempRoot: URL? = nil,
        isDebug: Bool = true,
        capacity: Int64? = 50_000_000_000
    ) -> SentinelEnvironment {
        SentinelEnvironment(
            clock: clock,
            dataRoot: dataRoot,
            backupRoot: backupRoot ?? dataRoot?.appendingPathComponent("Backups", isDirectory: true),
            tempRoot: tempRoot ?? FileManager.default.temporaryDirectory,
            isDebug: isDebug,
            appVersion: "test",
            capacityProvider: { _ in capacity },
            bundleIdentifier: AppIdentity.bundleIdentifier
        )
    }

    func freeSpace(at url: URL? = nil) -> Int64? {
        guard let target = url ?? dataRoot else { return nil }
        return capacityProvider(target)
    }

    /// Filesystem metadata only; no content reads. Nil when absent.
    func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    func fileSize(of url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

// MARK: - Logging

/// Small, rate-limited console trace used only in Debug. Probes never log
/// user text; this helper exists so a probe failure is visible without
/// spraying the console every 15 minutes.
nonisolated final class SentinelTrace: @unchecked Sendable {
    static let shared = SentinelTrace()

    private let lock = NSLock()
    private var lastEmitted: [String: Date] = [:]

    func emit(_ message: String, key: String, minimumInterval: TimeInterval = 300) {
        let now = Date()
        lock.lock()
        defer { lock.unlock() }
        if let last = lastEmitted[key], now.timeIntervalSince(last) < minimumInterval { return }
        lastEmitted[key] = now
        #if DEBUG
        print("[Sentinel] \(message)")
        #endif
    }
}
