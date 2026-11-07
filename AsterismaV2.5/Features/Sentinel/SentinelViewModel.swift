//  SentinelViewModel.swift
//  AsterismaV2.5
//
//  SG4 — the presentation bridge. It observes published state and calls the
//  runtime for actions. It never probes, never reads the store, and never
//  touches a file.

import Combine
import Foundation
import SwiftUI

nonisolated struct SentinelLaunchSummary: Equatable {
    var fixed: Int
    var needsDecision: Int
    var headline: String
    var band: SentinelHealthBand
    var marksAllClearShown: Bool = false
}

/// Pure launch-card policy. The view model only supplies state and the
/// once-per-day flag, which keeps the five card states testable without a
/// running app or a user-visible window.
nonisolated enum SentinelLaunchCardBuilder {
    static func make(
        state: SentinelPublishedState,
        now: Date,
        allClearAlreadyShownToday: Bool
    ) -> SentinelLaunchSummary? {
        // Recovery outranks every other card: nothing below it is meaningful
        // while the store is frozen.
        if state.operationalMode.isSuspended {
            return SentinelLaunchSummary(
                fixed: 0,
                needsDecision: 0,
                headline: "Library recovery is in progress. Sentinel is paused.",
                band: .unknown)
        }

        let cycle = state.lastCycle
        guard cycle.startedAt.timeIntervalSince1970 > 0 else { return nil }

        let visible = state.issues.filter { $0.isVisible(at: now) }
        let fixed = cycle.repairs.filter(\.succeeded).count
        let decisions = visible.filter { $0.severity >= .error }.count
        let band = state.health.band

        if fixed > 0 {
            return SentinelLaunchSummary(
                fixed: fixed,
                needsDecision: decisions,
                headline: "Sentinel fixed \(fixed) issue\(fixed == 1 ? "" : "s") while you were away.",
                band: band)
        }
        if decisions > 0 {
            return SentinelLaunchSummary(
                fixed: 0,
                needsDecision: decisions,
                headline: "\(decisions) issue\(decisions == 1 ? " needs" : "s need") your decision. Your library is otherwise clear.",
                band: band)
        }
        if cycle.coverage.totalProbes > 0 && !cycle.coverage.isComplete {
            let missing = cycle.coverage.requiredTotal - cycle.coverage.requiredRan + cycle.coverage.failed
            return SentinelLaunchSummary(
                fixed: 0,
                needsDecision: 0,
                headline: "Could not finish: \(max(1, missing)) of \(cycle.coverage.totalProbes) checks did not run.",
                band: .unknown)
        }
        if band == .healthy {
            guard !allClearAlreadyShownToday else { return nil }
            return SentinelLaunchSummary(
                fixed: 0,
                needsDecision: 0,
                headline: "Checked \(cycle.coverage.ran) things. All clear.",
                band: .healthy,
                marksAllClearShown: true)
        }
        if !visible.isEmpty {
            return SentinelLaunchSummary(
                fixed: 0,
                needsDecision: 0,
                headline: "\(visible.count) thing\(visible.count == 1 ? " is" : "s are") worth a look.",
                band: band)
        }
        return nil
    }
}

@MainActor
final class SentinelViewModel: ObservableObject {
    @Published private(set) var state: SentinelPublishedState = .empty
    @Published var selectedFingerprint: String?
    @Published var preview: SentinelRepairPlan?
    @Published var message: String?
    @Published private(set) var isWorking = false

    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: SentinelRuntime.didUpdateNotification,
            object: nil,
            queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - Reads

    func refresh() async {
        state = await SentinelRuntime.shared.publishedState()
        await SentinelNotifier.postIfNeeded(state: state)
    }

    var selectedIssue: SentinelIssue? {
        guard let selectedFingerprint else { return nil }
        return state.issues.first { $0.fingerprint == selectedFingerprint }
    }

    var visibleIssues: [SentinelIssue] {
        let now = Date()
        return state.issues.filter { $0.isVisible(at: now) }
    }

