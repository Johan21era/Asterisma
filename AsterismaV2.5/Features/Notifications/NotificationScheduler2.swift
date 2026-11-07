//  NotificationScheduler2.swift
//  AsterismaV2.5
//  Thin delivery wrapper around UNUserNotificationCenter.
//  The IntelligentNotificationEngine decides WHAT to send and WHEN.
//  This file handles only HOW to send it.
//
//  It is intentionally stateless — no candidate history, no cooldown logic.
//  The engine's own gating (shouldNotify threshold, notificationHistory param)
//  is the authority on delivery frequency.
//

import Foundation
import UserNotifications

@MainActor
final class NotificationScheduler {
    static let shared = NotificationScheduler()

    #if DEBUG
    private(set) var consoleAuthorizationGranted: Bool?
    private(set) var consoleLastAuthorizationError: String?
    private(set) var consoleScheduledCount: Int = 0
    private(set) var consoleLastScheduleError: String?
    private(set) var consoleLastActivityAt: Date?
    #endif

    private init() {
        #if DEBUG
        DeveloperConsoleRegistry.shared.register(self)
        #endif
    }

    // MARK: - Authorization

    /// Requests notification permission from the user.
    /// Safe to call multiple times — UNUserNotificationCenter is idempotent once
    /// the user has made a decision.
    func requestAuthorization() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            #if DEBUG
            consoleAuthorizationGranted = granted
            consoleLastActivityAt = Date()
            #endif
            if !granted {
                // User denied. App functions fully without notifications.
                // Log for diagnostics but treat as a soft failure.
                print("[NotificationScheduler] User denied notification permission.")
            }
        } catch {
            print("[NotificationScheduler] Authorization request failed: \(error)")
            #if DEBUG
            consoleLastAuthorizationError = error.localizedDescription
            consoleLastActivityAt = Date()
            #endif
        }
    }

    // MARK: - Delivery

    /// Schedules a notification from an IntelligentNotificationEngine candidate.
    ///
    /// Delivery timing:
    ///   - If `candidate.recommendedDeliveryTime` is > 60 s in the future,
    ///     a time-interval trigger is used.
    ///   - Otherwise the notification fires immediately (nil trigger = now).
    ///
    /// Each notification receives a unique identifier so concurrent candidates
    /// don't silently replace each other in the pending queue.
    func schedule(candidate: NotificationCandidate) async {
        let content = UNMutableNotificationContent()
        content.title = candidate.title
        content.body = candidate.message
        content.sound = .default

        let secondsUntilDelivery = candidate.recommendedDeliveryTime.timeIntervalSinceNow
        let trigger: UNNotificationTrigger? = secondsUntilDelivery > 60
            ? UNTimeIntervalNotificationTrigger(timeInterval: secondsUntilDelivery,
                                                repeats: false)
            : nil

        let request = UNNotificationRequest(
            identifier: "rt-prompt-\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            #if DEBUG
            consoleScheduledCount += 1
            consoleLastActivityAt = Date()
            #endif
        } catch {
            print("[NotificationScheduler] Failed to schedule notification: \(error)")
            #if DEBUG
            consoleLastScheduleError = error.localizedDescription
            consoleLastActivityAt = Date()
            #endif
        }
    }
}

// MARK: - Developer Console

#if DEBUG
extension NotificationScheduler: DeveloperConsoleObservable {
    static var consoleIdentity: ConsoleSubsystemIdentity {
        ConsoleSubsystemIdentity(
            id: "notification-scheduler",
            displayName: "Notification Scheduler",
            category: .service,
            purpose: "Thin delivery wrapper around UNUserNotificationCenter. Decides HOW to send a notification; IntelligentNotificationEngine decides WHAT and WHEN."
        )
    }

    var consoleSnapshot: ConsoleSubsystemSnapshot {
        var warnings: [String] = []
        var errors: [String] = []
        if consoleAuthorizationGranted == false {
            warnings.append("User denied notification permission")
        }
        if let authError = consoleLastAuthorizationError {
            errors.append("Authorization request failed: \(authError)")
        }
        if let scheduleError = consoleLastScheduleError {
            errors.append("Last schedule attempt failed: \(scheduleError)")
        }

        let status: ConsoleSubsystemStatus
        if !errors.isEmpty {
            status = .error
        } else if !warnings.isEmpty {
            status = .warning
        } else if consoleAuthorizationGranted == nil {
            status = .initializing
        } else {
            status = .healthy
        }

        return ConsoleSubsystemSnapshot(
            identity: Self.consoleIdentity,
            status: status,
            currentActivity: "Scheduled \(consoleScheduledCount) notification(s) this session",
            lastUpdated: consoleLastActivityAt,
            warnings: warnings,
            errors: errors,
            metrics: [
                "Authorization granted": consoleAuthorizationGranted.map { $0 ? "Yes" : "No" } ?? "Not requested yet",
                "Scheduled this session": "\(consoleScheduledCount)",
            ]
        )
    }
}
#endif
