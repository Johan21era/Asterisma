//  SentinelProbesSubsystems.swift
//  AsterismaV2.5
//
//  AUD + BHV + MIR + APP — the subsystems around the library.
//
//  Ownership rules:
//    • Mirage is read-only territory. These probes may open its identity map and
//      ledger read-only and may inspect Sentinel's own records for stray Mirage
//      paths. They never write, move, or repair anything under Mirage.
//    • Missing optional sources return nothing; a *present but corrupt* source
//      is a finding. Silence is never assumed.
//    • Evidence carries counts, booleans, dates, and hashed paths only. Titles,
//      listening metadata, and application names stay out of the safe journal.

import Darwin
import Foundation

// MARK: - File-local helpers

private func subsystemsDate(_ value: Any?) -> Date? {
    if let number = value as? Double {
        return Date(timeIntervalSince1970: number)
    }
    if let number = value as? NSNumber {
        return Date(timeIntervalSince1970: number.doubleValue)
    }
    guard let text = value as? String else { return nil }
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFraction.date(from: text) { return date }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: text)
}

private func subsystemsJSONObject(_ url: URL?) -> [String: Any]? {
    guard let url, let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

private func subsystemsJSONArray(_ url: URL?) -> [Any]? {
    guard let url, let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [Any]
}

/// Mirage's stratum is `.../mirage/`; older notes call it `Mirage/`. Check both
/// without ever creating either.
private func subsystemsMirageRoot(_ snapshot: SentinelSnapshot) -> URL? {
    guard let dataRoot = snapshot.dataRoot else { return nil }
    let candidates = [
        dataRoot.appendingPathComponent("mirage", isDirectory: true),
        dataRoot.appendingPathComponent("Mirage", isDirectory: true),
    ]
    if let existing = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
        return existing
    }
    return nil
}

private func subsystemsFileText(_ url: URL) -> String? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return String(data: data, encoding: .utf8)
}

private func subsystemsPlanFiles(_ snapshot: SentinelSnapshot) -> [URL] {
    guard let dataRoot = snapshot.dataRoot else { return [] }
    let plans = dataRoot.appendingPathComponent("Sentinel/plans", isDirectory: true)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: plans.path)) ?? []
    return names.filter { $0.hasSuffix(".json") }.map { plans.appendingPathComponent($0) }
}

private func subsystemsRecordFiles(_ snapshot: SentinelSnapshot) -> [URL] {
    guard let dataRoot = snapshot.dataRoot else { return [] }
    let sentinel = dataRoot.appendingPathComponent("Sentinel", isDirectory: true)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: sentinel.path)) ?? []
    return names
        .filter { $0.hasSuffix(".json") }
        .map { sentinel.appendingPathComponent($0) }
}

// MARK: - AUD

nonisolated struct AUD001AudioProfilesDecodable: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "AUD-001", domain: .audio,
        title: "The audio profile store cannot be read",
        what: "The audio profile archive exists but is not a valid array of profiles.",
        rootCauseKey: "audio.archive", tier: .t2, isRequired: false,
        defaultSeverity: .warning, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard let url = snapshot.audioProfilesURL,
              SentinelProbeSupport.fileExists(url) else { return [] }
        guard let array = subsystemsJSONArray(url) else {
            return [SentinelProbeSupport.finding(
                descriptor,
                subjects: [SentinelSubject(.profile, "audio")],
                evidence: [
                    SentinelProbeSupport.flag("evidence.aud001.decodable", false, at: environment.now, source: .fileSystem),
                    SentinelProbeSupport.bytes("evidence.aud001.size", SentinelProbeSupport.fileSize(url) ?? 0, at: environment.now),
                ],
                debug: "file=\(SentinelProbeSupport.hashedPath(url))")]
        }
        let validRows = array.filter { $0 is [String: Any] }
        guard validRows.count == array.count else {
            return [SentinelProbeSupport.finding(
                descriptor,
                subjects: [SentinelSubject(.profile, "audio")],
                evidence: [
                    SentinelProbeSupport.count("evidence.aud001.invalidRows", array.count - validRows.count, at: environment.now, source: .fileSystem),
                    SentinelProbeSupport.count("evidence.aud001.rows", array.count, at: environment.now, source: .fileSystem),
                ],
                debug: "file=\(SentinelProbeSupport.hashedPath(url))")]
        }
        return []
    }
}

