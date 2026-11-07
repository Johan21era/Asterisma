//  SentinelNotification.swift
//  AsterismaV2.5
//
//  §10.11 — notifications are opt-in, capped at one per issue per week, and
//  contain only the registry's static title. No book name, no path, no note.
//  The policy is pure so the cap and quiet hours are testable without the
//  system notification centre.

import Foundation
import UserNotifications

nonisolated enum SentinelNotificationSkip: String, Error, Equatable, Sendable {
    case notificationsOff
    case sentinelOff
    case quietHours
    case belowDecisionThreshold
    case alreadyNotifiedThisWeek

    var explanation: String {
        switch self {
        case .notificationsOff: return "Notifications are turned off."
        case .sentinelOff: return "Sentinel is off."
        case .quietHours: return "Quiet hours are active."
        case .belowDecisionThreshold: return "This issue does not need a decision."
        case .alreadyNotifiedThisWeek: return "This issue was already notified within the last week."
        }
    }
}

nonisolated enum SentinelNotificationPolicy {
    static let repeatWindow: TimeInterval = 7 * 86_400

    /// Returns the single issue that should produce a notification, or the
    /// reason nothing is posted. Severity wins; ties go to the newest issue.
    static func next(
        issues: [SentinelIssue],
        now: Date,
        configuration: SentinelConfiguration,
        lastNotified: [String: Date]
    ) -> Result<SentinelIssue, SentinelNotificationSkip> {
        guard configuration.autonomy != .off else { return .failure(.sentinelOff) }
        guard configuration.notificationsEnabled else { return .failure(.notificationsOff) }
        guard !configuration.quietHours.contains(now) else { return .failure(.quietHours) }

        let eligible = issues
            .filter { $0.isVisible(at: now) && $0.severity >= .error }
            .filter { issue in
                guard let last = lastNotified[issue.fingerprint] else { return true }
                return now.timeIntervalSince(last) >= repeatWindow
            }
            .sorted {
                if $0.severity != $1.severity { return $0.severity > $1.severity }
                return $0.lastSeen > $1.lastSeen
            }

        guard let issue = eligible.first else {
            let hasDecisionIssue = issues.contains { $0.isVisible(at: now) && $0.severity >= .error }
            return .failure(hasDecisionIssue ? .alreadyNotifiedThisWeek : .belowDecisionThreshold)
        }
        return .success(issue)
    }

    static func body(for issue: SentinelIssue) -> String {
        let title = SentinelProbeCatalog.ruleMetadata[issue.ruleID]?.title
            ?? "Sentinel found something that needs a decision."
        return "\(title) Open Sentinel Health for details and the safe fix."
    }
}

/// Thin system bridge. Kept out of the runtime actor so probes and tests never
/// touch UNUserNotificationCenter; the view model calls this after publishing.
@MainActor
enum SentinelNotifier {
    private static let defaultsKeyPrefix = "sentinel.notified."
    private static let requestKey = "sentinel.notification.requested"

    static func requestAuthorizationIfNeeded() async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: requestKey) else { return }
        defaults.set(true, forKey: requestKey)
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    static func postIfNeeded(
        state: SentinelPublishedState,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) async {
        let lastNotified = lastNotifiedDates(defaults: defaults)
        guard case .success(let issue) = SentinelNotificationPolicy.next(
            issues: state.issues,
            now: now,
            configuration: state.configuration,
            lastNotified: lastNotified) else { return }

        let content = UNMutableNotificationContent()
        content.title = "Sentinel"
        content.body = SentinelNotificationPolicy.body(for: issue)
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: issue.fingerprint,
            content: content,
            trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            defaults.set(now, forKey: defaultsKeyPrefix + issue.fingerprint)
        } catch {
            // A denied permission is a normal state, not a data problem. The
            // app-state probe reports the mismatch; nothing is journaled here.
        }
    }

    static func lastNotifiedDates(defaults: UserDefaults = .standard) -> [String: Date] {
        defaults.dictionaryRepresentation().reduce(into: [:]) { result, pair in
            guard pair.key.hasPrefix(defaultsKeyPrefix),
                  let date = pair.value as? Date else { return }
            result[String(pair.key.dropFirst(defaultsKeyPrefix.count))] = date
        }
    }

    static func resetBookkeeping(defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix(defaultsKeyPrefix) {
            defaults.removeObject(forKey: key)
        }
        defaults.removeObject(forKey: requestKey)
    }
}
