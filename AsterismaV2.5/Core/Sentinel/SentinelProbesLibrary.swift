//  SentinelProbesLibrary.swift
//  AsterismaV2.5
//
//  LIB + SES — the invariants the library has been silently trusting.
//
//  Every probe is a pure read of the snapshot. SQL probes open a read-only
//  handle and throw `SentinelProbeUnavailable` when there is no database, so a
//  missing source shows as skipped rather than clean.

import Foundation

// MARK: - LIB

nonisolated struct LIB001DuplicateBookIDs: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "LIB-001", domain: .library,
        title: "Duplicate book records",
        what: "Two books share the same internal identifier, so edits can land on the wrong one.",
        rootCauseKey: "library.duplicate-id", tier: .t1,
        defaultSeverity: .critical, defaultImpact: .high)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        var counts: [UUID: Int] = [:]
        for book in snapshot.books { counts[book.id, default: 0] += 1 }
        return counts.filter { $0.value > 1 }.map { id, count in
            SentinelProbeSupport.finding(
                descriptor,
                subjects: [SentinelSubject(.book, id.uuidString)],
                evidence: [
                    SentinelProbeSupport.count("evidence.lib001.duplicates", count, at: environment.now),
                    SentinelProbeSupport.record(.book, id.uuidString, key: "evidence.lib001.record", at: environment.now),
                ],
                debug: "book=\(id.uuidString) count=\(count)")
        }
    }
}

nonisolated struct LIB002DuplicateFileURLs: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "LIB-002", domain: .library,
        title: "Two books point at one file",
        what: "Two library entries resolve to the same file on disk, so progress can be split between them.",
        rootCauseKey: "library.duplicate-file", tier: .t2, isRequired: false,
        defaultSeverity: .warning, defaultImpact: .medium)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        var groups: [String: [Book]] = [:]
        for book in snapshot.books {
            let path = book.fileURL.standardizedFileURL.resolvingSymlinksInPath().path
            groups[path, default: []].append(book)
        }
        return groups.filter { $0.value.count > 1 }.map { path, books in
            SentinelProbeSupport.finding(
                descriptor,
                subjects: books.map { SentinelSubject(.book, $0.id.uuidString) },
                evidence: [
                    SentinelProbeSupport.count("evidence.lib002.books", books.count, at: environment.now),
                    SentinelProbeSupport.aggregate("evidence.lib002.path", SentinelProbeSupport.hashedPath(URL(fileURLWithPath: path)), at: environment.now),
                ],
                debug: books.map(\.id.uuidString).joined(separator: ","))
        }
    }
}

nonisolated struct LIB003InvalidPageCount: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "LIB-003", domain: .library,
        title: "A book has no usable page count",
        what: "A book records zero or a negative number of pages, so progress cannot be calculated.",
        rootCauseKey: "library.page-count", tier: .t1,
        defaultSeverity: .error, defaultImpact: .high)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        snapshot.books.filter { $0.totalPages <= 0 }.map { book in
            SentinelProbeSupport.finding(
                descriptor,
                subjects: SentinelProbeSupport.subjects(for: book),
                evidence: [SentinelProbeSupport.count("evidence.lib003.pages", book.totalPages, at: environment.now)],
                debug: "book=\(book.id.uuidString) totalPages=\(book.totalPages)")
        }
    }
}

nonisolated struct LIB004CurrentPageOutOfRange: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "LIB-004", domain: .library,
        title: "A book is parked outside its own pages",
        what: "The current page is before the first page or past the last page.",
        rootCauseKey: "library.page-range", tier: .t1,
        defaultSeverity: .warning, defaultImpact: .medium,
        riskClass: .r1, repairID: "REP-006")

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        snapshot.books.compactMap { book in
            guard book.totalPages > 0 else { return nil }
            guard book.currentPage < 0 || book.currentPage >= book.totalPages else { return nil }
            return SentinelProbeSupport.finding(
                descriptor,
                subjects: SentinelProbeSupport.subjects(for: book),
                evidence: [
                    SentinelProbeSupport.count("evidence.lib004.current", book.currentPage, at: environment.now),
                    SentinelProbeSupport.count("evidence.lib004.total", book.totalPages, at: environment.now),
                ],
                debug: "book=\(book.id.uuidString) current=\(book.currentPage) total=\(book.totalPages)")
        }
    }
}

nonisolated struct LIB005PhantomActiveSession: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "LIB-005", domain: .library,
        title: "An active session points at nothing",
        what: "A book says a reading session is active, but no session with that id exists.",
        rootCauseKey: "library.phantom-active", tier: .t1,
        defaultSeverity: .warning, defaultImpact: .medium,
        riskClass: .r1, repairID: "REP-002")

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        snapshot.books.compactMap { book in
            guard let id = book.activeSessionID,
                  !book.sessions.contains(where: { $0.id == id }) else { return nil }
            return SentinelProbeSupport.finding(
                descriptor,
                subjects: SentinelProbeSupport.subjects(for: book),
                evidence: [
                    SentinelProbeSupport.record(.session, id.uuidString, key: "evidence.lib005.missing", at: environment.now),
                ],
                debug: "book=\(book.id.uuidString) active=\(id.uuidString)")
        }
    }
}

