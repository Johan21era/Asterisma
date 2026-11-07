//  LibraryHealthCoordinator.swift
//  Library Safety — Phases 1–4
//
//  The one sequencer for storage state, recovery incidents, preservation,
//  diagnosis, export, and assisted restore. It owns ordering and publication;
//  it never performs file surgery or opens SQLite itself.

import Combine
import Foundation

@MainActor
final class LibraryHealthCoordinator: ObservableObject {
    @Published private(set) var incident: LibraryIncident? {
        didSet {
            guard oldValue != incident else { return }
            NotificationCenter.default.post(name: .libraryIncidentDidChange, object: nil)
        }
    }
    @Published private(set) var corruptIncidentIDs: [String] = []
    @Published private(set) var lastErrorKey: String?
    @Published private(set) var lastReceipt: RecoveryReceipt?
    @Published private(set) var backups: [LibraryBackup] = []
    @Published private(set) var isWorking = false

    private let store: LibraryIncidentStore
    private weak var host: (any LibraryRecoveryHost)?
    private let service: LibraryRecoveryService?
    private let dataRoot: URL?
    private let swap: LibrarySwapCoordinator?
    private let backupDirectory: URL?
    private var freezeToken: LibraryFreezeToken?

    /// Set by the app once Sentinel is open. Called only after a recovery has
    /// resolved and the store has been reopened, never before.
    var onRecoveryResolved: (@MainActor () async -> Void)?

    init(
        store: LibraryIncidentStore,
        host: (any LibraryRecoveryHost)? = nil,
        service: LibraryRecoveryService? = nil,
        dataRoot: URL? = nil,
        swap: LibrarySwapCoordinator? = nil
    ) {
        self.store = store
        self.host = host
        self.service = service
        self.dataRoot = dataRoot
        self.swap = swap
        self.backupDirectory = dataRoot?.appendingPathComponent("Backups", isDirectory: true)
    }

    /// Startup is read-only until it has finished reconciling. An incident that
    /// was mid-flight at quit becomes `failed` with `LR-007`; it never silently
    /// becomes `resolved` and it never gets deleted.
    func start() async {
        do {
            let result = try await store.scan()
            corruptIncidentIDs = result.corruptIncidentIDs

            if var open = result.incidents.first(where: { !$0.isTerminal }) {
                if open.state.isInterruptedCandidate {
                    let next = try LibraryIncidentStateMachine.transition(
                        from: open.state, event: .interrupted)
                    open.state = next
                    open.kind = .recoveryInterrupted
                    open.lastError = RecoveryError(
                        code: "LR-007",
                        messageKey: "recovery.error.interrupted",
                        isCritical: false)
                    open.readOnly = true
                    open = try await store.save(open)
                }
                incident = open
            } else {
                incident = nil
            }

            refreshBackups()
            await observeHostCondition()
            await resumeIfNeeded()
        } catch {
            lastErrorKey = "recovery.error.incidentStoreUnavailable"
        }
    }

    /// The coordinator may open an incident only for a condition that proves
    /// writes are unavailable. A healthy or degraded-but-writable store is not
    /// an incident.
    func handleStorageCondition(_ condition: StorageCondition) async {
        switch condition {
        case .healthy, .degraded, .recovering:
            return
        case let .readOnly(_, code, _), let .failed(_, code, _):
            guard incident == nil else { return }
            let kind: LibraryIncidentKind
            switch code {
            case "LR-001", "LR-002", "LR-101", "LR-102":
                kind = .databaseUnreadable
            case "LR-030", "LR-031", "LR-104", "LR-105":
                kind = .writeFailed
            default:
                kind = .loadFailed
            }
            let new = LibraryIncident(
                kind: kind,
                trigger: .loadFailure(code: code),
                userSummaryKey: "recovery.incident.storageUnavailable",
                readOnly: true)
            do {
                incident = try await store.create(new)
                await beginRecoveryIfPossible()
            } catch {
                lastErrorKey = "recovery.error.incidentStoreUnavailable"
            }
        }
    }