nonisolated struct AUD002DuplicateSessionProfiles: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "AUD-002", domain: .audio,
        title: "A session has more than one audio profile",
        what: "Two audio profiles claim the same reading session, so one silently replaces the other.",
        rootCauseKey: "audio.duplicate", tier: .t2, isRequired: false,
        defaultSeverity: .warning, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard let url = snapshot.audioProfilesURL,
              SentinelProbeSupport.fileExists(url),
              let array = subsystemsJSONArray(url) else { return [] }
        var counts: [String: Int] = [:]
        for row in array {
            guard let object = row as? [String: Any],
                  let session = object["sessionID"] as? String else { continue }
            counts[session, default: 0] += 1
        }
        return counts.filter { $0.value > 1 }.map { session, count in
            SentinelProbeSupport.finding(
                descriptor,
                subjects: [SentinelSubject(.profile, session)],
                evidence: [SentinelProbeSupport.count("evidence.aud002.duplicates", count, at: environment.now, source: .fileSystem)],
                debug: "session=\(session)")
        }
    }
}

nonisolated struct AUD003ImplausibleDuration: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "AUD-003", domain: .audio,
        title: "An audio profile reports an impossible duration",
        what: "Audio time is longer than the session it belongs to, or a profile is a few seconds long.",
        rootCauseKey: "audio.duration", tier: .t2, isRequired: false,
        defaultSeverity: .info, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard let url = snapshot.audioProfilesURL,
              SentinelProbeSupport.fileExists(url),
              let array = subsystemsJSONArray(url) else { return [] }
        var findings: [RawFinding] = []
        for row in array {
            guard let object = row as? [String: Any],
                  let session = object["sessionID"] as? String,
                  let sessionDuration = object["sessionDuration"] as? Double else { continue }
            let audioDuration = object["totalAudioDuration"] as? Double ?? 0
            guard sessionDuration < 5 || audioDuration > sessionDuration + 1 else { continue }
            findings.append(SentinelProbeSupport.finding(
                descriptor,
                subjects: [SentinelSubject(.profile, session)],
                evidence: [
                    SentinelProbeSupport.aggregate("evidence.aud003.sessionSeconds", String(format: "%.1f", sessionDuration), at: environment.now, source: .fileSystem),
                    SentinelProbeSupport.aggregate("evidence.aud003.audioSeconds", String(format: "%.1f", audioDuration), at: environment.now, source: .fileSystem),
                ],
                debug: "session=\(session)"))
        }
        return findings
    }
}

nonisolated struct AUD004OrphanProfiles: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "AUD-004", domain: .audio,
        title: "An audio profile belongs to no session",
        what: "A stored audio profile points at a reading session that no longer exists.",
        rootCauseKey: "audio.orphan", tier: .t3, isRequired: false,
        defaultSeverity: .info, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard let url = snapshot.audioProfilesURL,
              SentinelProbeSupport.fileExists(url),
              let array = subsystemsJSONArray(url) else { return [] }
        let sessions = snapshot.sessionIDs
        var orphans: [String] = []
        for row in array {
            guard let object = row as? [String: Any],
                  let sessionText = object["sessionID"] as? String,
                  let sessionID = UUID(uuidString: sessionText) else { continue }
            if !sessions.contains(sessionID) { orphans.append(sessionText) }
        }
        return orphans.map { session in
            SentinelProbeSupport.finding(
                descriptor,
                subjects: [SentinelSubject(.profile, session)],
                evidence: [SentinelProbeSupport.flag("evidence.aud004.sessionExists", false, at: environment.now, source: .fileSystem)],
                debug: "session=\(session)")
        }
    }
}

nonisolated struct AUD005UnboundedGrowth: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "AUD-005", domain: .audio,
        title: "The audio profile store keeps growing",
        what: "Audio profiles exceed the retention budget in count or file size.",
        rootCauseKey: "audio.growth", tier: .t3, isRequired: false,
        defaultSeverity: .info, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard let url = snapshot.audioProfilesURL,
              SentinelProbeSupport.fileExists(url) else { return [] }
        let count = subsystemsJSONArray(url)?.count ?? 0
        let size = SentinelProbeSupport.fileSize(url) ?? 0
        guard count > 5_000 || size > 20_000_000 else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.profile, "audio")],
            evidence: [
                SentinelProbeSupport.count("evidence.aud005.profiles", count, at: environment.now, source: .fileSystem),
                SentinelProbeSupport.bytes("evidence.aud005.size", size, at: environment.now),
            ],
            debug: "file=\(SentinelProbeSupport.hashedPath(url))")]
    }
}

