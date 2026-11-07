//  SessionCoordinator2.swift
// Manages the lifecycle of the currently-active reading session.
// PATCHED:
//   B2 — currentPage is the single authoritative source; PDFReaderScreen must
//         NOT maintain its own @State copy.
//   B3 — restoreSession now starts an elapsed timer from the resume point,
//         and validates that the DataStore book still has a matching activeSessionID.
// AUDIT:
//   Task 8  — startReading guards against same-book re-entry to prevent orphan sessions.
//   Task 15 — restoreSession elapsed timer behaviour confirmed correct (B3 patch).
//   Task 25 — endAllActiveSessions added so the app lifecycle can reset all state.

import Combine
import Foundation

@MainActor
final class SessionCoordinator: ObservableObject {
    // MARK: - Published State

    @Published private(set) var activeBookID: UUID?
    @Published private(set) var activeSessionID: UUID?

    /// B2: This is THE single authoritative current page value.
    /// PDFReaderScreen must read this property and must NOT maintain a parallel
    /// @State var currentPage. The only writers are startReading, turnToPage,
    /// and restoreSession — all inside this coordinator.
    @Published private(set) var currentPage: Int = 0

    /// Human-readable position for the HUD. EPUB sets chapter/page-in-chapter;
    /// PDF leaves it empty and the HUD falls back to its page counter.
    @Published private(set) var positionLabel: String = ""

    @Published private(set) var elapsedTime: TimeInterval = 0

    // MARK: - Private

    private weak var dataStore: DataStore?
    private var elapsedTimer: Timer?
    private var sessionStartDate: Date?

    /// Audio environment monitor. One instance per coordinator; monitors one session at a time.
    private let audioMonitor = AudioMonitorService()

    // MARK: - Init

    init(dataStore: DataStore) {
        self.dataStore = dataStore

        #if DEBUG
        DeveloperConsoleRegistry.shared.register(self)
        #endif
    }

    // MARK: - Public API

    var isReading: Bool {
        activeBookID != nil
    }

    func startReading(bookID: UUID, page: Int) {
        // TASK 8 FIX: Guard against same-book re-entry.
        //
        // SwiftUI may call onAppear multiple times (e.g. tab switches, sheet
        // dismissals, split-view resizing). Without this guard, each re-appear
        // triggers DataStore.startSession, which closes the current session and
        // opens a new zero-duration one — corrupting session analytics.
        //
        // Code evidence (original, no guard):
        //   if let previous = activeBookID, previous != bookID { endSession(for: previous) }
        //   dataStore?.startSession(bookID: bookID, onPage: page)  ← called unconditionally
        //
        // Fix: return early when the same book is already the active book.
        if activeBookID == bookID {
            // Same book re-appeared: keep the existing session, just ensure
            // the elapsed timer is running (it may have been stopped by a
            // transient disappear/appear cycle).
            if elapsedTimer == nil {
                sessionStartDate = Date()
                startElapsedTimer()
            }
            return
        }

        if let previous = activeBookID, previous != bookID {
            endSession(for: previous)
        }

        dataStore?.startSession(bookID: bookID, onPage: page)
        activeBookID = bookID
        currentPage = page
        positionLabel = ""
        sessionStartDate = Date()

        if let book = dataStore?.book(id: bookID),
           let sid = book.activeSessionID
        {
            activeSessionID = sid
            // Begin audio environment monitoring for this session.
            // AudioMonitorService captures a baseline snapshot immediately and
            // then polls every 60 seconds for the session's lifetime.
            audioMonitor.startMonitoring(sessionID: sid)
        }

        startElapsedTimer()
    }

    func turnToPage(_ page: Int) {
        guard let bookID = activeBookID, page != currentPage else { return }
        dataStore?.recordPageTurn(bookID: bookID, newPage: page)
        currentPage = page
    }

    func updatePositionLabel(_ label: String) {
        positionLabel = label
    }

    func endCurrentSession() {
        guard let bookID = activeBookID else { return }
        endSession(for: bookID)
    }