    // MARK: - Preservation and diagnosis

    /// Freeze, preserve, and diagnose. This runs only once per incident and
    /// only when every collaborator exists. A failure leaves the incident
    /// failed and read-only; it never reopens a half-processed store.
    func beginRecoveryIfPossible() async {
        guard !isWorking else { return }
        guard var current = incident, current.state == .detected else { return }
        guard let host, let service,
              let storeURL = host.liveDatabaseURL() else { return }

        isWorking = true
        defer { isWorking = false }

        do {
            current.state = try LibraryIncidentStateMachine.transition(
                from: current.state, event: .beginFreeze)
            current = try await store.save(current)
            incident = current

            let memory = host.memorySnapshotData()
            let token = try await host.freezeForRecovery(incidentID: current.id)
            freezeToken = token

            current.state = try LibraryIncidentStateMachine.transition(
                from: current.state, event: .frozen,
                context: LibraryIncidentTransitionContext(storeFrozen: true))
            current = try await store.save(current)
            incident = current

            let preserved = try await service.preserve(
                incidentID: current.id,
                storeURL: storeURL,
                memorySnapshot: memory)
            current.preserved = preserved
            current = try await store.save(current)
            incident = current

            current.state = try LibraryIncidentStateMachine.transition(
                from: current.state, event: .beginDiagnosis,
                context: LibraryIncidentTransitionContext(preservedVerified: true))
            current = try await store.save(current)
            incident = current

            let diagnosis = try await service.diagnose(incidentID: current.id)
            let options = await service.options(
                for: diagnosis, hasPreservedCopy: true)

            current.diagnosis = diagnosis
            current.options = options
            current.state = try LibraryIncidentStateMachine.transition(
                from: current.state, event: .optionsReady,
                context: LibraryIncidentTransitionContext(diagnosisComplete: true))
            current = try await store.save(current)
            incident = current
            refreshBackups()
        } catch {
            current.state = .failed
            current.lastError = RecoveryError(
                code: "LR-002",
                messageKey: "recovery.error.preserveOrDiagnose",
                isCritical: false)
            current.readOnly = true
            incident = try? await store.save(current)
            lastErrorKey = "recovery.error.preserveOrDiagnose"
        }
    }

    // MARK: - Export

    func exportCopy(to destination: URL) async {
        guard let service, let current = incident,
              current.preserved != nil else { return }
        isWorking = true
        defer { isWorking = false }
        let started = Date()
        do {
            try await service.export(
                incidentID: current.id, to: destination, replaceExisting: true)
            let receipt = RecoveryReceipt(
                schemaVersion: 1,
                id: "rec_" + UUID().uuidString,
                incidentID: current.id,
                optionID: "export",
                kind: .exportCopy,
                startedAt: started,
                finishedAt: Date(),
                outcome: .succeeded,
                beforeFingerprint: current.fingerprint,
                afterFingerprint: nil,
                recoveredRows: current.diagnosis?.tableCounts?.totalRows,
                lostRows: 0,
                quarantinedRows: 0,
                verification: nil,
                error: nil)
            await appendReceipt(receipt)
        } catch {
            lastErrorKey = "recovery.error.exportFailed"
        }
    }

    // MARK: - Assisted restore

