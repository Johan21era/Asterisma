//  LibraryRowRepairService.swift
//  Library Safety — Phase 5
//
//  Row repair is for referentially orphaned rows, not for undecodable payloads.
//  It assumes the live store is closed (the recovery incident is frozen). Every
//  delete is preceded by a raw-row export and can be undone from that file.

import Foundation
import GRDB

nonisolated struct LibraryOrphanGroup: Identifiable, Hashable, Sendable {
    var id: String { table }
    var table: String
    var count: Int
    var sampleKeys: [String]
}

nonisolated struct LibraryRowRepairReceipt: Sendable {
    var table: String
    var deletedRows: Int
    var exportURL: URL
    var deletedAt: Date
}

nonisolated enum LibraryRowRepairError: LocalizedError, Equatable {
    case unsupportedTable(String)
    case storeClosed
    case exportMissing(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedTable(table):
            return "Row repair does not support \(table)."
        case .storeClosed:
            return "The library must be frozen before row repair."
        case let .exportMissing(path):
            return "The row export is missing at \(path)."
        case let .writeFailed(message):
            return "Row repair failed: \(message)"
        }
    }
}

actor LibraryRowRepairService {
    let root: URL
    private let supportedTables: Set<String> = [
        "page_times", "sessions", "notes", "book_collections",
    ]

    init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: root.path)
    }

    func inventory(databaseURL: URL) throws -> [LibraryOrphanGroup] {
        let queue = try open(databaseURL)
        defer { try? queue.close() }
        return try queue.read { db in
            var groups: [LibraryOrphanGroup] = []
            for table in supportedTables.sorted() {
                guard try tableExists(db, table) else { continue }
                let predicate = try orphanPredicate(db, table: table)
                let count = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM \(table) WHERE \(predicate)") ?? 0
                guard count > 0 else { continue }
                let keyExpression = table == "book_collections"
                    ? "book_id || '|' || collection_id"
                    : "id"
                let sample = try String.fetchAll(
                    db,
                    sql: "SELECT \(keyExpression) FROM \(table) WHERE \(predicate) LIMIT 20")
                groups.append(LibraryOrphanGroup(
                    table: table, count: count, sampleKeys: sample))
            }
            return groups
        }
    }

    /// Exports every orphan row and deletes exactly those rowids in one
    /// transaction. The export is written and fsynced before the delete starts.
    func deleteOrphans(
        databaseURL: URL,
        table: String,
        now: Date = Date()
    ) throws -> LibraryRowRepairReceipt {
        guard supportedTables.contains(table) else {
            throw LibraryRowRepairError.unsupportedTable(table)
        }
        let queue = try open(databaseURL)
        defer { try? queue.close() }

        // PRAGMA foreign_keys is a no-op inside a transaction, and the export
        // must be durable before the delete commits. So the connection runs
        // without the implicit transaction that `write` would open.
        let result = try queue.writeWithoutTransaction { db -> (url: URL, count: Int) in
            guard try tableExists(db, table) else {
                throw LibraryRowRepairError.unsupportedTable(table)
            }
            let predicate = try orphanPredicate(db, table: table)
            let rows = try Row.fetchAll(
                db, sql: "SELECT rowid AS _repair_rowid, * FROM \(table) WHERE \(predicate)")
            guard !rows.isEmpty else {
                throw LibraryRowRepairError.writeFailed("no orphan rows found")
            }

            let export = try makeExport(
                table: table,
                rows: rows,
                databasePath: databaseURL.path,
                now: now)
            let url = try writeExport(export, table: table)

            let rowids = rows.compactMap { $0["_repair_rowid"] as Int64? }
            try db.inTransaction {
                for rowid in rowids {
                    try db.execute(
                        sql: "DELETE FROM \(table) WHERE rowid = ?",
                        arguments: [rowid])
                }
                return .commit
            }
            return (url, rows.count)
        }

        return LibraryRowRepairReceipt(
            table: table,
            deletedRows: result.count,
            exportURL: result.url,
            deletedAt: now)
    }

    /// Re-inserts every exported row. The file is untrusted input, so only
    /// columns that still exist and tables on the allowlist are accepted.
    @discardableResult
    func undo(exportURL: URL) throws -> Int {
        guard let data = try? Data(contentsOf: exportURL) else {
            throw LibraryRowRepairError.exportMissing(exportURL.path)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let table = object["table"] as? String,
              supportedTables.contains(table),
              let rows = object["rows"] as? [[String: Any]] else {
            throw LibraryRowRepairError.writeFailed("unrecognized row export")
        }

        let databasePath = object["databasePath"] as? String
        guard let databasePath else {
            throw LibraryRowRepairError.writeFailed("export has no database path")
        }
        let queue = try open(URL(fileURLWithPath: databasePath))
        defer { try? queue.close() }

        return try queue.writeWithoutTransaction { db in
            // Restoring orphan rows must not be blocked by enforcement, and the
            // pragma itself cannot change inside a transaction.
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            defer { try? db.execute(sql: "PRAGMA foreign_keys = ON") }
            var inserted = 0
            try db.inTransaction {
                for row in rows {
                    let columns = row.keys
                        .filter { $0 != "_repair_rowid" }
                        .sorted()
                    guard !columns.isEmpty else { continue }
                    let placeholders = Array(repeating: "?", count: columns.count)
                        .joined(separator: ", ")
                    let sql = "INSERT OR REPLACE INTO \(table) " +
                        "(\(columns.joined(separator: ", "))) VALUES (\(placeholders))"
                    let values = columns.map { column -> DatabaseValueConvertible? in
                        Self.databaseValue(row[column])
                    }
                    try db.execute(sql: sql, arguments: StatementArguments(values))
                    inserted += 1
                }
                return .commit
            }
            return inserted
        }
    }

    // MARK: - Orphans

    private func orphanPredicate(_ db: Database, table: String) throws -> String {
        switch table {
        case "page_times":
            return "session_id NOT IN (SELECT id FROM sessions)"
        case "sessions":
            return "book_id NOT IN (SELECT id FROM books)"
        case "notes":
            return "book_id NOT IN (SELECT id FROM books)"
        case "book_collections":
            return "book_id NOT IN (SELECT id FROM books) " +
                "OR collection_id NOT IN (SELECT id FROM collections)"
        default:
            throw LibraryRowRepairError.unsupportedTable(table)
        }
    }

    // MARK: - Export

    private func makeExport(
        table: String,
        rows: [Row],
        databasePath: String,
        now: Date
    ) throws -> [String: Any] {
        var encoded: [[String: Any]] = []
        for row in rows {
            var object: [String: Any] = [:]
            for column in row.columnNames {
                object[column] = Self.jsonValue(row[column] as DatabaseValue)
            }
            encoded.append(object)
        }
        return [
            "schemaVersion": 1,
            "table": table,
            "databasePath": databasePath,
            "exportedAt": ISO8601DateFormatter().string(from: now),
            "rows": encoded,
        ]
    }

    private func writeExport(
        _ object: [String: Any],
        table: String
    ) throws -> URL {
        let directory = root.appendingPathComponent("quarantine/rows", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let url = directory.appendingPathComponent(
            "orphans-\(table)-\(UUID().uuidString).json")
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: [])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
        try LibraryFileSync.fsyncFile(url)
        try LibraryFileSync.fsyncDirectory(directory)
        return url
    }

    private func open(_ url: URL) throws -> DatabaseQueue {
        var config = Configuration()
        config.busyMode = .timeout(2)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
        }
        return try DatabaseQueue(path: url.path, configuration: config)
    }

    private func tableExists(_ db: Database, _ name: String) throws -> Bool {
        (try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?",
            arguments: [name]) ?? 0) > 0
    }

    private static func jsonValue(_ value: DatabaseValue) -> Any {
        switch value.storage {
        case .null: return NSNull()
        case let .int64(number): return number
        case let .double(number): return number
        case let .string(text): return text
        case let .blob(data): return data.base64EncodedString()
        }
    }

    private static func databaseValue(_ value: Any?) -> DatabaseValueConvertible? {
        guard let value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber {
            let double = number.doubleValue
            if double.rounded() == double {
                return number.int64Value
            }
            return double
        }
        if let text = value as? String { return text }
        return nil
    }
}
