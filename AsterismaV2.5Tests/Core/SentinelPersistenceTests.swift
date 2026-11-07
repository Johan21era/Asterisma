//  SentinelPersistenceTests.swift
//  AsterismaV2.5Tests
//
//  SG1 persistence pins:
//    • journal lines round-trip and reject tampering;
//    • segments rotate and prune without rewriting history;
//    • the v1 journal migrates instead of vanishing;
//    • the issue store survives a torn state file;
//    • memory can be rebuilt from journal evidence;
//    • legacy autonomy keys migrate exactly as §5.2 says.

import Foundation
import Testing

@testable import AsterismaV2_5

private let fixedNow = Date(timeIntervalSince1970: 1_767_225_600)

private func makeTempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("sentinel-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeIssue(
    rule: String = "LIB-001",
    subject: String = "book-a",
    status: SentinelIssueStatus = .open,
    severity: SentinelSeverity = .warning,
    evidence: [SentinelEvidence]? = nil,
    fingerprint: String? = nil
) -> SentinelIssue {
    let ruleID = SentinelRuleID(rule)
    let subjects = [SentinelSubject(.book, subject)]
    return SentinelIssue(
        fingerprint: fingerprint ?? SentinelFingerprint.make(ruleID: ruleID, subjects: subjects),
        ruleID: ruleID,
        ruleVersion: 1,
        rootCauseKey: "library.test",
        domain: .library,
        titleKey: "issue.test.title",
        status: status,
        severity: severity,
        confidence: 0.9,
        impact: .medium,
        subjects: subjects,
        evidence: evidence ?? [
            SentinelEvidence(kind: .count, labelKey: "evidence.count",
                             safeValue: "1", observedAt: fixedNow, source: .dataStore)
        ],
        safeSummary: "A test condition.",
        firstSeen: fixedNow,
        lastSeen: fixedNow,
        updatedAt: fixedNow)
}

private func makeEntry(
    sequence: Int,
    event: SentinelJournalEvent = .issueOpened,
    fingerprint: String? = nil,
    status: SentinelIssueStatus? = .open
) -> SentinelJournalEntry {
    SentinelJournalEntry(
        sequence: sequence,
        event: event,
        at: fixedNow.addingTimeInterval(Double(sequence)),
        cycleID: "cycle-\(sequence)",
        fingerprint: fingerprint,
        ruleID: "LIB-001",
        domain: "library",
        severity: "warning",
        status: status?.rawValue,
        ruleVersion: 1,
        rootCauseKey: "library.test",
        titleKey: "issue.test.title",
        counts: ["occurrences": 1],
        note: "A test condition.")
}

// MARK: - Journal

@Suite("Sentinel Journal V2", .serialized)
struct SentinelJournalV2Tests {

    @Test("Entries round-trip through a segment")
    func roundTrip() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = SentinelJournalV2(directory: dir, clock: TestSentinelClock(fixedNow))

        #expect(journal.append(makeEntry(sequence: 1)))
        #expect(journal.append(makeEntry(sequence: 2, event: .repairApplied)))