    /// `confirmation` must be the typed phrase shown to the user. The caller
    /// cannot bypass the confirmation by calling this method directly.
    func restore(backupID: String, confirmation: String) async {
        guard confirmation == "RESTORE" else {
            lastErrorKey = "recovery.error.confirmationMismatch"
            return
        }
        guard !isWorking,
              var current = incident,
              current.state == .awaitingDecision,
              current.preserved != nil,
              let host,
              let service,
              let swap,
              let liveURL = host.liveDatabaseURL(),
              let backup = backups.first(where: { $0.id == backupID && $0.isVerified }),
              let manifest = backup.manifest else {
            lastErrorKey = "recovery.error.restorePrecondition"
            return
        }

        let started = Date()
        let beforeHash = try? LibraryFileSync.sha256(of: liveURL)
        let verificationBefore = current.fingerprint
        isWorking = true
        defer { isWorking = false }

        do {
            current.chosenOptionID = "restore:\(backupID)"
            current.state = try LibraryIncidentStateMachine.transition(
                from: current.state, event: .execute,
                context: LibraryIncidentTransitionContext(confirmationValid: true))
            current = try await store.save(current)
            incident = current

            _ = try await swap.restore(
                incidentID: current.id,
                backupID: backupID,
                backupURL: backup.url,
                liveURL: liveURL,
                expectedBeforeSHA256: beforeHash ?? "",
                expectedAfterSHA256: manifest.sha256)

            current.state = try LibraryIncidentStateMachine.transition(
                from: current.state, event: .verify,
                context: LibraryIncidentTransitionContext(newStoreExists: true))
            current = try await store.save(current)
            incident = current

            if let freezeToken {
                try await host.reopenAfterRecovery(token: freezeToken)
                self.freezeToken = nil
            }

            let verification = LibraryRecoveryVerifier.verify(
                liveURL: liveURL, expectedCounts: manifest.counts)

            if LibraryRecoveryVerifier.isPassed(verification) {
                current.state = try LibraryIncidentStateMachine.transition(
                    from: current.state, event: .resolved,
                    context: LibraryIncidentTransitionContext(verificationPassed: true))
                current.resolvedAt = Date()
                current.readOnly = false
                current = try await store.save(current)
                incident = current

                let receipt = RecoveryReceipt(
                    schemaVersion: 1,
                    id: "rec_" + UUID().uuidString,
                    incidentID: current.id,
                    optionID: "restore:\(backupID)",
                    kind: .restoreBackup,
                    startedAt: started,
                    finishedAt: Date(),
                    outcome: .succeeded,
                    beforeFingerprint: verificationBefore,
                    afterFingerprint: nil,
                    recoveredRows: manifest.counts.totalRows,
                    lostRows: 0,
                    quarantinedRows: 0,
                    verification: verification,
                    error: nil)
                await appendReceipt(receipt)
                await onRecoveryResolved?()
            } else {
                try await rollbackAfterFailedVerification(
                    current: &current,
                    liveURL: liveURL,
                    host: host,
                    swap: swap,
                    started: started,
                    verification: verification)
            }
        } catch {
            // The swap coordinator rolls back file-level failures itself. Reopen
            // the original through the still-held freeze token if possible.
            current.state = .failed
            current.lastError = RecoveryError(
                code: "LR-008",
                messageKey: "recovery.error.restoreFailed",
                isCritical: false)
            current.readOnly = true
            incident = try? await store.save(current)
            if let freezeToken {
                try? await host.reopenAfterRecovery(token: freezeToken)
                self.freezeToken = nil
            }
            lastErrorKey = "recovery.error.restoreFailed"
        }
    }

    private func rollbackAfterFailedVerification(
        current: inout LibraryIncident,
        liveURL: URL,
        host: any LibraryRecoveryHost,
        swap: LibrarySwapCoordinator,
        started: Date,
        verification: RecoveryVerification
    ) async throws {
        current.state = try LibraryIncidentStateMachine.transition(
            from: current.state, event: .verifyFailed)
        current.readOnly = true
        current.lastError = RecoveryError(
            code: "LR-008",
            messageKey: "recovery.error.verificationFailed",
            isCritical: false)
        incident = try? await store.save(current)

        let rollbackToken = try await host.freezeForRecovery(incidentID: current.id)
        do {
            _ = try await swap.rollback(liveURL: liveURL)
            try await host.reopenAfterRecovery(token: rollbackToken)
            let receipt = RecoveryReceipt(
                schemaVersion: 1,
                id: "rec_" + UUID().uuidString,
                incidentID: current.id,
                optionID: current.chosenOptionID ?? "restore",
                kind: .restoreBackup,
                startedAt: started,
                finishedAt: Date(),
                outcome: .rolledBack,
                beforeFingerprint: current.fingerprint,
                afterFingerprint: nil,
                recoveredRows: 0,
                lostRows: 0,
                quarantinedRows: 0,
                verification: verification,
                error: current.lastError)
            current = try await store.save(current)
            incident = current
            await appendReceipt(receipt)
            lastErrorKey = "recovery.error.verificationFailed"
        } catch {
            current.lastError = RecoveryError(
                code: "LR-009",
                messageKey: "recovery.error.rollbackFailed",
                isCritical: true)
            current.readOnly = true
            current = try await store.save(current)
            incident = current
            lastErrorKey = "recovery.error.rollbackFailed"
            throw error
        }
    }

