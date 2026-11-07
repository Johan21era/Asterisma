//  LibraryIncident.swift
//  Library Safety — Phase 1
//
//  The durable record of one recovery episode. Everything persisted here is
//  safe to hand to support: codes, counts, hashes, table names, and opaque IDs.
//  No paths, titles, authors, note text, or raw payloads.

import Foundation

// MARK: - Incident

nonisolated struct LibraryIncident: Codable, Hashable, Identifiable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var id: String
    var kind: LibraryIncidentKind
    var state: LibraryIncidentState
    var trigger: LibraryTrigger
    var detectedAt: Date
    var updatedAt: Date
    var resolvedAt: Date?

    var evidence: [LibraryEvidence]
    var fingerprint: LibraryStoreFingerprint?
    var preserved: PreservedStore?
    var diagnosis: LibraryDiagnosis?
    var options: [RecoveryOption]
    var chosenOptionID: String?
    var receipts: [String]
    var lastError: RecoveryError?
    var userSummaryKey: String
    var readOnly: Bool

    init(
        id: String = "inc_" + UUID().uuidString,
        kind: LibraryIncidentKind,
        state: LibraryIncidentState = .detected,
        trigger: LibraryTrigger,
        detectedAt: Date = Date(),
        updatedAt: Date? = nil,
        resolvedAt: Date? = nil,
        evidence: [LibraryEvidence] = [],
        fingerprint: LibraryStoreFingerprint? = nil,
        preserved: PreservedStore? = nil,
        diagnosis: LibraryDiagnosis? = nil,
        options: [RecoveryOption] = [],
        chosenOptionID: String? = nil,
        receipts: [String] = [],
        lastError: RecoveryError? = nil,
        userSummaryKey: String = "recovery.incident.generic",
        readOnly: Bool = true
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.kind = kind
        self.state = state
        self.trigger = trigger
        self.detectedAt = detectedAt
        self.updatedAt = updatedAt ?? detectedAt
        self.resolvedAt = resolvedAt
        self.evidence = evidence
        self.fingerprint = fingerprint
        self.preserved = preserved
        self.diagnosis = diagnosis
        self.options = options
        self.chosenOptionID = chosenOptionID
        self.receipts = receipts
        self.lastError = lastError
        self.userSummaryKey = userSummaryKey
        self.readOnly = readOnly
    }

    var isTerminal: Bool {
        state == .resolved || state == .abandoned
    }
}

// MARK: - Kind

