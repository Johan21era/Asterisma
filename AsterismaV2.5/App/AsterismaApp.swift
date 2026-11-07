//  AsterismaApp2.swift
//  AsterismaV2.5
//
//  The @main entry point. Owns every long-lived ObservableObject and injects
//  them into the SwiftUI environment.
//
//  Full engine wiring:
//    DataStore + SessionCoordinator     — core read/write pipeline (unchanged)
//    GoalProgressViewModel.bind()       — reactive goal tracking after init
//    SessionEventRouter.bind()          — post-session cascade (weather, notifs, context)
//    BehaviorContextAccessKit           — starts observing NSWorkspace automatically
//    BehaviorContextEngine              — populated by SessionEventRouter at session end
//    NotificationScheduler              — permission requested once at launch
//    scenePhase .background             — clean session teardown + immediate save
//    .newYearTransitionAware()          — celebration overlay (self-contained modifier)
//    Developer Console (#if DEBUG only) — separate Window scene + ⌘⇧D menu command;
//                                          zero footprint in Release builds, zero
//                                          impact on ContentView's own hierarchy
//    Settings window (roadmap 1.2a)     — ⌘, via CommandMenu("App"); hosts the goal
//                                          editor (NA-2), the previously missing
//                                          creation surface for goals/deadlines
//

import SwiftUI

@main
struct AsterismaApp: App {
    // MARK: - Owned State

    @StateObject private var dataStore: DataStore
    @StateObject private var coordinator: SessionCoordinator
    @StateObject private var goalVM = GoalProgressViewModel()
    @StateObject private var eventRouter = SessionEventRouter()
    @StateObject private var behaviorKit: BehaviorContextAccessKit
    @StateObject private var contextEngine = BehaviorContextEngine()

    @Environment(\.scenePhase) private var scenePhase

    #if DEBUG
    /// Only used to open the Developer Console window (see .commands below).
    /// Gating the property itself, not just its use, avoids an "unused
    /// property" warning in Release builds where it would otherwise still
    /// exist but never be read.
    @Environment(\.openWindow) private var openWindow
    #endif

    /// ROADMAP 1.2a (NA-2): opens the Settings window hosting the goal editor.
    /// Available in both configurations — goals are a production feature.
    #if !DEBUG
    @Environment(\.openWindow) private var openWindowRelease
    #endif

    /// SG4: the Health Center is a Release feature, so it needs an opener in
    /// both configurations. Kept separate from the Debug-only console opener.
    @Environment(\.openWindow) private var openWindowHealth

    // MARK: - Init

    //
    // SessionCoordinator must receive the exact same DataStore instance owned
    // by the App — not a second ephemeral copy. Two-step StateObject init is
    // the standard pattern when one StateObject depends on another.

    init() {
        // G3C: production uses the SQLite summary store. On first launch it
        // bootstraps from legacy library.json and leaves the JSON in place as a
        // fallback until the migration has been verified.
        let store = DataStore(storageEngine: .sqlite)
        _dataStore = StateObject(wrappedValue: store)
        _coordinator = StateObject(wrappedValue: SessionCoordinator(dataStore: store))
        _behaviorKit = StateObject(wrappedValue: BehaviorContextAccessKit(
            database: store.behaviorEvidenceDatabase))
    }

