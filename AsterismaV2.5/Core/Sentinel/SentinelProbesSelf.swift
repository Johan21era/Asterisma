//  SentinelProbesSelf.swift
//  AsterismaV2.5
//
//  SELF + SEC + CAP — the watchdog watching itself.
//
//  A Sentinel that cannot report its own damaged journal, stale memory, failed
//  repairs, coverage gaps, or write-scope escape is indistinguishable from a
//  healthy one. These probes are deliberately conservative: they read only
//  Sentinel-owned files, journal metadata, and filesystem facts. None of them
//  writes, and none of them claims to have checked something it could not read.
//
//  PRIVACY: SEC-001 is the only probe that touches user text, and it does so
//  entirely in memory to prove the safe journal contains none of it. Findings
//  report a count, never a matched string.

import Foundation

// MARK: - File-private journal reading

nonisolated private struct SelfProbeJournalRecord {
    var event: String
    var at: Date?
    var counts: [String: Int]
}

nonisolated private func selfProbeSentinelRoot(_ snapshot: SentinelSnapshot) -> URL? {
    snapshot.dataRoot?.appendingPathComponent("Sentinel", isDirectory: true)
}

nonisolated private func selfProbeJournalDirectory(_ snapshot: SentinelSnapshot) -> URL? {
    selfProbeSentinelRoot(snapshot)?.appendingPathComponent("journal", isDirectory: true)
}

nonisolated private func selfProbeJournalSegments(_ snapshot: SentinelSnapshot) -> [URL] {
    guard let directory = selfProbeJournalDirectory(snapshot) else { return [] }
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return names
        .filter { $0.hasPrefix("journal-") && $0.hasSuffix(".jsonl") }
        .sorted()
        .map { directory.appendingPathComponent($0) }
}

nonisolated private func selfProbeParseISO(_ text: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: text) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: text)
}

nonisolated private func selfProbeCounts(_ raw: Any?) -> [String: Int] {
    guard let dictionary = raw as? [String: Any] else { return [:] }
    var result: [String: Int] = [:]
    for (key, value) in dictionary {
        if let number = value as? NSNumber {
            result[key] = number.intValue
        } else if let integer = value as? Int {
            result[key] = integer
        }
    }
    return result
}

/// Reads the journal envelopes defensively. A line that is not a valid
/// envelope is ignored here; SELF-001 is the probe that reports corruption,
/// using the runtime's verified count rather than re-deriving it.
nonisolated private func selfProbeJournalRecords(_ snapshot: SentinelSnapshot) -> [SelfProbeJournalRecord] {
    var records: [SelfProbeJournalRecord] = []
    for url in selfProbeJournalSegments(snapshot) {
        guard let data = try? Data(contentsOf: url) else { continue }
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let body = object["body"] as? [String: Any],
                  let event = body["event"] as? String else { continue }
            let at = (body["at"] as? String).flatMap(selfProbeParseISO)
            records.append(SelfProbeJournalRecord(
                event: event,
                at: at,
                counts: selfProbeCounts(body["counts"])))
        }
    }
    return records.sorted { ($0.at ?? .distantPast) < ($1.at ?? .distantPast) }
}

nonisolated private func selfProbeDirectorySize(_ url: URL) -> Int64 {
    let manager = FileManager.default
    guard let enumerator = manager.enumerator(
        at: url,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
        options: []) else { return 0 }

    var total: Int64 = 0
    for case let file as URL in enumerator {
        let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else { continue }
        total += Int64(values?.fileSize ?? 0)
    }
    return total
}

nonisolated private func selfProbeJournalText(_ snapshot: SentinelSnapshot, maximumBytes: Int = 1_000_000) -> String {
    var text = ""
    var consumed = 0
    for url in selfProbeJournalSegments(snapshot) {
        guard consumed < maximumBytes,
              let data = try? Data(contentsOf: url) else { break }
        let slice = data.prefix(maximumBytes - consumed)
        consumed += slice.count
        text += String(decoding: slice, as: UTF8.self)
    }
    return text
}