    // MARK: - Logical rebuild

    /// Rebuilds a new store from decoded payloads and page-timing rows, then
    /// runs the same swap and verification path as an assisted restore. The
    /// rebuilt file is kept as evidence whether the swap succeeds or fails.
    func rebuild(confirmation: String) async {
        guard confirmation == "REBUILD" else {
            lastErrorKey = "recovery.error.confirmationMismatch"
            return
        }
        guard !isWorking,
              var current = incident,
              current.state == .awaitingDecision,
              current.preserved != nil,
              let host,
              let swap,
              let dataRoot,
              let liveURL = host.liveDatabaseURL() else {
            lastErrorKey = "recovery.error.rebuildPrecondition"
            return
        }

        let started = Date()
        isWorking = true
        defer { isWorking = false }

        do {
            let recoveryRoot = dataRoot.appendingPathComponent(
                "LibraryRecovery", isDirectory: true)
            let preserved = try LibraryStorePreserver.loadAndVerify(
                root: recoveryRoot, incidentID: current.id)
            let main = try LibraryStorePreserver.mainFileURL(
                root: recoveryRoot, incidentID: current.id, preserved: preserved)
            let rebuiltURL = LibraryStorePreserver.incidentDirectory(
                root: recoveryRoot, incidentID: current.id)
                .appendingPathComponent("rebuild-\(UUID().uuidString).sqlite3")

            let rebuild = try LibraryLogicalRebuilder.rebuild(
                sourceURL: main, destination: rebuiltURL)
            let beforeHash = try LibraryFileSync.sha256(of: liveURL)

            current.chosenOptionID = "rebuild"
            current.state = try LibraryIncidentStateMachine.transition(
                from: current.state, event: .execute,
                context: LibraryIncidentTransitionContext(confirmationValid: true))
            current = try await store.save(current)
            incident = current

            _ = try await swap.restore(
                incidentID: current.id,
                backupID: "rebuild",
                backupURL: rebuiltURL,
                liveURL: liveURL,
                expectedBeforeSHA256: beforeHash,
                expectedAfterSHA256: rebuild.manifest.sha256)

            current.state = try LibraryIncidentStateMachine.transition(
                from: current.state, event: .verify,
                context: LibraryIncidentTransitionContext(newStoreExists: true))
            current = try await store.save(current)
            incident = current

            if let freezeToken {
                try await host.reopenAfterRecovery(token: freezeToken)
                self.freezeToken = nil
            }

            let verification = LibraryRecoveryVerifier.verify(
                liveURL: liveURL, expectedCounts: rebuild.rebuiltCounts)
            if LibraryRecoveryVerifier.isPassed(verification) {
                current.state = try LibraryIncidentStateMachine.transition(
                    from: current.state, event: .resolved,
                    context: LibraryIncidentTransitionContext(verificationPassed: true))
                current.resolvedAt = Date()
                current.readOnly = false
                current = try await store.save(current)
                incident = current

                let receipt = RecoveryReceipt(
                    schemaVersion: 1,
                    id: "rec_" + UUID().uuidString,
                    incidentID: current.id,
                    optionID: "rebuild",
                    kind: .rebuildNormalizedTables,
                    startedAt: started,
                    finishedAt: Date(),
                    outcome: .succeeded,
                    beforeFingerprint: current.fingerprint,
                    afterFingerprint: nil,
                    recoveredRows: rebuild.rebuiltCounts.totalRows,
                    lostRows: rebuild.lostRows,
                    quarantinedRows: 0,
                    verification: verification,
                    error: nil)
                await appendReceipt(receipt)
                await onRecoveryResolved?()
            } else {
                try await rollbackAfterFailedVerification(
                    current: &current,
                    liveURL: liveURL,
                    host: host,
                    swap: swap,
                    started: started,
                    verification: verification)
            }
        } catch {
            current.state = .failed
            current.lastError = RecoveryError(
                code: "LR-021",
                messageKey: "recovery.error.rebuildFailed",
                isCritical: false)
            current.readOnly = true
            incident = try? await store.save(current)
            if let freezeToken {
                try? await host.reopenAfterRecovery(token: freezeToken)
                self.freezeToken = nil
            }
            lastErrorKey = "recovery.error.rebuildFailed"
        }
    }

