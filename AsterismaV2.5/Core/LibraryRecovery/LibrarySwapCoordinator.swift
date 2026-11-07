//  LibrarySwapCoordinator.swift
//  Library Safety — Phase 4
//
//  File replacement is a sequence of durable intent stages, not a copy over the
//  live file. The original is moved, never deleted. Every stage is fsynced
//  before the next irreversible step. Startup reconciliation decides from
//  hashes, never from optimism.

import Foundation

nonisolated enum LibrarySwapStage: String, Codable, Sendable {
    case intentWritten
    case originalMoved
    case sidecarsMoved
    case incomingCopied
    case incomingVerified
    case renamed
    case reopenedVerified
    case rolledBack
}

nonisolated struct LibrarySwapIntent: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int
    var incidentID: String
    var backupID: String
    var backupPath: String
    var livePath: String
    var preRestorePath: String
    var incomingPath: String
    var expectedBeforeSHA256: String
    var expectedAfterSHA256: String
    var stage: LibrarySwapStage
    var createdAt: Date
    var updatedAt: Date
}

nonisolated struct LibrarySwapResult: Sendable {
    var intent: LibrarySwapIntent
    var preRestoreURL: URL
}

nonisolated enum LibrarySwapReconcileOutcome: Sendable {
    case noIntent
    case notStarted
    case completed(LibrarySwapIntent)
    case rolledBack(LibrarySwapIntent)
    case critical(String)
}

nonisolated enum LibrarySwapError: LocalizedError, Equatable {
    case backupMissing(String)
    case liveMissing(String)
    case hashMismatch(String)
    case intentExists(String)
    case preconditionFailed(String)
    case failedAfterRollback(String)
    case rollbackFailed(String)
    case ioFailure(String)

    var errorDescription: String? {
        switch self {
        case let .backupMissing(path):
            return "The selected backup is missing at \(path)."
        case let .liveMissing(path):
            return "The live library is missing at \(path)."
        case let .hashMismatch(which):
            return "The \(which) file does not match its expected hash."
        case let .intentExists(path):
            return "A swap intent already exists at \(path)."
        case let .preconditionFailed(reason):
            return "Restore refused: \(reason)"
        case let .failedAfterRollback(message):
            return "The restore failed and the original was put back: \(message)"
        case let .rollbackFailed(message):
            return "The restore failed and rollback also failed: \(message)"
        case let .ioFailure(message):
            return "The swap failed: \(message)"
        }
    }
}