nonisolated struct LIB006MultipleActiveSessions: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "LIB-006", domain: .library,
        title: "Two reading sessions are open at once",
        what: "A book has more than one unfinished session, which double-counts reading time.",
        rootCauseKey: "session.overlap", tier: .t1,
        defaultSeverity: .warning, defaultImpact: .medium,
        riskClass: .r1, repairID: "REP-001")

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        snapshot.books.compactMap { book in
            let active = book.sessions.filter(\.isActive)
            guard active.count > 1 else { return nil }
            return SentinelProbeSupport.finding(
                descriptor,
                subjects: SentinelProbeSupport.subjects(for: book),
                evidence: [SentinelProbeSupport.count("evidence.lib006.active", active.count, at: environment.now)],
                debug: "book=\(book.id.uuidString) active=\(active.count)")
        }
    }
}

nonisolated struct LIB007CompletionInconsistency: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "LIB-007", domain: .library,
        title: "A finished book is not at its last page",
        what: "A book is marked finished but its saved position is before the end.",
        rootCauseKey: "library.completion", tier: .t1, isRequired: false,
        defaultSeverity: .info, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        snapshot.books.compactMap { book in
            guard book.isCompleted, book.totalPages > 0,
                  book.currentPage < book.totalPages - 1 else { return nil }
            return SentinelProbeSupport.finding(
                descriptor,
                subjects: SentinelProbeSupport.subjects(for: book),
                evidence: [
                    SentinelProbeSupport.count("evidence.lib007.current", book.currentPage, at: environment.now),
                    SentinelProbeSupport.count("evidence.lib007.total", book.totalPages, at: environment.now),
                ],
                debug: "book=\(book.id.uuidString)")
        }
    }
}

nonisolated struct LIB008ChapterRangeInvalid: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "LIB-008", domain: .library,
        title: "A chapter covers pages that do not exist",
        what: "A chapter starts outside the book or ends before it starts, so navigation can jump.",
        rootCauseKey: "library.chapter-range", tier: .t1, isRequired: false,
        defaultSeverity: .info, defaultImpact: .medium,
        riskClass: .r1, repairID: "REP-017")

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        snapshot.books.compactMap { book in
            guard book.totalPages > 0 else { return nil }
            let bad = book.chapters.filter {
                $0.startPage < 0 || $0.startPage >= book.totalPages
                    || $0.endPage < $0.startPage
                    || $0.endPage >= book.totalPages
            }
            guard !bad.isEmpty else { return nil }
            return SentinelProbeSupport.finding(
                descriptor,
                subjects: SentinelProbeSupport.subjects(for: book),
                evidence: [SentinelProbeSupport.count("evidence.lib008.chapters", bad.count, at: environment.now)],
                debug: "book=\(book.id.uuidString) bad=\(bad.map(\.index))")
        }
    }
}

nonisolated struct LIB009DanglingCollectionReference: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "LIB-009", domain: .library,
        title: "A book belongs to a collection that is gone",
        what: "A book still lists a collection id that no longer exists.",
        rootCauseKey: "collection.dangling-member", tier: .t1,
        defaultSeverity: .warning, defaultImpact: .low,
        riskClass: .r1, repairID: "REP-010")

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let valid = Set(snapshot.libraryState.collections.map(\.id))
        return snapshot.books.compactMap { book in
            let dangling = book.collectionIDs.filter { !valid.contains($0) }
            guard !dangling.isEmpty else { return nil }
            return SentinelProbeSupport.finding(
                descriptor,
                subjects: SentinelProbeSupport.subjects(for: book),
                evidence: [SentinelProbeSupport.count("evidence.lib009.dangling", dangling.count, at: environment.now)],
                debug: "book=\(book.id.uuidString) ids=\(dangling.map(\.uuidString))")
        }
    }
}