/// Reads only the tail of the newest segment. SELF-008 is a T1 probe and must
/// not parse megabytes on every fast pass just to read one number.
nonisolated private func selfProbeLatestJournalRecord(
    _ snapshot: SentinelSnapshot,
    event: String
) -> SelfProbeJournalRecord? {
    guard let url = selfProbeJournalSegments(snapshot).last,
          let data = try? Data(contentsOf: url) else { return nil }
    let tail = data.suffix(64_000)
    let lines = tail.split(separator: 0x0A, omittingEmptySubsequences: true)
    for line in lines.reversed() {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              let body = object["body"] as? [String: Any],
              let bodyEvent = body["event"] as? String,
              bodyEvent == event else { continue }
        return SelfProbeJournalRecord(
            event: bodyEvent,
            at: (body["at"] as? String).flatMap(selfProbeParseISO),
            counts: selfProbeCounts(body["counts"]))
    }
    return nil
}

/// Oldest and newest record dates without parsing the whole journal. CAP-005
/// is a T2 probe and should cost metadata reads, not a full replay.
nonisolated private func selfProbeJournalDateRange(_ snapshot: SentinelSnapshot) -> (oldest: Date, newest: Date)? {
    let segments = selfProbeJournalSegments(snapshot)
    guard let firstURL = segments.first, let lastURL = segments.last,
          let firstData = try? Data(contentsOf: firstURL),
          let lastData = try? Data(contentsOf: lastURL) else { return nil }

    func firstDate(in data: Data, fromEnd: Bool) -> Date? {
        let slice = fromEnd ? data.suffix(64_000) : data.prefix(64_000)
        let lines = slice.split(separator: 0x0A, omittingEmptySubsequences: true)
        let ordered = fromEnd ? Array(lines.reversed()) : Array(lines)
        for line in ordered {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let body = object["body"] as? [String: Any],
                  let text = body["at"] as? String,
                  let date = selfProbeParseISO(text) else { continue }
            return date
        }
        return nil
    }

    guard let oldest = firstDate(in: firstData, fromEnd: false),
          let newest = firstDate(in: lastData, fromEnd: true),
          newest >= oldest else { return nil }
    return (oldest, newest)
}

// MARK: - SELF

/// The journal's verified corruption count. A damaged line means history is
/// incomplete even if every probe currently passes.
nonisolated struct SELF001JournalParse: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SELF-001", domain: .selfAudit,
        title: "Sentinel's journal has damaged lines",
        what: "One or more journal records failed their integrity check, so part of Sentinel's history cannot be trusted.",
        rootCauseKey: "self.journal-parse", tier: .t1,
        defaultSeverity: .warning, defaultImpact: .medium)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard snapshot.journalFacts.corruptLines > 0 else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.journal, "safe")],
            evidence: [
                SentinelProbeSupport.count(
                    "evidence.self001.corrupt",
                    snapshot.journalFacts.corruptLines,
                    at: environment.now,
                    source: .sentinel),
                SentinelProbeSupport.count(
                    "evidence.self001.segments",
                    snapshot.journalFacts.segmentCount,
                    at: environment.now,
                    source: .sentinel),
            ],
            debug: "corruptLines=\(snapshot.journalFacts.corruptLines)")]
    }
}

/// Issue memory must exist if issues were ever recorded. A missing or invalid
/// state file is exactly when a silent empty memory would look like "all clear".
nonisolated struct SELF002IssueStore: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SELF-002", domain: .selfAudit,
        title: "Sentinel's issue memory is missing or unreadable",
        what: "The durable issue file is absent or malformed even though journal records show issues were recorded.",
        rootCauseKey: "self.state", tier: .t1,
        defaultSeverity: .warning, defaultImpact: .medium,
        riskClass: .r1, repairID: "REP-016")

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard let root = selfProbeSentinelRoot(snapshot) else { return [] }
        let stateURL = root.appendingPathComponent("state.json")

        if !SentinelProbeSupport.fileExists(stateURL) {
            // Only the degraded path pays for a journal scan. The healthy path
            // is a single file-existence check.
            let recordedInJournal = selfProbeJournalRecords(snapshot)
                .filter { $0.event == "issueOpened" }
                .count
            guard recordedInJournal > 0 else { return [] }
            return [SentinelProbeSupport.finding(
                descriptor,
                subjects: [SentinelSubject(.store, "issue-state")],
                evidence: [
                    SentinelProbeSupport.flag("evidence.self002.stateExists", false, at: environment.now, source: .fileSystem),
                    SentinelProbeSupport.count("evidence.self002.journalIssues", recordedInJournal, at: environment.now, source: .sentinel),
                ],
                debug: "state.json missing; journal issues=\(recordedInJournal)")]
        }

        guard let object = SentinelProbeSupport.jsonObject(at: stateURL) else {
            return [SentinelProbeSupport.finding(
                descriptor,
                subjects: [SentinelSubject(.store, "issue-state")],
                evidence: [
                    SentinelProbeSupport.flag("evidence.self002.parses", false, at: environment.now, source: .fileSystem),
                ],
                debug: "state.json is not a JSON object")]
        }

        let hasSchema = object["schemaVersion"] != nil
        let hasIssues = object["issues"] != nil
        guard hasSchema && hasIssues else {
            return [SentinelProbeSupport.finding(
                descriptor,
                subjects: [SentinelSubject(.store, "issue-state")],
                evidence: [
                    SentinelProbeSupport.flag("evidence.self002.schema", hasSchema, at: environment.now, source: .fileSystem),
                    SentinelProbeSupport.flag("evidence.self002.issues", hasIssues, at: environment.now, source: .fileSystem),
                ],
                debug: "state.json missing schemaVersion or issues")]
        }

        return []
    }
}

