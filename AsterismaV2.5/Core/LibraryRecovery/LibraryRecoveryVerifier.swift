//  LibraryRecoveryVerifier.swift
//  Library Safety — Phase 4
//
//  Independent post-recovery checks. This does not trust the option that ran,
//  the manifest alone, or the absence of an error. It opens the new live file
//  read-only and decodes it.

import Foundation

nonisolated enum LibraryRecoveryVerifier {

    static func verify(
        liveURL: URL,
        expectedCounts: LibraryTableCounts?,
        now: Date = Date()
    ) -> RecoveryVerification {
        do {
            let connection = try LibraryReadOnlyConnection(url: liveURL)
            defer { connection.close() }
            let inspection = try connection.inspect(fullIntegrity: true)
            let books = try connection.readBooks()
            let stateDecoded = try connection.readStateDecoded()

            let countsMatch = expectedCounts.map {
                $0 == inspection.manifest.counts
            } ?? false

            return RecoveryVerification(
                quickCheck: inspection.manifest.quickCheck,
                integrityCheck: inspection.integrityMessages,
                foreignKeyViolations: inspection.manifest.foreignKeyViolations,
                countsMatchManifest: countsMatch,
                booksDecoded: books.undecodable == 0 ? books.total : nil,
                stateDecoded: stateDecoded,
                sentinelVerified: nil,
                verifiedAt: now)
        } catch {
            return RecoveryVerification(
                quickCheck: nil,
                integrityCheck: ["unreadable"],
                foreignKeyViolations: 0,
                countsMatchManifest: false,
                booksDecoded: nil,
                stateDecoded: false,
                sentinelVerified: nil,
                verifiedAt: now)
        }
    }

    static func isPassed(_ verification: RecoveryVerification) -> Bool {
        verification.quickCheck?.lowercased() == "ok"
            && verification.integrityCheck.isEmpty
            && verification.foreignKeyViolations == 0
            && verification.countsMatchManifest
            && verification.booksDecoded != nil
            && verification.stateDecoded
    }
}