nonisolated struct LIB010CachedSpeedContradiction: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "LIB-010", domain: .library,
        title: "A cached reading speed disagrees with the timings",
        what: "The speed stored for quick analytics no longer matches the per-page timings on disk.",
        rootCauseKey: "cache.speed", tier: .t2, isRequired: false,
        defaultSeverity: .info, defaultImpact: .low,
        riskClass: .r1, repairID: "REP-019")

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        snapshot.books.compactMap { book in
            let speeds = book.sessions
                .filter { $0.endTime != nil && $0.pagesRead > 0 }
                .map(\.averageSecondsPerPage)
                .filter { $0 > 0 }
            guard !speeds.isEmpty, let cached = book.cachedSecondsPerPage else { return nil }
            let computed = speeds.reduce(0, +) / Double(speeds.count)
            let tolerance = max(0.25, computed * 0.2)
            guard abs(cached - computed) > tolerance else { return nil }
            return SentinelProbeSupport.finding(
                descriptor,
                subjects: SentinelProbeSupport.subjects(for: book),
                evidence: [
                    SentinelProbeSupport.aggregate("evidence.lib010.cached", String(format: "%.2f", cached), at: environment.now),
                    SentinelProbeSupport.aggregate("evidence.lib010.computed", String(format: "%.2f", computed), at: environment.now),
                ],
                debug: "book=\(book.id.uuidString)")
        }
    }
}

nonisolated struct LIB011OrphanNoteReference: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "LIB-011", domain: .library,
        title: "A note belongs to a different book",
        what: "A note's stored book id does not match the book that holds it.",
        rootCauseKey: "note.ownership", tier: .t1,
        defaultSeverity: .warning, defaultImpact: .medium)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        snapshot.books.compactMap { book in
            let orphans = book.notes.filter { $0.bookID != book.id }
            guard !orphans.isEmpty else { return nil }
            return SentinelProbeSupport.finding(
                descriptor,
                subjects: SentinelProbeSupport.subjects(for: book),
                evidence: [SentinelProbeSupport.count("evidence.lib011.notes", orphans.count, at: environment.now)],
                debug: "book=\(book.id.uuidString) notes=\(orphans.map(\.id.uuidString))")
        }
    }
}

nonisolated struct LIB012DuplicateNoteIDs: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "LIB-012", domain: .library,
        title: "Two notes share an identifier",
        what: "A book contains the same note id twice, so editing one can change both.",
        rootCauseKey: "note.duplicate-id", tier: .t1, isRequired: false,
        defaultSeverity: .warning, defaultImpact: .low,
        riskClass: .r1, repairID: "REP-018")

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        snapshot.books.compactMap { book in
            var seen = Set<UUID>()
            let duplicates = book.notes.filter { !seen.insert($0.id).inserted }
            guard !duplicates.isEmpty else { return nil }
            return SentinelProbeSupport.finding(
                descriptor,
                subjects: SentinelProbeSupport.subjects(for: book),
                evidence: [SentinelProbeSupport.count("evidence.lib012.duplicates", duplicates.count, at: environment.now)],
                debug: "book=\(book.id.uuidString)")
        }
    }
}

nonisolated struct LIB013EmptyLibraryWithState: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "LIB-013", domain: .library,
        title: "The library is empty but its settings are not",
        what: "Books are missing while goals, deadlines, or collections remain — a sign that a load failed.",
        rootCauseKey: "library.empty-with-state", tier: .t0,
        defaultSeverity: .critical, defaultImpact: .high)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        guard snapshot.books.isEmpty else { return [] }
        let state = snapshot.libraryState
        let hasState = !state.deadlines.isEmpty
            || !state.collections.isEmpty
            || !state.earnedAchievements.isEmpty
        guard hasState else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.store, "library")],
            evidence: [
                SentinelProbeSupport.count("evidence.lib013.deadlines", state.deadlines.count, at: environment.now),
                SentinelProbeSupport.count("evidence.lib013.collections", state.collections.count, at: environment.now),
            ],
            debug: "books=0 state=non-empty")]
    }
}

nonisolated struct LIB014MetadataDecay: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "LIB-014", domain: .library,
        title: "A book has malformed metadata",
        what: "Series or word-count metadata contains an impossible value.",
        rootCauseKey: "library.metadata", tier: .t1, isRequired: false,
        defaultSeverity: .info, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        snapshot.books.compactMap { book in
            var problems: [String] = []
            if let series = book.series, series.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                problems.append("empty-series")
            }
            if let words = book.wordCountEstimate, words < 0 {
                problems.append("negative-words")
            }
            guard !problems.isEmpty else { return nil }
            return SentinelProbeSupport.finding(
                descriptor,
                subjects: SentinelProbeSupport.subjects(for: book),
                evidence: [SentinelProbeSupport.aggregate("evidence.lib014.problems", problems.joined(separator: ","), at: environment.now)],
                debug: "book=\(book.id.uuidString) \(problems)")
        }
    }
}