// MARK: - BHV

nonisolated struct BHV001EvidenceArchiveDecodable: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "BHV-001", domain: .behavior,
        title: "The behavior archive cannot be read",
        what: "The behavior evidence archive exists but does not match its documented shape.",
        rootCauseKey: "behavior.archive", tier: .t2, isRequired: false,
        defaultSeverity: .warning, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard let url = snapshot.behaviorEvidenceURL,
              SentinelProbeSupport.fileExists(url) else { return [] }
        guard let object = subsystemsJSONObject(url),
              object["version"] as? Int != nil,
              object["events"] is [Any],
              object["applicationSessions"] is [Any] else {
            return [SentinelProbeSupport.finding(
                descriptor,
                subjects: [SentinelSubject(.profile, "behavior")],
                evidence: [
                    SentinelProbeSupport.flag("evidence.bhv001.decodable", false, at: environment.now, source: .fileSystem),
                    SentinelProbeSupport.bytes("evidence.bhv001.size", SentinelProbeSupport.fileSize(url) ?? 0, at: environment.now),
                ],
                debug: "file=\(SentinelProbeSupport.hashedPath(url))")]
        }
        return []
    }
}

nonisolated struct BHV002OrphanEvidence: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "BHV-002", domain: .behavior,
        title: "Behavior evidence belongs to no session",
        what: "An evidence event names a reading session that is not in the library.",
        rootCauseKey: "behavior.orphan", tier: .t3, isRequired: false,
        defaultSeverity: .info, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard let url = snapshot.behaviorEvidenceURL,
              SentinelProbeSupport.fileExists(url),
              let object = subsystemsJSONObject(url),
              let events = object["events"] as? [Any] else { return [] }
        let sessions = snapshot.sessionIDs
        var orphans = 0
        for row in events {
            guard let event = row as? [String: Any],
                  let metadata = event["metadata"] as? [String: Any],
                  let sessionText = metadata["sessionID"] as? String,
                  let sessionID = UUID(uuidString: sessionText) else { continue }
            if !sessions.contains(sessionID) { orphans += 1 }
        }
        guard orphans > 0 else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.profile, "behavior")],
            evidence: [SentinelProbeSupport.count("evidence.bhv002.orphanEvents", orphans, at: environment.now, source: .fileSystem)],
            debug: "file=\(SentinelProbeSupport.hashedPath(url))")]
    }
}

nonisolated struct BHV003Retention: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "BHV-003", domain: .behavior,
        title: "Behavior evidence is older than its retention policy",
        what: "Evidence older than a year is still stored, so the archive grows without adding value.",
        rootCauseKey: "behavior.retention", tier: .t3, isRequired: false,
        defaultSeverity: .info, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard let url = snapshot.behaviorEvidenceURL,
              SentinelProbeSupport.fileExists(url),
              let object = subsystemsJSONObject(url),
              let events = object["events"] as? [Any] else { return [] }
        let cutoff = environment.now.addingTimeInterval(-365 * 86_400)
        var stale = 0
        for row in events {
            guard let event = row as? [String: Any],
                  let date = subsystemsDate(event["timestamp"]) else { continue }
            if date < cutoff { stale += 1 }
        }
        guard stale > 0 else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.profile, "behavior")],
            evidence: [SentinelProbeSupport.count("evidence.bhv003.staleEvents", stale, at: environment.now, source: .fileSystem)],
            debug: "file=\(SentinelProbeSupport.hashedPath(url))")]
    }
}