        let result = journal.readAll()
        #expect(result.entries.count == 2)
        #expect(result.corruptLines == 0)
        #expect(result.entries.map(\.sequence) == [1, 2])
        #expect(result.entries.last?.event == .repairApplied)
    }

    @Test("A tampered line is reported as corrupt, not trusted")
    func tamperDetection() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = SentinelJournalV2(directory: dir, clock: TestSentinelClock(fixedNow))
        journal.append(makeEntry(sequence: 1))

        let file = dir.appendingPathComponent("journal-000000.jsonl")
        var text = try String(contentsOf: file, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"warning\"", with: "\"critical\"")
        try text.write(to: file, atomically: true, encoding: .utf8)

        let result = journal.readAll()
        #expect(result.corruptLines == 1)
        #expect(result.entries.isEmpty)
    }

    @Test("Segments rotate at the configured size")
    func rotation() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = SentinelJournalV2(
            directory: dir, clock: TestSentinelClock(fixedNow),
            maxEntriesPerSegment: 100, maxSegments: 4)
        for index in 1...105 {
            journal.append(makeEntry(sequence: index))
        }
        let result = journal.readAll()
        #expect(result.segments == 2)
        #expect(result.entries.count == 105)
    }

    @Test("Old segments are pruned by count and the newest survives")
    func pruning() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = SentinelJournalV2(
            directory: dir, clock: TestSentinelClock(fixedNow),
            maxEntriesPerSegment: 100, maxSegments: 2)
        for index in 1...350 {
            journal.append(makeEntry(sequence: index))
        }
        let result = journal.readAll()
        #expect(result.segments == 2)
        // Whole segments are dropped, including a partially filled oldest one:
        // 350 entries of 100/segment leaves 100 + 50.
        #expect(result.entries.count == 150)
        #expect(result.entries.last?.sequence == 350)
    }

    @Test("Trimming by bytes keeps at least the newest segment")
    func byteTrim() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = SentinelJournalV2(
            directory: dir, clock: TestSentinelClock(fixedNow),
            maxEntriesPerSegment: 100, maxSegments: 5)
        for index in 1...350 {
            journal.append(makeEntry(sequence: index))
        }
        let removed = journal.trimToByteBudget(0)
        #expect(removed >= 1)
        let result = journal.readAll()
        #expect(result.segments == 1)
        #expect(!result.entries.isEmpty)
    }

    @Test("The v1 journal is imported and archived, never deleted")
    func migration() throws {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = dir.appendingPathComponent("sentinel-journal.jsonl")
        let lines = """
        {"cycle":true,"date":"2026-10-01T10:00:00Z","fixed":2,"stalled":1}
        {"id":"x","date":"2026-10-01T10:00:01Z","probe":"p","rule":"r","severity":"info","outcome":"stalled","userSummary":"s"}
        {"cycle":true,"date":"2026-10-01T11:00:00Z","fixed":0,"stalled":3}

        """
        try lines.write(to: legacy, atomically: true, encoding: .utf8)

        let journal = SentinelJournalV2(directory: dir.appendingPathComponent("journal"),
                                        clock: TestSentinelClock(fixedNow))
        let result = journal.migrateFromV1(at: legacy)
        #expect(result.importedCycles == 2)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(result.archivedAt.map { FileManager.default.fileExists(atPath: $0.path) } == true)

        let read = journal.readAll()
        #expect(read.entries.contains { $0.event == .migration })
        #expect(read.entries.first?.counts["cycles"] == 2)
    }

    @Test("An entry carries no free-form user text field")
    func noFreeFormText() throws {
        let entry = makeEntry(sequence: 1, fingerprint: "0123456789abcdef")
        let encoded = try JSONEncoder().encode(entry)
        let object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let keys = Set(object.keys)
        // The type has no field for titles, paths, messages, or note text.
        #expect(!keys.contains("title"))
        #expect(!keys.contains("path"))
        #expect(!keys.contains("message"))
        #expect(!keys.contains("userSummary"))
        #expect(keys.contains("ruleID"))
        #expect(keys.contains("fingerprint"))
    }
}

// MARK: - Issue store

@Suite("Sentinel Issue Store", .serialized)
struct SentinelIssueStoreTests {

    private func makeStore(_ dir: URL) -> SentinelIssueStore {
        let paths = SentinelPaths(root: dir.appendingPathComponent("Sentinel", isDirectory: true))
        let journal = SentinelJournalV2(directory: paths.journalDirectory,
                                         clock: TestSentinelClock(fixedNow))
        return SentinelIssueStore(paths: paths, clock: TestSentinelClock(fixedNow), journal: journal)
    }

