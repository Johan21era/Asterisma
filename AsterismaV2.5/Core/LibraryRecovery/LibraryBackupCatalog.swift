//  LibraryBackupCatalog.swift
//  Library Safety — Phase 3
//
//  A backup without evidence is only a file. Every new snapshot gets a
//  sidecar manifest; legacy files are inspected and given one without being
//  modified. Rotation is explicit about what it deletes and never removes the
//  last verified restore point.

import Foundation

nonisolated enum LibraryBackupState: String, Codable, Hashable, Sendable {
    case verified
    case legacy
    case unverified
    case failed
}

nonisolated struct LibraryBackup: Identifiable, Hashable, Sendable {
    var id: String
    var url: URL
    var manifest: LibrarySnapshotManifest?
    var state: LibraryBackupState
    var failureCode: String?
    var isSafetySnapshot: Bool

    var createdAt: Date {
        manifest?.createdAt
            ?? (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate)
            ?? .distantPast
    }

    var isVerified: Bool { state == .verified }
}

nonisolated struct LibraryBackupScan: Sendable {
    var backups: [LibraryBackup]
    var verifiedCount: Int
    var failedCount: Int
}

nonisolated enum LibraryBackupCatalogError: LocalizedError, Equatable {
    case failedToWriteManifest(String)
    case failedToReadManifest(String)

    var errorDescription: String? {
        switch self {
        case let .failedToWriteManifest(message):
            return "The backup manifest could not be written: \(message)"
        case let .failedToReadManifest(message):
            return "The backup manifest could not be read: \(message)"
        }
    }
}

// MARK: - Manifest sidecar

