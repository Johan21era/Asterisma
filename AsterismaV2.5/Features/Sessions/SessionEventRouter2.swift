//  SessionEventRouter2.swift
//  AsterismaV2.5
//  Observes DataStore for session-close events and fans out to engines that
//  act at session end. Contains NO engine logic — only calls existing APIs.
//
//  Cascade at session close:
//    1. IntelligentNotificationEngine  — evaluates a reading prompt
//    2. NotificationScheduler          — delivers the prompt if score qualifies
//    3. BehaviorContextEngine.analyze()— updates behavioral context summary
//    4. WeatherKitService              — captures a weather snapshot, concurrently
//
//  Weather is last on purpose: it is the only network call in the cascade.
//  Offline, its failure must never delay notifications or local analysis.
//
//  ROADMAP 2.3 (RA-002 / AUDIT F-12): bind(to:) now clears prior subscriptions
//  before attaching new ones. Previously, closing/reopening the app window re-ran
//  the root .task and appended another sink set per cycle — subscriptions grew for
  //  process lifetime (redundant refresh work; self-suppressing but wasteful).

import Combine
import Foundation

@MainActor
final class SessionEventRouter: ObservableObject {
    // MARK: - Private

    private weak var dataStore: DataStore?
    private weak var behaviorKit: BehaviorContextAccessKit?
    private weak var contextEngine: BehaviorContextEngine?

    /// Books that had an open activeSessionID on the last observed update.
    /// Diffing against the next emission reveals which sessions just closed.
    private var previouslyActiveBookIDs: Set<UUID> = []
    private var cancellables = Set<AnyCancellable>()

    #if DEBUG
    /// Developer Console instrumentation only. Every value here already
    /// existed as a real fact this method observes — this just remembers
    /// the last one so consoleSnapshot has something to report.
    private(set) var consoleLastCascadeAt: Date?
    private(set) var consoleCascadeCount: Int = 0
    #endif

    // MARK: - Init

    /// Previously relied on Swift's compiler-synthesized zero-arg init
    /// (every stored property above already has a default value). Made
    /// explicit only so there is a place to register with the console —
    /// the zero-arg construction `SessionEventRouter()` in
    /// AsterismaApp.swift is unchanged.
    init() {
        #if DEBUG
        DeveloperConsoleRegistry.shared.register(self)
        #endif
    }

    // MARK: - Bind