nonisolated struct LIB015ProgressMonotonicity: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "LIB-015", domain: .library,
        title: "Saved progress is behind the last session",
        what: "The current page is earlier than where the most recent finished session ended.",
        rootCauseKey: "library.progress", tier: .t2, isRequired: false,
        defaultSeverity: .info, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        snapshot.books.compactMap { book in
            guard book.totalPages > 0,
                  let lastEnd = book.sessions
                    .filter({ $0.endTime != nil })
                    .max(by: { $0.startTime < $1.startTime })?.endPage
            else { return nil }
            guard lastEnd > book.currentPage + 1 else { return nil }
            return SentinelProbeSupport.finding(
                descriptor,
                subjects: SentinelProbeSupport.subjects(for: book),
                evidence: [
                    SentinelProbeSupport.count("evidence.lib015.current", book.currentPage, at: environment.now),
                    SentinelProbeSupport.count("evidence.lib015.lastSessionEnd", lastEnd, at: environment.now),
                ],
                debug: "book=\(book.id.uuidString)")
        }
    }
}

// MARK: - SES

nonisolated struct SES001NegativeSessionDuration: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SES-001", domain: .sessions,
        title: "A reading session ends before it starts",
        what: "A session's end time is earlier than its start time, so it contributes negative reading time.",
        rootCauseKey: "session.time", tier: .t1,
        defaultSeverity: .warning, defaultImpact: .medium,
        riskClass: .r1, repairID: "REP-003")

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        SentinelProbeSupport.sessionsWithTiming(in: snapshot).compactMap { book, session in
            guard let end = session.endTime, end < session.startTime else { return nil }
            return SentinelProbeSupport.finding(
                descriptor,
                subjects: SentinelProbeSupport.subjects(for: book, session: session),
                evidence: [
                    SentinelProbeSupport.timestamp("evidence.ses001.start", session.startTime, at: environment.now),
                    SentinelProbeSupport.timestamp("evidence.ses001.end", end, at: environment.now),
                ],
                debug: "book=\(book.id.uuidString) session=\(session.id.uuidString)")
        }
    }
}

nonisolated struct SES002NegativePageRange: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SES-002", domain: .sessions,
        title: "A session ends on an earlier page than it starts",
        what: "The session page range is inverted, which subtracts pages from the total.",
        rootCauseKey: "session.page-range", tier: .t1,
        defaultSeverity: .warning, defaultImpact: .medium,
        riskClass: .r1, repairID: "REP-007")

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        SentinelProbeSupport.sessionsWithTiming(in: snapshot).compactMap { book, session in
            guard session.endPage < session.startPage else { return nil }
            return SentinelProbeSupport.finding(
                descriptor,
                subjects: SentinelProbeSupport.subjects(for: book, session: session),
                evidence: [
                    SentinelProbeSupport.count("evidence.ses002.start", session.startPage, at: environment.now),
                    SentinelProbeSupport.count("evidence.ses002.end", session.endPage, at: environment.now),
                ],
                debug: "session=\(session.id.uuidString)")
        }
    }
}

nonisolated struct SES003SessionPageOutOfRange: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SES-003", domain: .sessions,
        title: "A session covers pages outside the book",
        what: "A session's start or end page is outside the book's page range.",
        rootCauseKey: "session.page-range", tier: .t1,
        defaultSeverity: .warning, defaultImpact: .medium,
        riskClass: .r1, repairID: "REP-007")

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        SentinelProbeSupport.sessionsWithTiming(in: snapshot).compactMap { book, session in
            guard book.totalPages > 0 else { return nil }
            guard !SentinelProbeSupport.pageInRange(session.startPage, totalPages: book.totalPages)
                    || !SentinelProbeSupport.pageInRange(session.endPage, totalPages: book.totalPages) else { return nil }
            return SentinelProbeSupport.finding(
                descriptor,
                subjects: SentinelProbeSupport.subjects(for: book, session: session),
                evidence: [
                    SentinelProbeSupport.count("evidence.ses003.start", session.startPage, at: environment.now),
                    SentinelProbeSupport.count("evidence.ses003.end", session.endPage, at: environment.now),
                    SentinelProbeSupport.count("evidence.ses003.total", book.totalPages, at: environment.now),
                ],
                debug: "session=\(session.id.uuidString)")
        }
    }
}

nonisolated struct SES004OrphanActiveSession: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SES-004", domain: .sessions,
        title: "A reading session was left open",
        what: "A session has no end time and is older than the staleness threshold, usually from a crash.",
        rootCauseKey: "session.orphan", tier: .t1,
        defaultSeverity: .warning, defaultImpact: .medium,
        riskClass: .r1, repairID: "REP-001")

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        SentinelProbeSupport.sessionsWithTiming(in: snapshot).compactMap { book, session in
            guard session.isActive,
                  environment.now.timeIntervalSince(session.startTime) > environment.effectiveOrphanSessionAge
            else { return nil }
            return SentinelProbeSupport.finding(
                descriptor,
                subjects: SentinelProbeSupport.subjects(for: book, session: session),
                evidence: [
                    SentinelProbeSupport.timestamp("evidence.ses004.start", session.startTime, at: environment.now),
                    SentinelProbeSupport.aggregate(
                        "evidence.ses004.ageHours",
                        String(format: "%.1f", environment.now.timeIntervalSince(session.startTime) / 3600),
                        at: environment.now),
                ],
                debug: "book=\(book.id.uuidString) session=\(session.id.uuidString)")
        }
    }
}

