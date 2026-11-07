//  SentinelDataBridgeV2.swift
//  AsterismaV2.5
//
//  SG3 — the single audited mutation path between Sentinel and the app.
//
//  Everything here is explicit and checkable:
//    • the caller passes the value it expects to replace, and the bridge
//      refuses if the live value differs (no lost update);
//    • models are changed through DataStore's own APIs, which validate and
//      schedule the normal save;
//    • the only file moves are into `Sentinel/quarantine/`, never user folders;
//    • Sentinel's own maintenance (journal trim, issue-store rebuild,
//      checkpoint) is delegated back to the runtime actor.
//
//  This file is MainActor-bound because DataStore is. The runtime awaits it;
//  no probe ever calls it.

import AppKit
import Foundation

@MainActor
final class LiveSentinelRepairBridge: SentinelRepairBridge {

    private weak var store: DataStore?
    private let fileManager = FileManager.default

    init(store: DataStore) {
        self.store = store
    }

    // MARK: - Reads

    func safetySnapshot() async -> Bool {
        guard let store else { return false }
        return store.createSafetySnapshot()
    }

    func currentGeneration() async -> UInt64 {
        store?.analyticsEpoch ?? 0
    }

    func currentBook(id: UUID) async -> Book? {
        store?.book(id: id)
    }

    func currentLibraryState() async -> LibraryState? {
        store?.libraryState
    }

    func hasRecentReadingActivity(within interval: TimeInterval) async -> Bool {
        guard let store else { return false }
        let threshold = Date().addingTimeInterval(-interval)
        return store.books.contains { book in
            book.sessions.contains { session in
                guard session.endTime == nil else { return false }
                let last = session.pageTimes.compactMap { $0.endTime ?? $0.startTime }.max() ?? session.startTime
                return last >= threshold
            }
        }
    }

    // MARK: - Writes

    func replaceBook(previous: Book, updated: Book) async -> Bool {
        guard let store, let live = store.book(id: previous.id), live == previous else {
            return false
        }
        store.updateBook(updated)
        return store.book(id: updated.id) == updated
    }

    func replaceLibraryState(previous: LibraryState, updated: LibraryState) async -> Bool {
        guard let store,
              SentinelRepairEquality.equal(store.libraryState, previous) else { return false }
        store.updateLibraryState(updated)
        return SentinelRepairEquality.equal(store.libraryState, updated)
    }

    func quarantineFile(at url: URL, name: String) async -> Bool {
        guard let root = AppIdentity.dataRootURL() else { return false }
        let paths = SentinelPaths.standard(dataRoot: root)
        paths.ensureDirectories()
        let safeName = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "_")
        let destination = uniqueDestination(in: paths.quarantineDirectory, name: safeName)
        do {
            try fileManager.moveItem(at: url, to: destination)
            return true
        } catch {
            SentinelTrace.shared.emit("quarantine move failed", key: "quarantine-move", minimumInterval: 3600)
            return false
        }
    }

    func restoreQuarantinedFile(named name: String, to url: URL) async -> Bool {
        guard let root = AppIdentity.dataRootURL() else { return false }
        let paths = SentinelPaths.standard(dataRoot: root)
        let safeName = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "_")
        let source = paths.quarantineDirectory.appendingPathComponent(safeName)
        guard fileManager.fileExists(atPath: source.path) else { return false }
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            try fileManager.moveItem(at: source, to: url)
            return true
        } catch {
            return false
        }
    }

    func trimJournal(maxBytes: Int64) async -> Bool {
        await SentinelRuntime.shared.performJournalTrim(maxBytes: maxBytes)
    }

    func trimDebugJournal(maxBytes: Int64) async -> Bool {
        await SentinelRuntime.shared.performDebugJournalTrim(maxBytes: maxBytes)
    }

    func rebuildIssueStore() async -> Bool {
        await SentinelRuntime.shared.performStoreRebuild()
    }

    func checkpointDatabase() async -> Bool {
        guard let store else { return false }
        return await store.performCheckpoint()
    }

    func writeCover(bookID: UUID, data: Data) async -> Bool {
        CoverStore.active.store(data, forBookID: bookID)
        return CoverStore.active.hasCover(forBookID: bookID)
    }

    func removeCover(bookID: UUID) async -> Bool {
        CoverStore.active.remove(forBookID: bookID)
        return !CoverStore.active.hasCover(forBookID: bookID)
    }

    func resetNotificationState() async -> Bool {
        SentinelNotifier.resetBookkeeping()
        return true
    }

    // MARK: - Helpers

    private func uniqueDestination(in directory: URL, name: String) -> URL {
        let candidate = directory.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }
        let stamp = Int(Date().timeIntervalSince1970)
        return directory.appendingPathComponent("\(stamp)-\(name)")
    }
}

// MARK: - App integration

@MainActor
enum SentinelAppIntegration {
    private static var started = false

    /// Opens the runtime's write scope, attaches the live snapshot source and
    /// repair bridge, and starts the scheduler. Idempotent.
    static func start(dataStore: DataStore) async {
        guard !started else { return }
        guard let root = AppIdentity.dataRootURL() else { return }
        started = true

        // Recovery comes first: it may freeze the store before Sentinel ever
        // probes, and it owns the gate Sentinel must respect.
        let health = await LibraryHealthIntegration.start(
            dataStore: dataStore, dataRoot: root)

        let runtime = SentinelRuntime.shared
        await runtime.open(dataRoot: root)
        let environment = await runtime.environment
        await runtime.setSnapshotProvider(.live(environment: environment))
        await runtime.setBridge(LiveSentinelRepairBridge(store: dataStore))
        await runtime.setRecoveryGate(health)
        await runtime.setCandidateSink { candidate in
            await health?.handleSentinelCandidate(candidate)
        }
        health?.onRecoveryResolved = {
            await runtime.runRecoveryVerification()
        }
        await runtime.start()
    }

    static func stop() async {
        await SentinelRuntime.shared.stop()
        started = false
    }
}

enum SentinelHealthCenterWindowID {
    static let id = "sentinel-health-center"
}