nonisolated enum LibraryIncidentKind: String, Codable, CaseIterable, Sendable {
    case loadFailed
    case writeFailed
    case integrityCheckFailed
    case databaseUnreadable
    case schemaMismatch
    case recordDecodeFailed
    case backupVerificationFailed
    case diskSpaceCritical
    case recoveryInterrupted
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

// MARK: - State

nonisolated enum LibraryIncidentState: String, Codable, CaseIterable, Sendable {
    case detected
    case freezing
    case frozen
    case diagnosing
    case awaitingDecision
    case executing
    case verifying
    case resolved
    case failed
    case abandoned
    case unknown

    var isTerminal: Bool {
        self == .resolved || self == .abandoned
    }

    var isInterruptedCandidate: Bool {
        switch self {
        case .freezing, .frozen, .diagnosing, .executing, .verifying:
            return true
        case .detected, .awaitingDecision, .resolved, .failed, .abandoned, .unknown:
            return false
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

// MARK: - Trigger

nonisolated enum LibraryTrigger: Codable, Hashable, Sendable {
    case loadFailure(code: String)
    case writeFailure(code: String)
    case probeFinding(ruleID: String, fingerprint: String)
    case backupVerification(backupID: String)
    case launchInterruptedSwap(incidentID: String)
    case userRequested
    case unknown

    private enum CodingKeys: String, CodingKey {
        case type, code, ruleID, fingerprint, backupID, incidentID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "loadFailure":
            self = .loadFailure(code: try container.decode(String.self, forKey: .code))
        case "writeFailure":
            self = .writeFailure(code: try container.decode(String.self, forKey: .code))
        case "probeFinding":
            self = .probeFinding(
                ruleID: try container.decode(String.self, forKey: .ruleID),
                fingerprint: try container.decode(String.self, forKey: .fingerprint))
        case "backupVerification":
            self = .backupVerification(
                backupID: try container.decode(String.self, forKey: .backupID))
        case "launchInterruptedSwap":
            self = .launchInterruptedSwap(
                incidentID: try container.decode(String.self, forKey: .incidentID))
        case "userRequested":
            self = .userRequested
        default:
            self = .unknown
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .loadFailure(code):
            try container.encode("loadFailure", forKey: .type)
            try container.encode(code, forKey: .code)
        case let .writeFailure(code):
            try container.encode("writeFailure", forKey: .type)
            try container.encode(code, forKey: .code)
        case let .probeFinding(ruleID, fingerprint):
            try container.encode("probeFinding", forKey: .type)
            try container.encode(ruleID, forKey: .ruleID)
            try container.encode(fingerprint, forKey: .fingerprint)
        case let .backupVerification(backupID):
            try container.encode("backupVerification", forKey: .type)
            try container.encode(backupID, forKey: .backupID)
        case let .launchInterruptedSwap(incidentID):
            try container.encode("launchInterruptedSwap", forKey: .type)
            try container.encode(incidentID, forKey: .incidentID)
        case .userRequested:
            try container.encode("userRequested", forKey: .type)
        case .unknown:
            try container.encode("unknown", forKey: .type)
        }
    }

    var code: String? {
        switch self {
        case let .loadFailure(code), let .writeFailure(code): return code
        case let .probeFinding(ruleID, _): return ruleID
        case .backupVerification, .launchInterruptedSwap, .userRequested, .unknown:
            return nil
        }
    }
}

// MARK: - Safe evidence

nonisolated struct LibraryEvidence: Codable, Hashable, Sendable {
    var code: String
    var count: Int?
    var bytes: Int64?
    var hash: String?
    var table: String?
    var enumValue: String?
}

nonisolated struct RecoveryError: Codable, Hashable, Sendable {
    var code: String
    var messageKey: String
    var isCritical: Bool
}

// MARK: - Fingerprint

nonisolated struct LibraryStoreFingerprint: Codable, Hashable, Sendable {
    var mainSHA256: String
    var mainBytes: Int64
    var walBytes: Int64?
    var shmBytes: Int64?
    var pageCount: Int?
    var freelistCount: Int?
    var pageSize: Int?
    var journalMode: String?
    var schemaVersion: Int?
    var sqliteVersion: String?
    var tableCounts: LibraryTableCounts?
    var capturedAt: Date
}

// MARK: - Preserved store

nonisolated struct PreservedStore: Codable, Hashable, Sendable {
    var directoryName: String
    var files: [PreservedFile]
    var combinedSHA256: String
    var createdAt: Date
    var method: PreservationMethod
}

nonisolated struct PreservedFile: Codable, Hashable, Sendable {
    var role: PreservedFileRole
    var name: String
    var bytes: Int64
    var sha256: String
}

nonisolated enum PreservedFileRole: String, Codable, Sendable {
    case main
    case wal
    case shm
    case memorySnapshot
    case manifest
}

nonisolated enum PreservationMethod: String, Codable, Sendable {
    case apfsClone
    case byteCopy
}

// MARK: - Diagnosis

nonisolated struct LibraryDiagnosis: Codable, Hashable, Sendable {
    var canOpenReadOnly: Bool
    var quickCheck: String?
    var integrityCheck: [String]
    var foreignKeyViolations: [String: Int]
    var tableCounts: LibraryTableCounts?
    var missingTables: [String]
    var unexpectedTables: [String]
    var undecodableBooks: Int
    var undecodableState: Bool
    var pageCount: Int?
    var freelistCount: Int?
    var pageSize: Int?
    var canVacuum: Bool
    var canRebuildFromPayloads: Bool
    var canRecoverPageTimings: Bool
    var notes: [String]
    var diagnosedAt: Date
}

// MARK: - Options

nonisolated struct RecoveryOption: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var kind: RecoveryOptionKind
    var risk: RecoveryRisk
    var titleKey: String
    var detailKey: String
    var estimate: RecoveryEstimate
    var preconditions: [RecoveryPrecondition]
    var confirmation: RecoveryConfirmationLevel
    var isEnabled: Bool
    var disabledReasonKey: String?
    var backupID: String?
}

nonisolated enum RecoveryOptionKind: String, Codable, CaseIterable, Sendable {
    case exportCopy
    case restoreBackup
    case salvageReadableRows
    case rebuildNormalizedTables
    case quarantineRecord
    case doNothing
}

nonisolated enum RecoveryRisk: String, Codable, Sendable {
    case readOnly
    case rowLevel
    case fileLevel
}

nonisolated enum RecoveryPrecondition: String, Codable, Hashable, Sendable {
    case preservedCopyVerified
    case verifiedBackup
    case schemaCompatible
    case sufficientFreeSpace
    case storeFrozen
    case confirmationRequired
}

nonisolated enum RecoveryConfirmationLevel: String, Codable, Sendable {
    case none
    case singleAction
    case typedPhrase
}

nonisolated struct RecoveryEstimate: Codable, Hashable, Sendable {
    var recoveredRows: Int?
    var lostRows: Int?
    var unknownRows: Bool
    var perTable: [String: Int]
    var noteKey: String?
}

// MARK: - Receipt

nonisolated struct RecoveryReceipt: Codable, Hashable, Identifiable, Sendable {
    var schemaVersion: Int
    var id: String
    var incidentID: String
    var optionID: String
    var kind: RecoveryOptionKind
    var startedAt: Date
    var finishedAt: Date
    var outcome: RecoveryOutcome
    var beforeFingerprint: LibraryStoreFingerprint?
    var afterFingerprint: LibraryStoreFingerprint?
    var recoveredRows: Int?
    var lostRows: Int?
    var quarantinedRows: Int?
    var verification: RecoveryVerification?
    var error: RecoveryError?
}

nonisolated enum RecoveryOutcome: String, Codable, Sendable {
    case succeeded
    case failed
    case rolledBack
    case critical
    case abandoned
}

nonisolated struct RecoveryVerification: Codable, Hashable, Sendable {
    var quickCheck: String?
    var integrityCheck: [String]
    var foreignKeyViolations: Int
    var countsMatchManifest: Bool
    var booksDecoded: Int?
    var stateDecoded: Bool
    var sentinelVerified: Bool?
    var verifiedAt: Date
}

// MARK: - State machine

nonisolated enum LibraryIncidentEvent: Sendable {
    case beginFreeze
    case frozen
    case freezeFailed
    case beginDiagnosis
    case optionsReady
    case diagnosisFailed
    case execute
    case abandon
    case verify
    case executeFailed
    case resolved
    case verifyFailed
    case retry
    case interrupted
    case critical
}

nonisolated struct LibraryIncidentTransitionContext: Sendable {
    var hasTrigger = true
    var storeFrozen = false
    var preservedVerified = false
    var diagnosisComplete = false
    var confirmationValid = false
    var newStoreExists = false
    var verificationPassed = false
    var preservedIntact = false

    static let none = LibraryIncidentTransitionContext()
}

nonisolated enum LibraryIncidentTransitionError: LocalizedError, Equatable {
    case invalidTransition(from: LibraryIncidentState, event: String)
    case guardFailed(String)

    var errorDescription: String? {
        switch self {
        case let .invalidTransition(from, event):
            return "The incident cannot move from \(from.rawValue) on \(event)."
        case let .guardFailed(reason):
            return "The incident transition was refused: \(reason)"
        }
    }
}

nonisolated enum LibraryIncidentStateMachine {

    static func transition(
        from state: LibraryIncidentState,
        event: LibraryIncidentEvent,
        context: LibraryIncidentTransitionContext = .none
    ) throws -> LibraryIncidentState {
        switch (state, event) {
        case (.detected, .beginFreeze):
            guard context.hasTrigger else { throw LibraryIncidentTransitionError.guardFailed("missing trigger") }
            return .freezing

        case (.freezing, .frozen):
            guard context.storeFrozen else { throw LibraryIncidentTransitionError.guardFailed("store not frozen") }
            return .frozen
        case (.freezing, .freezeFailed):
            return .failed

        case (.frozen, .beginDiagnosis):
            guard context.preservedVerified else {
                throw LibraryIncidentTransitionError.guardFailed("preserved copy not verified")
            }
            return .diagnosing

        case (.diagnosing, .optionsReady):
            guard context.diagnosisComplete else {
                throw LibraryIncidentTransitionError.guardFailed("diagnosis incomplete")
            }
            return .awaitingDecision
        case (.diagnosing, .diagnosisFailed):
            return .failed

        case (.awaitingDecision, .execute):
            guard context.confirmationValid else {
                throw LibraryIncidentTransitionError.guardFailed("confirmation missing")
            }
            return .executing
        case (.awaitingDecision, .abandon):
            return .abandoned

        case (.executing, .verify):
            guard context.newStoreExists else {
                throw LibraryIncidentTransitionError.guardFailed("new store missing")
            }
            return .verifying
        case (.executing, .executeFailed):
            return .awaitingDecision
        case (.executing, .critical):
            return .failed

        case (.verifying, .resolved):
            guard context.verificationPassed else {
                throw LibraryIncidentTransitionError.guardFailed("verification not passed")
            }
            return .resolved
        case (.verifying, .verifyFailed):
            return .failed

        case (.failed, .retry):
            guard context.preservedIntact else {
                throw LibraryIncidentTransitionError.guardFailed("preserved copy missing")
            }
            return .awaitingDecision
        case (.failed, .abandon):
            return .abandoned

        case (.detected, .interrupted),
             (.freezing, .interrupted),
             (.frozen, .interrupted),
             (.diagnosing, .interrupted),
             (.executing, .interrupted),
             (.verifying, .interrupted):
            return .failed

        default:
            throw LibraryIncidentTransitionError.invalidTransition(
                from: state, event: String(describing: event))
        }
    }
}