nonisolated struct BHV004FabricatedSampling: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "BHV-004", domain: .behavior,
        title: "Behavior evidence is dated after its session",
        what: "An evidence event claims a time later than the session it describes, which would fabricate context.",
        rootCauseKey: "behavior.timestamp", tier: .t3, isRequired: false,
        defaultSeverity: .warning, defaultImpact: .medium)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard let url = snapshot.behaviorEvidenceURL,
              SentinelProbeSupport.fileExists(url),
              let object = subsystemsJSONObject(url),
              let events = object["events"] as? [Any] else { return [] }
        var sessions: [UUID: ReadingSession] = [:]
        for book in snapshot.books {
            for session in book.sessions { sessions[session.id] = session }
        }
        var findings: [RawFinding] = []
        for row in events {
            guard let event = row as? [String: Any],
                  let metadata = event["metadata"] as? [String: Any],
                  let sessionText = metadata["sessionID"] as? String,
                  let sessionID = UUID(uuidString: sessionText),
                  let session = sessions[sessionID],
                  let timestamp = subsystemsDate(event["timestamp"]),
                  let end = session.endTime else { continue }
            guard timestamp > end.addingTimeInterval(3600) else { continue }
            findings.append(SentinelProbeSupport.finding(
                descriptor,
                subjects: [SentinelSubject(.session, sessionText)],
                evidence: [
                    SentinelProbeSupport.timestamp("evidence.bhv004.event", timestamp, at: environment.now, source: .fileSystem),
                    SentinelProbeSupport.timestamp("evidence.bhv004.sessionEnd", end, at: environment.now),
                ],
                debug: "session=\(sessionText)"))
        }
        return findings
    }
}

nonisolated struct BHV005CorruptArchiveFallback: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "BHV-005", domain: .behavior,
        title: "Corrupt behavior evidence is not being surfaced",
        what: "The behavior archive cannot be decoded, so context reports risk being silently empty.",
        rootCauseKey: "behavior.corrupt", tier: .t2, isRequired: false,
        defaultSeverity: .warning, defaultImpact: .medium,
        riskClass: .r2, repairID: "REP-024")

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard let url = snapshot.behaviorEvidenceURL,
              SentinelProbeSupport.fileExists(url) else { return [] }
        guard let object = subsystemsJSONObject(url),
              object["events"] is [Any] else {
            return [SentinelProbeSupport.finding(
                descriptor,
                subjects: [SentinelSubject(.file, SentinelProbeSupport.hashedPath(url))],
                evidence: [
                    SentinelProbeSupport.flag("evidence.bhv005.decodable", false, at: environment.now, source: .fileSystem),
                    SentinelProbeSupport.bytes("evidence.bhv005.size", SentinelProbeSupport.fileSize(url) ?? 0, at: environment.now),
                ],
                debug: "file=\(SentinelProbeSupport.hashedPath(url))")]
        }
        return []
    }
}

// MARK: - MIR

nonisolated struct MIR001IdentityMapReadable: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "MIR-001", domain: .mirage,
        title: "Mirage's identity map cannot be read",
        what: "The identity map exists but does not have the documented schema and entries.",
        rootCauseKey: "mirage.identity-map", tier: .t2, isRequired: false,
        defaultSeverity: .warning, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard let root = subsystemsMirageRoot(snapshot) else { return [] }
        let url = root.appendingPathComponent("identity-map.json")
        guard SentinelProbeSupport.fileExists(url) else { return [] }
        guard let object = subsystemsJSONObject(url),
              object["schema"] is String,
              let entries = object["entries"] as? [Any] else {
            return [SentinelProbeSupport.finding(
                descriptor,
                subjects: [SentinelSubject(.file, SentinelProbeSupport.hashedPath(url))],
                evidence: [SentinelProbeSupport.flag("evidence.mir001.readable", false, at: environment.now, source: .fileSystem)],
                debug: "file=\(SentinelProbeSupport.hashedPath(url))")]
        }
        let malformed = entries.filter { row in
            guard let entry = row as? [String: Any] else { return true }
            return (entry["rtBookID"] as? String) == nil
                || (entry["mirageBookID"] as? String) == nil
                || (entry["status"] as? String) == nil
        }.count
        guard malformed > 0 else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.file, SentinelProbeSupport.hashedPath(url))],
            evidence: [SentinelProbeSupport.count("evidence.mir001.malformed", malformed, at: environment.now, source: .fileSystem)],
            debug: "file=\(SentinelProbeSupport.hashedPath(url))")]
    }
}

