//  ReliabilityTests.swift
//  AsterismaV2.5Tests
//
//  Regression battery authored during the bug-fix session, mapped 1:1 onto
//  TESTING_STRATEGY.md's risk table and fix-log entries:
//
//    ValidatorTests            → Audit §3.3 gate input (pure functions)
//    DataStorePersistenceTests → §1.2 banner state · §3.3 auto-save gate · round-trip
//    LibraryMutationTests      → §2.1 identity-based removal contract
//    ObserverLifecycleTests    → §4.1 start/stop cycles must not stack observers
//
//  Every test names the defect class it pins in a comment, so a future failure
//  points straight at the regression that re-introduced it.

import Foundation
import Testing
import AppKit

@testable import AsterismaV2_5

// MARK: - ValidatorTests (Audit §3.3 — pure-function layer)

@Suite("DataIntegrityValidator")
struct ValidatorTests {

    private func makeBook(
        title: String = "T",
        totalPages: Int = 100,
        currentPage: Int = 10,
        activeSessionID: UUID? = nil,
        id: UUID = UUID()
    ) -> Book {
        var b = Book(id: id, title: title, author: "A", fileURL: URL(fileURLWithPath: "/tmp/x.pdf"), fileType: .pdf)
        b.totalPages = totalPages
        b.currentPage = currentPage
        b.activeSessionID = activeSessionID
        return b
    }

    @Test("Clean library reports clean")
    func cleanLibraryIsClean() {
        let (_, report) = DataIntegrityValidator.validate([makeBook()])
        #expect(report.isClean)
        #expect(!report.hasUnrepairableErrors)
    }

    @Test("Out-of-range currentPage is repaired, not fatal")
    func currentPageClampIsRepaired() {
        let (repaired, report) = DataIntegrityValidator.validate([makeBook(totalPages: 100, currentPage: 250)])
        // §3.3 gate input: repairs exist but nothing unrepaired — auto-save stays allowed.
        #expect(!report.isClean)
        #expect(!report.hasUnrepairableErrors)
        #expect(repaired[0].currentPage == 99)
    }

    @Test("totalPages ≤ 0 is flagged as UNREPAIRED — the §3.3 gate key")
    func zeroTotalPagesIsUnrepairable() {
        let (_, report) = DataIntegrityValidator.validate([makeBook(totalPages: 0)])
        #expect(!report.isClean)
        #expect(report.hasUnrepairableErrors)   // ← what DataStore.loadBooks branches on
    }

    @Test("Duplicate book IDs are unrepaired errors")
    func duplicateIDsAreUnrepairable() {
        let id = UUID()
        let (_, report) = DataIntegrityValidator.validate([makeBook(id: id), makeBook(id: id)])
        #expect(report.hasUnrepairableErrors)
    }

    @Test("Phantom activeSessionID is cleared as a repair")
    func phantomActiveSessionRepaired() {
        let ghost = UUID()
        let (repaired, report) = DataIntegrityValidator.validate([makeBook(activeSessionID: ghost)])
        #expect(repaired[0].activeSessionID == nil)
        #expect(!report.hasUnrepairableErrors)
    }
}

// MARK: - DataStorePersistenceTests (§1.2 + §3.3 — persistence surface)

@Suite("DataStore Persistence")
@MainActor
final class DataStorePersistenceTests {

    let dir: URL

    /// Fresh sandbox per test — mirrors WeatherSnapshotStoreTests' init/deinit pattern.
    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    private var libraryURL: URL { dir.appendingPathComponent("library.json") }

    private func writeLibrary(_ books: [Book]) throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(books)
        try data.write(to: libraryURL, options: .atomic)
        return data
    }

    private func makeBook(title: String, totalPages: Int = 100, currentPage: Int = 10) -> Book {
        var b = Book(title: title, author: "A", fileURL: URL(fileURLWithPath: "/tmp/\(title).pdf"), fileType: .pdf)
        b.totalPages = totalPages
        b.currentPage = currentPage
        return b
    }

    @Test("Round-trip: saveImmediately persists; fresh store reads it back")
    func roundTripPersistsAndReloads() throws {
        let url = libraryURL
        let store = DataStore(fileURL: url)
        store.addBook(makeBook(title: "Persist Me"))
        store.saveImmediately()

        let reopened = DataStore(fileURL: url)
        #expect(reopened.books.count == 1)
        #expect(reopened.books.first?.title == "Persist Me")
        #if DEBUG
        #expect(reopened.persistenceHealth == .healthy)
        #endif
    }

    @Test("§1.2: undecodable file → empty library + degraded health + .bak preserved")
    func corruptFileDegradesInsteadOfSilence() throws {
        try "not json {{{".write(to: libraryURL, atomically: true, encoding: .utf8)

        let store = DataStore(fileURL: libraryURL)

        #expect(store.books.isEmpty)
        #if DEBUG
        if case .degraded = store.persistenceHealth {
            // expected — silent would be the bug this pins
        } else {
            Issue.record("persistenceHealth should be degraded after unreadable file")
        }
        #endif
        let backupName = libraryURL.deletingPathExtension().appendingPathExtension("bak.json")
        #expect(FileManager.default.fileExists(atPath: backupName.path))
    }

    @Test("§3.3: unrepairable corruption is surfaced AND the source file is left untouched")
    func unrepairableCorruptionIsNotRepersisted() throws {
        // Decodes fine; validator flags totalPages≤0 as an unrepaired error.
        let original = try writeLibrary([makeBook(title: "Broken", totalPages: 0)])

        let store = DataStore(fileURL: libraryURL)

        #if DEBUG
        if case .degraded = store.persistenceHealth {
            // expected
        } else {
            Issue.record("unrepairable load must degrade persistenceHealth")
        }
        #endif
        // The gate: loadBooks must NOT auto-save over the last-good file.
        let onDisk = try Data(contentsOf: libraryURL)
        #expect(onDisk == original)
    }

    @Test("§3.3 companion: repairable-only loads still auto-save the fix")
    func repairableCorruptionAutosaves() throws {
        _ = try writeLibrary([makeBook(title: "Clamped", totalPages: 100, currentPage: 250)])

        _ = DataStore(fileURL: libraryURL)
        let reopened = DataStore(fileURL: libraryURL)

        #expect(reopened.books.first?.currentPage == 99)
    }
}