    func endSession(for bookID: UUID) {
        // Finalize audio context BEFORE clearing activeSessionID.
        // elapsedTime is the best available duration approximation for this stint;
        // the actual session duration (startTime→endTime) is set by DataStore.closeActiveSession.
        if activeBookID == bookID, let sid = activeSessionID {
            let profile = audioMonitor.finalizeContext(
                sessionID: sid,
                sessionDuration: elapsedTime
            )
            dataStore?.attachAudioContext(to: sid, profile: profile)
        }

        dataStore?.endSession(bookID: bookID)

        if activeBookID == bookID {
            activeBookID = nil
            activeSessionID = nil
            currentPage = 0
            positionLabel = ""
            stopElapsedTimer()
        }
    }

    /// TASK 25: End all active sessions in both DataStore and this coordinator.
    /// Called by the app lifecycle (scene phase → .background) to ensure no sessions
    /// remain open when the process may be suspended or terminated.
    func endAllActiveSessions() {
        // Finalize the one session this coordinator is monitoring before bulk-closing.
        if let sid = activeSessionID {
            let profile = audioMonitor.finalizeContext(
                sessionID: sid,
                sessionDuration: elapsedTime
            )
            dataStore?.attachAudioContext(to: sid, profile: profile)
        }

        dataStore?.endAllActiveSessions()
        activeBookID = nil
        activeSessionID = nil
        stopElapsedTimer()
    }

    /// B3 FIX: restoreSession now starts the elapsed timer from the resume
    /// point (not the original session start, which is unknowable after relaunch)
    /// and verifies the DataStore book has a matching activeSessionID.
    ///
    /// If the DataStore book does NOT have a live activeSessionID (e.g. it was
    /// closed cleanly before crash), this method starts a brand-new session so
    /// subsequent page turns are recorded correctly.
    func restoreSession(bookID: UUID, sessionID: UUID, page: Int) {
        activeBookID = bookID
        currentPage = page

        if let book = dataStore?.book(id: bookID),
           book.activeSessionID == sessionID
        {
            // The session survived serialization — hook into it.
            activeSessionID = sessionID
        } else {
            // Session was closed before serialization; open a new one so
            // subsequent recordPageTurn calls have a valid activeSessionID.
            dataStore?.startSession(bookID: bookID, onPage: page)
            if let book = dataStore?.book(id: bookID) {
                activeSessionID = book.activeSessionID
            }
        }

        // B3 FIX: always start an elapsed timer from now so the UI shows
        // meaningful elapsed time for this reading stint (not the time since
        // the original session was created on a previous launch).
        sessionStartDate = Date()
        startElapsedTimer()
    }

    // MARK: - Elapsed Timer

    private func startElapsedTimer() {
        stopElapsedTimer()
        elapsedTime = 0
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let start = self.sessionStartDate else { return }
            Task { @MainActor in
                self.elapsedTime = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        elapsedTime = 0
        sessionStartDate = nil
    }
}

// MARK: - Developer Console

#if DEBUG
extension SessionCoordinator: DeveloperConsoleObservable {
    static var consoleIdentity: ConsoleSubsystemIdentity {
        ConsoleSubsystemIdentity(
            id: "session-coordinator",
            displayName: "Session Coordinator",
            category: .manager,
            purpose: "Owns the lifecycle of whichever reading session is currently active — the single authoritative source for current page and elapsed time."
        )
    }

    var consoleSnapshot: ConsoleSubsystemSnapshot {
        ConsoleSubsystemSnapshot(
            identity: Self.consoleIdentity,
            status: isReading ? .running : .idle,
            currentActivity: isReading
                ? "Reading session active — page \(currentPage), \(Int(elapsedTime))s elapsed this stint"
                : "No active reading session",
            lastUpdated: Date(),
            metrics: [
                "Active book": activeBookID?.uuidString.prefix(8).description ?? "None",
                "Active session": activeSessionID?.uuidString.prefix(8).description ?? "None",
            ]
        )
    }
}
#endif