nonisolated struct MIR002UnknownSchema: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "MIR-002", domain: .mirage,
        title: "Mirage's identity map has an unknown schema",
        what: "The map's schema string is not the version this build understands; it should fail closed, visibly.",
        rootCauseKey: "mirage.schema", tier: .t2, isRequired: false,
        defaultSeverity: .warning, defaultImpact: .medium)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard let root = subsystemsMirageRoot(snapshot) else { return [] }
        let url = root.appendingPathComponent("identity-map.json")
        guard SentinelProbeSupport.fileExists(url),
              let object = subsystemsJSONObject(url),
              let schema = object["schema"] as? String else { return [] }
        guard schema != "mirage-identity-map@1" else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.file, SentinelProbeSupport.hashedPath(url))],
            evidence: [SentinelProbeSupport.aggregate("evidence.mir002.schema", schema, at: environment.now, source: .fileSystem)],
            summary: "Mirage's identity map uses a schema this build does not understand; the feature will stay unreadable rather than guess.")]
    }
}

nonisolated struct MIR003LedgerPresence: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "MIR-003", domain: .mirage,
        title: "Mirage's map has no backing ledger",
        what: "Identity-map entries exist but the Mirage ledger database is missing or has no recognizable tables.",
        rootCauseKey: "mirage.ledger", tier: .t3, isRequired: false,
        defaultSeverity: .warning, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard let root = subsystemsMirageRoot(snapshot) else { return [] }
        let mapURL = root.appendingPathComponent("identity-map.json")
        guard let object = subsystemsJSONObject(mapURL),
              let entries = object["entries"] as? [Any], !entries.isEmpty else { return [] }
        let ledger = root.appendingPathComponent("mirage.sqlite3")
        guard SentinelProbeSupport.fileExists(ledger) else {
            return [SentinelProbeSupport.finding(
                descriptor,
                subjects: [SentinelSubject(.database, "mirage")],
                evidence: [
                    SentinelProbeSupport.count("evidence.mir003.entries", entries.count, at: environment.now),
                    SentinelProbeSupport.flag("evidence.mir003.ledgerExists", false, at: environment.now, source: .fileSystem),
                ],
                debug: "ledger missing")]
        }
        let tableCount = try SentinelProbeSupport.readDatabase(at: ledger) { db in
            try SentinelProbeSupport.tableNames(in: db).count
        }
        guard tableCount == 0 else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.database, "mirage")],
            evidence: [SentinelProbeSupport.count("evidence.mir003.tables", tableCount, at: environment.now, source: .sqlite)],
            debug: "ledger has no tables")]
    }
}

nonisolated struct MIR004RuntimeMissing: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "MIR-004", domain: .mirage,
        title: "Mirage is enabled but its runtime is missing",
        what: "The switch is on, but no bundled runtime manifest can be found, so analysis cannot run.",
        rootCauseKey: "mirage.runtime", tier: .t2, isRequired: false,
        defaultSeverity: .warning, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        // A Debug/test build legitimately ships without the staged 47 MB runtime;
        // only a packaged Release is expected to carry it. Reporting it in a
        // development build would make every clean install look damaged.
        guard !environment.isDebug else { return [] }
        if snapshot.defaults.object(forKey: "mirage.enabled") as? Bool == false { return [] }

        let bundleRoot = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources", isDirectory: true)
        let candidates = [
            bundleRoot.appendingPathComponent("mirage-runtime", isDirectory: true),
            bundleRoot,
            snapshot.dataRoot?.appendingPathComponent("mirage-runtime", isDirectory: true),
            snapshot.dataRoot?.appendingPathComponent("mirage", isDirectory: true),
        ].compactMap { $0 }

        let found = candidates.contains {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("RUNTIME-MANIFEST.json").path)
                || FileManager.default.fileExists(atPath: $0.appendingPathComponent("examples/mirage_sidecar.py").path)
        }
        guard !found else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.subsystem, "mirage-runtime")],
            evidence: [SentinelProbeSupport.flag("evidence.mir004.manifestFound", false, at: environment.now, source: .fileSystem)],
            summary: "Mirage is turned on, but its analysis runtime is not present in this build. Nothing is broken in your library.")]
    }
}

nonisolated struct MIR005StaleGuardPID: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "MIR-005", domain: .mirage,
        title: "Mirage left a stale guard process file",
        what: "A guard pid file remains but the process it names is no longer running.",
        rootCauseKey: "mirage.guard", tier: .t2, isRequired: false,
        defaultSeverity: .info, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard let root = subsystemsMirageRoot(snapshot) else { return [] }
        let url = root.appendingPathComponent("guard.pid")
        guard let text = subsystemsFileText(url)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(text) else { return [] }
        guard pid > 0 else { return [] }
        errno = 0
        let alive = kill(pid, 0) == 0 || errno == EPERM
        guard !alive else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.file, SentinelProbeSupport.hashedPath(url))],
            evidence: [SentinelProbeSupport.flag("evidence.mir005.processAlive", false, at: environment.now, source: .fileSystem)],
            debug: "pid=\(pid)")]
    }
}

