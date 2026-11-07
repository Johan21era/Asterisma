//  LibraryIncidentStore.swift
//  Library Safety — Phase 1
//
//  One incident = one directory. `incident.json` is replaced atomically and
//  fsynced before the coordinator publishes anything. Receipts are immutable
//  once written. A directory that cannot be decoded is reported as corrupt and
//  left untouched, never deleted.

import Darwin
import Foundation

nonisolated struct LibraryIncidentScanResult: Sendable {
    var incidents: [LibraryIncident]
    var corruptIncidentIDs: [String]
}

nonisolated enum LibraryIncidentStoreError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case corruptIncident(String)
    case receiptExists(String)
    case ioFailure(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            return "This incident was written by a newer app (schema \(version))."
        case let .corruptIncident(id):
            return "The incident \(id) could not be decoded."
        case let .receiptExists(id):
            return "The receipt \(id) already exists and is immutable."
        case let .ioFailure(message):
            return "Incident storage failed: \(message)"
        }
    }
}

actor LibraryIncidentStore {
    let root: URL
    private let incidentsRoot: URL
    private let receiptsRoot: URL
    private let fileManager = FileManager.default

    init(root: URL) throws {
        self.root = root
        self.incidentsRoot = root.appendingPathComponent("incidents", isDirectory: true)
        self.receiptsRoot = root.appendingPathComponent("receipts", isDirectory: true)
        try Self.ensurePrivateDirectory(root)
        try Self.ensurePrivateDirectory(incidentsRoot)
        try Self.ensurePrivateDirectory(receiptsRoot)
    }

    static func standard(dataRoot: URL) throws -> LibraryIncidentStore {
        try LibraryIncidentStore(
            root: dataRoot.appendingPathComponent("LibraryRecovery", isDirectory: true))
    }

    func incidentDirectory(id: String) -> URL {
        incidentsRoot.appendingPathComponent(id, isDirectory: true)
    }

    func create(_ incident: LibraryIncident) throws -> LibraryIncident {
        try Self.ensurePrivateDirectory(incidentDirectory(id: incident.id))
        return try save(incident)
    }

    @discardableResult
    func save(_ incident: LibraryIncident) throws -> LibraryIncident {
        var copy = incident
        copy.updatedAt = Date()
        let directory = incidentDirectory(id: copy.id)
        try Self.ensurePrivateDirectory(directory)
        let destination = directory.appendingPathComponent("incident.json")
        try writeAtomic(try Self.encoder().encode(copy), to: destination)
        return copy
    }

    func read(id: String) throws -> LibraryIncident {
        let url = incidentDirectory(id: id).appendingPathComponent("incident.json")
        guard let data = try? Data(contentsOf: url) else {
            throw LibraryIncidentStoreError.corruptIncident(id)
        }
        return try Self.decode(data, expectedID: id)
    }

    func scan() throws -> LibraryIncidentScanResult {
        let children = (try? fileManager.contentsOfDirectory(
            at: incidentsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []

        var incidents: [LibraryIncident] = []
        var corrupt: [String] = []
        for child in children {
            let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey])
                .isDirectory) ?? false
            guard isDirectory else { continue }
            do {
                incidents.append(try read(id: child.lastPathComponent))
            } catch {
                corrupt.append(child.lastPathComponent)
            }
        }
        incidents.sort { $0.updatedAt > $1.updatedAt }
        return LibraryIncidentScanResult(
            incidents: incidents,
            corruptIncidentIDs: corrupt.sorted())
    }

    func latestOpenIncident() throws -> LibraryIncident? {
        try scan().incidents.first { !$0.isTerminal }
    }

    @discardableResult
    func writeReceipt(_ receipt: RecoveryReceipt) throws -> URL {
        let destination = receiptsRoot.appendingPathComponent("\(receipt.id).json")
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw LibraryIncidentStoreError.receiptExists(receipt.id)
        }
        try writeAtomic(try Self.encoder().encode(receipt), to: destination)
        return destination
    }

    func readReceipt(id: String) throws -> RecoveryReceipt {
        let url = receiptsRoot.appendingPathComponent("\(id).json")
        guard let data = try? Data(contentsOf: url) else {
            throw LibraryIncidentStoreError.corruptIncident(id)
        }
        let decoder = Self.decoder()
        guard let receipt = try? decoder.decode(RecoveryReceipt.self, from: data) else {
            throw LibraryIncidentStoreError.corruptIncident(id)
        }
        return receipt
    }

    // MARK: - Encoding

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Tolerant of the older `deferredToDate` encoding, but refuses a newer
    /// schema instead of pretending it can operate on it.
    private static func decode(_ data: Data, expectedID: String) throws -> LibraryIncident {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let schema = raw["schemaVersion"] as? Int else {
            throw LibraryIncidentStoreError.corruptIncident(expectedID)
        }
        guard schema <= LibraryIncident.currentSchemaVersion else {
            throw LibraryIncidentStoreError.unsupportedSchema(schema)
        }

        let iso = decoder()
        if let incident = try? iso.decode(LibraryIncident.self, from: data) {
            guard incident.id == expectedID else {
                throw LibraryIncidentStoreError.corruptIncident(expectedID)
            }
            return incident
        }

        let legacy = JSONDecoder()
        legacy.dateDecodingStrategy = .deferredToDate
        guard let incident = try? legacy.decode(LibraryIncident.self, from: data) else {
            throw LibraryIncidentStoreError.corruptIncident(expectedID)
        }
        guard incident.id == expectedID else {
            throw LibraryIncidentStoreError.corruptIncident(expectedID)
        }
        return incident
    }

    // MARK: - Durable write

    private func writeAtomic(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try Self.ensurePrivateDirectory(directory)
        let temporary = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")

        do {
            try data.write(to: temporary, options: [])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            try LibraryFileSync.fsyncFile(temporary)

            // POSIX rename is atomic and replaces the old file in one step.
            guard rename(temporary.path, destination.path) == 0 else {
                throw LibraryIncidentStoreError.ioFailure(
                    "rename failed: errno \(errno)")
            }
            try LibraryFileSync.fsyncDirectory(directory)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            if let known = error as? LibraryIncidentStoreError { throw known }
            throw LibraryIncidentStoreError.ioFailure(error.localizedDescription)
        }
    }

    private static func ensurePrivateDirectory(_ url: URL) throws {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            throw LibraryIncidentStoreError.ioFailure(error.localizedDescription)
        }
    }
}