    @Test("Issues survive a save and load")
    func roundTrip() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        let issues = [makeIssue(subject: "a"), makeIssue(subject: "b")]
        #expect(store.save(issues))

        let reloaded = store.load()
        #expect(reloaded.count == 2)
        #expect(Set(reloaded.map(\.fingerprint)) == Set(issues.map(\.fingerprint)))
        #expect(store.lastLoadOutcome == .loaded)
    }

    @Test("A torn state file falls back to the previous good copy")
    func backupRecovery() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)

        let first = [makeIssue(subject: "first")]
        #expect(store.save(first))
        #expect(store.save([makeIssue(subject: "second")]))

        // Simulate a partial write that replaced the authoritative file.
        let stateURL = dir.appendingPathComponent("Sentinel/state.json")
        try? Data("{ this is not json".utf8).write(to: stateURL)

        let reloaded = store.load()
        #expect(reloaded.count == 1)
        #expect(reloaded[0].subjects.first?.id == "first")
        #expect(store.lastLoadOutcome == .recoveredFromBackup)
    }

    @Test("With no state at all, the journal rebuilds identity")
    func journalRebuild() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        let issue = makeIssue()
        store.record(SentinelJournalEntry(
            sequence: 1, event: .issueOpened, at: fixedNow, cycleID: "c1",
            fingerprint: issue.fingerprint, ruleID: issue.ruleID.rawValue,
            domain: issue.domain.rawValue, severity: issue.severity.rawValue,
            status: issue.status.rawValue, ruleVersion: 1,
            rootCauseKey: issue.rootCauseKey, titleKey: issue.titleKey,
            counts: ["occurrences": 3], note: issue.safeSummary))

        let rebuilt = store.load()
        #expect(rebuilt.count == 1)
        #expect(rebuilt[0].fingerprint == issue.fingerprint)
        #expect(rebuilt[0].ruleID == issue.ruleID)
        #expect(rebuilt[0].occurrenceCount == 3)
        #expect(store.lastLoadOutcome == .rebuiltFromJournal)
    }

    @Test("Unusable fingerprints are dropped rather than deduped wrongly")
    func sanitizeBadFingerprint() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        store.save([makeIssue(fingerprint: "short")])
        #expect(store.load().isEmpty)
    }

    @Test("A warning issue without evidence is marked unactionable, not dropped")
    func sanitizeMissingEvidence() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        store.save([makeIssue(evidence: [])])
        let loaded = store.load()
        #expect(loaded.count == 1)
        #expect(loaded[0].status == .unactionable)
    }

    @Test("Archiving keeps a deliberate rebuild reversible")
    func archiveState() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        store.save([makeIssue()])
        let archived = store.archiveState(reason: "rebuild")
        #expect(archived != nil)
        #expect(archived.map { FileManager.default.fileExists(atPath: $0.path) } == true)
    }

    @Test("Sequence numbers never go backwards")
    func sequenceMonotonic() {
        let dir = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        store.record(makeEntry(sequence: 40))
        store.record(makeEntry(sequence: 12))
        #expect(store.sequence == 40)
        #expect(store.nextSequence() == 41)
    }
}

// MARK: - Configuration