actor LibrarySwapCoordinator {
    let root: URL
    private let io: any LibraryRecoveryIO
    private let intentURL: URL

    init(root: URL, io: any LibraryRecoveryIO = ProductionLibraryRecoveryIO()) throws {
        self.root = root
        self.io = io
        self.intentURL = root.appendingPathComponent("swap.intent")
        try io.createDirectory(root)
    }

    func currentIntent() -> LibrarySwapIntent? {
        loadIntent()
    }

    @discardableResult
    func restore(
        incidentID: String,
        backupID: String,
        backupURL: URL,
        liveURL: URL,
        expectedBeforeSHA256: String,
        expectedAfterSHA256: String,
        now: Date = Date()
    ) throws -> LibrarySwapResult {
        guard io.fileExists(backupURL) else {
            throw LibrarySwapError.backupMissing(backupURL.path)
        }
        guard io.fileExists(liveURL) else {
            throw LibrarySwapError.liveMissing(liveURL.path)
        }
        guard !io.fileExists(intentURL) else {
            throw LibrarySwapError.intentExists(intentURL.path)
        }

        let liveHash = try io.sha256(liveURL)
        guard liveHash == expectedBeforeSHA256 else {
            throw LibrarySwapError.hashMismatch("live library")
        }
        let backupHash = try io.sha256(backupURL)
        guard backupHash == expectedAfterSHA256 else {
            throw LibrarySwapError.hashMismatch("selected backup")
        }

        let incidentDirectory = root.appendingPathComponent("incidents", isDirectory: true)
            .appendingPathComponent(incidentID, isDirectory: true)
        try io.createDirectory(incidentDirectory)
        let preRestore = incidentDirectory.appendingPathComponent("pre-restore.sqlite3")
        guard !io.fileExists(preRestore) else {
            throw LibrarySwapError.preconditionFailed("a pre-restore copy already exists")
        }

        let incoming = liveURL.deletingLastPathComponent()
            .appendingPathComponent(".incoming-\(UUID().uuidString).sqlite3")
        var intent = LibrarySwapIntent(
            schemaVersion: LibrarySwapIntent.currentSchemaVersion,
            incidentID: incidentID,
            backupID: backupID,
            backupPath: backupURL.path,
            livePath: liveURL.path,
            preRestorePath: preRestore.path,
            incomingPath: incoming.path,
            expectedBeforeSHA256: expectedBeforeSHA256,
            expectedAfterSHA256: expectedAfterSHA256,
            stage: .intentWritten,
            createdAt: now,
            updatedAt: now)

        do {
            try writeIntent(&intent)
            try moveLiveAside(intent: &intent)
            try copyIncoming(intent: &intent)
            try publishIncoming(intent: &intent)
            return LibrarySwapResult(intent: intent, preRestoreURL: preRestore)
        } catch {
            do {
                try rollbackFiles(intent: &intent)
                throw LibrarySwapError.failedAfterRollback(error.localizedDescription)
            } catch let known as LibrarySwapError {
                throw known
            } catch {
                throw LibrarySwapError.rollbackFailed(error.localizedDescription)
            }
        }
    }

    /// Puts the pre-restore file back after a failed post-reopen verification.
    @discardableResult
    func rollback(liveURL: URL, now: Date = Date()) throws -> LibrarySwapIntent {
        guard var intent = loadIntent() else {
            throw LibrarySwapError.preconditionFailed("no swap intent")
        }
        guard liveURL.path == intent.livePath else {
            throw LibrarySwapError.preconditionFailed("live path does not match the intent")
        }
        try rollbackFiles(intent: &intent)
        intent.updatedAt = now
        try writeIntent(&intent)
        return intent
    }

    /// Launch-time reconciliation. It never deletes a file whose hash is
    /// unknown; an unexpected live file is moved aside as evidence.
    func reconcile(now: Date = Date()) -> LibrarySwapReconcileOutcome {
        guard var intent = loadIntent() else { return .noIntent }
        let live = URL(fileURLWithPath: intent.livePath)
        let preRestore = URL(fileURLWithPath: intent.preRestorePath)

        let liveHash = try? io.sha256(live)
        if liveHash == intent.expectedAfterSHA256 {
            intent.stage = .renamed
            intent.updatedAt = now
            try? writeIntent(&intent)
            return .completed(intent)
        }
        if liveHash == intent.expectedBeforeSHA256 {
            try? io.remove(intentURL)
            return .notStarted
        }
        if io.fileExists(preRestore) {
            do {
                if let liveHash, liveHash != intent.expectedBeforeSHA256 {
                    let evidence = root.appendingPathComponent("incidents", isDirectory: true)
                        .appendingPathComponent(intent.incidentID, isDirectory: true)
                        .appendingPathComponent("unknown-live-\(UUID().uuidString).sqlite3")
                    try io.move(live, to: evidence)
                }
                try io.move(preRestore, to: live)
                intent.stage = .rolledBack
                intent.updatedAt = now
                try writeIntent(&intent)
                return .rolledBack(intent)
            } catch {
                return .critical(error.localizedDescription)
            }
        }
        return .critical("the live file is missing and no pre-restore copy exists")
    }

    // MARK: - Steps

    private func moveLiveAside(intent: inout LibrarySwapIntent) throws {
        let live = URL(fileURLWithPath: intent.livePath)
        let preRestore = URL(fileURLWithPath: intent.preRestorePath)
        try io.move(live, to: preRestore)
        intent.stage = .originalMoved
        intent.updatedAt = Date()
        try writeIntent(&intent)

        for suffix in ["-wal", "-shm"] {
            let source = URL(fileURLWithPath: intent.livePath + suffix)
            guard io.fileExists(source) else { continue }
            try io.move(source, to: URL(fileURLWithPath: intent.preRestorePath + suffix))
        }
        intent.stage = .sidecarsMoved
        intent.updatedAt = Date()
        try writeIntent(&intent)
    }

    private func copyIncoming(intent: inout LibrarySwapIntent) throws {
        let backup = URL(fileURLWithPath: intent.backupPath)
        let incoming = URL(fileURLWithPath: intent.incomingPath)

        // Inspect the selected backup before copying. Inspecting the hidden
        // incoming file can make SQLite try to create a WAL beside a name that
        // has not been published yet; the bytes are identical, so the verified
        // source is the correct object to inspect.
        let inspection = try LibraryDatabase.inspectSnapshot(at: backup)
        guard inspection.missingTables.isEmpty,
              inspection.integrityMessages.isEmpty else {
            throw LibrarySwapError.preconditionFailed("the selected backup does not pass inspection")
        }

        try io.copy(backup, to: incoming)
        try io.fsyncFile(incoming)
        guard try io.sha256(incoming) == intent.expectedAfterSHA256 else {
            throw LibrarySwapError.hashMismatch("copied backup")
        }
        intent.stage = .incomingCopied
        intent.updatedAt = Date()
        try writeIntent(&intent)

        intent.stage = .incomingVerified
        intent.updatedAt = Date()
        try writeIntent(&intent)
    }

    private func publishIncoming(intent: inout LibrarySwapIntent) throws {
        let incoming = URL(fileURLWithPath: intent.incomingPath)
        let live = URL(fileURLWithPath: intent.livePath)
        try io.fsyncDirectory(live.deletingLastPathComponent())
        try io.move(incoming, to: live)
        intent.stage = .renamed
        intent.updatedAt = Date()
        try writeIntent(&intent)
        try io.fsyncDirectory(live.deletingLastPathComponent())
    }

    private func rollbackFiles(intent: inout LibrarySwapIntent) throws {
        let live = URL(fileURLWithPath: intent.livePath)
        let preRestore = URL(fileURLWithPath: intent.preRestorePath)
        guard io.fileExists(preRestore) else {
            throw LibrarySwapError.rollbackFailed("the pre-restore file is missing")
        }

        if io.fileExists(live) {
            let evidence = root.appendingPathComponent("incidents", isDirectory: true)
                .appendingPathComponent(intent.incidentID, isDirectory: true)
                .appendingPathComponent("failed-restore-\(UUID().uuidString).sqlite3")
            try io.move(live, to: evidence)
        }
        for suffix in ["-wal", "-shm"] {
            let source = URL(fileURLWithPath: intent.livePath + suffix)
            if io.fileExists(source) {
                let evidence = root.appendingPathComponent("incidents", isDirectory: true)
                    .appendingPathComponent(intent.incidentID, isDirectory: true)
                    .appendingPathComponent("failed-restore-\(UUID().uuidString)\(suffix)")
                try io.move(source, to: evidence)
            }
        }

        try io.move(preRestore, to: live)
        for suffix in ["-wal", "-shm"] {
            let source = URL(fileURLWithPath: intent.preRestorePath + suffix)
            guard io.fileExists(source) else { continue }
            try io.move(source, to: URL(fileURLWithPath: intent.livePath + suffix))
        }
        let incoming = URL(fileURLWithPath: intent.incomingPath)
        if io.fileExists(incoming) {
            try? io.remove(incoming)
        }
        try io.fsyncDirectory(live.deletingLastPathComponent())
        intent.stage = .rolledBack
        intent.updatedAt = Date()
        try writeIntent(&intent)
    }

    // MARK: - Intent

    private func writeIntent(_ intent: inout LibrarySwapIntent) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        do {
            try io.writeAtomic(try encoder.encode(intent), to: intentURL)
            try io.fsyncFile(intentURL)
            try io.fsyncDirectory(root)
        } catch {
            throw LibrarySwapError.ioFailure(error.localizedDescription)
        }
    }

    private func loadIntent() -> LibrarySwapIntent? {
        guard let data = try? Data(contentsOf: intentURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LibrarySwapIntent.self, from: data)
    }
}