/// A cycle that blew its budget is a leading indicator of a probe that will
/// eventually time out or block the launch card.
nonisolated struct SELF003CycleOverrun: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SELF-003", domain: .selfAudit,
        title: "Sentinel's last check ran long",
        what: "The previous cycle exceeded its time budget, so deeper checks may be crowding the fast path.",
        rootCauseKey: "self.cycle-budget", tier: .t1,
        defaultSeverity: .warning, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard snapshot.journalFacts.lastCycleOverranBudget else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.subsystem, "runtime")],
            evidence: [
                SentinelProbeSupport.aggregate(
                    "evidence.self003.durationSeconds",
                    String(format: "%.2f", snapshot.journalFacts.lastCycleDuration ?? 0),
                    at: environment.now,
                    source: .sentinel),
                SentinelProbeSupport.count(
                    "evidence.self003.probes",
                    snapshot.journalFacts.lastCycleProbeCount,
                    at: environment.now,
                    source: .sentinel),
            ],
            debug: "overranBudget=true")]
    }
}

/// One probe repeatedly failing is a broken detector, not a broken library.
nonisolated struct SELF004ProbeFailureRate: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SELF-004", domain: .selfAudit,
        title: "A Sentinel check keeps failing",
        what: "The same probe failed or timed out repeatedly, so its area is currently unchecked rather than healthy.",
        rootCauseKey: "self.probe-failure", tier: .t1,
        defaultSeverity: .warning, defaultImpact: .medium)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let failing = snapshot.journalFacts.consecutiveFailuresByProbe
            .filter { $0.value > 2 }
            .sorted { $0.key < $1.key }
        guard !failing.isEmpty else { return [] }
        return failing.map { entry in
            SentinelProbeSupport.finding(
                descriptor,
                subjects: [SentinelSubject(.subsystem, entry.key)],
                evidence: [
                    SentinelProbeSupport.count("evidence.self004.failures", entry.value, at: environment.now, source: .sentinel),
                    SentinelProbeSupport.aggregate("evidence.self004.probe", entry.key, at: environment.now, source: .sentinel),
                ],
                discriminator: entry.key,
                debug: "probe=\(entry.key) failures=\(entry.value)")
        }
    }
}

/// A repair that rolls back is the most important signal Sentinel can emit:
/// the fix did not hold. More than two in a week is a stop condition (§17.1).
nonisolated struct SELF005RepairFailureSpike: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SELF-005", domain: .selfAudit,
        title: "Sentinel repairs have been rolling back",
        what: "Several repairs failed verification and were reverted in the last week, which means the detector and the fix disagree.",
        rootCauseKey: "self.repair-failure", tier: .t2, isRequired: false,
        defaultSeverity: .critical, defaultImpact: .high)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard let root = selfProbeSentinelRoot(snapshot) else { return [] }
        let repairsURL = root.appendingPathComponent("repairs.json")
        guard let array = SentinelProbeSupport.jsonArray(at: repairsURL) else { return [] }

        let cutoff = environment.now.addingTimeInterval(-7 * 86_400)
        var rolledBack = 0
        for item in array {
            guard let dictionary = item as? [String: Any],
                  let status = dictionary["status"] as? String,
                  status == "rolledBack" else { continue }
            var appliedAt = environment.now
            if let raw = dictionary["appliedAt"] as? NSNumber {
                appliedAt = Date(timeIntervalSinceReferenceDate: raw.doubleValue)
            }
            if appliedAt >= cutoff { rolledBack += 1 }
        }

        guard rolledBack > 2 else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.subsystem, "repairs")],
            evidence: [
                SentinelProbeSupport.count("evidence.self005.rolledBack", rolledBack, at: environment.now, source: .sentinel),
                SentinelProbeSupport.count("evidence.self005.records", array.count, at: environment.now, source: .sentinel),
            ],
            debug: "rolledBackLastWeek=\(rolledBack)")]
    }
}

