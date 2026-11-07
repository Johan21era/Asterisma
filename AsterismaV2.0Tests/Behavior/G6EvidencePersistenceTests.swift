import Foundation
import Testing
@testable import AsterismaV2_0

@Suite("G6 · Evidence persistence", .serialized)
@MainActor
final class G6EvidencePersistenceTests {

    @Test("Behavioral evidence archive loads application sessions on init")
    func archiveLoads() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("behavior-evidence.json")

        let app = ApplicationDescriptor(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            processIdentifier: 1,
            category: .browsing,
            executableURL: nil)
        let session = ApplicationUsageSession(
            application: app,
            startTime: Date().addingTimeInterval(-300),
            endTime: Date())
        let archive = BehaviorContextAccessKit.BehaviorEvidenceArchive(
            events: [],
            applicationSessions: [session],
            inactivityRecords: [],
            deviceStateEvents: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(archive).write(to: url)

        let kit = BehaviorContextAccessKit(archiveURL: url)
        #expect(kit.applicationSessions.count == 1)
        #expect(kit.applicationSessions.first?.application.applicationName == "Safari")
    }

    @Test("SQLite is the live store and JSON is only the import seed")
    func sqliteIsLiveStore() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let database = try LibraryDatabase(
            url: dir.appendingPathComponent("library.grdb.sqlite3"))
        let jsonURL = dir.appendingPathComponent("behavior-evidence.json")

        let safari = ApplicationDescriptor(
            applicationName: "Safari",
            bundleIdentifier: "com.apple.Safari",
            processIdentifier: 1,
            category: .browsing,
            executableURL: nil)
        let safariSession = ApplicationUsageSession(
            application: safari,
            startTime: Date().addingTimeInterval(-300),
            endTime: Date())
        try writeArchive(applicationSessions: [safariSession], to: jsonURL)

        let first = BehaviorContextAccessKit(archiveURL: jsonURL, database: database)
        #expect(first.applicationSessions.first?.application.applicationName == "Safari")
        let counts = try database.behaviorEvidenceCounts()
        #expect(counts.sessions == 1)

        // Replace the JSON seed with a different app. A second kit must read
        // the SQLite rows, not the file, or JSON is still the live store.
        let chrome = ApplicationDescriptor(
            applicationName: "Chrome",
            bundleIdentifier: "com.google.Chrome",
            processIdentifier: 2,
            category: .browsing,
            executableURL: nil)
        let chromeSession = ApplicationUsageSession(
            application: chrome,
            startTime: Date().addingTimeInterval(-200),
            endTime: Date())
        try writeArchive(applicationSessions: [chromeSession], to: jsonURL)

        let second = BehaviorContextAccessKit(archiveURL: jsonURL, database: database)
        #expect(second.applicationSessions.first?.application.applicationName == "Safari")
    }

    private func writeArchive(
        applicationSessions: [ApplicationUsageSession],
        to url: URL
    ) throws {
        let archive = BehaviorContextAccessKit.BehaviorEvidenceArchive(
            events: [],
            applicationSessions: applicationSessions,
            inactivityRecords: [],
            deviceStateEvents: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(archive).write(to: url, options: .atomic)
    }
}