nonisolated struct SES005ActiveTimingInClosedSession: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SES-005", domain: .sessions,
        title: "A finished session still has a page timer running",
        what: "A session has an end time but one of its page timings does not.",
        rootCauseKey: "session.timing-window", tier: .t2,
        defaultSeverity: .warning, defaultImpact: .low,
        riskClass: .r1, repairID: "REP-005")

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        SentinelProbeSupport.sessionsWithTiming(in: snapshot).compactMap { book, session in
            guard session.endTime != nil else { return nil }
            let open = session.pageTimes.filter(\.isActive)
            guard !open.isEmpty else { return nil }
            return SentinelProbeSupport.finding(
                descriptor,
                subjects: SentinelProbeSupport.subjects(for: book, session: session),
                evidence: [SentinelProbeSupport.count("evidence.ses005.open", open.count, at: environment.now)],
                debug: "session=\(session.id.uuidString)")
        }
    }
}

nonisolated struct SES006NegativeTimingDuration: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SES-006", domain: .sessions,
        title: "A page timer ends before it starts",
        what: "A page timing has an end earlier than its start, which subtracts reading time.",
        rootCauseKey: "session.timing", tier: .t2,
        defaultSeverity: .warning, defaultImpact: .low,
        riskClass: .r1, repairID: "REP-004")

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        var findings: [RawFinding] = []
        for (book, session) in SentinelProbeSupport.sessionsWithTiming(in: snapshot) {
            for timing in session.pageTimes {
                guard let end = timing.endTime, end < timing.startTime else { continue }
                findings.append(SentinelProbeSupport.finding(
                    descriptor,
                    subjects: SentinelProbeSupport.subjects(for: book, session: session)
                        + [SentinelSubject(.timing, timing.id.uuidString)],
                    evidence: [
                        SentinelProbeSupport.timestamp("evidence.ses006.start", timing.startTime, at: environment.now),
                        SentinelProbeSupport.timestamp("evidence.ses006.end", end, at: environment.now),
                    ],
                    debug: "timing=\(timing.id.uuidString)"))
            }
        }
        return findings
    }
}

nonisolated struct SES007TimingPageOutOfRange: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SES-007", domain: .sessions,
        title: "A page timer points outside the book",
        what: "A page timing records a page number the book does not have.",
        rootCauseKey: "session.timing-page", tier: .t2,
        defaultSeverity: .warning, defaultImpact: .low,
        riskClass: .r1, repairID: "REP-004")

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        var findings: [RawFinding] = []
        for (book, session) in SentinelProbeSupport.sessionsWithTiming(in: snapshot) where book.totalPages > 0 {
            for timing in session.pageTimes
            where !SentinelProbeSupport.pageInRange(timing.pageNumber, totalPages: book.totalPages) {
                findings.append(SentinelProbeSupport.finding(
                    descriptor,
                    subjects: SentinelProbeSupport.subjects(for: book, session: session)
                        + [SentinelSubject(.timing, timing.id.uuidString)],
                    evidence: [
                        SentinelProbeSupport.count("evidence.ses007.page", timing.pageNumber, at: environment.now),
                        SentinelProbeSupport.count("evidence.ses007.total", book.totalPages, at: environment.now),
                    ],
                    debug: "timing=\(timing.id.uuidString)"))
            }
        }
        return findings
    }
}

nonisolated struct SES008TimingOutsideSessionWindow: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SES-008", domain: .sessions,
        title: "A page timer falls outside its session",
        what: "A page timing starts before the session or ends after it, beyond the grace window.",
        rootCauseKey: "session.timing-window", tier: .t2, isRequired: false,
        defaultSeverity: .warning, defaultImpact: .low,
        riskClass: .r1, repairID: "REP-003")

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let grace: TimeInterval = 300
        var findings: [RawFinding] = []
        for (book, session) in SentinelProbeSupport.sessionsWithTiming(in: snapshot) {
            guard let sessionEnd = session.endTime else { continue }
            for timing in session.pageTimes {
                let end = timing.endTime ?? sessionEnd
                guard timing.startTime < session.startTime.addingTimeInterval(-grace)
                        || end > sessionEnd.addingTimeInterval(grace) else { continue }
                findings.append(SentinelProbeSupport.finding(
                    descriptor,
                    subjects: SentinelProbeSupport.subjects(for: book, session: session)
                        + [SentinelSubject(.timing, timing.id.uuidString)],
                    evidence: [SentinelProbeSupport.invariant("evidence.ses008.window", "timing ⊄ session", at: environment.now)],
                    debug: "timing=\(timing.id.uuidString)"))
            }
        }
        return findings
    }
}

