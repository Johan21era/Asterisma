//  SentinelRuntime.swift
//  AsterismaV2.5
//
//  SG2 — one actor owns time, scheduling, persistence, and mutation.
//
//  What changed from v1:
//    • probes run off the main thread, concurrently, each with its own timeout;
//    • a cycle lock makes overlap impossible;
//    • a snapshot generation check aborts repairs if the library moved;
//    • coverage is a first-class result, so "clean" can be honest;
//    • repairs go through the SG3 executor and are verified by re-running the
//      detecting probe, never assumed.
//
//  The actor never touches SwiftUI. It publishes an immutable state snapshot
//  and posts one notification; the view model pulls.

import Foundation

// MARK: - Trigger and scope

nonisolated enum SentinelCycleTrigger: String, Codable, Sendable {
    case launch
    case scheduled
    case deep
    case manual
    case wake
    case repair
    /// A complete verification run after the library leaves recovery. It is
    /// never the first cycle of a normal launch.
    case recovery
}

nonisolated enum SentinelCycleScope: String, Codable, Sendable {
    case fast
    case normal
    case deep

    var maximumTier: SentinelProbeTier {
        switch self {
        case .fast: return .t1
        case .normal: return .t2
        case .deep: return .t4
        }
    }
}

// MARK: - Snapshot provider

nonisolated struct SentinelSnapshotProvider: Sendable {
    var capture: @Sendable (SentinelJournalFacts) async -> SentinelSnapshot?

    static func live(environment: SentinelEnvironment) -> SentinelSnapshotProvider {
        SentinelSnapshotProvider { facts in
            await MainActor.run {
                guard let store = SentinelDataBridge.shared.store else { return nil }
                return SentinelSnapshot.capture(
                    store: store,
                    environment: environment,
                    journalFacts: facts,
                    defaults: .standard)
            }
        }
    }

    static func fixture(_ snapshot: SentinelSnapshot) -> SentinelSnapshotProvider {
        SentinelSnapshotProvider { _ in snapshot }
    }
}

// MARK: - Reports

nonisolated struct SentinelCycleReport: Sendable {
    var cycleID: String
    var trigger: SentinelCycleTrigger
    var scope: SentinelCycleScope
    var startedAt: Date
    var duration: TimeInterval
    var probeResults: [SentinelProbeRunResult]
    var coverage: SentinelCoverage
    var opened: [String]
    var resolved: [String]
    var regressed: [String]
    var repairs: [SentinelRepairOutcome]
    var health: SentinelHealthModel
    var generation: UInt64
    var error: String?

    static let idle = SentinelCycleReport(
        cycleID: "",
        trigger: .manual,
        scope: .fast,
        startedAt: Date(timeIntervalSinceReferenceDate: 0),
        duration: 0,
        probeResults: [],
        coverage: .empty,
        opened: [],
        resolved: [],
        regressed: [],
        repairs: [],
        health: SentinelHealthModel(
            band: .unknown, visibleIssueCount: 0, criticalCount: 0,
            errorCount: 0, warningCount: 0, infoCount: 0,
            coverage: .empty, computedAt: Date(timeIntervalSinceReferenceDate: 0),
            headline: "Sentinel has not checked anything yet."),
        generation: 0,
        error: nil)
}

nonisolated struct SentinelPublishedState: Sendable {
    var issues: [SentinelIssue]
    var health: SentinelHealthModel
    var coverage: SentinelCoverage
    var configuration: SentinelConfiguration
    var lastCycle: SentinelCycleReport
    var history: [SentinelJournalEntry]
    var repairs: [SentinelRepairRecord]
    var counters: [String: Int]
    var storeOutcome: String
    var isRunning: Bool
    var isOpen: Bool
    var error: String?
    var probes: [SentinelProbeRunResult]
    var journalBytes: Int64
    var operationalMode: LibraryOperationalMode

    static let empty = SentinelPublishedState(
        issues: [],
        health: SentinelHealthModel(
            band: .unknown, visibleIssueCount: 0, criticalCount: 0,
            errorCount: 0, warningCount: 0, infoCount: 0,
            coverage: .empty, computedAt: Date(timeIntervalSinceReferenceDate: 0),
            headline: "Sentinel has not checked anything yet."),
        coverage: .empty,
        configuration: .default,
        lastCycle: .idle,
        history: [],
        repairs: [],
        counters: [:],
        storeOutcome: "not opened",
        isRunning: false,
        isOpen: false,
        error: nil,
        probes: [],
        journalBytes: 0,
        operationalMode: .normal)
}

// MARK: - Runtime