/// Sentinel's own footprint. The budget is 10 MB/month; a journal that big is
/// either a loop or a leak, and both are fixable without touching user data.
nonisolated struct SELF006JournalGrowth: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SELF-006", domain: .selfAudit,
        title: "Sentinel's journal is larger than its budget",
        what: "The safe journal has grown past ten megabytes, so old segments should be trimmed.",
        rootCauseKey: "self.journal-growth", tier: .t2, isRequired: false,
        defaultSeverity: .warning, defaultImpact: .low,
        riskClass: .r1, repairID: "REP-015")

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let budget: Int64 = 10 * 1_000_000
        guard snapshot.journalFacts.byteSize > budget else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.journal, "safe")],
            evidence: [
                SentinelProbeSupport.bytes("evidence.self006.bytes", snapshot.journalFacts.byteSize, at: environment.now, source: .sentinel),
                SentinelProbeSupport.bytes("evidence.self006.budget", budget, at: environment.now, source: .sentinel),
            ],
            debug: "bytes=\(snapshot.journalFacts.byteSize)")]
    }
}

/// A journal entry from the future means the clock moved, which makes every
/// age-based rule (orphan sessions, backup freshness) untrustworthy.
nonisolated struct SELF007ClockSkew: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SELF-007", domain: .selfAudit,
        title: "Sentinel's clock does not match its own records",
        what: "The newest journal entry is more than five minutes ahead of the current time.",
        rootCauseKey: "self.clock", tier: .t0,
        defaultSeverity: .warning, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard let newest = snapshot.journalFacts.lastEntryAt,
              newest > environment.now.addingTimeInterval(300) else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.subsystem, "clock")],
            evidence: [
                SentinelProbeSupport.timestamp("evidence.self007.newest", newest, at: environment.now, source: .sentinel),
                SentinelProbeSupport.timestamp("evidence.self007.now", environment.now, at: environment.now, source: .sentinel),
            ],
            debug: "newest is ahead of now")]
    }
}

/// Coverage honesty at the point of use: the previous cycle already told us
/// whether a required check was missing. This probe surfaces that gap as an
/// issue instead of leaving it buried in a report.
nonisolated struct SELF008CoverageGap: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SELF-008", domain: .selfAudit,
        title: "The last check did not finish",
        what: "One or more required checks did not run in the previous cycle, so the result was not a clean bill of health.",
        rootCauseKey: "self.coverage", tier: .t1,
        defaultSeverity: .warning, defaultImpact: .medium)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard let coverage = selfProbeLatestJournalRecord(snapshot, event: "coverage") else { return [] }
        let missing = coverage.counts["requiredMissing"] ?? 0
        guard missing > 0 else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.subsystem, "coverage")],
            evidence: [
                SentinelProbeSupport.count("evidence.self008.missing", missing, at: environment.now, source: .sentinel),
                SentinelProbeSupport.count(
                    "evidence.self008.total",
                    coverage.counts["total"] ?? 0,
                    at: environment.now,
                    source: .sentinel),
            ],
            debug: "requiredMissing=\(missing)")]
    }
}

/// If the kill switch is off, a running probe is a contradiction worth
/// reporting: either a timer survived `stop()` or something re-enabled work.
nonisolated struct SELF009KillSwitch: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SELF-009", domain: .selfAudit,
        title: "Sentinel checked while switched off",
        what: "The configuration says Sentinel is off, but a cycle still ran.",
        rootCauseKey: "self.kill-switch", tier: .t0,
        defaultSeverity: .info, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let autonomy = snapshot.defaults.string(forKey: "sentinel.autonomy.v2")
        guard autonomy == "off" else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.subsystem, "kill-switch")],
            evidence: [
                SentinelProbeSupport.aggregate("evidence.self009.autonomy", "off", at: environment.now, source: .sentinel),
            ],
            debug: "autonomy=off but probe ran")]
    }
}

