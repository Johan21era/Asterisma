//  LibraryRecoveryService.swift
//  Library Safety — Phase 2
//
//  The actor that performs preservation, read-only diagnosis, and export. It has
//  no DataStore, SwiftUI, GRDB pool, or Sentinel dependency. The coordinator
//  gives it paths; it gives back durable evidence.

import Foundation

nonisolated enum LibraryRecoveryServiceError: LocalizedError, Equatable {
    case noPreservedCopy
    case exportDestinationExists(String)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noPreservedCopy:
            return "The preserved copy is missing."
        case let .exportDestinationExists(path):
            return "An export already exists at \(path)."
        case let .exportFailed(message):
            return "The export failed: \(message)"
        }
    }
}

actor LibraryRecoveryService {
    let root: URL

    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: root.path)
    }

    func preserve(
        incidentID: String,
        storeURL: URL,
        memorySnapshot: Data?,
        now: Date = Date()
    ) throws -> PreservedStore {
        try LibraryStorePreserver.preserve(
            storeURL: storeURL,
            root: root,
            incidentID: incidentID,
            memorySnapshot: memorySnapshot,
            now: now)
    }

    func reloadPreserved(incidentID: String) throws -> PreservedStore {
        try LibraryStorePreserver.loadAndVerify(root: root, incidentID: incidentID)
    }

    func diagnose(incidentID: String) throws -> LibraryDiagnosis {
        let preserved = try LibraryStorePreserver.loadAndVerify(
            root: root, incidentID: incidentID)
        let main = try LibraryStorePreserver.mainFileURL(
            root: root, incidentID: incidentID, preserved: preserved)
        return LibraryDatabaseDoctor.diagnose(mainURL: main)
    }

    func options(
        for diagnosis: LibraryDiagnosis,
        hasPreservedCopy: Bool
    ) -> [RecoveryOption] {
        LibraryRecoveryPlanner.options(
            diagnosis: diagnosis,
            hasPreservedCopy: hasPreservedCopy)
    }

    /// Copies the preserved main file and its sidecars as a portable set. It
    /// does not open the copy read-write, so an exported corrupt file stays
    /// exactly as evidence.
    @discardableResult
    func export(
        incidentID: String,
        to destination: URL,
        replaceExisting: Bool = false
    ) throws -> URL {
        let preserved = try LibraryStorePreserver.loadAndVerify(
            root: root, incidentID: incidentID)
        let source = try LibraryStorePreserver.mainFileURL(
            root: root, incidentID: incidentID, preserved: preserved)

        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            guard replaceExisting else {
                throw LibraryRecoveryServiceError.exportDestinationExists(destination.path)
            }
            try manager.removeItem(at: destination)
        }

        do {
            try manager.copyItem(at: source, to: destination)
            try manager.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: destination.path)
            try LibraryFileSync.fsyncFile(destination)

            let wal = URL(fileURLWithPath: source.path + "-wal")
            if manager.fileExists(atPath: wal.path) {
                let destinationWal = URL(fileURLWithPath: destination.path + "-wal")
                if manager.fileExists(atPath: destinationWal.path) {
                    try manager.removeItem(at: destinationWal)
                }
                try manager.copyItem(at: wal, to: destinationWal)
                try manager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: destinationWal.path)
            }
            try LibraryFileSync.fsyncDirectory(destination.deletingLastPathComponent())
            return destination
        } catch {
            try? manager.removeItem(at: destination)
            if let known = error as? LibraryRecoveryServiceError { throw known }
            throw LibraryRecoveryServiceError.exportFailed(error.localizedDescription)
        }
    }
}