// MARK: - LibraryMutationTests (§2.1 — removal contract behind deleteItems)

@Suite("Library Mutation")
@MainActor
struct LibraryMutationTests {

    @Test("§2.1: removing by captured identities removes exactly those books")
    func removingByIdentitiesRemovesExactlyThoseBooks() {
        let store = DataStore(fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString + ".json"))

        for i in 0..<6 { store.addBook(Book(title: "Book \(i)", author: "A",
            fileURL: URL(fileURLWithPath: "/tmp/b\(i).pdf"), fileType: .pdf)) }

        // This mirrors ContentView.deleteItems' fixed logic: identities FIRST,
        // mutation SECOND — never indices into a shrinking array.
        let doomed: Set<UUID> = [store.books[2].id, store.books[5].id]
        doomed.forEach { store.removeBook(id: $0) }

        #expect(store.books.map(\.title).sorted() == ["Book 0", "Book 1", "Book 3", "Book 4"])
    }

    @Test("Duplicate fileURL imports are rejected (existing dedupe contract)")
    func duplicateImportRejected() {
        let store = DataStore(fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString + ".json"))
        let shared = URL(fileURLWithPath: "/tmp/same.pdf")
        store.addBook(Book(title: "One", author: "A", fileURL: shared, fileType: .pdf))
        store.addBook(Book(title: "Two", author: "A", fileURL: shared, fileType: .pdf))
        #expect(store.books.count == 1)
    }
}

// MARK: - ObserverLifecycleTests (§4.1 — the leak that multiplied evidence)

@Suite("BehaviorContextAccessKit Lifecycle")
@MainActor
final class ObserverLifecycleTests {

    @Test("§4.1: start/stop abuse cycles deliver each screen-lock exactly once")
    func startStopCyclesDoNotStackObservers() async throws {
        let kit = BehaviorContextAccessKit()


        // Hostile usage: every background/foreground transition used to stack
        // two zombie DistributedNotificationCenter observers per cycle.
        for _ in 0..<10 {
            kit.startMonitoring()
            kit.stopMonitoring()
        }
        kit.startMonitoring()               // leave in the 'foreground' state
        defer { kit.stopMonitoring() }

        let lockedName = NSNotification.Name("com.apple.screenIsLocked")
        let baseline = kit.events.filter { $0.eventType == .screenLocked }.count
        print("DIAG baseline=\(baseline) totalEvents=\(kit.events.count)")

        DistributedNotificationCenter.default().post(name: lockedName, object: nil)

        // Block-based observers deliver async on .main — poll briefly.
        var delivered = -999
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(50))
            delivered = kit.events.filter { $0.eventType == .screenLocked }.count - baseline
            if delivered >= 1 { break }
        }
        print("DIAG delivered=\(delivered) totalEvents=\(kit.events.count)")
        // Pre-fix, ten cycles meant this same event arrived ~10×.
        #expect(delivered == 1, "RESULT baseline=\(baseline) delivered=\(delivered) total=\(kit.events.count)")
    }

    @Test("§4.1/F-07: redundant startMonitoring (launch double-call) registers workspace observers exactly once")
    func redundantStartsDoNotDuplicateWorkspaceObservers() async throws {
        let kit = BehaviorContextAccessKit()

        // The launch sequence calls startMonitoring() twice with NO intervening
        // stop (.task binding + initial scenePhase change). Pre-F07, each Combine
        // registration path ran twice → one synthetic willSleep delivered TWO
        // DeviceStateEvents. Post-fix the re-entry gate makes it exactly one.
        kit.startMonitoring()
        kit.startMonitoring()
        defer { kit.stopMonitoring() }

        let baseline = kit.deviceStateEvents.filter { $0.state == .sleeping }.count

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.willSleepNotification, object: nil
        )

        var delivered = -1
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(50))
            delivered = kit.deviceStateEvents.filter { $0.state == .sleeping }.count - baseline
            if delivered >= 1 { break }
        }
        #expect(delivered == 1,
                "F-07 regression: synthetic sleep recorded \(delivered)× after double-start")
    }
}
