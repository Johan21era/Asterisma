//  SentinelCatalogTests.swift
//  AsterismaV2.5Tests
//
//  SG2/SG5 catalog pins: every probe has a valid descriptor and complete copy,
//  contributes no false positive on a clean empty library, leaks no user text,
//  and returns evidence-shaped findings on a deliberately damaged fixture.

import Foundation
import GRDB
import Testing

@testable import AsterismaV2_5

@Suite("Sentinel Probe Catalog", .serialized)
struct SentinelCatalogTests {

    // MARK: - Descriptor contract

    @Test("Every descriptor is well-formed and has complete copy",
          arguments: SentinelProbeCatalog.descriptors)
    func descriptorContract(_ descriptor: SentinelProbeDescriptor) {
        let parts = descriptor.id.split(separator: "-")
        #expect(parts.count == 2)
        #expect(parts[0] == Substring(descriptor.domain.code))
        #expect(Int(parts[1]) != nil)
        #expect(descriptor.ruleVersion >= 1)
        #expect(descriptor.timeout > 0)
        #expect(!descriptor.title.isEmpty)
        #expect(!descriptor.what.isEmpty)
        #expect(!descriptor.rootCauseKey.isEmpty)
        #expect(descriptor.metadata.copy.isComplete, "\(descriptor.id) has incomplete copy")
        if descriptor.isRequired {
            #expect(descriptor.tier <= .t2, "\(descriptor.id) is required but slow")
        }
        if descriptor.role == .owner {
            #expect(descriptor.ownerProbeID == nil)
        } else {
            #expect(descriptor.ownerProbeID != nil)
        }
        if let repair = descriptor.repairID {
            #expect(SentinelRepairCatalog.implementedIDs.contains(repair),
                    "\(descriptor.id) points at unimplemented \(repair)")
            #expect(descriptor.riskClass.isMutation)
        } else {
            #expect(descriptor.riskClass == .r0)
            }
    }

    @Test("Probe ids and rule ids are unique")
    func uniqueIDs() {
        let descriptors = SentinelProbeCatalog.descriptors
        #expect(Set(descriptors.map(\.id)).count == descriptors.count)
    }

    @Test("Every contributor points at a real owner")
    func ownerReferences() {
        let ids = Set(SentinelProbeCatalog.descriptors.map(\.id))
        for descriptor in SentinelProbeCatalog.descriptors where descriptor.role != .owner {
            #expect(descriptor.ownerProbeID.map(ids.contains) == true)
        }
    }

    @Test("The catalog is the full first tranche across all 15 domains")
    func catalogScale() {
        #expect(SentinelProbeCatalog.descriptors.count == 140)
        #expect(SentinelProbeCatalog.domainCount == 15)
        #expect(SentinelProbeCatalog.requiredCount >= 55)
        #expect(SentinelRepairCatalog.implementedIDs.count >= 25)
    }

    // MARK: - False positives

    @Test("A clean empty library produces no findings at all")
    func emptyLibraryIsQuiet() async {
        let root = SentinelTempRoot()
        defer { root.remove() }
        let defaults = UserDefaults(suiteName: "sentinel.empty.\(UUID().uuidString)")!
        let snapshot = SentinelSnapshot.fixture(
            books: [],
            state: LibraryState(),
            dataRoot: root.url,
            generation: 1,
            now: sentinelTestNow,
            defaults: defaults,
            isDebug: true)
        let environment = SentinelEnvironment.test(
            clock: TestSentinelClock(sentinelTestNow),
            dataRoot: root.url,
            tempRoot: root.url,
            isDebug: true,
            capacity: 50_000_000_000)

        var findings: [RawFinding] = []
        for probe in SentinelProbeCatalog.all() {
            if let result = try? await probe.run(snapshot: snapshot, environment: environment) {
                findings.append(contentsOf: result)
            }
        }
        #expect(findings.isEmpty, "Unexpected findings: \(findings.map(\.ruleID.rawValue))")
    }

    // MARK: - Per-probe contract (one case per registry entry)

    private func registryProbe(for descriptor: SentinelProbeDescriptor) -> (any SentinelProbeV2)? {
        SentinelProbeCatalog.all().first { $0.descriptor.id == descriptor.id }
    }

    @Test("Every probe is silent on a clean install",
          arguments: SentinelProbeCatalog.descriptors)
    func cleanInstallIsQuiet(_ descriptor: SentinelProbeDescriptor) async throws {
        let probe = try #require(registryProbe(for: descriptor))
        let root = SentinelTempRoot()
        defer { root.remove() }
        let defaults = UserDefaults(suiteName: "sentinel.clean.\(UUID().uuidString)")!
        let snapshot = SentinelSnapshot.fixture(
            books: [], state: LibraryState(), dataRoot: root.url,
            now: sentinelTestNow, defaults: defaults, isDebug: true)
        let environment = SentinelEnvironment.test(
            clock: TestSentinelClock(sentinelTestNow), dataRoot: root.url,
            tempRoot: root.url, isDebug: true)
        let findings: [RawFinding]
        do {
            findings = try await probe.run(snapshot: snapshot, environment: environment)
        } catch is SentinelProbeUnavailable {
            return
        }
        #expect(findings.isEmpty, "\(descriptor.id) reported on a clean install")
    }

    @Test("Every probe is deterministic",
          arguments: SentinelProbeCatalog.descriptors)
    func determinism(_ descriptor: SentinelProbeDescriptor) async throws {
        let probe = try #require(registryProbe(for: descriptor))
        let root = SentinelTempRoot()
        defer { root.remove() }
        var book = sentinelBook(totalPages: 10, currentPage: 99)
        book.activeSessionID = UUID()
        book.collectionIDs = [UUID(), UUID()]
        let defaults = UserDefaults(suiteName: "sentinel.det.\(UUID().uuidString)")!
        let snapshot = SentinelSnapshot.fixture(
            books: [book], state: LibraryState(), dataRoot: root.url,
            now: sentinelTestNow, defaults: defaults, isDebug: true)
        let environment = SentinelEnvironment.test(
            clock: TestSentinelClock(sentinelTestNow), dataRoot: root.url,
            tempRoot: root.url, isDebug: true, capacity: 100_000_000)
        let first: [RawFinding]
        let second: [RawFinding]
        do {
            first = try await probe.run(snapshot: snapshot, environment: environment)
            second = try await probe.run(snapshot: snapshot, environment: environment)
        } catch is SentinelProbeUnavailable {
            return
        }
        #expect(first == second, "\(descriptor.id) produced different findings across two identical runs")
    }

    // MARK: - Privacy

    @Test("No probe puts user text into a safe summary or safe evidence")
    func privacyAcrossCatalog() async {
        let root = SentinelTempRoot()
        defer { root.remove() }
        let secret = "PRIVATE-BOOK-TITLE-\(UUID().uuidString)"
        let noteText = "PRIVATE-NOTE-\(UUID().uuidString)"
        var book = sentinelBook(title: secret, totalPages: 20, currentPage: 99)
        book.notes = [BookNote(bookID: book.id, pageNumber: 1, text: noteText)]
        book.series = "PRIVATE-SERIES-\(UUID().uuidString)"
        let state = LibraryState(collections: [BookCollection(name: "PRIVATE-COLLECTION")])

        let defaults = UserDefaults(suiteName: "sentinel.privacy.\(UUID().uuidString)")!
        let snapshot = SentinelSnapshot.fixture(
            books: [book], state: state, dataRoot: root.url,
            now: sentinelTestNow, defaults: defaults, isDebug: true)
        let environment = SentinelEnvironment.test(
            clock: TestSentinelClock(sentinelTestNow), dataRoot: root.url,
            tempRoot: root.url, isDebug: true, capacity: 50_000_000_000)

        for probe in SentinelProbeCatalog.all() {
            guard let findings = try? await probe.run(snapshot: snapshot, environment: environment) else { continue }
            for finding in findings {
                #expect(!finding.safeSummary.orEmpty.contains(secret))
                #expect(!finding.safeSummary.orEmpty.contains(noteText))
                for item in finding.evidence {
                    #expect(!item.safeValue.contains(secret))
                    #expect(!item.safeValue.contains(noteText))
                    #expect(!item.safeValue.contains("PRIVATE-COLLECTION"))
                    #expect(!item.labelKey.isEmpty)
                    #expect(!item.safeValue.isEmpty)
                }
            }
        }
    }

    @Test("Every probe keeps user text out of safe output",
          arguments: SentinelProbeCatalog.descriptors)
    func privacyPerProbe(_ descriptor: SentinelProbeDescriptor) async throws {
        let probe = try #require(registryProbe(for: descriptor))
        let root = SentinelTempRoot()
        defer { root.remove() }
        let secret = "PRIVATE-\(UUID().uuidString)"
        var book = sentinelBook(title: secret, totalPages: 20, currentPage: 99)
        book.notes = [BookNote(bookID: book.id, text: secret)]
        book.series = secret
        let defaults = UserDefaults(suiteName: "sentinel.priv.\(UUID().uuidString)")!
        let snapshot = SentinelSnapshot.fixture(
            books: [book], state: LibraryState(collections: [BookCollection(name: secret)]),
            dataRoot: root.url, now: sentinelTestNow, defaults: defaults, isDebug: true)
        let environment = SentinelEnvironment.test(
            clock: TestSentinelClock(sentinelTestNow), dataRoot: root.url,
            tempRoot: root.url, isDebug: true)
        guard let findings = try? await probe.run(snapshot: snapshot, environment: environment) else { return }
        for finding in findings {
            #expect(!finding.safeSummary.orEmpty.contains(secret))
            #expect(!finding.subjects.contains { $0.id.contains(secret) })
            for item in finding.evidence {
                #expect(!item.safeValue.contains(secret))
            }
        }
    }

    // MARK: - Damaged fixture

    @Test("A damaged library produces shaped, explainable findings")
    func damagedFixture() async throws {
        let root = SentinelTempRoot()
        defer { root.remove() }
        let covers = root.url.appendingPathComponent("covers", isDirectory: true)
        try FileManager.default.createDirectory(at: covers, withIntermediateDirectories: true)
        // An orphan cover with no matching book id.
        try Data([0xFF, 0xD8, 0xFF]).write(to: covers.appendingPathComponent("\(UUID().uuidString).jpg"))

        var book = sentinelBook(totalPages: 10, currentPage: 99)
        book.activeSessionID = UUID()
        book.notes = [
            BookNote(id: UUID(), bookID: UUID(), text: "orphan"),
            BookNote(id: UUID(), bookID: book.id, text: "a"),
        ]
        book.notes.append(book.notes[1])
        book.collectionIDs = [UUID(), UUID()]
        let negativeSession = ReadingSession(
            bookID: book.id,
            startTime: sentinelTestNow.addingTimeInterval(-600),
            endTime: sentinelTestNow.addingTimeInterval(-1200),
            startPage: 5,
            endPage: 2,
            pageTimes: [
                PageTiming(pageNumber: 2, startTime: sentinelTestNow,
                           endTime: sentinelTestNow.addingTimeInterval(-30)),
                PageTiming(pageNumber: 900, startTime: sentinelTestNow),
            ])
        book.sessions = [negativeSession]

        var zeroPageBook = sentinelBook(title: "Zero", totalPages: 0, currentPage: 0)
        zeroPageBook.currentPage = 0
        let state = LibraryState()

        let defaults = UserDefaults(suiteName: "sentinel.damaged.\(UUID().uuidString)")!
        let snapshot = SentinelSnapshot.fixture(
            books: [book, zeroPageBook], state: state, dataRoot: root.url,
            now: sentinelTestNow, defaults: defaults, isDebug: true)
        let environment = SentinelEnvironment.test(
            clock: TestSentinelClock(sentinelTestNow), dataRoot: root.url,
            tempRoot: root.url, isDebug: true, capacity: 100_000_000)

        var rules: Set<String> = []
        var findings: [RawFinding] = []
        for probe in SentinelProbeCatalog.all() {
            guard let produced = try? await probe.run(snapshot: snapshot, environment: environment) else { continue }
            findings.append(contentsOf: produced)
            rules.formUnion(produced.map(\.ruleID.rawValue))
        }

        #expect(rules.contains("LIB-003"))
        #expect(rules.contains("LIB-004"))
        #expect(rules.contains("LIB-005"))
        #expect(rules.contains("SES-001"))
        #expect(rules.contains("SES-002"))
        #expect(rules.contains("SES-006"))
        #expect(rules.contains("CAP-001"))
        #expect(rules.contains("BAK-001"))
        #expect(rules.contains("FILE-004"))

        for finding in findings {
            #expect(!finding.subjects.isEmpty, "\(finding.ruleID) had no subjects")
            #expect(!finding.evidence.isEmpty, "\(finding.ruleID) had no evidence")
            #expect(finding.confidence >= 0 && finding.confidence <= 1)
            #expect(!finding.safeSummary.orEmpty.isEmpty)
        }
    }

    // MARK: - Performance

    @Test("Fast pass on a 70-book library stays inside the 50 ms budget")
    func fastPassBudget() async {
        let root = SentinelTempRoot()
        defer { root.remove() }
        let books = (0..<70).map { _ in sentinelBook(totalPages: 300, currentPage: 40) }
        let defaults = UserDefaults(suiteName: "sentinel.perf.\(UUID().uuidString)")!
        let snapshot = SentinelSnapshot.fixture(
            books: books, dataRoot: root.url, now: sentinelTestNow,
            defaults: defaults, isDebug: true)
        let environment = SentinelEnvironment.test(
            clock: TestSentinelClock(sentinelTestNow), dataRoot: root.url,
            tempRoot: root.url, isDebug: true, capacity: 100_000_000_000)
        let fast = SentinelProbeCatalog.all().filter { $0.descriptor.tier == .t0 || $0.descriptor.tier == .t1 }

        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            for probe in fast {
                _ = try? await probe.run(snapshot: snapshot, environment: environment)
            }
        }
        let milliseconds = Double(elapsed.components.attoseconds) / 1e15
        print("SENTINEL-FASTPASS-MS=\(String(format: "%.2f", milliseconds))")
        #expect(milliseconds < 50, "Fast pass took \(milliseconds) ms on a 70-book library")
    }

    // MARK: - SQL fixture

    @Test("SQL probes find real orphan rows and stay silent on a clean database")
    func sqliteFixture() async throws {
        let root = SentinelTempRoot()
        defer { root.remove() }
        let dbURL = root.url.appendingPathComponent("library.grdb.sqlite3")

        var config = Configuration()
        config.foreignKeysEnabled = false
        let queue = try DatabaseQueue(path: dbURL.path, configuration: config)
        try await queue.write { db in
            try db.execute(sql: "CREATE TABLE books (id TEXT PRIMARY KEY)")
            try db.execute(sql: "CREATE TABLE sessions (id TEXT PRIMARY KEY, book_id TEXT)")
            try db.execute(sql: "CREATE TABLE page_times (id TEXT PRIMARY KEY, session_id TEXT, idx INTEGER, page_number INTEGER, start_time DOUBLE)")
            try db.execute(sql: "INSERT INTO books (id) VALUES ('b1')")
            try db.execute(sql: "INSERT INTO sessions (id, book_id) VALUES ('s1', 'b1')")
            try db.execute(sql: "INSERT INTO page_times (id, session_id, idx, page_number, start_time) VALUES ('t1','s1',0,1,0)")
        }
        try queue.close()

        let snapshot = SentinelSnapshot.fixture(
            books: [], dataRoot: root.url, now: sentinelTestNow, isDebug: true)
        let environment = SentinelEnvironment.test(
            clock: TestSentinelClock(sentinelTestNow), dataRoot: root.url,
            tempRoot: root.url, isDebug: true)

        let orphanTimings = try await SES015OrphanTimingRows()
            .run(snapshot: snapshot, environment: environment)
        let orphanSessions = try await SES016OrphanSessionRows()
            .run(snapshot: snapshot, environment: environment)
        let integrity = try await SQL001IntegrityCheck()
            .run(snapshot: snapshot, environment: environment)
        #expect(orphanTimings.isEmpty)
        #expect(orphanSessions.isEmpty)
        #expect(integrity.isEmpty)

        // Add a dangling row.
        let queue2 = try DatabaseQueue(path: dbURL.path)
        try await queue2.write { db in
            try db.execute(sql: "INSERT INTO page_times (id, session_id, idx, page_number, start_time) VALUES ('t2','missing',0,1,0)")
            try db.execute(sql: "INSERT INTO sessions (id, book_id) VALUES ('s2','missing')")
        }
        try queue2.close()

        let timings = try await SES015OrphanTimingRows()
            .run(snapshot: snapshot, environment: environment)
        let sessions = try await SES016OrphanSessionRows()
            .run(snapshot: snapshot, environment: environment)
        #expect(timings.count == 1)
        #expect(sessions.count == 1)
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
