//  LibraryHealthIntegration.swift
//  Library Safety — Phase 6
//
//  The single composition point for the recovery subsystem. It builds the
//  incident store, recovery service, and swap coordinator under the app data
//  root, then hands the coordinator to the app. If any directory cannot be
//  created, the app keeps running with recovery unavailable; it never crashes
//  at launch because a recovery log could not be written.

import Foundation

@MainActor
enum LibraryHealthIntegration {
    private(set) static var coordinator: LibraryHealthCoordinator?

    /// Idempotent. Returns nil only when the recovery directories cannot be
    /// created, in which case the caller must leave the Sentinel gate open and
    /// show "recovery unavailable" rather than a dead Health Center.
    @discardableResult
    static func start(
        dataStore: DataStore,
        dataRoot: URL
    ) async -> LibraryHealthCoordinator? {
        if let coordinator {
            await coordinator.start()
            return coordinator
        }

        let recoveryRoot = dataRoot.appendingPathComponent(
            "LibraryRecovery", isDirectory: true)
        guard let store = try? LibraryIncidentStore(root: recoveryRoot) else {
            return nil
        }

        let coordinator = LibraryHealthCoordinator(
            store: store,
            host: dataStore,
            service: try? LibraryRecoveryService(root: recoveryRoot),
            dataRoot: dataRoot,
            swap: try? LibrarySwapCoordinator(root: recoveryRoot))
        self.coordinator = coordinator
        await coordinator.start()
        return coordinator
    }

    /// A view reads this; it never constructs a second coordinator.
    static func existing() -> LibraryHealthCoordinator? {
        coordinator
    }
}