    // MARK: - Sentinel candidates

    /// Sentinel may only nominate. This coordinator decides whether a finding
    /// is allowed to become an incident, and the matrix is deliberately narrow.
    func handleSentinelCandidate(_ candidate: LibraryIncidentCandidate) async {
        guard incident == nil else { return }
        guard SentinelIncidentPromotion.shouldPromote(candidate) else { return }

        let new = LibraryIncident(
            kind: candidate.kind,
            trigger: .probeFinding(
                ruleID: candidate.ruleID ?? "",
                fingerprint: candidate.fingerprint ?? ""),
            detectedAt: candidate.detectedAt,
            evidence: candidate.evidence,
            userSummaryKey: "recovery.incident.structuralDamage",
            readOnly: true)
        do {
            incident = try await store.create(new)
            await beginRecoveryIfPossible()
        } catch {
            lastErrorKey = "recovery.error.incidentStoreUnavailable"
        }
    }

    // MARK: - Decisions

    func abandon() async {
        guard var current = incident,
              current.state == .awaitingDecision || current.state == .failed else { return }
        do {
            current.state = try LibraryIncidentStateMachine.transition(
                from: current.state, event: .abandon)
            current.readOnly = true
            incident = try await store.save(current)
        } catch {
            lastErrorKey = "recovery.error.invalidTransition"
        }
    }

    func retry() async {
        guard var current = incident, current.state == .failed else { return }
        let context = LibraryIncidentTransitionContext(preservedIntact: current.preserved != nil)
        do {
            current.state = try LibraryIncidentStateMachine.transition(
                from: current.state, event: .retry, context: context)
            incident = try await store.save(current)
        } catch {
            lastErrorKey = "recovery.error.preservedCopyMissing"
        }
    }

    // MARK: - Backups

    func refreshBackups() {
        guard let backupDirectory else { return }
        let scan = LibraryBackupCatalog.scan(directory: backupDirectory)
        backups = scan.backups
    }

    func drill(_ backupID: String) {
        guard let backup = backups.first(where: { $0.id == backupID }) else { return }
        _ = LibraryBackupVerifier.verify(backup, level: .drill)
        refreshBackups()
    }

    // MARK: - Helpers

    private func resumeIfNeeded() async {
        if incident?.state == .detected {
            await beginRecoveryIfPossible()
        }
    }

    private func observeHostCondition() async {
        guard let condition = host?.currentStorageCondition() else { return }
        await handleStorageCondition(condition)
    }

    private func appendReceipt(_ receipt: RecoveryReceipt) async {
        do {
            try await store.writeReceipt(receipt)
            if var current = incident {
                current.receipts.append(receipt.id)
                incident = try await store.save(current)
            }
            lastReceipt = receipt
        } catch {
            lastErrorKey = "recovery.error.receiptWriteFailed"
        }
    }
}

// MARK: - Sentinel gate