nonisolated struct SES009OverlappingSessions: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SES-009", domain: .sessions,
        title: "Two sessions overlap in time",
        what: "Two finished sessions for the same book cover the same minutes.",
        rootCauseKey: "session.overlap", tier: .t2, isRequired: false,
        defaultSeverity: .info, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let grace: TimeInterval = 60
        var findings: [RawFinding] = []
        for book in snapshot.books {
            let intervals = book.sessions.compactMap { session -> (Date, Date, ReadingSession)? in
                guard let end = session.endTime, end > session.startTime else { return nil }
                return (session.startTime, end, session)
            }.sorted { $0.0 < $1.0 }
            guard intervals.count > 1 else { continue }
            for index in 1..<intervals.count {
                let previous = intervals[index - 1]
                let current = intervals[index]
                if current.0 < previous.1.addingTimeInterval(-grace) {
                    findings.append(SentinelProbeSupport.finding(
                        descriptor,
                        subjects: SentinelProbeSupport.subjects(for: book)
                            + [
                                SentinelSubject(.session, previous.2.id.uuidString),
                                SentinelSubject(.session, current.2.id.uuidString),
                            ],
                        evidence: [SentinelProbeSupport.invariant("evidence.ses009.overlap", "later.start < earlier.end", at: environment.now)],
                        debug: "book=\(book.id.uuidString)"))
                }
            }
        }
        return findings
    }
}

nonisolated struct SES010DuplicateSessionIDs: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SES-010", domain: .sessions,
        title: "Two sessions share an identifier",
        what: "The same session id appears more than once, so statistics can attach to the wrong session.",
        rootCauseKey: "session.duplicate-id", tier: .t1,
        defaultSeverity: .critical, defaultImpact: .high)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        var seen = Set<UUID>()
        var duplicates = Set<UUID>()
        for book in snapshot.books {
            for session in book.sessions where !seen.insert(session.id).inserted {
                duplicates.insert(session.id)
            }
        }
        return duplicates.map { id in
            SentinelProbeSupport.finding(
                descriptor,
                subjects: [SentinelSubject(.session, id.uuidString)],
                evidence: [SentinelProbeSupport.count("evidence.ses010.count", 2, at: environment.now)],
                debug: "session=\(id.uuidString)")
        }
    }
}

nonisolated struct SES011ExtremeTimingDuration: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SES-011", domain: .sessions,
        title: "A single page took an implausibly long time",
        what: "One page timing is longer than thirty minutes, which usually means a paused timer.",
        rootCauseKey: "session.timing-duration", tier: .t2, isRequired: false,
        defaultSeverity: .info, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        var findings: [RawFinding] = []
        for (book, session) in SentinelProbeSupport.sessionsWithTiming(in: snapshot) {
            for timing in session.pageTimes where timing.duration > 1800 {
                findings.append(SentinelProbeSupport.finding(
                    descriptor,
                    subjects: SentinelProbeSupport.subjects(for: book, session: session)
                        + [SentinelSubject(.timing, timing.id.uuidString)],
                    evidence: [SentinelProbeSupport.aggregate(
                        "evidence.ses011.minutes",
                        String(format: "%.0f", timing.duration / 60),
                        at: environment.now)],
                    debug: "timing=\(timing.id.uuidString)"))
            }
        }
        return findings
    }
}

nonisolated struct SES012FutureTimestamps: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SES-012", domain: .sessions,
        title: "A session is dated in the future",
        what: "A session or page timer starts more than five minutes after the current time.",
        rootCauseKey: "session.clock", tier: .t1,
        defaultSeverity: .warning, defaultImpact: .medium)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let threshold = environment.now.addingTimeInterval(300)
        var findings: [RawFinding] = []
        for (book, session) in SentinelProbeSupport.sessionsWithTiming(in: snapshot) {
            guard session.startTime > threshold else { continue }
            findings.append(SentinelProbeSupport.finding(
                descriptor,
                subjects: SentinelProbeSupport.subjects(for: book, session: session),
                evidence: [SentinelProbeSupport.timestamp("evidence.ses012.start", session.startTime, at: environment.now)],
                debug: "session=\(session.id.uuidString)"))
        }
        return findings
    }
}

nonisolated struct SES013ZeroDurationSessions: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SES-013", domain: .sessions,
        title: "A session has no duration",
        what: "A session starts and ends at the same instant, usually a crash artifact.",
        rootCauseKey: "session.zero", tier: .t1, isRequired: false,
        defaultSeverity: .info, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        SentinelProbeSupport.sessionsWithTiming(in: snapshot).compactMap { book, session in
            guard let end = session.endTime, end == session.startTime else { return nil }
            return SentinelProbeSupport.finding(
                descriptor,
                subjects: SentinelProbeSupport.subjects(for: book, session: session),
                evidence: [SentinelProbeSupport.timestamp("evidence.ses013.start", session.startTime, at: environment.now)],
                debug: "session=\(session.id.uuidString)")
        }
    }
}

