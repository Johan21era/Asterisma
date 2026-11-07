//  LibraryBackupVerifier.swift
//  Library Safety — Phase 3
//
//  A verified backup is one whose manifest hash matches, whose SQLite file
//  opens read-only, and whose row counts match the manifest. A drill goes one
//  step further and proves the books and state decode.

import Foundation

nonisolated enum LibraryBackupVerificationLevel: String, Sendable {
    case quick
    case full
    case drill
}

nonisolated struct LibraryBackupVerificationResult: Sendable {
    var level: LibraryBackupVerificationLevel
    var state: LibraryBackupState
    var manifest: LibrarySnapshotManifest?
    var inspection: LibrarySnapshotInspection?
    var failureCode: String?
    var durationMilliseconds: Int
}

nonisolated enum LibraryBackupVerifier {

    static func verify(
        _ backup: LibraryBackup,
        level: LibraryBackupVerificationLevel = .quick
    ) -> LibraryBackupVerificationResult {
        let started = CFAbsoluteTimeGetCurrent()
        func finish(
            _ state: LibraryBackupState,
            _ manifest: LibrarySnapshotManifest?,
            _ inspection: LibrarySnapshotInspection?,
            _ code: String?
        ) -> LibraryBackupVerificationResult {
            LibraryBackupVerificationResult(
                level: level,
                state: state,
                manifest: manifest,
                inspection: inspection,
                failureCode: code,
                durationMilliseconds: Int(
                    (CFAbsoluteTimeGetCurrent() - started) * 1000))
        }

        guard let manifest = try? LibraryBackupManifestStore.read(for: backup.url) else {
            return finish(.failed, nil, nil, "LR-013")
        }
        guard (try? LibraryFileSync.sha256(of: backup.url)) == manifest.sha256 else {
            return finish(.failed, manifest, nil, "LR-014")
        }

        do {
            let connection = try LibraryReadOnlyConnection(url: backup.url)
            defer { connection.close() }
            let inspection = try connection.inspect(
                fullIntegrity: level != .quick)

            guard inspection.missingTables.isEmpty else {
                return finish(.failed, manifest, inspection, "LR-015")
            }
            guard inspection.integrityMessages.isEmpty else {
                return finish(.failed, manifest, inspection, "LR-018")
            }
            guard inspection.manifest.foreignKeyViolations == 0 else {
                return finish(.failed, manifest, inspection, "LR-019")
            }
            guard inspection.manifest.counts == manifest.counts else {
                return finish(.failed, manifest, inspection, "LR-016")
            }

            if level == .drill {
                let books = try connection.readBooks()
                let stateDecoded = try connection.readStateDecoded()
                let timings = try connection.samplePageTimings(limit: 1_000)
                guard books.undecodable == 0,
                      stateDecoded,
                      timings.undecodable == 0 else {
                    return finish(.failed, manifest, inspection, "LR-020")
                }
            }

            return finish(.verified, manifest, inspection, nil)
        } catch {
            return finish(.failed, manifest, nil, "LR-017")
        }
    }

    /// Replaces the catalog entry with the verifier's result, so callers never
    /// show a stale "verified" badge.
    static func refresh(_ backup: LibraryBackup) -> LibraryBackup {
        let result = verify(backup, level: .quick)
        var copy = backup
        copy.state = result.state
        copy.failureCode = result.failureCode
        if let manifest = result.manifest { copy.manifest = manifest }
        return copy
    }
}
