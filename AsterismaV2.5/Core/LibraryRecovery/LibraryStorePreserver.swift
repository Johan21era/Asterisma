//  LibraryStorePreserver.swift
//  Library Safety — Phase 2
//
//  Preserve before diagnosis. The live store is closed by DataStore first.
//  A preserved copy is never a hard link, never overwritten, and never opened
//  read-write. APFS clone is preferred; a byte copy is the fallback.

import CryptoKit
import Darwin
import Foundation

nonisolated enum LibraryPreservationError: LocalizedError, Equatable {
    case missingStore(String)
    case preservedCopyExists(String)
    case unverifiedCopy(String)
    case ioFailure(String)

    var errorDescription: String? {
        switch self {
        case let .missingStore(path):
            return "The live library does not exist at \(path)."
        case let .preservedCopyExists(path):
            return "A preserved copy already exists at \(path); it was not overwritten."
        case let .unverifiedCopy(message):
            return "The preserved copy could not be verified: \(message)"
        case let .ioFailure(message):
            return "The preserved copy failed: \(message)"
        }
    }
}

nonisolated enum LibraryStorePreserver {

    static func incidentDirectory(root: URL, incidentID: String) -> URL {
        root.appendingPathComponent("incidents", isDirectory: true)
            .appendingPathComponent(incidentID, isDirectory: true)
    }

    static func preservedDirectory(root: URL, incidentID: String) -> URL {
        incidentDirectory(root: root, incidentID: incidentID)
            .appendingPathComponent("preserved", isDirectory: true)
    }

    /// Copies the main store and any sidecars into a fresh directory, hashes
    /// every file, and writes a self-describing manifest.
    static func preserve(
        storeURL: URL,
        root: URL,
        incidentID: String,
        memorySnapshot: Data?,
        now: Date = Date()
    ) throws -> PreservedStore {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            throw LibraryPreservationError.missingStore(storeURL.path)
        }

        let directory = preservedDirectory(root: root, incidentID: incidentID)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            return try loadAndVerify(root: root, incidentID: incidentID)
        }
        if FileManager.default.fileExists(atPath: directory.path) {
            let contents = (try? FileManager.default.contentsOfDirectory(
                atPath: directory.path)) ?? []
            if !contents.isEmpty {
                throw LibraryPreservationError.preservedCopyExists(directory.path)
            }
        }

        try ensurePrivateDirectory(incidentDirectory(root: root, incidentID: incidentID))
        try ensurePrivateDirectory(directory)
        var files: [PreservedFile] = []
        var usedClone = true

        do {
            let main = try preserveFile(
                source: storeURL,
                role: .main,
                in: directory)
            files.append(main.file)
            usedClone = usedClone && main.cloned

            // The WAL is durable evidence; the SHM is a volatile shared-memory
            // index that SQLite recreates. It is not copied: hashing it is not
            // stable, and it can never be the only copy of committed data.
            let wal = URL(fileURLWithPath: storeURL.path + "-wal")
            if FileManager.default.fileExists(atPath: wal.path) {
                let preserved = try preserveFile(
                    source: wal,
                    role: .wal,
                    in: directory)
                files.append(preserved.file)
                usedClone = usedClone && preserved.cloned
            }

            if let memorySnapshot {
                let name = "memory-snapshot.json"
                let destination = directory.appendingPathComponent(name)
                try writePrivate(memorySnapshot, to: destination)
                files.append(PreservedFile(
                    role: .memorySnapshot,
                    name: name,
                    bytes: Int64(memorySnapshot.count),
                    sha256: try LibraryFileSync.sha256(of: destination)))
            }

            let combined = combinedHash(files)
            var preserved = PreservedStore(
                directoryName: "preserved",
                files: files,
                combinedSHA256: combined,
                createdAt: now,
                method: usedClone ? .apfsClone : .byteCopy)

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let manifest = try encoder.encode(preserved)
            let destination = directory.appendingPathComponent("manifest.json")
            try writePrivate(manifest, to: destination)
            preserved = try loadAndVerify(root: root, incidentID: incidentID)
            return preserved
        } catch {
            // Remove only files created by this failed attempt; never a
            // pre-existing preserved copy (guarded above).
            try? FileManager.default.removeItem(at: directory)
            if let known = error as? LibraryPreservationError { throw known }
            throw LibraryPreservationError.ioFailure(error.localizedDescription)
        }
    }

    static func loadAndVerify(root: URL, incidentID: String) throws -> PreservedStore {
        let directory = preservedDirectory(root: root, incidentID: incidentID)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw LibraryPreservationError.unverifiedCopy("manifest missing")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let preserved = try? decoder.decode(PreservedStore.self, from: data) else {
            throw LibraryPreservationError.unverifiedCopy("manifest unreadable")
        }
        for file in preserved.files {
            let url = directory.appendingPathComponent(file.name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw LibraryPreservationError.unverifiedCopy("missing \(file.name)")
            }
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? -1
            guard bytes == file.bytes else {
                throw LibraryPreservationError.unverifiedCopy("size changed for \(file.name)")
            }
            guard try LibraryFileSync.sha256(of: url) == file.sha256 else {
                throw LibraryPreservationError.unverifiedCopy("hash changed for \(file.name)")
            }
        }
        guard combinedHash(preserved.files) == preserved.combinedSHA256 else {
            throw LibraryPreservationError.unverifiedCopy("combined hash mismatch")
        }
        return preserved
    }

    static func mainFileURL(
        root: URL,
        incidentID: String,
        preserved: PreservedStore
    ) throws -> URL {
        guard let main = preserved.files.first(where: { $0.role == .main }) else {
            throw LibraryPreservationError.unverifiedCopy("main file missing")
        }
        let url = preservedDirectory(root: root, incidentID: incidentID)
            .appendingPathComponent(main.name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LibraryPreservationError.unverifiedCopy("main file missing")
        }
        return url
    }

    // MARK: - Files

    private static func preserveFile(
        source: URL,
        role: PreservedFileRole,
        in directory: URL
    ) throws -> (file: PreservedFile, cloned: Bool) {
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw LibraryPreservationError.preservedCopyExists(destination.path)
        }

        let cloned: Bool
        if clonefile(source.path, destination.path, 0) == 0 {
            cloned = true
        } else {
            do {
                try FileManager.default.copyItem(at: source, to: destination)
                cloned = false
            } catch {
                throw LibraryPreservationError.ioFailure(error.localizedDescription)
            }
        }

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: destination.path)
        try LibraryFileSync.fsyncFile(destination)

        let attrs = try FileManager.default.attributesOfItem(atPath: destination.path)
        let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let hash = try LibraryFileSync.sha256(of: destination)
        return (
            PreservedFile(
                role: role,
                name: destination.lastPathComponent,
                bytes: bytes,
                sha256: hash),
            cloned)
    }

    private static func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
        try LibraryFileSync.fsyncFile(url)
    }

    private static func ensurePrivateDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            throw LibraryPreservationError.ioFailure(error.localizedDescription)
        }
    }

    static func combinedHash(_ files: [PreservedFile]) -> String {
        let order: [PreservedFileRole] = [.main, .wal, .shm, .memorySnapshot, .manifest]
        let material = files
            .sorted { lhs, rhs in
                let left = order.firstIndex(of: lhs.role) ?? order.count
                let right = order.firstIndex(of: rhs.role) ?? order.count
                if left == right { return lhs.name < rhs.name }
                return left < right
            }
            .map { "\($0.role.rawValue)|\($0.name)|\($0.sha256)" }
            .joined(separator: "\n")
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