nonisolated struct SES014CachedAverageContradiction: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SES-014", domain: .sessions,
        title: "A cached session average disagrees with its timings",
        what: "The average stored on the session does not match the page timings it summarises.",
        rootCauseKey: "cache.speed", tier: .t2, isRequired: false,
        defaultSeverity: .info, defaultImpact: .low,
        riskClass: .r1, repairID: "REP-019")

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        var findings: [RawFinding] = []
        for (book, session) in SentinelProbeSupport.sessionsWithTiming(in: snapshot) {
            let timed = session.pageTimes.filter { $0.duration > 0 }
            guard !timed.isEmpty, let cached = session.cachedAverageSecondsPerPage else { continue }
            let computed = timed.reduce(0) { $0 + $1.duration } / Double(timed.count)
            let tolerance = max(0.25, computed * 0.2)
            guard abs(cached - computed) > tolerance else { continue }
            findings.append(SentinelProbeSupport.finding(
                descriptor,
                subjects: SentinelProbeSupport.subjects(for: book, session: session),
                evidence: [
                    SentinelProbeSupport.aggregate("evidence.ses014.cached", String(format: "%.2f", cached), at: environment.now),
                    SentinelProbeSupport.aggregate("evidence.ses014.computed", String(format: "%.2f", computed), at: environment.now),
                ],
                debug: "session=\(session.id.uuidString)"))
        }
        return findings
    }
}

nonisolated struct SES015OrphanTimingRows: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SES-015", domain: .sessions,
        title: "Page timings exist without their session",
        what: "Normalized page-timing rows point at a session that is not in the database.",
        rootCauseKey: "sql.orphan-timing", tier: .t2,
        defaultSeverity: .critical, defaultImpact: .high)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let count = try SentinelProbeSupport.readDatabase(at: snapshot.databaseURL) { db in
            guard try SentinelProbeSupport.hasTable("page_times", in: db),
                  try SentinelProbeSupport.hasTable("sessions", in: db) else {
                throw SentinelProbeUnavailable(.databaseNotInitialized)
            }
            return try SentinelProbeSupport.scalarInt(
                db,
                "SELECT COUNT(*) FROM page_times t LEFT JOIN sessions s ON s.id = t.session_id WHERE s.id IS NULL")
        }
        guard count > 0 else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.database, "library")],
            evidence: [SentinelProbeSupport.count("evidence.ses015.rows", count, at: environment.now, source: .sqlite)],
            debug: "orphanPageTimings=\(count)")]
    }
}

nonisolated struct SES016OrphanSessionRows: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SES-016", domain: .sessions,
        title: "Sessions exist without their book",
        what: "Normalized session rows point at a book that is not in the database.",
        rootCauseKey: "sql.orphan-session", tier: .t2,
        defaultSeverity: .critical, defaultImpact: .high)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let count = try SentinelProbeSupport.readDatabase(at: snapshot.databaseURL) { db in
            guard try SentinelProbeSupport.hasTable("sessions", in: db) else {
                throw SentinelProbeUnavailable(.databaseNotInitialized)
            }
            return try SentinelProbeSupport.scalarInt(
                db,
                "SELECT COUNT(*) FROM sessions s LEFT JOIN books b ON b.id = s.book_id WHERE b.id IS NULL")
        }
        guard count > 0 else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.database, "library")],
            evidence: [SentinelProbeSupport.count("evidence.ses016.rows", count, at: environment.now, source: .sqlite)],
            debug: "orphanSessions=\(count)")]
    }
}

nonisolated struct SES017DuplicateTimingIndices: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SES-017", domain: .sessions,
        title: "Page timings repeat their position",
        what: "The same session has more than one timing at the same index, so ordering is ambiguous.",
        rootCauseKey: "sql.duplicate-timing", tier: .t2,
        defaultSeverity: .warning, defaultImpact: .medium)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let count = try SentinelProbeSupport.readDatabase(at: snapshot.databaseURL) { db in
            guard try SentinelProbeSupport.hasTable("page_times", in: db) else {
                throw SentinelProbeUnavailable(.databaseNotInitialized)
            }
            return try SentinelProbeSupport.scalarInt(
                db,
                "SELECT COUNT(*) FROM (SELECT session_id, idx FROM page_times GROUP BY session_id, idx HAVING COUNT(*) > 1)")
        }
        guard count > 0 else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.database, "library")],
            evidence: [SentinelProbeSupport.count("evidence.ses017.groups", count, at: environment.now, source: .sqlite)],
            debug: "duplicateIndices=\(count)")]
    }
}

