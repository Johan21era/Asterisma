//  LibraryRecoveryContracts.swift
//  Library Safety — Phase 0
//
//  The shared vocabulary between DataStore, Sentinel, and Library Recovery.
//  Recovery owns file surgery; DataStore owns the live connection; Sentinel
//  consumes only these status types. Nothing here imports Sentinel or Recovery.

import Foundation

nonisolated enum LibraryStorageEngineKind: String, Codable, Hashable, Sendable {
    case json
    case sqlite
}

/// What the app is allowed to do with the library right now. This is a
/// product-visible fact, not a log line: the UI, Sentinel, and recovery all
/// read the same value.
nonisolated enum StorageCondition: Equatable, Sendable {
    case healthy(engine: LibraryStorageEngineKind)
    case degraded(engine: LibraryStorageEngineKind, code: String, message: String)
    case readOnly(engine: LibraryStorageEngineKind, code: String, message: String)
    case recovering(incidentID: String)
    case failed(engine: LibraryStorageEngineKind, code: String, message: String)

    var engine: LibraryStorageEngineKind {
        switch self {
        case let .healthy(engine), let .degraded(engine, _, _),
             let .readOnly(engine, _, _), let .failed(engine, _, _):
            return engine
        case .recovering:
            return .sqlite
        }
    }

    var isWritable: Bool {
        if case .healthy = self { return true }
        return false
    }

    var isRecovering: Bool {
        if case .recovering = self { return true }
        return false
    }

    var code: String? {
        switch self {
        case let .degraded(_, code, _), let .readOnly(_, code, _),
             let .failed(_, code, _):
            return code
        case .healthy, .recovering:
            return nil
        }
    }
}

/// Proof that the live store was drained and closed for a recovery episode.
/// The token is bound to one incident; it cannot be reused by a second flow.
nonisolated struct LibraryFreezeToken: Codable, Hashable, Sendable {
    var id: String
    var incidentID: String
    var engine: LibraryStorageEngineKind
    var databasePath: String?
    var createdAt: Date
}

/// DataStore's side of the recovery boundary. Library Recovery can freeze the
/// live store and reopen it, but it never opens SQLite itself.
@MainActor
protocol LibraryRecoveryHost: AnyObject {
    func currentStorageCondition() -> StorageCondition
    func freezeForRecovery(incidentID: String) async throws -> LibraryFreezeToken
    func reopenAfterRecovery(token: LibraryFreezeToken) async throws
    /// The live SQLite file recovery must preserve. Nil in JSON mode.
    func liveDatabaseURL() -> URL?
    /// The app's in-memory library, encoded before the store is closed. This is
    /// the last source of truth when the file itself cannot be opened.
    func memorySnapshotData() -> Data?
}

/// The in-memory library at freeze time. Recovery never treats this as a
/// database, but it may be the only readable copy of a book if the file is
/// destroyed. It is encoded before the live connection closes.
nonisolated struct LibraryMemorySnapshot: Codable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int
    var capturedAt: Date
    var books: [Book]
    var state: LibraryState
}

nonisolated enum LibraryRecoveryHostError: LocalizedError, Equatable {
    case notSQLite
    case alreadyFrozen
    case notFrozen
    case tokenMismatch
    case noDatabaseURL
    case closeFailed(String)
    case reopenFailed(String)

    var errorDescription: String? {
        switch self {
        case .notSQLite:
            return "This library is not using SQLite; recovery is not applicable."
        case .alreadyFrozen:
            return "The library is already frozen for recovery."
        case .notFrozen:
            return "The library is not frozen for recovery."
        case .tokenMismatch:
            return "The recovery token does not match the active freeze."
        case .noDatabaseURL:
            return "The database location is not known."
        case let .closeFailed(message):
            return "The database could not be closed: \(message)"
        case let .reopenFailed(message):
            return "The recovered database could not be reopened: \(message)"
        }
    }
}
