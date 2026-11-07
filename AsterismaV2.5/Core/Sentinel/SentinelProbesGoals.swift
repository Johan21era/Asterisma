//  SentinelProbesGoals.swift
//  AsterismaV2.5
//
//  GOL + COL — goals, achievements, collections, notes.
//
//  These are pure in-memory checks over the snapshot: no database, no file
//  metadata, no main thread. They are the cheapest probes in the catalog and
//  the ones most likely to catch a half-migrated library.

import Foundation

// MARK: - GOL

nonisolated struct GOL001DuplicateAchievements: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "GOL-001", domain: .goals,
        title: "An achievement was earned twice",
        what: "The library contains more than one earned record for the same achievement kind.",
        rootCauseKey: "goals.duplicate-achievement", tier: .t1,
        defaultSeverity: .warning, defaultImpact: .low,
        riskClass: .r1, repairID: "REP-009")

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        var groups: [String: [EarnedAchievement]] = [:]
        for achievement in snapshot.libraryState.earnedAchievements {
            groups[achievement.kind.rawValue, default: []].append(achievement)
        }
        return groups.filter { $0.value.count > 1 }.map { kind, achievements in
            SentinelProbeSupport.finding(
                descriptor,
                subjects: achievements.map { SentinelSubject(.achievement, $0.id.uuidString) },
                evidence: [
                    SentinelProbeSupport.count("evidence.gol001.records", achievements.count, at: environment.now),
                    SentinelProbeSupport.aggregate("evidence.gol001.kind", kind, at: environment.now),
                ],
                debug: "kind=\(kind) ids=\(achievements.map(\.id.uuidString))")
        }
    }
}

nonisolated struct GOL002UnknownAchievementKind: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "GOL-002", domain: .goals,
        title: "An earned achievement is not in the registry",
        what: "An earned achievement kind no longer has a definition, so its badge cannot be described.",
        rootCauseKey: "goals.unknown-achievement", tier: .t1, isRequired: false,
        defaultSeverity: .info, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        snapshot.libraryState.earnedAchievements.compactMap { achievement in
            guard AchievementDefinition.definition(for: achievement.kind) == nil else { return nil }
            return SentinelProbeSupport.finding(
                descriptor,
                subjects: [SentinelSubject(.achievement, achievement.id.uuidString)],
                evidence: [
                    SentinelProbeSupport.aggregate("evidence.gol002.kind", achievement.kind.rawValue, at: environment.now),
                ],
                debug: "achievement=\(achievement.id.uuidString)")
        }
    }
}

nonisolated struct GOL003AchievementMissingBook: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "GOL-003", domain: .goals,
        title: "An achievement points at a missing book",
        what: "An earned achievement references a book id that is not in the library.",
        rootCauseKey: "goals.achievement-book", tier: .t1, isRequired: false,
        defaultSeverity: .info, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let bookIDs = Set(snapshot.books.map(\.id))
        return snapshot.libraryState.earnedAchievements.compactMap { achievement in
            guard let bookID = achievement.relatedBookID, !bookIDs.contains(bookID) else { return nil }
            return SentinelProbeSupport.finding(
                descriptor,
                subjects: [SentinelSubject(.achievement, achievement.id.uuidString)],
                evidence: [
                    SentinelProbeSupport.record(.book, bookID.uuidString, key: "evidence.gol003.missing", at: environment.now),
                ],
                debug: "achievement=\(achievement.id.uuidString) book=\(bookID.uuidString)")
        }
    }
}

nonisolated struct GOL004ImpossibleGoalValues: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "GOL-004", domain: .goals,
        title: "A reading goal has an impossible target",
        what: "A goal target is zero or negative, so it can never be met meaningfully.",
        rootCauseKey: "goals.impossible-target", tier: .t1,
        defaultSeverity: .warning, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let goals = snapshot.libraryState.goalSet
        var problems: [(String, Int)] = []
        if let value = goals.dailyPageTarget, value <= 0 { problems.append(("daily-pages", value)) }
        if let value = goals.dailyTimeTarget, value <= 0 { problems.append(("daily-time", Int(value))) }
        if let value = goals.annualBookTarget, value <= 0 { problems.append(("annual-books", value)) }
        if let value = goals.weeklyReadingDays, value <= 0 || value > 7 {
            problems.append(("weekly-days", value))
        }
        guard !problems.isEmpty else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.store, "goals")],
            evidence: problems.map {
                SentinelProbeSupport.aggregate("evidence.gol004.\($0.0)", "\($0.1)", at: environment.now)
            },
            debug: problems.map { "\($0.0)=\($0.1)" }.joined(separator: ","))]
    }
}