@Suite("Sentinel Configuration")
struct SentinelConfigurationTests {

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "sentinel-config-\(UUID().uuidString)")!
    }

    @Test("Release defaults to Assist")
    func releaseDefault() {
        let config = SentinelConfiguration.load(from: defaults(), isDebug: false)
        #expect(config.autonomy == .assist)
        #expect(config.cadenceMinutes == 15)
    }

    @Test("Debug defaults to Auto-safe")
    func debugDefault() {
        #expect(SentinelConfiguration.load(from: defaults(), isDebug: true).autonomy == .autoSafe)
    }

    @Test("The legacy kill switch wins")
    func legacyKillSwitch() {
        let store = defaults()
        store.set(false, forKey: SentinelConfiguration.Keys.legacyEnabled)
        #expect(SentinelConfiguration.load(from: store, isDebug: true).autonomy == .off)
    }

    @Test("Legacy allowRepair false migrates to observe")
    func legacyObserve() {
        let store = defaults()
        store.set(false, forKey: SentinelConfiguration.Keys.legacyAllowRepair)
        #expect(SentinelConfiguration.load(from: store, isDebug: false).autonomy == .observe)
    }

    @Test("Legacy allowRepair true migrates to auto-safe")
    func legacyAutoSafe() {
        let store = defaults()
        store.set(true, forKey: SentinelConfiguration.Keys.legacyAllowRepair)
        #expect(SentinelConfiguration.load(from: store, isDebug: false).autonomy == .autoSafe)
    }

    @Test("The legacy interval migrates to cadence")
    func legacyInterval() {
        let store = defaults()
        store.set(30, forKey: SentinelConfiguration.Keys.legacyInterval)
        #expect(SentinelConfiguration.load(from: store, isDebug: false).cadenceMinutes == 30)
    }

    @Test("A saved configuration round-trips")
    func roundTrip() {
        let store = defaults()
        var config = SentinelConfiguration.default
        config.autonomy = .observe
        config.cadenceMinutes = 45
        config.quietHours = SentinelQuietHours(isEnabled: true, startHour: 23, endHour: 6)
        config.disabledDomains = [.weather, .audio]
        config.save(to: store)

        let loaded = SentinelConfiguration.load(from: store, isDebug: false)
        #expect(loaded.autonomy == .observe)
        #expect(loaded.cadenceMinutes == 45)
        #expect(loaded.quietHours.isEnabled)
        #expect(loaded.disabledDomains == [.weather, .audio])
    }

    @Test("Only auto-safe may act without a click, and only on R1")
    func autonomyPolicy() {
        #expect(SentinelAutonomy.autoSafe.allowsAutomatic(.r1))
        #expect(!SentinelAutonomy.autoSafe.allowsAutomatic(.r2))
        #expect(!SentinelAutonomy.autoSafe.allowsAutomatic(.r3))
        #expect(!SentinelAutonomy.assist.allowsAutomatic(.r1))
        #expect(!SentinelAutonomy.observe.allowsAutomatic(.r1))
        #expect(!SentinelAutonomy.off.allowsAutomatic(.r1))
    }

    @Test("Observe blocks even user-initiated changes")
    func observeBlocksManual() {
        #expect(!SentinelAutonomy.observe.allowsUserInitiated(.r1))
        #expect(SentinelAutonomy.assist.allowsUserInitiated(.r1))
        #expect(SentinelAutonomy.assist.allowsUserInitiated(.r2))
        #expect(!SentinelAutonomy.assist.allowsUserInitiated(.r3))
    }

    @Test("Quiet hours cross midnight")
    func quietHours() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let quiet = SentinelQuietHours(isEnabled: true, startHour: 22, endHour: 7)

        func hour(_ value: Int) throws -> Date {
            try #require(calendar.date(from: DateComponents(
                year: 2026, month: 10, day: 28, hour: value)))
        }

        #expect(try quiet.contains(hour(23), calendar: calendar))
        #expect(try quiet.contains(hour(3), calendar: calendar))
        #expect(try quiet.contains(hour(6), calendar: calendar))
        #expect(try !quiet.contains(hour(12), calendar: calendar))
        #expect(try !quiet.contains(hour(21), calendar: calendar))
    }

    @Test("Loader clamps nonsensical values")
    func clamping() {
        let store = defaults()
        store.set(-5, forKey: SentinelConfiguration.Keys.cadenceMinutes)
        store.set(0, forKey: SentinelConfiguration.Keys.journalMaxSegments)
        let config = SentinelConfiguration.load(from: store, isDebug: false)
        #expect(config.cadenceMinutes >= 1)
        #expect(config.journalMaxSegments >= 1)
    }
}