actor SentinelRuntime {
    static let shared = SentinelRuntime()

    /// Posted after every state-changing operation. The view model observes it
    /// and pulls `publishedState()`; the actor never calls into SwiftUI.
    nonisolated static let didUpdateNotification = Notification.Name("sentinel.runtime.didUpdate")

    private(set) var environment: SentinelEnvironment
    private(set) var configuration: SentinelConfiguration
    private(set) var issues: [SentinelIssue] = []
    private(set) var isOpen = false
    private(set) var lastError: String?
    private(set) var lastReport: SentinelCycleReport = .idle

    private var probes: [any SentinelProbeV2]
    private var descriptors: [SentinelProbeDescriptor]
    private var store: SentinelIssueStore?
    private var journal: SentinelJournalV2?
    private var repairStore: SentinelRepairStore?
    private var paths: SentinelPaths?
    private var snapshotProvider: SentinelSnapshotProvider?
    private var bridge: (any SentinelRepairBridge)?
    private var recoveryGate: (any SentinelRecoveryGate)?
    private var candidateSink: (@Sendable (LibraryIncidentCandidate) async -> Void)?
    private var lastObservedMode: LibraryOperationalMode = .normal
    private var schedulerTask: Task<Void, Never>?
    private var isCycleRunning = false

    init(
        environment: SentinelEnvironment = .live(
            dataRoot: nil,
            backupRoot: nil,
            isDebug: {
                #if DEBUG
                return true
                #else
                return false
                #endif
            }()),
        configuration: SentinelConfiguration = SentinelConfiguration.load(
            from: .standard,
            isDebug: {
                #if DEBUG
                return true
                #else
                return false
                #endif
            }()),
        probes: [any SentinelProbeV2]? = nil
    ) {
        self.environment = environment
        self.configuration = configuration
        let resolved = probes ?? SentinelProbeCatalog.all()
        self.probes = resolved
        self.descriptors = resolved.map(\.descriptor)
    }

    // MARK: - Opening

    /// Creates the write scope and loads durable memory. Idempotent for the
    /// same data root.
    func open(dataRoot: URL, backupRoot: URL? = nil) {
        if isOpen,
           let existing = paths,
           existing.root.deletingLastPathComponent().standardizedFileURL == dataRoot.standardizedFileURL,
           FileManager.default.fileExists(atPath: existing.root.path) {
            return
        }

        environment.dataRoot = dataRoot
        environment.backupRoot = backupRoot ?? dataRoot.appendingPathComponent("Backups", isDirectory: true)
        let scope = SentinelPaths.standard(dataRoot: dataRoot)
        scope.ensureDirectories()
        paths = scope

        let clock = environment.clock
        let journal = SentinelJournalV2(
            directory: scope.journalDirectory,
            clock: clock,
            maxSegments: configuration.journalMaxSegments)
        journal.migrateFromV1(at: dataRoot.appendingPathComponent("sentinel-journal.jsonl"))
        self.journal = journal

        let store = SentinelIssueStore(paths: scope, clock: clock, journal: journal)
        issues = store.load()
        self.store = store
        repairStore = SentinelRepairStore(directory: scope.root, clock: clock)
        isOpen = true
        lastError = store.lastSaveError
        postUpdate()
    }

    func setSnapshotProvider(_ provider: SentinelSnapshotProvider?) {
        snapshotProvider = provider
    }

    func setBridge(_ bridge: (any SentinelRepairBridge)?) {
        self.bridge = bridge
    }

    /// Recovery owns the gate. Sentinel may only read it.
    func setRecoveryGate(_ gate: (any SentinelRecoveryGate)?) {
        recoveryGate = gate
        postUpdate()
    }

    /// Sentinel only nominates structural findings. The coordinator decides
    /// whether a nomination becomes an incident.
    func setCandidateSink(
        _ sink: (@Sendable (LibraryIncidentCandidate) async -> Void)?
    ) {
        candidateSink = sink
    }

    func currentOperationalMode() async -> LibraryOperationalMode {
        await operationalMode()
    }

    private func operationalMode() async -> LibraryOperationalMode {
        guard let recoveryGate else { return .normal }
        return await recoveryGate.operationalMode()
    }

    func updateConfiguration(_ config: SentinelConfiguration) {
        configuration = config
        config.save(to: .standard)
        postUpdate()
    }

    // MARK: - Scheduling

    /// Runs a launch cycle immediately, then a cadence loop. The loop is a
    /// single task, so there is no timer pile-up across sleep/wake.
    func start() {
        guard configuration.autonomy.isMonitoring else { return }
        guard schedulerTask == nil else { return }
        schedulerTask = Task { [weak self] in
            guard let self else { return }
            _ = await self.runCycle(trigger: .launch, scope: .fast)
            while !Task.isCancelled {
                let minutes = await self.currentCadenceMinutes()
                do {
                    try await Task.sleep(for: .seconds(Double(max(1, minutes)) * 60))
                } catch {
                    break
                }
                if Task.isCancelled { break }
                _ = await self.runCycle(trigger: .scheduled, scope: .normal)
                if await self.shouldRunDeepCycle() {
                    _ = await self.runCycle(trigger: .deep, scope: .deep)
                }
            }
        }
    }

    func stop() {
        schedulerTask?.cancel()
        schedulerTask = nil
    }

    func runOnce(trigger: SentinelCycleTrigger = .manual, scope: SentinelCycleScope = .normal) async -> SentinelCycleReport {
        await runCycle(trigger: trigger, scope: scope)
    }

    private func currentCadenceMinutes() -> Int {
        configuration.cadenceMinutes
    }

    private func shouldRunDeepCycle() -> Bool {
        guard let lastDeep = lastReport.trigger == .deep ? lastReport.startedAt : nil else { return true }
        return environment.now.timeIntervalSince(lastDeep) >= Double(configuration.deepCadenceHours) * 3600
    }

    // MARK: - Cycle

    func runCycle(trigger: SentinelCycleTrigger, scope: SentinelCycleScope = .normal) async -> SentinelCycleReport {
        guard configuration.autonomy.isMonitoring else {
            return SentinelCycleReport.idle
        }
        guard !isCycleRunning else { return lastReport }

        let startedAt = environment.now
        let startedUptime = DispatchTime.now().uptimeNanoseconds
        isCycleRunning = true
        defer { isCycleRunning = false }

        // P6-1: recovery owns this window. A suspended cycle runs no probe and
        // writes no cycle entry; it only records the boundary once.
        let mode = await operationalMode()
        if case let .suspended(reason) = mode {
            noteModeTransition(to: mode, reason: reason)
            lastReport = suspendedReport(
                trigger: trigger, scope: scope, startedAt: startedAt,
                startedUptime: startedUptime)
            postUpdate()
            return lastReport
        }
        noteModeTransition(to: mode, reason: nil)

        guard let provider = snapshotProvider else {
            lastError = "No snapshot source is attached."
            return failedReport(trigger: trigger, scope: scope, startedAt: startedAt,
                                startedUptime: startedUptime, error: lastError)
        }

        let factsBefore = journalFacts()
        guard let snapshot = await provider.capture(factsBefore) else {
            lastError = "Sentinel could not read the library."
            return failedReport(trigger: trigger, scope: scope, startedAt: startedAt,
                                startedUptime: startedUptime, error: lastError)
        }

        let selection = probesForCycle(scope: scope)
        var results: [SentinelProbeRunResult] = []
        let probeList = selection
        var environment = self.environment
        environment.orphanSessionAge = configuration.orphanSessionAge

        await withTaskGroup(of: SentinelProbeRunResult.self) { group in
            for probe in probeList {
                group.addTask {
                    await Self.execute(probe: probe, snapshot: snapshot, environment: environment)
                }
            }
            for await result in group {
                results.append(result)
            }
        }
        results.sort { $0.probeID < $1.probeID }

        let completed = Set(results.filter(\.ran).map(\.probeID))
        let failed = Set(results.filter { $0.status == .failed || $0.status == .timedOut }.map(\.probeID))
        let findings = results.filter(\.ran).flatMap(\.findings)

        let diagnosis = SentinelDiagnoser.diagnose(
            existing: issues,
            findings: findings,
            descriptors: descriptors,
            completedProbeIDs: completed,
            failedProbeIDs: failed,
            cycleID: UUID().uuidString,
            now: environment.now,
            maximumIssues: configuration.maximumIssuesPerCycle)

        var updatedIssues = diagnosis.issues
        let coverage = coverage(for: results)

        // Automatic repairs: only R1, only when the user chose auto-safe, and
        // only when a bridge exists. Any aborted generation check blocks them.
        var outcomes: [SentinelRepairOutcome] = []
        if let bridge, !updatedIssues.isEmpty,
           await operationalMode() == .normal {
            let candidates = automaticCandidates(in: updatedIssues)
            if !candidates.isEmpty {
                let fresh = await provider.capture(journalFacts())
                if let fresh, fresh.generation != snapshot.generation {
                    lastError = "The library changed during the check; repairs were postponed."
                } else {
                    for issue in candidates.prefix(5) {
                        guard let metadata = ruleMetadata(for: issue),
                              let plan = SentinelRepairCatalog.plan(
                                for: issue, rule: metadata, snapshot: snapshot,
                                configuration: configuration, now: environment.now)
                        else { continue }

                        let outcome = await SentinelRepairExecutor.execute(
                            plan: plan,
                            autonomy: configuration.autonomy,
                            userInitiated: false,
                            bridge: bridge,
                            at: environment.now,
                            verify: { [weak self] rules, fingerprints in
                                guard let self else { return false }
                                return await self.verify(rules: rules, fingerprints: fingerprints)
                            })
                        outcomes.append(outcome)
                        updatedIssues = apply(outcome: outcome, to: updatedIssues)
                        record(outcome: outcome, plan: plan, userInitiated: false)
                    }
                }
            }
        }

        issues = updatedIssues
        await emitCandidates(from: updatedIssues)
        let health = SentinelHealthModel.compute(
            issues: updatedIssues,
            coverage: coverage,
            now: environment.now)

        persist(
            diagnosis: diagnosis,
            coverage: coverage,
            results: results,
            outcomes: outcomes,
            health: health,
            trigger: trigger)

        let duration = Double(DispatchTime.now().uptimeNanoseconds - startedUptime) / 1_000_000_000
        lastError = nil
        let report = SentinelCycleReport(
            cycleID: UUID().uuidString,
            trigger: trigger,
            scope: scope,
            startedAt: startedAt,
            duration: duration,
            probeResults: results,
            coverage: coverage,
            opened: diagnosis.opened,
            resolved: diagnosis.resolved,
            regressed: diagnosis.regressed,
            repairs: outcomes,
            health: health,
            generation: snapshot.generation,
            error: nil)
        lastReport = report
        postUpdate()
        return report
    }

    /// Emits at most one candidate per promotable rule per cycle. The matrix
    /// still filters severity and status, so this is safe to call broadly.
    private func emitCandidates(from issues: [SentinelIssue]) async {
        guard let candidateSink else { return }
        var seen = Set<String>()
        for issue in issues {
            guard let candidate = SentinelIncidentPromotion.candidate(
                from: issue, now: environment.now) else { continue }
            let key = candidate.ruleID ?? candidate.kind.rawValue
            guard seen.insert(key).inserted else { continue }
            await candidateSink(candidate)
        }
    }

    static let suspendedMessage =
        "Sentinel is paused while the library is in recovery."

    /// A suspended cycle is not a failure of the library and not a probe
    /// result. It keeps the previous issues untouched and says why.
    private func suspendedReport(
        trigger: SentinelCycleTrigger,
        scope: SentinelCycleScope,
        startedAt: Date,
        startedUptime: UInt64
    ) -> SentinelCycleReport {
        let duration = Double(DispatchTime.now().uptimeNanoseconds - startedUptime) / 1_000_000_000
        return SentinelCycleReport(
            cycleID: UUID().uuidString,
            trigger: trigger,
            scope: scope,
            startedAt: startedAt,
            duration: duration,
            probeResults: [],
            coverage: .empty,
            opened: [],
            resolved: [],
            regressed: [],
            repairs: [],
            health: SentinelHealthModel.compute(
                issues: issues, coverage: .empty, now: environment.now),
            generation: lastReport.generation,
            error: Self.suspendedMessage)
    }

    /// Records the boundary exactly once per transition. A cycle that keeps
    /// being suspended does not append a line per attempt.
    private func noteModeTransition(
        to mode: LibraryOperationalMode,
        reason: LibrarySuspensionReason?
    ) {
        guard mode != lastObservedMode else { return }
        lastObservedMode = mode
        switch mode {
        case let .suspended(suspendedReason):
            store?.record(SentinelJournalEntry(
                sequence: nextSequence(),
                event: .sentinelSuspended,
                at: environment.now,
                status: suspendedReason.rawValue,
                counts: ["suspended": 1],
                note: suspendedReason.messageKey))
        case .normal:
            store?.record(SentinelJournalEntry(
                sequence: nextSequence(),
                event: .sentinelResumed,
                at: environment.now,
                counts: ["suspended": 0]))
        }
    }

    /// P6-3: after recovery resolves, run the full deep set, not a fast pass.
    /// Refuses to run while the gate is still closed.
    @discardableResult
    func runRecoveryVerification() async -> SentinelCycleReport {
        guard await operationalMode() == .normal else {
            return suspendedReport(
                trigger: .recovery, scope: .deep,
                startedAt: environment.now,
                startedUptime: DispatchTime.now().uptimeNanoseconds)
        }
        let report = await runCycle(trigger: .recovery, scope: .deep)
        store?.record(SentinelJournalEntry(
            sequence: nextSequence(),
            event: .recoveryVerified,
            at: environment.now,
            cycleID: report.cycleID,
            status: report.error == nil ? "completed" : "failed",
            counts: [
                "ran": report.coverage.ran,
                "requiredMissing": report.coverage.requiredTotal - report.coverage.requiredRan,
                "findings": report.probeResults.reduce(0) { $0 + $1.findings.count },
            ]))
        postUpdate()
        return report
    }

    private func failedReport(
        trigger: SentinelCycleTrigger,
        scope: SentinelCycleScope,
        startedAt: Date,
        startedUptime: UInt64,
        error: String?
    ) -> SentinelCycleReport {
        let duration = Double(DispatchTime.now().uptimeNanoseconds - startedUptime) / 1_000_000_000
        let report = SentinelCycleReport(
            cycleID: UUID().uuidString,
            trigger: trigger,
            scope: scope,
            startedAt: startedAt,
            duration: duration,
            probeResults: [],
            coverage: .empty,
            opened: [],
            resolved: [],
            regressed: [],
            repairs: [],
            health: SentinelHealthModel.compute(issues: issues, coverage: .empty, now: environment.now),
            generation: 0,
            error: error)
        lastReport = report
        postUpdate()
        return report
    }

    private func probesForCycle(scope: SentinelCycleScope) -> [any SentinelProbeV2] {
        probes.filter { probe in
            guard probe.descriptor.tier <= scope.maximumTier else { return false }
            return configuration.isEnabled(for: probe.descriptor.domain)
        }
    }

    private func coverage(for results: [SentinelProbeRunResult]) -> SentinelCoverage {
        let selected = results.count
        let ran = results.filter(\.ran).count
        let skipped = results.filter { $0.status == .skipped }.count
        let failed = results.filter { $0.status == .failed || $0.status == .timedOut }.count
        let required = results.filter(\.isRequired)
        let requiredRan = required.filter(\.ran).count
        let missing = required.filter { !$0.ran }.map(\.probeID).sorted()
        var byDomain: [String: Int] = [:]
        for result in results where result.status == .skipped {
            byDomain[result.domain.rawValue, default: 0] += 1
        }
        return SentinelCoverage(
            totalProbes: selected,
            ran: ran,
            skipped: skipped,
            failed: failed,
            requiredTotal: required.count,
            requiredRan: requiredRan,
            missingRequired: missing,
            skippedByDomain: byDomain)
    }

    private func ruleMetadata(for issue: SentinelIssue) -> SentinelRuleMetadata? {
        descriptors.first { $0.ruleID == issue.ruleID }?.metadata
    }

    private func automaticCandidates(in issues: [SentinelIssue]) -> [SentinelIssue] {
        guard configuration.autonomy == .autoSafe else { return [] }
        return issues.filter { issue in
            guard issue.isVisible(at: environment.now) else { return false }
            guard issue.attemptCount < 3 else { return false }
            guard let metadata = ruleMetadata(for: issue) else { return false }
            return metadata.riskClass == .r1 && metadata.repairID != nil
        }
    }

    // MARK: - Probe execution

    /// One probe, one timeout, one isolated failure.
    nonisolated static func execute(
        probe: any SentinelProbeV2,
        snapshot: SentinelSnapshot,
        environment: SentinelEnvironment
    ) async -> SentinelProbeRunResult {
        let descriptor = probe.descriptor
        let started = DispatchTime.now().uptimeNanoseconds

        enum Outcome: Sendable {
            case findings([RawFinding])
            case failure(String)
            case skipped(SentinelProbeSkipReason, String?)
            case timeout
        }

        let outcome = await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                do {
                    let findings = try await probe.run(snapshot: snapshot, environment: environment)
                    return .findings(findings)
                } catch let unavailable as SentinelProbeUnavailable {
                    return .skipped(unavailable.reason, unavailable.detail)
                } catch {
                    return .failure(String(describing: error))
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(max(0.05, descriptor.timeout)))
                return .timeout
            }
            let first = await group.next() ?? .timeout
            group.cancelAll()
            return first
        }

        let duration = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000

        switch outcome {
        case .findings(let findings):
            return SentinelProbeRunResult(
                probeID: descriptor.id,
                ruleID: descriptor.ruleID,
                domain: descriptor.domain,
                tier: descriptor.tier,
                isRequired: descriptor.isRequired,
                status: .completed,
                findings: findings,
                duration: duration,
                skipReason: nil,
                errorDescription: nil)
        case .failure(let message):
            return SentinelProbeRunResult(
                probeID: descriptor.id,
                ruleID: descriptor.ruleID,
                domain: descriptor.domain,
                tier: descriptor.tier,
                isRequired: descriptor.isRequired,
                status: .failed,
                findings: [],
                duration: duration,
                skipReason: nil,
                errorDescription: message)
        case .skipped(let reason, let detail):
            return SentinelProbeRunResult(
                probeID: descriptor.id,
                ruleID: descriptor.ruleID,
                domain: descriptor.domain,
                tier: descriptor.tier,
                isRequired: descriptor.isRequired,
                status: .skipped,
                findings: [],
                duration: duration,
                skipReason: reason,
                errorDescription: detail)
        case .timeout:
            return SentinelProbeRunResult(
                probeID: descriptor.id,
                ruleID: descriptor.ruleID,
                domain: descriptor.domain,
                tier: descriptor.tier,
                isRequired: descriptor.isRequired,
                status: .timedOut,
                findings: [],
                duration: duration,
                skipReason: nil,
                errorDescription: "Timed out after \(descriptor.timeout)s")
        }
    }

    // MARK: - Verification

    /// Re-runs the probes that own this rule against a fresh snapshot. A probe
    /// that cannot run means "not verified", never "fixed".
    func verify(rules: [SentinelRuleID], fingerprints: [String]) async -> Bool {
        // A repair cannot be called verified while recovery owns the store.
        guard await operationalMode() == .normal else { return false }
        guard let provider = snapshotProvider else { return false }
        let ruleSet = Set(rules)
        let verifyProbes = probes.filter { ruleSet.contains($0.descriptor.ruleID) }
        guard !verifyProbes.isEmpty else { return false }
        guard let fresh = await provider.capture(journalFacts()) else { return false }

        var results: [SentinelProbeRunResult] = []
        let environment = self.environment
        await withTaskGroup(of: SentinelProbeRunResult.self) { group in
            for probe in verifyProbes {
                group.addTask { await Self.execute(probe: probe, snapshot: fresh, environment: environment) }
            }
            for await result in group { results.append(result) }
        }

        guard results.allSatisfy(\.ran) else { return false }
        let expected = Set(fingerprints)
        let remaining = results.flatMap(\.findings).map(SentinelFingerprint.make(for:))
        return Set(remaining).isDisjoint(with: expected)
    }

    // MARK: - Repairs

    /// User-initiated repair from the Health Center. Explicit, previewed, and
    /// still verified.
    func repair(fingerprint: String) async -> SentinelRepairOutcome {
        guard await operationalMode() == .normal else {
            return .blocked("suspended", Self.suspendedMessage)
        }
        guard let issue = issues.first(where: { $0.fingerprint == fingerprint }) else {
            return .blocked("unknown", "That issue no longer exists.")
        }
        guard let bridge else {
            return .blocked("unavailable", "No repair path is attached.")
        }
        guard let metadata = ruleMetadata(for: issue) else {
            return .blocked("unavailable", "That rule has no repair.")
        }
        guard let facts = snapshotProvider else {
            return .blocked("unavailable", "No snapshot source is attached.")
        }
        guard let snapshot = await facts.capture(journalFacts()) else {
            return .blocked("unavailable", "The library could not be read.")
        }
        guard let plan = SentinelRepairCatalog.plan(
            for: issue, rule: metadata, snapshot: snapshot,
            configuration: configuration, now: environment.now) else {
            return .blocked(metadata.repairID ?? "unavailable",
                            "There is nothing safe to change right now.")
        }

        let outcome = await SentinelRepairExecutor.execute(
            plan: plan,
            autonomy: configuration.autonomy,
            userInitiated: true,
            bridge: bridge,
            at: environment.now,
            verify: { [weak self] rules, fingerprints in
                guard let self else { return false }
                return await self.verify(rules: rules, fingerprints: fingerprints)
            })

        issues = apply(outcome: outcome, to: issues)
        record(outcome: outcome, plan: plan, userInitiated: true)
        saveIssues()
        postUpdate()
        return outcome
    }

    func previewRepair(fingerprint: String) async -> SentinelRepairPlan? {
        guard await operationalMode() == .normal else { return nil }
        guard let issue = issues.first(where: { $0.fingerprint == fingerprint }),
              let metadata = ruleMetadata(for: issue),
              let provider = snapshotProvider,
              let snapshot = await provider.capture(journalFacts()) else { return nil }
        return SentinelRepairCatalog.plan(
            for: issue, rule: metadata, snapshot: snapshot,
            configuration: configuration, now: environment.now)
    }

    func undoRepair(recordID: String) async -> SentinelRepairOutcome {
        guard await operationalMode() == .normal else {
            return .blocked("suspended", Self.suspendedMessage)
        }
        guard let repairStore,
              let record = repairStore.records.first(where: { $0.id == recordID }) else {
            return .blocked("undo", "That repair record no longer exists.")
        }
        guard record.isUndoable,
              let planName = record.planFileName,
              let plan = repairStore.plan(named: planName) else {
            return .blocked(record.repairID, "This repair has no undo handle.")
        }
        guard let bridge else {
            return .blocked(record.repairID, "No repair path is attached.")
        }
        guard configuration.autonomy.allowsUserInitiated(plan.riskClass) else {
            return .blocked(record.repairID, "This autonomy level does not allow changes.")
        }
        if await bridge.hasRecentReadingActivity(within: 10 * 60) {
            return .blocked(record.repairID, "You are reading right now; undo will wait.")
        }
        guard await bridge.safetySnapshot() else {
            return .blocked(record.repairID, "A safety snapshot could not be created.")
        }

        for action in plan.actions.reversed() {
            switch action {
            case .replaceBook(let bookID, _, let replacement):
                guard let current = await bridge.currentBook(id: bookID) else { continue }
                guard current == replacement else {
                    return .blocked(record.repairID, "The book changed since this repair; undo would overwrite newer work.")
                }
                _ = await bridge.replaceBook(previous: replacement, updated: planBookPrevious(action))
            case .replaceLibraryState(_, let replacement):
                guard let current = await bridge.currentLibraryState(),
                      SentinelRepairEquality.equal(current, replacement) else {
                    return .blocked(record.repairID, "Library settings changed since this repair.")
                }
                if let previous = planStatePrevious(action) {
                    _ = await bridge.replaceLibraryState(previous: replacement, updated: previous)
                }
            case .quarantineFile(let source, let name):
                _ = await bridge.restoreQuarantinedFile(named: name, to: source)
            case .writeCover(let bookID, _):
                _ = await bridge.removeCover(bookID: bookID)
            default:
                break
            }
        }

        _ = repairStore.markUndone(id: record.id)
        let journalEntry = SentinelJournalEntry(
            sequence: nextSequence(),
            event: .repairUndone,
            at: environment.now,
            cycleID: lastReport.cycleID,
            fingerprint: record.issueFingerprints.first,
            ruleID: record.ruleIDs.first,
            repairID: record.repairID,
            counts: ["records": 1],
            note: "Undo applied.")
        store?.record(journalEntry)
        saveIssues()
        postUpdate()
        return SentinelRepairOutcome(
            repairID: record.repairID,
            issueFingerprints: record.issueFingerprints,
            status: .appliedVerified,
            message: "Undone.",
            record: record)
    }

    private func planBookPrevious(_ action: SentinelRepairAction) -> Book {
        if case .replaceBook(_, let previous, _) = action { return previous }
        return Book(title: "", author: "", fileURL: URL(fileURLWithPath: "/"), fileType: .pdf)
    }

    private func planStatePrevious(_ action: SentinelRepairAction) -> LibraryState? {
        if case .replaceLibraryState(let previous, _) = action { return previous }
        return nil
    }

    private func apply(outcome: SentinelRepairOutcome, to issues: [SentinelIssue]) -> [SentinelIssue] {
        var result = issues
        for index in result.indices where outcome.issueFingerprints.contains(result[index].fingerprint) {
            result[index].attemptCount += 1
            if let id = outcome.record?.id { result[index].lastRepairID = id }
            if outcome.status == .appliedVerified {
                result[index].status = SentinelLifecycle.apply(.repaired, to: result[index].status)
                result[index].updatedAt = environment.now
            }
        }
        return result
    }

    private func record(outcome: SentinelRepairOutcome, plan: SentinelRepairPlan, userInitiated: Bool) {
        guard let repairStore, let record = outcome.record else { return }
        _ = repairStore.append(record, plan: outcome.status == .appliedVerified ? plan : nil)
        let event: SentinelJournalEvent
        switch outcome.status {
        case .appliedVerified: event = .repairVerified
        case .rolledBack: event = .repairFailed
        case .blocked, .failed, .unavailable: event = .repairPlanned
        case .appliedUnverified: event = .repairApplied
        }
        store?.record(SentinelJournalEntry(
            sequence: nextSequence(),
            event: event,
            at: environment.now,
            cycleID: lastReport.cycleID,
            fingerprint: outcome.issueFingerprints.first,
            ruleID: plan.ruleIDs.first?.rawValue,
            repairID: plan.id,
            counts: ["actions": plan.actions.count, "userInitiated": userInitiated ? 1 : 0],
            note: outcome.message))
    }

    // MARK: - Issue actions

    func setStatus(
        fingerprint: String,
        status: SentinelIssueStatus,
        snoozedUntil: Date? = nil
    ) -> Bool {
        guard let index = issues.firstIndex(where: { $0.fingerprint == fingerprint }) else { return false }
        guard SentinelLifecycle.canTransition(from: issues[index].status, to: status) else { return false }
        issues[index].status = status
        issues[index].updatedAt = environment.now
        switch status {
        case .snoozed: issues[index].snoozedUntil = snoozedUntil
        case .acknowledged: issues[index].acknowledgedAt = environment.now
        case .ignored: issues[index].ignoredAt = environment.now
        case .resolved: issues[index].resolvedAt = environment.now
        default: break
        }
        store?.record(SentinelJournalEntry(
            sequence: nextSequence(),
            event: .issueUpdated,
            at: environment.now,
            fingerprint: fingerprint,
            ruleID: issues[index].ruleID.rawValue,
            domain: issues[index].domain.rawValue,
            severity: issues[index].severity.rawValue,
            status: status.rawValue,
            ruleVersion: issues[index].ruleVersion,
            rootCauseKey: issues[index].rootCauseKey,
            titleKey: issues[index].titleKey,
            counts: ["occurrences": 0],
            note: issues[index].safeSummary))
        saveIssues()
        postUpdate()
        return true
    }

    // MARK: - Persistence

    private func nextSequence() -> Int {
        store?.nextSequence() ?? 0
    }

    private func saveIssues() {
        store?.save(issues)
    }

    private func persist(
        diagnosis: SentinelDiagnosisResult,
        coverage: SentinelCoverage,
        results: [SentinelProbeRunResult],
        outcomes: [SentinelRepairOutcome],
        health: SentinelHealthModel,
        trigger: SentinelCycleTrigger
    ) {
        guard let store else { return }

        store.bump("cycles")
        if !diagnosis.opened.isEmpty { store.bump("issuesOpened", by: diagnosis.opened.count) }
        if !diagnosis.resolved.isEmpty { store.bump("issuesResolved", by: diagnosis.resolved.count) }
        if !outcomes.isEmpty {
            store.bump("repairsAttempted", by: outcomes.count)
            store.bump("repairsVerified", by: outcomes.filter(\.succeeded).count)
        }
        saveIssues()

        for issue in issues where diagnosis.opened.contains(issue.fingerprint) {
            store.record(SentinelJournalEntry(
                sequence: nextSequence(),
                event: .issueOpened,
                at: environment.now,
                cycleID: lastReport.cycleID,
                fingerprint: issue.fingerprint,
                ruleID: issue.ruleID.rawValue,
                domain: issue.domain.rawValue,
                severity: issue.severity.rawValue,
                status: issue.status.rawValue,
                ruleVersion: issue.ruleVersion,
                rootCauseKey: issue.rootCauseKey,
                titleKey: issue.titleKey,
                counts: ["occurrences": issue.occurrenceCount],
                note: issue.safeSummary))
        }

        for issue in issues where diagnosis.resolved.contains(issue.fingerprint) {
            store.record(SentinelJournalEntry(
                sequence: nextSequence(),
                event: .issueClosed,
                at: environment.now,
                cycleID: lastReport.cycleID,
                fingerprint: issue.fingerprint,
                ruleID: issue.ruleID.rawValue,
                domain: issue.domain.rawValue,
                severity: issue.severity.rawValue,
                status: issue.status.rawValue,
                counts: ["occurrences": issue.occurrenceCount],
                note: issue.safeSummary))
        }

        for result in results where result.status == .failed || result.status == .timedOut {
            store.record(SentinelJournalEntry(
                sequence: nextSequence(),
                event: .probeSkipped,
                at: environment.now,
                cycleID: lastReport.cycleID,
                ruleID: result.ruleID.rawValue,
                domain: result.domain.rawValue,
                counts: ["durationMs": Int(result.duration * 1000)],
                note: result.status.rawValue))
        }

        store.record(SentinelJournalEntry(
            sequence: nextSequence(),
            event: .coverage,
            at: environment.now,
            cycleID: lastReport.cycleID,
            counts: [
                "total": coverage.totalProbes,
                "ran": coverage.ran,
                "skipped": coverage.skipped,
                "failed": coverage.failed,
                "requiredMissing": coverage.requiredTotal - coverage.requiredRan,
                "band": health.band == .healthy ? 1 : 0,
            ],
            note: trigger.rawValue))

        store.record(SentinelJournalEntry(
            sequence: nextSequence(),
            event: .cycle,
            at: environment.now,
            cycleID: lastReport.cycleID,
            counts: [
                "probes": results.count,
                "findings": results.reduce(0) { $0 + $1.findings.count },
                "issues": issues.count,
                "repaired": outcomes.filter(\.succeeded).count,
            ],
            note: trigger.rawValue))
    }

    func journalFacts() -> SentinelJournalFacts {
        guard let journal else { return .empty }
        let read = journal.readAll()
        let failures = lastReport.probeResults
            .filter { $0.status == .failed || $0.status == .timedOut }
            .reduce(into: [String: Int]()) { result, probe in
                result[probe.probeID, default: 0] += 1
            }
        return SentinelJournalFacts(
            exists: read.totalLines > 0,
            byteSize: journal.totalBytes(),
            segmentCount: read.segments,
            corruptLines: read.corruptLines,
            lastEntryAt: read.entries.last?.at,
            lastCycleDuration: lastReport.startedAt.timeIntervalSince1970 > 0 ? lastReport.duration : nil,
            lastCycleProbeCount: lastReport.probeResults.count,
            consecutiveFailuresByProbe: failures,
            lastCycleOverranBudget: lastReport.duration > 2.0)
    }

    // MARK: - Published state

    func publishedState() async -> SentinelPublishedState {
        let mode = await operationalMode()
        let journal = self.journal
        let read = journal?.readAll()
        let history = Array((read?.entries ?? []).suffix(100).reversed())
        let coverage = lastReport.coverage
        let health = SentinelHealthModel.compute(
            issues: issues, coverage: coverage, now: environment.now)
        return SentinelPublishedState(
            issues: issues,
            health: health,
            coverage: coverage,
            configuration: configuration,
            lastCycle: lastReport,
            history: history,
            repairs: repairStore?.records ?? [],
            counters: store?.counters ?? [:],
            storeOutcome: describe(store?.lastLoadOutcome),
            isRunning: isCycleRunning,
            isOpen: isOpen,
            error: lastError,
            probes: lastReport.probeResults,
            journalBytes: read?.entries.isEmpty == false ? (journal?.totalBytes() ?? 0) : (journal?.totalBytes() ?? 0),
            operationalMode: mode)
    }

    private func describe(_ outcome: SentinelIssueStore.LoadOutcome?) -> String {
        guard let outcome else { return "not opened" }
        switch outcome {
        case .loaded: return "loaded"
        case .recoveredFromBackup: return "recovered from backup"
        case .rebuiltFromJournal: return "rebuilt from journal"
        case .empty: return "empty"
        case .failed(let reason): return "unreadable: \(reason)"
        }
    }

    func history(limit: Int = 200) -> [SentinelJournalEntry] {
        guard let journal else { return [] }
        return Array(journal.readAll().entries.suffix(limit).reversed())
    }

    // MARK: - Store maintenance (called by the repair bridge)

    func performStoreRebuild() -> Bool {
        guard let store else { return false }
        _ = store.archiveState(reason: "rebuild")
        let rebuilt = store.recoverFromJournal()
        issues = rebuilt
        store.bump("storeRebuilds")
        let saved = store.save(rebuilt)
        postUpdate()
        return saved
    }

    func performJournalTrim(maxBytes: Int64) -> Bool {
        guard let journal else { return false }
        _ = journal.trimToByteBudget(maxBytes)
        store?.bump("journalTrims")
        postUpdate()
        return true
    }

    func performDebugJournalTrim(maxBytes: Int64) -> Bool {
        guard let paths else { return false }
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: paths.debugDirectory.path)) ?? []
        var files: [(URL, Int64, Date)] = []
        for name in names {
            let url = paths.debugDirectory.appendingPathComponent(name)
            let size = ((try? manager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
            let date = ((try? manager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date) ?? .distantPast
            files.append((url, size, date))
        }
        var total = files.reduce(Int64(0)) { $0 + $1.1 }
        for file in files.sorted(by: { $0.2 < $1.2 }) where total > maxBytes {
            try? manager.removeItem(at: file.0)
            total -= file.1
        }
        postUpdate()
        return true
    }

    // MARK: - Notification

    private func postUpdate() {
        NotificationCenter.default.post(name: Self.didUpdateNotification, object: nil)
    }
}