nonisolated struct GOL005DeadlineMissingBook: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "GOL-005", domain: .goals,
        title: "A deadline points at a missing book",
        what: "A book deadline references a book id that is not in the library.",
        rootCauseKey: "goals.deadline-book", tier: .t1,
        defaultSeverity: .warning, defaultImpact: .low,
        riskClass: .r1, repairID: "REP-011")

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let bookIDs = Set(snapshot.books.map(\.id))
        return snapshot.libraryState.deadlines.compactMap { deadline in
            guard !bookIDs.contains(deadline.bookID) else { return nil }
            return SentinelProbeSupport.finding(
                descriptor,
                subjects: [SentinelSubject(.deadline, deadline.id.uuidString)],
                evidence: [
                    SentinelProbeSupport.record(.book, deadline.bookID.uuidString, key: "evidence.gol005.missing", at: environment.now),
                    SentinelProbeSupport.timestamp("evidence.gol005.target", deadline.targetDate, at: environment.now),
                ],
                debug: "deadline=\(deadline.id.uuidString) book=\(deadline.bookID.uuidString)")
        }
    }
}

nonisolated struct GOL006DuplicateDeadlines: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "GOL-006", domain: .goals,
        title: "A book has more than one deadline",
        what: "The same book has multiple active deadlines, so the app cannot say which one to follow.",
        rootCauseKey: "goals.duplicate-deadline", tier: .t1, isRequired: false,
        defaultSeverity: .info, defaultImpact: .low,
        riskClass: .r1, repairID: "REP-011")

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        var groups: [UUID: [BookDeadline]] = [:]
        for deadline in snapshot.libraryState.deadlines {
            groups[deadline.bookID, default: []].append(deadline)
        }
        return groups.filter { $0.value.count > 1 }.map { bookID, deadlines in
            SentinelProbeSupport.finding(
                descriptor,
                subjects: deadlines.map { SentinelSubject(.deadline, $0.id.uuidString) },
                evidence: [
                    SentinelProbeSupport.count("evidence.gol006.deadlines", deadlines.count, at: environment.now),
                    SentinelProbeSupport.record(.book, bookID.uuidString, key: "evidence.gol006.book", at: environment.now),
                ],
                debug: "book=\(bookID.uuidString) ids=\(deadlines.map(\.id.uuidString))")
        }
    }
}

nonisolated struct GOL007OverdueDeadline: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "GOL-007", domain: .goals,
        title: "A reading deadline has passed",
        what: "A book deadline is in the past and has not been cleared.",
        rootCauseKey: "goals.overdue", tier: .t1, isRequired: false,
        defaultSeverity: .info, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        snapshot.libraryState.deadlines.compactMap { deadline in
            guard deadline.targetDate < environment.now else { return nil }
            return SentinelProbeSupport.finding(
                descriptor,
                subjects: [SentinelSubject(.deadline, deadline.id.uuidString)],
                evidence: [
                    SentinelProbeSupport.timestamp("evidence.gol007.target", deadline.targetDate, at: environment.now),
                ],
                debug: "deadline=\(deadline.id.uuidString)")
        }
    }
}

nonisolated struct GOL008AchievementWithoutGoal: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "GOL-008", domain: .goals,
        title: "Achievements exist with no goals configured",
        what: "Achievements were earned while every goal target is empty, which usually means goals were cleared.",
        rootCauseKey: "goals.achievement-without-goal", tier: .t2, isRequired: false,
        defaultSeverity: .info, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let goals = snapshot.libraryState.goalSet
        let hasGoal = goals.dailyPageTarget != nil
            || goals.dailyTimeTarget != nil
            || goals.annualBookTarget != nil
            || goals.weeklyReadingDays != nil
        guard !hasGoal, !snapshot.libraryState.earnedAchievements.isEmpty else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.store, "goals")],
            evidence: [
                SentinelProbeSupport.count("evidence.gol008.achievements",
                                           snapshot.libraryState.earnedAchievements.count,
                                           at: environment.now),
            ],
            debug: "achievements=\(snapshot.libraryState.earnedAchievements.count) goals=none")]
    }
}

// MARK: - COL

nonisolated struct COL001DuplicateCollectionIDs: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "COL-001", domain: .collections,
        title: "Two collections share an identifier",
        what: "The same collection id appears more than once, so membership is ambiguous.",
        rootCauseKey: "collections.duplicate-id", tier: .t1,
        defaultSeverity: .warning, defaultImpact: .medium)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        var counts: [UUID: Int] = [:]
        for collection in snapshot.libraryState.collections {
            counts[collection.id, default: 0] += 1
        }
        return counts.filter { $0.value > 1 }.map { id, count in
            SentinelProbeSupport.finding(
                descriptor,
                subjects: [SentinelSubject(.collection, id.uuidString)],
                evidence: [SentinelProbeSupport.count("evidence.col001.duplicates", count, at: environment.now)],
                debug: "collection=\(id.uuidString)")
        }
    }
}

nonisolated struct COL002DuplicateMembership: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "COL-002", domain: .collections,
        title: "A book is in the same collection twice",
        what: "A book lists one collection id more than once, which inflates counts and can duplicate rows.",
        rootCauseKey: "collections.duplicate-member", tier: .t1,
        defaultSeverity: .warning, defaultImpact: .low,
        riskClass: .r1, repairID: "REP-008")

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        snapshot.books.compactMap { book in
            var seen = Set<UUID>()
            let duplicates = book.collectionIDs.filter { !seen.insert($0).inserted }
            guard !duplicates.isEmpty else { return nil }
            return SentinelProbeSupport.finding(
                descriptor,
                subjects: SentinelProbeSupport.subjects(for: book),
                evidence: [SentinelProbeSupport.count("evidence.col002.duplicates", duplicates.count, at: environment.now)],
                debug: "book=\(book.id.uuidString) ids=\(duplicates.map(\.uuidString))")
        }
    }
}