nonisolated struct MIR006NoPlanTouchesMirage: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "MIR-006", domain: .mirage,
        title: "A Sentinel plan would touch Mirage",
        what: "A stored repair plan references a Mirage path. Sentinel must never write there, even as an undo handle.",
        rootCauseKey: "mirage.boundary", tier: .t3, isRequired: false,
        defaultSeverity: .critical, defaultImpact: .high)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let plans = subsystemsPlanFiles(snapshot)
        var offending: [String] = []
        for plan in plans {
            guard let object = subsystemsJSONObject(plan),
                  let actions = object["actions"] as? [Any] else { continue }
            for row in actions {
                guard let action = row as? [String: Any],
                      let quarantine = action["quarantineFile"] as? [String: Any],
                      let source = quarantine["source"] as? String else { continue }
                if source.lowercased().contains("/mirage/") {
                    offending.append(SentinelProbeSupport.hashedPath(plan))
                }
            }
        }
        return offending.map { planHash in
            SentinelProbeSupport.finding(
                descriptor,
                subjects: [SentinelSubject(.file, planHash)],
                evidence: [SentinelProbeSupport.invariant("evidence.mir006.scope", "plan targets mirage stratum", at: environment.now)],
                debug: "plan=\(planHash)")
        }
    }
}

nonisolated struct MIR007DuplicateMappings: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "MIR-007", domain: .mirage,
        title: "Mirage maps one book twice",
        what: "Two active entries point at the same library book, or two entries reuse one Mirage book id.",
        rootCauseKey: "mirage.duplicate", tier: .t2, isRequired: false,
        defaultSeverity: .warning, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard let root = subsystemsMirageRoot(snapshot) else { return [] }
        let url = root.appendingPathComponent("identity-map.json")
        guard let object = subsystemsJSONObject(url),
              let entries = object["entries"] as? [Any] else { return [] }

        var activeBooks: [String: Int] = [:]
        var mirageBooks: [String: Int] = [:]
        for row in entries {
            guard let entry = row as? [String: Any],
                  (entry["status"] as? String) == "active" else { continue }
            if let book = entry["rtBookID"] as? String {
                activeBooks[book, default: 0] += 1
            }
            if let mirage = entry["mirageBookID"] as? String {
                mirageBooks[mirage, default: 0] += 1
            }
        }

        var findings: [RawFinding] = []
        for (book, count) in activeBooks where count > 1 {
            findings.append(SentinelProbeSupport.finding(
                descriptor,
                subjects: [SentinelSubject(.book, book)],
                evidence: [SentinelProbeSupport.count("evidence.mir007.activeForBook", count, at: environment.now, source: .fileSystem)],
                discriminator: "book",
                debug: "book=\(book)"))
        }
        for (mirage, count) in mirageBooks where count > 1 {
            findings.append(SentinelProbeSupport.finding(
                descriptor,
                subjects: [SentinelSubject(.file, "mirage-book:\(mirage)")],
                evidence: [SentinelProbeSupport.count("evidence.mir007.entriesForMirageBook", count, at: environment.now, source: .fileSystem)],
                discriminator: "mirage-book",
                debug: "mirageBook=\(mirage)"))
        }
        return findings
    }
}

nonisolated struct MIR008NoRecordTargetsMirage: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "MIR-008", domain: .mirage,
        title: "A Sentinel record points into Mirage",
        what: "Sentinel's own journal, repair records, or quarantine names reference the Mirage stratum.",
        rootCauseKey: "mirage.boundary", tier: .t3, isRequired: false,
        defaultSeverity: .critical, defaultImpact: .high)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard snapshot.dataRoot != nil else { return [] }
        var offending: [String] = []

        for file in subsystemsRecordFiles(snapshot) {
            guard let text = subsystemsFileText(file)?.lowercased() else { continue }
            if text.contains("/mirage/") || text.contains("mirage.sqlite3") {
                offending.append(file.lastPathComponent)
            }
        }

        let quarantine = snapshot.dataRoot?
            .appendingPathComponent("Sentinel/quarantine", isDirectory: true)
        for name in SentinelProbeSupport.directoryNames(quarantine) where name.lowercased().contains("mirage") {
            offending.append("quarantine:\(name)")
        }

        return offending.map { reference in
            SentinelProbeSupport.finding(
                descriptor,
                subjects: [SentinelSubject(.file, reference)],
                evidence: [SentinelProbeSupport.invariant("evidence.mir008.scope", "sentinel record targets mirage", at: environment.now)],
                debug: "reference=\(reference)")
        }
    }
}