    /// Attaches the router to the three objects it needs. Call once at app launch.
    func bind(
        to dataStore: DataStore,
        behaviorKit: BehaviorContextAccessKit,
        contextEngine: BehaviorContextEngine
    ) {
        // AUDIT F-12 (roadmap 2.3): re-binding used to append another sink set on
        // every call. Clearing first makes re-bind idempotent.
        cancellables.removeAll()

        self.dataStore = dataStore
        self.behaviorKit = behaviorKit
        self.contextEngine = contextEngine

        // Seed the initial set so the first diff is accurate.
        previouslyActiveBookIDs = Set(
            dataStore.books.filter { $0.activeSessionID != nil }.map(\.id)
        )

        dataStore.$books
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] newBooks in
                self?.handleBooksUpdate(newBooks)
            }
            .store(in: &cancellables)
    }

    // MARK: - Private

    private func handleBooksUpdate(_ books: [Book]) {
        let currentlyActive = Set(
            books.filter { $0.activeSessionID != nil }.map(\.id)
        )
        let justClosed = previouslyActiveBookIDs.subtracting(currentlyActive)
        previouslyActiveBookIDs = currentlyActive

        guard !justClosed.isEmpty else { return }

        Task {
            await runPostSessionCascade(allBooks: books)
        }
    }

    private func runPostSessionCascade(allBooks: [Book]) async {
        #if DEBUG
        consoleLastCascadeAt = Date()
        consoleCascadeCount += 1
        #endif

        // ── 1. Local notification evaluation ──────────────────────────────
        // Weather is its own task: it is the only network call in this
        // cascade, and offline it must never delay notifications or analysis.
        let twoMinutesAgo = Date().addingTimeInterval(-120)
        let recentlyClosed = allBooks
            .flatMap(\.sessions)
            .filter { s in
                guard let end = s.endTime else { return false }
                return end >= twoMinutesAgo
            }

        Task { @MainActor in
            // Failures are swallowed — weather enriches analytics but is never
            // critical to the core reading function.
            for session in recentlyClosed {
                guard !Task.isCancelled else { return }
                try? await WeatherKitService.shared.snapshotForCurrentConditions(
                    sessionID: session.id
                )
            }
        }

        // IntelligentNotificationEngine.evaluate() is a pure function.
        // Its shouldNotify flag already applies the engine's own threshold.
        let result = IntelligentNotificationEngine.evaluate(
            books: allBooks,
            date: Date()
        )
        if result.shouldNotify, let candidate = result.selectedNotification {
            // A push notification is the one pathway in this app where a
            // claim reaches the user completely outside SwiftUI — the
            // engine's own shouldNotify/rankingScore threshold is a
            // real-time targeting decision, not evidence gating. This is
            // the actual "has this earned the right to exist" check.
            let verdict = DataMaturityNotificationAdapter.evaluate(candidate)
            if verdict.maySurface {
                await NotificationScheduler.shared.schedule(candidate: candidate)
            }
        }

        // ── 2. Behavioral context analysis ──────────────────────────────
        // Convert BehaviorContextAccessKit's raw event data into the types
        // BehaviorContextEngine.analyze() expects, then call analyze().
        // analyze() sets contextEngine.summary (the @Published property)
        // internally — no return value needs to be stored here.
        guard let kit = behaviorKit, let engine = contextEngine else { return }

        let allSessions = allBooks.flatMap(\.sessions)

        let readingRecords = BehaviorEvidenceBuilder.readingSessionRecords(
            from: allSessions
        )

        // Only run the analysis when there is meaningful data.
        // The engine handles sparse input gracefully, but calling it with
        // zero records produces a low-confidence summary with no content.
        guard !readingRecords.isEmpty else { return }

        // G6: run the full V3 pipeline, not just V1. V3 calls V1 internally,
        // then adds significance, routine, and narrative stages.
        let input = IntegrationInputBuilder.build(
            from: allBooks,
            kit: kit)
        _ = engine.analyzeWithIntelligence(input: input)
    }

    /// G6: analyze existing history after launch/import, not only on a live
    /// session close. Safe to call repeatedly; it rebuilds deterministically.
    func analyzeHistory(books: [Book]) {
        guard let kit = behaviorKit, let engine = contextEngine else { return }
        let sessions = books.flatMap(\.sessions).filter { $0.endTime != nil }
        guard !sessions.isEmpty else { return }
        let input = IntegrationInputBuilder.build(from: books, kit: kit)
        _ = engine.analyzeWithIntelligence(input: input)
    }
}

// MARK: - Developer Console

#if DEBUG
extension SessionEventRouter: DeveloperConsoleObservable {
    static var consoleIdentity: ConsoleSubsystemIdentity {
        ConsoleSubsystemIdentity(
            id: "session-event-router",
            displayName: "Session Event Router",
            category: .manager,
            purpose: "Watches for a reading session closing, then fans that event out to WeatherKit, the notification engine, and the behavior context engine. Contains no engine logic of its own — only calls existing APIs in sequence."
        )
    }

    var consoleSnapshot: ConsoleSubsystemSnapshot {
        ConsoleSubsystemSnapshot(
            identity: Self.consoleIdentity,
            status: dataStore == nil ? .unavailable : .healthy,
            currentActivity: dataStore == nil
                ? "Not bound yet — bind(to:behaviorKit:contextEngine:) has not been called"
                : "Watching for session-close events (ran \(consoleCascadeCount) cascade(s) this session)",
            lastUpdated: consoleLastCascadeAt,
            metrics: [
                "Cascades run this session": "\(consoleCascadeCount)",
            ]
        )
    }
}
#endif