    // MARK: - Scene

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(dataStore)
                .environmentObject(coordinator)
                .environmentObject(goalVM)
                .environmentObject(contextEngine) // read by ContextInsightPanel
                .task {
                    // ── One-time pipeline bindings ──────────────────────────
                    // GoalProgressViewModel: subscribes to dataStore.$books AND
                    // dataStore.$libraryState via Combine. Refreshes automatically
                    // on every change from this point on (libraryState observation
                    // added by roadmap 1.2b — goal saves now propagate live).
                    goalVM.bind(
                        to: dataStore,
                        goalSet: dataStore.libraryState.goalSet,
                        deadlines: dataStore.libraryState.deadlines
                    )

                    // SessionEventRouter: watches dataStore.$books for session close
                    // events and fans out to WeatherKit, notifications, and context engine.
                    eventRouter.bind(
                        to: dataStore,
                        behaviorKit: behaviorKit,
                        contextEngine: contextEngine
                    )

                    // BehaviorContextAccessKit: self-contained NSWorkspace observer.
                    // Calling startMonitoring() is all that is needed — it wires up
                    // all notification observers internally.
                    behaviorKit.startMonitoring()

                    // Notification permission — idempotent after first call.
                    await NotificationScheduler.shared.requestAuthorization()

                    // G6: analyze imported/history sessions once the app is up,
                    // not only when a live session closes.
                    eventRouter.analyzeHistory(books: dataStore.books)
                }
                // The New Year celebration modifier manages its own
                // NewYearTransitionMonitor @StateObject internally.
                .newYearTransitionAware()
        }
        .defaultSize(width: 1200, height: 780)
        // Owner-test F4: without a content minimum, macOS restored a 900x450
        // window and the toolbar collapsed/hid. Keep a usable floor and let
        // the green zoom button work normally.
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unifiedCompact)
        // Native titlebar remains; the library toolbar itself is hidden in ContentView.
        .commands {
            // ROADMAP 1.2a: standard macOS Settings affordance (⌘,) for the goal
            // editor window. The Developer menu below appends its own items in
            // DEBUG; both menus coexist on the menu bar.
            CommandMenu("App") {
                Button("Settings…") {
                    #if DEBUG
                    openWindow(id: "reading-tracker-settings")
                    #else
                    openWindowRelease(id: "reading-tracker-settings")
                    #endif
                }
                .keyboardShortcut(",", modifiers: [.command])

                Button("Sentinel Health") {
                    openWindowHealth(id: SentinelHealthCenterWindowID.id)
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            }

            #if DEBUG
            // Menu command only — does not touch ContentView's hierarchy or
            // state in any way. "Disabled by default unless intentionally
            // opened": nothing here runs until this menu item is chosen.
            CommandMenu("Developer") {
                Button("Open Developer Console") {
                    openWindow(id: DeveloperConsoleWindowID.id)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
            #endif
        }
        // Owner-test F4: `.hiddenTitleBar` hid the toolbar in windowed mode
        // (and left the green zoom button inert). Keep the standard title bar;
        // the transparent toolbar background still lets the starfield show.
        // Safe teardown when the app moves to the background.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                coordinator.endAllActiveSessions()
                dataStore.saveImmediately()
                behaviorKit.stopMonitoring()
                // ADR-13: background is a lifecycle boundary for the warm
                // Mirage engine too. Any in-flight request finishes first;
                // nothing stored is deleted.
                Task { await MirageEngineService.shared.stop() }
            }
            if newPhase == .active {
                behaviorKit.startMonitoring()
            }
        }
        // LIVE-TEST LT-4: Insights as a real, movable window instead of a
        // dead-center sheet that dragged the main window around.
        Window("Reading Insights", id: "reading-insights") {
            ReadingInsightsDashboard()
                .environmentObject(dataStore)
                .frame(minWidth: 760, minHeight: 540)
        }

        Window("Advanced Context", id: "reading-context-advanced") {
            AdvancedContextView()
                .environmentObject(contextEngine)
                .frame(minWidth: 760, minHeight: 620)
        }

        // SG4: Sentinel Health Center — a real Release surface, not a Debug toy.
        Window("Sentinel Health", id: SentinelHealthCenterWindowID.id) {
            SentinelHealthCenterView()
                .environmentObject(dataStore)
                .frame(minWidth: 860, minHeight: 640)
        }
        .defaultSize(width: 980, height: 720)

        // ROADMAP 1.2a/1.2b (NA-2): Settings window — the goal/deadline editor.
        // Shares the SAME environment objects as the main window, so a save here
        // mutates the one DataStore everything else reads.
        Window("Settings", id: "reading-tracker-settings") {
            SettingsRootView()
                .environmentObject(dataStore)
                .environmentObject(goalVM)
                .frame(minWidth: 560, minHeight: 430)
        }

        #if DEBUG
        // A fully separate Window scene — its own window, its own view
        // tree, no relationship to ContentView/NavigationSplitView at all.
        // This is what makes "no impact on existing view hierarchies or
        // navigation state" true structurally rather than by convention.
        // Compiles out completely outside Debug (see project build
        // settings: SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG
        // $(inherited)" on the Debug configuration only — verified in
        // project.pbxproj, not assumed).
        Window("Developer Console", id: DeveloperConsoleWindowID.id) {
            DeveloperConsoleRootView()
                .environmentObject(dataStore)
        }
        .defaultSize(width: 1200, height: 780)
        #endif
    }
}