// MARK: - APP

nonisolated struct APP001SelectedBookExists: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "APP-001", domain: .app,
        title: "The selected book is no longer in the library",
        what: "App state names a book that was removed, so the main surface can open empty.",
        rootCauseKey: "app.selection", tier: .t1,
        defaultSeverity: .info, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard let selected = snapshot.appFlags.selectedBookID,
              let id = UUID(uuidString: selected) else { return [] }
        guard !snapshot.books.contains(where: { $0.id == id }) else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.book, selected)],
            evidence: [SentinelProbeSupport.flag("evidence.app001.bookExists", false, at: environment.now)],
            debug: "selected=\(selected)")]
    }
}

nonisolated struct APP002OnboardingState: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "APP-002", domain: .app,
        title: "Onboarding says it is finished for an empty library",
        what: "Onboarding was dismissed but no books exist, so a required first step may have been skipped.",
        rootCauseKey: "app.onboarding", tier: .t1,
        defaultSeverity: .info, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard snapshot.books.isEmpty, snapshot.appFlags.onboardingDismissed else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.store, "app-state")],
            evidence: [
                SentinelProbeSupport.flag("evidence.app002.dismissed", true, at: environment.now),
                SentinelProbeSupport.count("evidence.app002.books", 0, at: environment.now),
            ],
            debug: "empty library with dismissed onboarding")]
    }
}

nonisolated struct APP003NotificationPermission: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "APP-003", domain: .app,
        title: "Notifications are wanted but not permitted",
        what: "The app believes notifications are on while the system has not granted permission.",
        rootCauseKey: "app.notifications", tier: .t2, isRequired: false,
        defaultSeverity: .warning, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let flags = snapshot.appFlags
        guard flags.notificationPermissionRequested, !flags.notificationPermissionGranted else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.store, "notifications")],
            evidence: [
                SentinelProbeSupport.flag("evidence.app003.requested", true, at: environment.now),
                SentinelProbeSupport.flag("evidence.app003.granted", false, at: environment.now),
            ],
            debug: "requested but denied")]
    }
}

nonisolated struct APP004StaleImportTemp: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "APP-004", domain: .app,
        title: "Stale import scratch files are left behind",
        what: "Temporary items from an import are older than a day and were never cleaned up.",
        rootCauseKey: "app.temp", tier: .t3, isRequired: false,
        defaultSeverity: .info, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: snapshot.tempRoot.path)) ?? []
        var stale: [String] = []
        for name in names where name.lowercased().contains("asterisma") {
            let url = snapshot.tempRoot.appendingPathComponent(name)
            guard let date = (try? manager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { continue }
            if environment.now.timeIntervalSince(date) > 86_400 {
                stale.append(name)
            }
        }
        guard !stale.isEmpty else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.file, "import-temp")],
            evidence: [
                SentinelProbeSupport.count("evidence.app004.staleItems", stale.count, at: environment.now, source: .fileSystem),
                SentinelProbeSupport.aggregate("evidence.app004.tempRoot", SentinelProbeSupport.hashedPath(snapshot.tempRoot), at: environment.now, source: .fileSystem),
            ],
            debug: "items=\(stale.count)")]
    }
}

nonisolated struct APP005DemoResidue: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "APP-005", domain: .app,
        title: "Demo artifacts remain in a real library",
        what: "The store is not in demo mode but still contains demo-named files.",
        rootCauseKey: "app.demo-residue", tier: .t1, isRequired: false,
        defaultSeverity: .warning, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard !snapshot.appFlags.demoModeActive, let root = snapshot.dataRoot else { return [] }
        let names = SentinelProbeSupport.directoryNames(root)
        let residue = names.filter { name in
            let lower = name.lowercased()
            return lower.contains("demo") && (lower.hasSuffix(".json") || lower.hasSuffix(".sqlite3"))
        }
        guard !residue.isEmpty else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.file, "demo-residue")],
            evidence: [SentinelProbeSupport.count("evidence.app005.files", residue.count, at: environment.now, source: .fileSystem)],
            summary: "Files from a demo profile are still in this library folder.",
            debug: "files=\(residue.count)")]
    }
}

