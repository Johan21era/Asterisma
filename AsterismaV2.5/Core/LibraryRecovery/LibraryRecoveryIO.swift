//  LibraryRecoveryIO.swift
//  Library Safety — Phase 4
//
//  File operations behind a protocol so crash paths can be injected without
//  changing the production coordinator. Production always uses full fsync.

import Foundation

nonisolated protocol LibraryRecoveryIO: Sendable {
    func fileExists(_ url: URL) -> Bool
    func directoryExists(_ url: URL) -> Bool
    func createDirectory(_ url: URL) throws
    func move(_ source: URL, to destination: URL) throws
    func copy(_ source: URL, to destination: URL) throws
    func remove(_ url: URL) throws
    func writeAtomic(_ data: Data, to url: URL) throws
    func sha256(_ url: URL) throws -> String
    func fsyncFile(_ url: URL) throws
    func fsyncDirectory(_ url: URL) throws
    func fileSize(_ url: URL) throws -> Int64
}

nonisolated struct ProductionLibraryRecoveryIO: LibraryRecoveryIO {
    func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    func move(_ source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }

    func copy(_ source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }

    func remove(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    func writeAtomic(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func sha256(_ url: URL) throws -> String {
        try LibraryFileSync.sha256(of: url)
    }

    func fsyncFile(_ url: URL) throws {
        try LibraryFileSync.fsyncFile(url)
    }

    func fsyncDirectory(_ url: URL) throws {
        try LibraryFileSync.fsyncDirectory(url)
    }

    func fileSize(_ url: URL) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }
}