nonisolated struct SES018TimingCoverage: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SES-018", domain: .sessions,
        title: "Some sessions have no page timings",
        what: "Sessions that read pages carry no per-page timing, so speed analysis is thinner than it looks.",
        rootCauseKey: "session.coverage", tier: .t2, isRequired: false,
        defaultSeverity: .info, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        var total = 0
        var missing = 0
        for book in snapshot.books {
            for session in book.sessions where session.pagesRead > 0 && session.endTime != nil {
                total += 1
                if session.pageTimes.isEmpty { missing += 1 }
            }
        }
        guard total > 0, missing > 0 else { return [] }
        let ratio = Double(missing) / Double(total)
        guard ratio > 0.5 else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.store, "sessions")],
            evidence: [
                SentinelProbeSupport.count("evidence.ses018.missing", missing, at: environment.now),
                SentinelProbeSupport.count("evidence.ses018.total", total, at: environment.now),
                SentinelProbeSupport.aggregate("evidence.ses018.ratio", SentinelFormat.percent(ratio), at: environment.now),
            ],
            debug: "ratio=\(String(format: "%.2f", ratio))")]
    }
}

nonisolated struct SES019ClockSkew: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SES-019", domain: .sessions,
        title: "Session dates do not fit this clock",
        what: "The newest session is in the future or more than a year older than the current time.",
        rootCauseKey: "session.clock", tier: .t0,
        defaultSeverity: .warning, defaultImpact: .low)

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        let dates = SentinelProbeSupport.sessionsWithTiming(in: snapshot).map(\.session.startTime)
        guard let newest = dates.max() else { return [] }
        let future = newest > environment.now.addingTimeInterval(300)
        let stale = newest < environment.now.addingTimeInterval(-365 * 86_400)
        guard future || stale else { return [] }
        return [SentinelProbeSupport.finding(
            descriptor,
            subjects: [SentinelSubject(.store, "clock")],
            evidence: [SentinelProbeSupport.timestamp("evidence.ses019.newest", newest, at: environment.now)],
            debug: "future=\(future) stale=\(stale)")]
    }
}

nonisolated struct SES020LongSessionWithoutActivity: SentinelProbeV2 {
    let descriptor = SentinelProbeDescriptor(
        id: "SES-020", domain: .sessions,
        title: "An open session has been idle for hours",
        what: "A session is still open but no page activity has been recorded for more than two hours.",
        rootCauseKey: "session.orphan", tier: .t1,
        defaultSeverity: .info, defaultImpact: .medium,
        riskClass: .r1, repairID: "REP-001")

    func run(snapshot: SentinelSnapshot, environment: SentinelEnvironment) async throws -> [RawFinding] {
        SentinelProbeSupport.sessionsWithTiming(in: snapshot).compactMap { book, session in
            guard session.isActive else { return nil }
            let lastActivity = session.pageTimes.compactMap { $0.endTime ?? $0.startTime }.max() ?? session.startTime
            guard environment.now.timeIntervalSince(lastActivity) > 2 * 3600 else { return nil }
            return SentinelProbeSupport.finding(
                descriptor,
                subjects: SentinelProbeSupport.subjects(for: book, session: session),
                evidence: [
                    SentinelProbeSupport.timestamp("evidence.ses020.lastActivity", lastActivity, at: environment.now),
                ],
                debug: "session=\(session.id.uuidString)")
        }
    }
}

// MARK: - Catalog

nonisolated enum SentinelLibraryProbes {
    static let all: [any SentinelProbeV2] = [
        LIB001DuplicateBookIDs(), LIB002DuplicateFileURLs(), LIB003InvalidPageCount(),
        LIB004CurrentPageOutOfRange(), LIB005PhantomActiveSession(), LIB006MultipleActiveSessions(),
        LIB007CompletionInconsistency(), LIB008ChapterRangeInvalid(), LIB009DanglingCollectionReference(),
        LIB010CachedSpeedContradiction(), LIB011OrphanNoteReference(), LIB012DuplicateNoteIDs(),
        LIB013EmptyLibraryWithState(), LIB014MetadataDecay(), LIB015ProgressMonotonicity(),
        SES001NegativeSessionDuration(), SES002NegativePageRange(), SES003SessionPageOutOfRange(),
        SES004OrphanActiveSession(), SES005ActiveTimingInClosedSession(), SES006NegativeTimingDuration(),
        SES007TimingPageOutOfRange(), SES008TimingOutsideSessionWindow(), SES009OverlappingSessions(),
        SES010DuplicateSessionIDs(), SES011ExtremeTimingDuration(), SES012FutureTimestamps(),
        SES013ZeroDurationSessions(), SES014CachedAverageContradiction(), SES015OrphanTimingRows(),
        SES016OrphanSessionRows(), SES017DuplicateTimingIndices(), SES018TimingCoverage(),
        SES019ClockSkew(), SES020LongSessionWithoutActivity(),
    ]
}