nonisolated struct APP006ConfigValidity: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "APP-006", domain: .app,
        title: "A Sentinel setting is invalid",
        what: "The autonomy value is unknown or the cadence is outside its allowed range.",
        rootCauseKey: "app.config", tier: .t1,
        defaultSeverity: .warning, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        var problems: [String] = []
        if let raw = snapshot.defaults.string(forKey: "sentinel.autonomy.v2"),
           SentinelAutonomy(rawValue: raw) == nil {
            problems.append("autonomy")
        }
        let cadence = snapshot.defaults.integer(forKey: "sentinel.cadenceMinutes")
        if cadence != 0 && (cadence < 1 || cadence > 240) {
            problems.append("cadence")
        }
        guard !problems.isEmpty else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.store, "settings")],
            evidence: [SentinelProbeSupport.aggregate("evidence.app006.invalid", problems.joined(separator: ","), at: environment.now)],
            debug: "invalid=\(problems)")]
    }
}

nonisolated struct APP007TestStoreLeakage: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "APP-007", domain: .app,
        title: "A production session is running against a test store",
        what: "The data root is a test or temporary directory while the app is not in a test process.",
        rootCauseKey: "app.test-store", tier: .t0,
        defaultSeverity: .critical, defaultImpact: .high)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        // Tests are allowed to run against a test store; only a Release/real
        // session with a test root is a finding.
        guard !environment.isDebug, let root = snapshot.dataRoot else { return [] }
        let path = root.standardizedFileURL.path
        let leaked = path.contains("Asterisma-Tests-")
            || path.contains("Asterisma-UITests-")
            || path.contains("RT_TEST_STORE_DIR")
            || path.hasPrefix(NSTemporaryDirectory())
            || path.hasPrefix("/private/var/folders/")
            || path.hasPrefix("/var/folders/")
        guard leaked else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.store, "data-root")],
            evidence: [SentinelProbeSupport.flag("evidence.app007.testRoot", true, at: environment.now, source: .fileSystem)],
            debug: "root=\(SentinelProbeSupport.hashedPath(root))")]
    }
}

nonisolated struct APP008LaunchCrashLoop: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "APP-008", domain: .app,
        title: "The app has failed to launch repeatedly",
        what: "Three or more consecutive launches ended abnormally, which usually precedes a crash loop.",
        rootCauseKey: "app.launch", tier: .t0,
        defaultSeverity: .critical, defaultImpact: .high)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard snapshot.appFlags.launchFailureCount >= 3 else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.store, "app-launch")],
            evidence: [SentinelProbeSupport.count("evidence.app008.failures", snapshot.appFlags.launchFailureCount, at: environment.now)],
            debug: "failures=\(snapshot.appFlags.launchFailureCount)")]
    }
}

// MARK: - Catalog

nonisolated enum SentinelSubsystemProbes {
    static let all: [any SentinelProbeV2] = [
        AUD001AudioProfilesDecodable(),
        AUD002DuplicateSessionProfiles(),
        AUD003ImplausibleDuration(),
        AUD004OrphanProfiles(),
        AUD005UnboundedGrowth(),
        BHV001EvidenceArchiveDecodable(),
        BHV002OrphanEvidence(),
        BHV003Retention(),
        BHV004FabricatedSampling(),
        BHV005CorruptArchiveFallback(),
        MIR001IdentityMapReadable(),
        MIR002UnknownSchema(),
        MIR003LedgerPresence(),
        MIR004RuntimeMissing(),
        MIR005StaleGuardPID(),
        MIR006NoPlanTouchesMirage(),
        MIR007DuplicateMappings(),
        MIR008NoRecordTargetsMirage(),
        APP001SelectedBookExists(),
        APP002OnboardingState(),
        APP003NotificationPermission(),
        APP004StaleImportTemp(),
        APP005DemoResidue(),
        APP006ConfigValidity(),
        APP007TestStoreLeakage(),
        APP008LaunchCrashLoop(),
    ]
}