/// Debug-only detail has its own retention. If it outgrows it, the honest fix
/// is to trim debug, never to touch the safe journal.
nonisolated struct SELF010DebugJournalGrowth: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SELF-010", domain: .selfAudit,
        title: "Sentinel's debug detail is over its budget",
        what: "The debug-only detail folder is larger than five megabytes and should be trimmed.",
        rootCauseKey: "self.debug-growth", tier: .t3, isRequired: false,
        defaultSeverity: .info, defaultImpact: .low,
        riskClass: .r1, repairID: "REP-020")

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard let root = selfProbeSentinelRoot(snapshot) else { return [] }
        let debug = root.appendingPathComponent("debug", isDirectory: true)
        guard SentinelProbeSupport.fileExists(debug) else { return [] }
        let size = selfProbeDirectorySize(debug)
        let budget: Int64 = 5 * 1_000_000
        guard size > budget else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.journal, "debug")],
            evidence: [
                SentinelProbeSupport.bytes("evidence.self010.bytes", size, at: environment.now, source: .fileSystem),
                SentinelProbeSupport.bytes("evidence.self010.budget", budget, at: environment.now, source: .fileSystem),
            ],
            debug: "debugBytes=\(size)")]
    }
}

// MARK: - SEC

/// The privacy promise, tested against the real journal. Matches are counted,
/// never reported. Titles under eight characters are ignored so a common word
/// cannot create a false accusation.
nonisolated struct SEC001JournalPrivacy: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SEC-001", domain: .security,
        title: "A private title reached Sentinel's journal",
        what: "Text from a book title or note appears in the safe journal, which must never contain user reading content.",
        rootCauseKey: "security.journal-privacy", tier: .t2, isRequired: false,
        defaultSeverity: .critical, defaultImpact: .high)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        var secrets: [String] = []
        for book in snapshot.books.prefix(50) {
            let title = book.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.count >= 8 { secrets.append(title) }
            for note in book.notes.prefix(10) {
                let text = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.count >= 8 { secrets.append(text) }
            }
            if secrets.count >= 100 { break }
        }
        guard !secrets.isEmpty else { return [] }

        let journal = selfProbeJournalText(snapshot)
        guard !journal.isEmpty else { return [] }

        var matched = 0
        for secret in secrets where journal.contains(secret) {
            matched += 1
        }
        guard matched > 0 else { return [] }

        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.journal, "safe")],
            evidence: [
                SentinelProbeSupport.count("evidence.sec001.matches", matched, at: environment.now, source: .sentinel),
                SentinelProbeSupport.count("evidence.sec001.scanned", secrets.count, at: environment.now, source: .sentinel),
            ],
            debug: "matches=\(matched)")]
    }
}

/// Every file Sentinel owns must resolve inside its own scope. A symlink that
/// escapes would let a future write land outside `Sentinel/`.
nonisolated struct SEC002WriteScope: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SEC-002", domain: .security,
        title: "A Sentinel file resolves outside its scope",
        what: "A file under Sentinel's folder resolves to a location outside that folder.",
        rootCauseKey: "security.write-scope", tier: .t2, isRequired: false,
        defaultSeverity: .critical, defaultImpact: .high)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard let root = selfProbeSentinelRoot(snapshot),
              SentinelProbeSupport.fileExists(root) else { return [] }
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []) else { return [] }

        var escapes: [URL] = []
        var inspected = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true || values?.isSymbolicLink == true else { continue }
            inspected += 1
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            if resolved != rootPath && !resolved.hasPrefix(rootPath + "/") {
                escapes.append(url)
            }
        }

        guard !escapes.isEmpty else { return [] }
        return escapes.prefix(20).map { url in
            SentinelProbeSupport.finding(
                descriptor,
                subjects: [SentinelSubject(.file, SentinelProbeSupport.hashedPath(url))],
                evidence: [
                    SentinelProbeSupport.count("evidence.sec002.inspected", inspected, at: environment.now, source: .fileSystem),
                    SentinelProbeSupport.aggregate(
                        "evidence.sec002.target",
                        SentinelProbeSupport.hashedPath(url.resolvingSymlinksInPath()),
                        at: environment.now,
                        source: .fileSystem),
                ],
                discriminator: SentinelProbeSupport.hashedPath(url),
                debug: "path=\(url.path)")
        }
    }
}