/// Corroborator: emits evidence against LIB-009's identity so the same missing
/// collection never becomes two separate issues (L6).
nonisolated struct COL003DanglingCollectionID: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "COL-003", domain: .collections,
        title: "A book references a collection that is gone",
        what: "A book still lists a collection id that no longer exists.",
        role: .corroborator, ownerProbeID: "LIB-009",
        rootCauseKey: "collection.dangling-member", tier: .t1,
        defaultSeverity: .warning, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let valid = Set(snapshot.libraryState.collections.map(\.id))
        return snapshot.books.compactMap { book in
            let dangling = book.collectionIDs.filter { !valid.contains($0) }
            guard !dangling.isEmpty else { return nil }
            return RawFinding(
                probeID: descriptor.id,
                ruleID: SentinelRuleID("LIB-009"),
                severity: descriptor.defaultSeverity,
                confidence: 0.95,
                impact: descriptor.defaultImpact,
                subjects: SentinelProbeSupport.subjects(for: book),
                evidence: [
                    SentinelProbeSupport.count("evidence.col003.dangling", dangling.count, at: environment.now),
                ],
                discriminator: "",
                safeSummary: "A book belongs to a collection that is gone.",
                debugDetail: "book=\(book.id.uuidString) ids=\(dangling.map(\.uuidString))",
                isEvidenceOnly: true)
        }
    }
}

nonisolated struct COL004EmptyCollectionName: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "COL-004", domain: .collections,
        title: "A collection has no name",
        what: "A collection name is empty or only whitespace, so it cannot be identified in a list.",
        rootCauseKey: "collections.empty-name", tier: .t1, isRequired: false,
        defaultSeverity: .info, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        snapshot.libraryState.collections.compactMap { collection in
            guard collection.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return SentinelProbeSupport.finding(
                descriptor,
                subjects: [SentinelSubject(.collection, collection.id.uuidString)],
                evidence: [SentinelProbeSupport.invariant("evidence.col004.name", "trimmed name is empty", at: environment.now)],
                debug: "collection=\(collection.id.uuidString)")
        }
    }
}

nonisolated struct COL005CollectionNameCollision: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "COL-005", domain: .collections,
        title: "Two collections have the same name",
        what: "Two collections share a display name. The product allows this, but it is worth knowing.",
        rootCauseKey: "collections.name-collision", tier: .t2, isRequired: false,
        defaultSeverity: .info, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        var groups: [String: [BookCollection]] = [:]
        for collection in snapshot.libraryState.collections {
            let name = collection.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !name.isEmpty else { continue }
            groups[name, default: []].append(collection)
        }
        return groups.filter { $0.value.count > 1 }.map { name, collections in
            SentinelProbeSupport.finding(
                descriptor,
                subjects: collections.map { SentinelSubject(.collection, $0.id.uuidString) },
                evidence: [SentinelProbeSupport.count("evidence.col005.collections", collections.count, at: environment.now)],
                debug: "nameHash=\(SentinelProbeSupport.hashedPath(URL(fileURLWithPath: name)))")
        }
    }
}

nonisolated struct COL006NoteTimestampInversion: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "COL-006", domain: .collections,
        title: "A note was modified before it was created",
        what: "A note's modified time is earlier than its created time, so sorting puts it in the wrong place.",
        rootCauseKey: "note.timestamp", tier: .t1, isRequired: false,
        defaultSeverity: .info, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        var findings: [RawFinding] = []
        for book in snapshot.books {
            for note in book.notes where note.modifiedAt < note.createdAt {
                findings.append(SentinelProbeSupport.finding(
                    descriptor,
                    subjects: SentinelProbeSupport.subjects(for: book)
                        + [SentinelSubject(.note, note.id.uuidString)],
                    evidence: [
                        SentinelProbeSupport.timestamp("evidence.col006.created", note.createdAt, at: environment.now),
                        SentinelProbeSupport.timestamp("evidence.col006.modified", note.modifiedAt, at: environment.now),
                    ],
                    debug: "note=\(note.id.uuidString)"))
            }
        }
        return findings
    }
}

// MARK: - Catalog

nonisolated enum SentinelGoalProbes {
    static let all: [any SentinelProbeV2] = [
        GOL001DuplicateAchievements(), GOL002UnknownAchievementKind(),
        GOL003AchievementMissingBook(), GOL004ImpossibleGoalValues(),
        GOL005DeadlineMissingBook(), GOL006DuplicateDeadlines(),
        GOL007OverdueDeadline(), GOL008AchievementWithoutGoal(),
        COL001DuplicateCollectionIDs(), COL002DuplicateMembership(),
        COL003DanglingCollectionID(), COL004EmptyCollectionName(),
        COL005CollectionNameCollision(), COL006NoteTimestampInversion(),
    ]
}