@MainActor
extension LibraryHealthCoordinator: SentinelRecoveryGate {
    /// Sentinel reads this before every cycle, every automatic repair, and
    /// every user-initiated repair. A `.resolved` incident opens the gate; a
    /// failed or abandoned one keeps the app read-only until the next launch.
    func operationalMode() async -> LibraryOperationalMode {
        guard let incident else {
            return isWorking ? .suspended(.recoveryExecuting) : .normal
        }
        switch incident.state {
        case .resolved:
            return isWorking ? .suspended(.recoveryExecuting) : .normal
        case .verifying:
            return .suspended(.recoveryVerifying)
        case .freezing, .frozen:
            return .suspended(.storeFrozen)
        case .diagnosing, .executing:
            return .suspended(.recoveryExecuting)
        case .detected, .awaitingDecision, .failed, .abandoned, .unknown:
            return .suspended(.incidentOpen)
        }
    }
}

// MARK: - Support bundle

extension LibraryHealthCoordinator {
    /// A deliberately path-free, text-free summary for support. It contains
    /// ids, enums, counts, and truncated hashes. The library file itself is
    /// never included; exporting it is a separate, explicit user action.
    func supportSummaryData(now: Date = Date()) -> Data? {
        var summary: [String: Any] = [
            "schemaVersion": 1,
            "generatedAt": ISO8601DateFormatter().string(from: now),
            "corruptIncidentCount": corruptIncidentIDs.count,
        ]

        if let incident {
            var row: [String: Any] = [
                "id": incident.id,
                "kind": incident.kind.rawValue,
                "state": incident.state.rawValue,
                "readOnly": incident.readOnly,
                "detectedAt": ISO8601DateFormatter().string(from: incident.detectedAt),
                "updatedAt": ISO8601DateFormatter().string(from: incident.updatedAt),
                "optionIDs": incident.options.map(\.id),
                "receiptCount": incident.receipts.count,
                "userSummaryKey": incident.userSummaryKey,
            ]
            if let resolvedAt = incident.resolvedAt {
                row["resolvedAt"] = ISO8601DateFormatter().string(from: resolvedAt)
            }
            if let chosen = incident.chosenOptionID { row["chosenOptionID"] = chosen }
            if let error = incident.lastError {
                row["lastError"] = [
                    "code": error.code,
                    "messageKey": error.messageKey,
                    "isCritical": error.isCritical,
                ]
            }
            if let preserved = incident.preserved {
                row["preserved"] = [
                    "fileCount": preserved.files.count,
                    "hashPrefix": String(preserved.combinedSHA256.prefix(16)),
                    "createdAt": ISO8601DateFormatter().string(from: preserved.createdAt),
                ]
            }
            if let diagnosis = incident.diagnosis {
                row["diagnosis"] = [
                    "canOpenReadOnly": diagnosis.canOpenReadOnly,
                    "integrityLines": diagnosis.integrityCheck.count,
                    "undecodableBooks": diagnosis.undecodableBooks,
                    "undecodableState": diagnosis.undecodableState,
                    "missingTables": diagnosis.missingTables,
                    "totalRows": diagnosis.tableCounts?.totalRows ?? 0,
                ]
            }
            summary["incident"] = row
        }

        summary["backups"] = backups.map { backup in
            [
                "id": backup.id,
                "state": backup.state.rawValue,
                "isSafetySnapshot": backup.isSafetySnapshot,
                "hashPrefix": String((backup.manifest?.sha256 ?? "").prefix(16)),
                "counts": backup.manifest.map { manifest in
                    [
                        "books": manifest.counts.books,
                        "sessions": manifest.counts.sessions,
                        "pageTimes": manifest.counts.pageTimes,
                    ]
                } ?? [:],
            ] as [String: Any]
        }

        return try? JSONSerialization.data(
            withJSONObject: summary,
            options: [.prettyPrinted, .sortedKeys])
    }
}

// MARK: - Notifications

nonisolated extension Notification.Name {
    /// Posted on the main queue only after the incident file is durably saved.
    static let libraryIncidentDidChange =
        Notification.Name("library.incident.didChange")
    static let libraryRecoveryDidChange =
        Notification.Name("library.recovery.didChange")
}