/// Sentinel never creates symlinks. Finding one is a tampering signal, and a
/// write through it could escape the scope entirely.
nonisolated struct SEC003SymlinkRejection: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SEC-003", domain: .security,
        title: "A symlink appeared in Sentinel's folder",
        what: "Sentinel's write scope contains a symbolic link, which it never creates.",
        rootCauseKey: "security.symlink", tier: .t2, isRequired: false,
        defaultSeverity: .critical, defaultImpact: .high)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard let root = selfProbeSentinelRoot(snapshot),
              SentinelProbeSupport.fileExists(root) else { return [] }
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []) else { return [] }

        var links: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values?.isSymbolicLink == true { links.append(url) }
        }

        guard !links.isEmpty else { return [] }
        return links.prefix(20).map { url in
            SentinelProbeSupport.finding(
                descriptor,
                subjects: [SentinelSubject(.file, SentinelProbeSupport.hashedPath(url))],
                evidence: [
                    SentinelProbeSupport.invariant("evidence.sec003.link", "symbolic link present", at: environment.now),
                ],
                discriminator: SentinelProbeSupport.hashedPath(url),
                debug: "path=\(url.path)")
        }
    }
}

/// Diagnostics export does not exist yet. Reporting a clean scan would be a lie,
/// so this probe returns nothing and says so here: when the export lands, it
/// gains a real redaction check and this comment is deleted.
nonisolated struct SEC004DiagnosticsRedaction: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SEC-004", domain: .security,
        title: "Diagnostics export redaction",
        what: "A shareable diagnostics bundle must not contain titles, paths, or locations.",
        rootCauseKey: "security.diagnostics", tier: .t3, isRequired: false,
        defaultSeverity: .info, defaultImpact: .medium)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        // There is no diagnostics bundle to scan yet. An empty result here means
        // "nothing to check", not "verified clean" — the rule is not required
        // for a clean band, so coverage stays honest.
        return []
    }
}

// MARK: - CAP

/// The floor that turns "saving is fine" into "saving is about to fail".
nonisolated struct CAP001LowDisk: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "CAP-001", domain: .capacity,
        title: "Disk space is running low",
        what: "Free space on the data volume is below five hundred megabytes, so saves and backups may start failing.",
        rootCauseKey: "capacity.disk", tier: .t1,
        defaultSeverity: .warning, defaultImpact: .high)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard let free = environment.freeSpace() else { return [] }
        let floor: Int64 = 500_000_000
        guard free < floor else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.store, "disk")],
            evidence: [
                SentinelProbeSupport.bytes("evidence.cap001.free", free, at: environment.now, source: .fileSystem),
                SentinelProbeSupport.bytes("evidence.cap001.floor", floor, at: environment.now),
            ],
            debug: "freeBytes=\(free)")]
    }
}

/// A projection, not a promise. Uses the database size as the monthly growth
/// proxy; with no database or no capacity there is nothing honest to project.
nonisolated struct CAP002DiskProjection: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "CAP-002", domain: .capacity,
        title: "The disk will fill at the current rate",
        what: "At the current database growth rate, free space is projected to run out within six months.",
        rootCauseKey: "capacity.projection", tier: .t3, isRequired: false,
        defaultSeverity: .info, defaultImpact: .medium)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard let free = environment.freeSpace(), free > 0,
              let databaseBytes = SentinelProbeSupport.fileSize(snapshot.databaseURL),
              databaseBytes > 0 else { return [] }

        // Database size is treated as one month of growth. Conservative on
        // purpose: it is a report, never a repair trigger.
        let dailyGrowth = Double(databaseBytes) / 30.0
        guard dailyGrowth > 1_000_000 else { return [] }
        let days = Double(free) / dailyGrowth
        guard days < 180 else { return [] }

        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.store, "disk")],
            evidence: [
                SentinelProbeSupport.bytes("evidence.cap002.free", free, at: environment.now, source: .fileSystem),
                SentinelProbeSupport.bytes("evidence.cap002.database", databaseBytes, at: environment.now, source: .fileSystem),
                SentinelProbeSupport.count("evidence.cap002.daysLeft", Int(days), at: environment.now, source: .sentinel),
            ],
            debug: "projectedDays=\(Int(days))")]
    }
}