    var sortedIssues: [SentinelIssue] {
        visibleIssues.sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            return $0.lastSeen > $1.lastSeen
        }
    }

    func copy(for issue: SentinelIssue) -> SentinelCopy? {
        SentinelProbeCatalog.ruleMetadata[issue.ruleID]?.copy
    }

    func metadata(for issue: SentinelIssue) -> SentinelRuleMetadata? {
        SentinelProbeCatalog.ruleMetadata[issue.ruleID]
    }

    var canShowRepair: Bool {
        state.configuration.autonomy != .off && state.configuration.autonomy != .observe
    }

    /// A launch card only appears when there is something new to say. "All
    /// clear" is at most once a day and only with complete coverage. The policy
    /// itself lives in `SentinelLaunchCardBuilder` so it can be pinned directly.
    func launchSummary(now: Date = Date()) -> SentinelLaunchSummary? {
        let summary = SentinelLaunchCardBuilder.make(
            state: state,
            now: now,
            allClearAlreadyShownToday: hasShownAllClearToday(now: now))
        if summary?.marksAllClearShown == true {
            markAllClearShown(now: now)
        }
        return summary
    }

    private func hasShownAllClearToday(now: Date) -> Bool {
        UserDefaults.standard.string(forKey: "sentinel.card.allClearDay") == SentinelFormat.day(now)
    }

    private func markAllClearShown(now: Date) {
        UserDefaults.standard.set(SentinelFormat.day(now), forKey: "sentinel.card.allClearDay")
    }

    // MARK: - Actions

    func runCheck(scope: SentinelCycleScope = .deep) async {
        guard !isWorking else { return }
        isWorking = true
        let report = await SentinelRuntime.shared.runOnce(trigger: .manual, scope: scope)
        await refresh()
        isWorking = false
        if let error = report.error {
            message = error
        } else {
            message = "Checked \(report.coverage.ran) of \(report.probeResults.count) checks in \(String(format: "%.2f", report.duration))s."
        }
    }

    func requestFix(_ issue: SentinelIssue) async {
        preview = await SentinelRuntime.shared.previewRepair(fingerprint: issue.fingerprint)
        if preview == nil {
            message = "There is nothing safe to change right now. Sentinel will keep watching."
        }
    }

    func confirmFix() async {
        guard let preview,
              let fingerprint = preview.issueFingerprints.first else { return }
        isWorking = true
        let outcome = await SentinelRuntime.shared.repair(fingerprint: fingerprint)
        message = outcome.message
        self.preview = nil
        await refresh()
        isWorking = false
    }

    func cancelFix() {
        preview = nil
    }

    func undo(_ record: SentinelRepairRecord) async {
        isWorking = true
        let outcome = await SentinelRuntime.shared.undoRepair(recordID: record.id)
        message = outcome.message
        await refresh()
        isWorking = false
    }

    func acknowledge(_ issue: SentinelIssue) async {
        _ = await SentinelRuntime.shared.setStatus(fingerprint: issue.fingerprint, status: .acknowledged)
        await refresh()
    }

    func snooze(_ issue: SentinelIssue, hours: Int = 24) async {
        _ = await SentinelRuntime.shared.setStatus(
            fingerprint: issue.fingerprint,
            status: .snoozed,
            snoozedUntil: Date().addingTimeInterval(Double(hours) * 3600))
        await refresh()
    }

    func ignore(_ issue: SentinelIssue) async {
        _ = await SentinelRuntime.shared.setStatus(fingerprint: issue.fingerprint, status: .ignored)
        selectedFingerprint = nil
        await refresh()
    }

    func reopen(_ issue: SentinelIssue) async {
        _ = await SentinelRuntime.shared.setStatus(fingerprint: issue.fingerprint, status: .open)
        await refresh()
    }

    func saveConfiguration(_ config: SentinelConfiguration) async {
        if config.notificationsEnabled && !state.configuration.notificationsEnabled {
            await SentinelNotifier.requestAuthorizationIfNeeded()
        }
        await SentinelRuntime.shared.updateConfiguration(config)
        await refresh()
        message = "Saved."
    }

    // MARK: - Derived presentation

    var bandColor: Color {
        switch state.health.band {
        case .healthy: return .green
        case .watch: return .blue
        case .attention: return .orange
        case .critical: return .red
        case .unknown: return .secondary
        }
    }

    var coverageLine: String {
        let coverage = state.coverage
        guard coverage.totalProbes > 0 else { return "No checks have run yet." }
        if coverage.isComplete {
            return "Checked \(coverage.ran) of \(coverage.totalProbes) checks. Required coverage complete."
        }
        let missing = coverage.requiredTotal - coverage.requiredRan + coverage.failed
        return "Checked \(coverage.ran) of \(coverage.totalProbes) checks — \(max(1, missing)) required did not run."
    }

    var probes: [SentinelProbeRunResult] { state.probes }

    var registryCount: Int { SentinelProbeCatalog.descriptors.count }
    var domainCount: Int { SentinelProbeCatalog.domainCount }
    var repairCatalogCount: Int { SentinelRepairCatalog.implementedIDs.count }
}