nonisolated enum LibraryBackupManifestStore {

    /// `library-….sqlite3.manifest.json`, kept adjacent so moving the backup
    /// moves its evidence with it.
    static func manifestURL(for backupURL: URL) -> URL {
        backupURL.appendingPathExtension("manifest.json")
    }

    static func write(_ manifest: LibrarySnapshotManifest, for backupURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        do {
            let data = try encoder.encode(manifest)
            let url = manifestURL(for: backupURL)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
            try LibraryFileSync.fsyncFile(url)
            try LibraryFileSync.fsyncDirectory(url.deletingLastPathComponent())
        } catch {
            throw LibraryBackupCatalogError.failedToWriteManifest(error.localizedDescription)
        }
    }

    static func read(for backupURL: URL) throws -> LibrarySnapshotManifest {
        let url = manifestURL(for: backupURL)
        guard let data = try? Data(contentsOf: url) else {
            throw LibraryBackupCatalogError.failedToReadManifest("manifest missing")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(LibrarySnapshotManifest.self, from: data) else {
            throw LibraryBackupCatalogError.failedToReadManifest("manifest unreadable")
        }
        return manifest
    }
}

// MARK: - Catalog

nonisolated enum LibraryBackupCatalog {

    static func scan(directory: URL) -> LibraryBackupScan {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(
            atPath: directory.path)) ?? []
        let candidates = names
            .filter { $0.hasSuffix(".sqlite3") && !$0.hasPrefix(".") }
            .sorted()
            .map { directory.appendingPathComponent($0) }

        var backups: [LibraryBackup] = []
        for url in candidates {
            backups.append(inspect(url))
        }
        backups.sort { $0.createdAt > $1.createdAt }
        return LibraryBackupScan(
            backups: backups,
            verifiedCount: backups.filter(\.isVerified).count,
            failedCount: backups.filter { $0.state == .failed }.count)
    }

    static func inspect(_ url: URL) -> LibraryBackup {
        let safety = url.lastPathComponent.hasPrefix("sentinel-pre-repair-")
        let manifest = try? LibraryBackupManifestStore.read(for: url)
        guard let manifest else {
            return LibraryBackup(
                id: "bak_legacy_\(stableID(url))",
                url: url,
                manifest: nil,
                state: .legacy,
                failureCode: nil,
                isSafetySnapshot: safety)
        }

        do {
            let currentHash = try LibraryFileSync.sha256(of: url)
            guard currentHash == manifest.sha256 else {
                return LibraryBackup(
                    id: "bak_\(manifest.sha256.prefix(16))",
                    url: url,
                    manifest: manifest,
                    state: .failed,
                    failureCode: "LR-014",
                    isSafetySnapshot: safety)
            }
            let inspection = try LibraryDatabase.inspectSnapshot(at: url)
            guard inspection.missingTables.isEmpty,
                  inspection.integrityMessages.isEmpty else {
                return LibraryBackup(
                    id: "bak_\(manifest.sha256.prefix(16))",
                    url: url,
                    manifest: manifest,
                    state: .failed,
                    failureCode: "LR-015",
                    isSafetySnapshot: safety)
            }
            guard inspection.manifest.counts == manifest.counts else {
                return LibraryBackup(
                    id: "bak_\(manifest.sha256.prefix(16))",
                    url: url,
                    manifest: manifest,
                    state: .failed,
                    failureCode: "LR-016",
                    isSafetySnapshot: safety)
            }
            return LibraryBackup(
                id: "bak_\(manifest.sha256.prefix(16))",
                url: url,
                manifest: manifest,
                state: .verified,
                failureCode: nil,
                isSafetySnapshot: safety)
        } catch {
            return LibraryBackup(
                id: "bak_\(manifest.sha256.prefix(16))",
                url: url,
                manifest: manifest,
                state: .failed,
                failureCode: "LR-017",
                isSafetySnapshot: safety)
        }
    }

    /// Adds a manifest to a legacy snapshot without touching the snapshot. If
    /// the file fails full inspection, it is reported as failed and no manifest
    /// is written. This is explicit, never automatic during launch.
    static func migrateLegacy(_ backup: LibraryBackup) throws -> LibraryBackup {
        guard backup.manifest == nil, backup.state == .legacy else { return backup }
        let inspection = try LibraryDatabase.inspectSnapshot(
            at: backup.url, fullIntegrity: true)
        guard inspection.missingTables.isEmpty,
              inspection.integrityMessages.isEmpty else {
            return LibraryBackup(
                id: backup.id,
                url: backup.url,
                manifest: nil,
                state: .failed,
                failureCode: "LR-015",
                isSafetySnapshot: backup.isSafetySnapshot)
        }
        try LibraryBackupManifestStore.write(inspection.manifest, for: backup.url)
        return inspect(backup.url)
    }

    static func verifiedBackups(in directory: URL) -> [LibraryBackup] {
        scan(directory: directory).backups.filter(\.isVerified)
    }

    /// Keep the newest `keepDaily` ordinary snapshots and `keepSafety` safety
    /// snapshots. If only one verified backup exists, it is never removed.
    @discardableResult
    static func prune(
        directory: URL,
        keepDaily: Int = 10,
        keepSafety: Int = 5
    ) -> [URL] {
        let scan = scan(directory: directory)
        let verified = scan.backups.filter(\.isVerified)
        let daily = scan.backups.filter { !$0.isSafetySnapshot }
        let safety = scan.backups.filter(\.isSafetySnapshot)
        let doomed = daily.dropFirst(keepDaily) + safety.dropFirst(keepSafety)

        var removed: [URL] = []
        for backup in doomed {
            // Never delete the only verified restore point, and never delete a
            // verified backup as part of a count trim if it is the final one.
            if backup.isVerified, verified.count <= 1 { continue }
            do {
                try FileManager.default.removeItem(at: backup.url)
                let manifest = LibraryBackupManifestStore.manifestURL(for: backup.url)
                try? FileManager.default.removeItem(at: manifest)
                removed.append(backup.url)
            } catch {
                continue
            }
        }
        return removed
    }

    private static func stableID(_ url: URL) -> String {
        // A filename is not secret; keep the identifier stable across scans
        // without hashing the entire backup during a list refresh.
        url.lastPathComponent
            .replacingOccurrences(of: ".sqlite3", with: "")
            .replacingOccurrences(of: " ", with: "-")
    }
}