/// Scale is not a defect by itself, but at some point the fast path stops being
/// fast. This is the early warning, not a complaint.
nonisolated struct CAP003LibraryScale: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "CAP-003", domain: .capacity,
        title: "The library has grown into a heavier tier",
        what: "Book, session, or page-timing counts are high enough that checks and analytics may feel slower.",
        rootCauseKey: "capacity.scale", tier: .t2, isRequired: false,
        defaultSeverity: .info, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let books = snapshot.books.count
        var sessions = 0
        var timings = 0
        for book in snapshot.books {
            sessions += book.sessions.count
            for session in book.sessions {
                timings += session.pageTimes.count
            }
        }
        guard timings > 250_000 || books > 2_000 else { return [] }

        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.store, "library")],
            evidence: [
                SentinelProbeSupport.count("evidence.cap003.books", books, at: environment.now),
                SentinelProbeSupport.count("evidence.cap003.sessions", sessions, at: environment.now),
                SentinelProbeSupport.count("evidence.cap003.timings", timings, at: environment.now),
            ],
            debug: "books=\(books) sessions=\(sessions) timings=\(timings)")]
    }
}

/// Backups are only useful with headroom to write them. Above half the free
/// space, the next backup is the thing that fills the disk.
nonisolated struct CAP004BackupHeadroom: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "CAP-004", domain: .capacity,
        title: "Backups are using too much free space",
        what: "The database plus its backups exceed half of the remaining free space.",
        rootCauseKey: "capacity.backup-headroom", tier: .t2, isRequired: false,
        defaultSeverity: .warning, defaultImpact: .high)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard let free = environment.freeSpace(), free > 0 else { return [] }
        let databaseBytes = SentinelProbeSupport.fileSize(snapshot.databaseURL) ?? 0
        let backupBytes = snapshot.backupsRoot.map { selfProbeDirectorySize($0) } ?? 0
        let total = databaseBytes + backupBytes
        guard total > free / 2 else { return [] }

        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.backup, "rotation")],
            evidence: [
                SentinelProbeSupport.bytes("evidence.cap004.combined", total, at: environment.now, source: .fileSystem),
                SentinelProbeSupport.bytes("evidence.cap004.free", free, at: environment.now, source: .fileSystem),
            ],
            debug: "combined=\(total) free=\(free)")]
    }
}

/// Growth is reported per day so a slow leak is visible before it becomes
/// SELF-006's flat ten-megabyte alarm.
nonisolated struct CAP005JournalGrowthRate: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "CAP-005", domain: .capacity,
        title: "Sentinel's journal is growing quickly",
        what: "The safe journal is accumulating more than half a megabyte per day.",
        rootCauseKey: "capacity.journal-growth", tier: .t2, isRequired: false,
        defaultSeverity: .info, defaultImpact: .low,
        riskClass: .r1, repairID: "REP-015")

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let bytes = snapshot.journalFacts.byteSize
        guard bytes > 0 else { return [] }

        guard let range = selfProbeJournalDateRange(snapshot), range.newest > range.oldest else { return [] }
        let days = max(range.newest.timeIntervalSince(range.oldest) / 86_400, 1.0 / 24.0)
        let megabytesPerDay = (Double(bytes) / 1_000_000) / days
        guard megabytesPerDay > 0.5 else { return [] }

        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.journal, "safe")],
            evidence: [
                SentinelProbeSupport.bytes("evidence.cap005.bytes", bytes, at: environment.now, source: .sentinel),
                SentinelProbeSupport.aggregate(
                    "evidence.cap005.megabytesPerDay",
                    String(format: "%.2f", megabytesPerDay),
                    at: environment.now,
                    source: .sentinel),
                SentinelProbeSupport.count("evidence.cap005.days", Int(days.rounded()), at: environment.now, source: .sentinel),
            ],
            debug: "mbPerDay=\(String(format: "%.2f", megabytesPerDay))")]
    }
}

// MARK: - Catalog

nonisolated enum SentinelSelfProbes {
    static let all: [any SentinelProbeV2] = [
        SELF001JournalParse(),
        SELF002IssueStore(),
        SELF003CycleOverrun(),
        SELF004ProbeFailureRate(),
        SELF005RepairFailureSpike(),
        SELF006JournalGrowth(),
        SELF007ClockSkew(),
        SELF008CoverageGap(),
        SELF009KillSwitch(),
        SELF010DebugJournalGrowth(),
        SEC001JournalPrivacy(),
        SEC002WriteScope(),
        SEC003SymlinkRejection(),
        SEC004DiagnosticsRedaction(),
        CAP001LowDisk(),
        CAP002DiskProjection(),
        CAP003LibraryScale(),
        CAP004BackupHeadroom(),
        CAP005JournalGrowthRate(),
    ]
}
