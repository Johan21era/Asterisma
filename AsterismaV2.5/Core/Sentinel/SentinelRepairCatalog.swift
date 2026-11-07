//  SentinelRepairCatalog.swift
//  AsterismaV2.5
//
//  SG3 — the plan catalog. Plans are pure: they read a snapshot and produce
//  typed actions plus the previous values for rollback and undo. Nothing here
//  mutates. The executor is the only caller of the bridge.
//
//  Every plan carries the exact `Book`/`LibraryState` it expects to find, so an
//  unrelated edit between planning and applying is refused rather than
//  overwritten.

import Foundation

nonisolated enum SentinelRepairCatalog {

    /// Plans that are fully implemented and can verify themselves.
    static let implementedIDs: Set<String> = [
        "REP-001", "REP-002", "REP-003", "REP-004", "REP-005", "REP-006",
        "REP-007", "REP-008", "REP-009", "REP-010", "REP-011", "REP-012",
        "REP-013", "REP-014", "REP-015", "REP-016", "REP-017", "REP-018",
        "REP-019", "REP-020", "REP-021", "REP-022", "REP-023", "REP-024",
        "REP-025",
    ]

    /// The catalog key is the repair ID, not the rule ID: several rules share
    /// one safe normalization (SES-004 and SES-020 both close an orphan).
    static func plan(
        for issue: SentinelIssue,
        rule: SentinelRuleMetadata,
        snapshot: SentinelSnapshot,
        configuration: SentinelConfiguration,
        now: Date
    ) -> SentinelRepairPlan? {
        guard let repairID = rule.repairID, implementedIDs.contains(repairID) else { return nil }
        guard let affected = booksAffected(by: issue, in: snapshot), !affected.isEmpty || needsGlobalScan(repairID) else {
            return nil
        }

        switch repairID {
        case "REP-001": return closeOrphanSessions(issue, rule, snapshot, affected, configuration, now)
        case "REP-002": return clearPhantomActiveSession(issue, rule, snapshot, affected)
        case "REP-003": return pinSessionEnds(issue, rule, snapshot, affected)
        case "REP-004": return pinTimings(issue, rule, snapshot, affected)
        case "REP-005": return closeOrphanTimings(issue, rule, snapshot, affected)
        case "REP-006": return clampCurrentPage(issue, rule, snapshot, affected)
        case "REP-007": return clampSessionPages(issue, rule, snapshot, affected)
        case "REP-008": return dedupeCollectionMembership(issue, rule, snapshot, affected)
        case "REP-009": return dedupeAchievements(issue, rule, snapshot)
        case "REP-010": return stripDanglingCollections(issue, rule, snapshot, affected)
        case "REP-011": return pruneDeadlines(issue, rule, snapshot)
        case "REP-012": return quarantineOrphanCover(issue, rule, snapshot)
        case "REP-013": return quarantineCorruptCover(issue, rule, snapshot)
        case "REP-014": return checkpoint(issue, rule, snapshot)
        case "REP-015": return trimJournal(issue, rule, snapshot)
        case "REP-016": return rebuildIssueStore(issue, rule, snapshot)
        case "REP-017": return normalizeChapterRanges(issue, rule, snapshot, affected)
        case "REP-018": return dedupeNotes(issue, rule, snapshot, affected)
        case "REP-019": return recomputeCachedSpeeds(issue, rule, snapshot)
        case "REP-020": return trimDebugJournal(issue, rule, snapshot)
        case "REP-021": return quarantineOldBackups(issue, rule, snapshot)
        case "REP-022": return quarantineStaleTemp(issue, rule, snapshot, now)
        case "REP-023": return resetNotifications(issue, rule, snapshot)
        case "REP-024": return quarantineBehaviorArchive(issue, rule, snapshot)
        case "REP-025": return rebuildCoverFromEmbedded(issue, rule, snapshot, affected)
        default: return nil
        }
    }

    // MARK: - Subject resolution

    private static func booksAffected(
        by issue: SentinelIssue,
        in snapshot: SentinelSnapshot
    ) -> [Book]? {
        var ids = Set<UUID>()
        var sessionIDs = Set<UUID>()
        for subject in issue.subjects {
            switch subject.kind {
            case .book:
                if let id = UUID(uuidString: subject.id) { ids.insert(id) }
            case .session, .timing:
                if let id = UUID(uuidString: subject.id) { sessionIDs.insert(id) }
            default:
                break
            }
        }
        var books = snapshot.books.filter { ids.contains($0.id) }
        if !sessionIDs.isEmpty {
            books += snapshot.books.filter { book in
                book.sessions.contains { sessionIDs.contains($0.id) }
            }
        }
        var seen = Set<UUID>()
        return books.filter { seen.insert($0.id).inserted }
    }

    private static func needsGlobalScan(_ repairID: String) -> Bool {
        ["REP-009", "REP-011", "REP-014", "REP-015", "REP-016", "REP-019",
         "REP-020", "REP-021", "REP-022", "REP-023", "REP-024"].contains(repairID)
    }

    // MARK: - Plan helpers

    private static func makePlan(
        _ id: String,
        _ title: String,
        issue: SentinelIssue,
        rule: SentinelRuleMetadata,
        snapshot: SentinelSnapshot,
        summary: String,
        preview: [String],
        actions: [SentinelRepairAction]
    ) -> SentinelRepairPlan? {
        guard !actions.isEmpty else { return nil }
        return SentinelRepairPlan(
            id: id,
            title: title,
            riskClass: rule.riskClass,
            ruleIDs: [rule.ruleID],
            issueFingerprints: [issue.fingerprint],
            summary: summary,
            preview: preview,
            actions: actions,
            expectedGeneration: snapshot.generation)
    }

    private static func replaceBooks(
        _ books: [(previous: Book, updated: Book)]
    ) -> [SentinelRepairAction] {
        books
            .filter { $0.previous != $0.updated }
            .map { .replaceBook(bookID: $0.previous.id, expected: $0.previous, replacement: $0.updated) }
    }

    // MARK: - Sessions

    private static func closeOrphanSessions(
        _ issue: SentinelIssue,
        _ rule: SentinelRuleMetadata,
        _ snapshot: SentinelSnapshot,
        _ books: [Book],
        _ configuration: SentinelConfiguration,
        _ now: Date
    ) -> SentinelRepairPlan? {
        var changed: [(Book, Book)] = []
        var count = 0
        for book in books {
            var updated = book
            var touched = false
            for index in updated.sessions.indices {
                let session = updated.sessions[index]
                guard session.endTime == nil,
                      now.timeIntervalSince(session.startTime) > configuration.orphanSessionAge else { continue }
                let lastActivity = session.pageTimes
                    .compactMap { $0.endTime ?? $0.startTime }
                    .max() ?? session.startTime
                let end = min(now, lastActivity.addingTimeInterval(300))
                updated.sessions[index].endTime = end
                for timingIndex in updated.sessions[index].pageTimes.indices
                where updated.sessions[index].pageTimes[timingIndex].endTime == nil {
                    updated.sessions[index].pageTimes[timingIndex].endTime = end
                }
                if updated.activeSessionID == session.id {
                    updated.activeSessionID = nil
                }
                touched = true
                count += 1
            }
            if touched { changed.append((book, updated)) }
        }
        return makePlan(
            "REP-001", "Close reading sessions left open",
            issue: issue, rule: rule, snapshot: snapshot,
            summary: "Closes sessions that were left open at the last recorded page activity, not at the current time.",
            preview: ["Close \(count) session\(count == 1 ? "" : "s") at their last real activity."],
            actions: replaceBooks(changed))
    }

    private static func clearPhantomActiveSession(
        _ issue: SentinelIssue,
        _ rule: SentinelRuleMetadata,
        _ snapshot: SentinelSnapshot,
        _ books: [Book]
    ) -> SentinelRepairPlan? {
        var changed: [(Book, Book)] = []
        for book in books {
            guard let id = book.activeSessionID,
                  !book.sessions.contains(where: { $0.id == id }) else { continue }
            var updated = book
            updated.activeSessionID = nil
            changed.append((book, updated))
        }
        return makePlan(
            "REP-002", "Clear a broken active-session pointer",
            issue: issue, rule: rule, snapshot: snapshot,
            summary: "Clears a book's active-session id when no session with that id exists.",
            preview: ["Clear \(changed.count) dangling active-session pointer\(changed.count == 1 ? "" : "s")."],
            actions: replaceBooks(changed))
    }

    private static func pinSessionEnds(
        _ issue: SentinelIssue,
        _ rule: SentinelRuleMetadata,
        _ snapshot: SentinelSnapshot,
        _ books: [Book]
    ) -> SentinelRepairPlan? {
        var changed: [(Book, Book)] = []
        var count = 0
        for book in books {
            var updated = book
            var touched = false
            for index in updated.sessions.indices {
                if let end = updated.sessions[index].endTime, end < updated.sessions[index].startTime {
                    updated.sessions[index].endTime = updated.sessions[index].startTime
                    touched = true
                    count += 1
                }
            }
            if touched { changed.append((book, updated)) }
        }
        return makePlan(
            "REP-003", "Pin invalid session end times",
            issue: issue, rule: rule, snapshot: snapshot,
            summary: "Sets a session's end to its start when the recorded end is earlier.",
            preview: ["Pin \(count) session end\(count == 1 ? "" : "s") to the session start."],
            actions: replaceBooks(changed))
    }

    private static func pinTimings(
        _ issue: SentinelIssue,
        _ rule: SentinelRuleMetadata,
        _ snapshot: SentinelSnapshot,
        _ books: [Book]
    ) -> SentinelRepairPlan? {
        var changed: [(Book, Book)] = []
        var count = 0
        for book in books {
            var updated = book
            var touched = false
            for s in updated.sessions.indices {
                for t in updated.sessions[s].pageTimes.indices {
                    var timing = updated.sessions[s].pageTimes[t]
                    if let end = timing.endTime, end < timing.startTime {
                        timing.endTime = timing.startTime
                        touched = true
                        count += 1
                    }
                    if book.totalPages > 0 {
                        let clamped = max(0, min(book.totalPages - 1, timing.pageNumber))
                        if clamped != timing.pageNumber {
                            timing.pageNumber = clamped
                            touched = true
                            count += 1
                        }
                    }
                    updated.sessions[s].pageTimes[t] = timing
                }
            }
            if touched { changed.append((book, updated)) }
        }
        return makePlan(
            "REP-004", "Normalize page timings",
            issue: issue, rule: rule, snapshot: snapshot,
            summary: "Pins a negative page duration to zero and keeps page numbers inside the book.",
            preview: ["Normalize \(count) page timing\(count == 1 ? "" : "s")."],
            actions: replaceBooks(changed))
    }

    private static func closeOrphanTimings(
        _ issue: SentinelIssue,
        _ rule: SentinelRuleMetadata,
        _ snapshot: SentinelSnapshot,
        _ books: [Book]
    ) -> SentinelRepairPlan? {
        var changed: [(Book, Book)] = []
        var count = 0
        for book in books {
            var updated = book
            var touched = false
            for s in updated.sessions.indices {
                guard let sessionEnd = updated.sessions[s].endTime else { continue }
                for t in updated.sessions[s].pageTimes.indices
                where updated.sessions[s].pageTimes[t].endTime == nil {
                    updated.sessions[s].pageTimes[t].endTime = sessionEnd
                    touched = true
                    count += 1
                }
            }
            if touched { changed.append((book, updated)) }
        }
        return makePlan(
            "REP-005", "Close page timings in finished sessions",
            issue: issue, rule: rule, snapshot: snapshot,
            summary: "Gives an unfinished page timing the end time of its already-finished session.",
            preview: ["Close \(count) stranded page timing\(count == 1 ? "" : "s")."],
            actions: replaceBooks(changed))
    }

    // MARK: - Library

    private static func clampCurrentPage(
        _ issue: SentinelIssue,
        _ rule: SentinelRuleMetadata,
        _ snapshot: SentinelSnapshot,
        _ books: [Book]
    ) -> SentinelRepairPlan? {
        var changed: [(Book, Book)] = []
        var count = 0
        for book in books {
            guard book.totalPages > 0 else { continue }
            let clamped = max(0, min(book.totalPages - 1, book.currentPage))
            guard clamped != book.currentPage else { continue }
            var updated = book
            updated.currentPage = clamped
            changed.append((book, updated))
            count += 1
        }
        return makePlan(
            "REP-006", "Bring the current page back into the book",
            issue: issue, rule: rule, snapshot: snapshot,
            summary: "Clamps a book's current page to the first or last real page.",
            preview: ["Clamp \(count) book page position\(count == 1 ? "" : "s")."],
            actions: replaceBooks(changed))
    }

    private static func clampSessionPages(
        _ issue: SentinelIssue,
        _ rule: SentinelRuleMetadata,
        _ snapshot: SentinelSnapshot,
        _ books: [Book]
    ) -> SentinelRepairPlan? {
        var changed: [(Book, Book)] = []
        var count = 0
        for book in books where book.totalPages > 0 {
            var updated = book
            var touched = false
            let maxPage = book.totalPages - 1
            for index in updated.sessions.indices {
                var session = updated.sessions[index]
                if session.endPage < session.startPage {
                    session.endPage = session.startPage
                    touched = true
                    count += 1
                }
                let start = max(0, min(maxPage, session.startPage))
                let end = max(0, min(maxPage, session.endPage))
                if start != session.startPage || end != session.endPage {
                    session.startPage = min(start, end)
                    session.endPage = max(start, end)
                    touched = true
                    count += 1
                }
                updated.sessions[index] = session
            }
            if touched { changed.append((book, updated)) }
        }
        return makePlan(
            "REP-007", "Keep session pages inside the book",
            issue: issue, rule: rule, snapshot: snapshot,
            summary: "Ensures a session's page range is ordered and inside the book's real pages.",
            preview: ["Normalize \(count) session page range\(count == 1 ? "" : "s")."],
            actions: replaceBooks(changed))
    }

    private static func dedupeCollectionMembership(
        _ issue: SentinelIssue,
        _ rule: SentinelRuleMetadata,
        _ snapshot: SentinelSnapshot,
        _ books: [Book]
    ) -> SentinelRepairPlan? {
        var changed: [(Book, Book)] = []
        var removed = 0
        for book in books {
            var seen = Set<UUID>()
            let deduped = book.collectionIDs.filter { seen.insert($0).inserted }
            guard deduped.count != book.collectionIDs.count else { continue }
            var updated = book
            updated.collectionIDs = deduped
            changed.append((book, updated))
            removed += book.collectionIDs.count - deduped.count
        }
        return makePlan(
            "REP-008", "Remove duplicate collection memberships",
            issue: issue, rule: rule, snapshot: snapshot,
            summary: "Keeps the first occurrence of each collection on a book.",
            preview: ["Remove \(removed) duplicate membership\(removed == 1 ? "" : "s")."],
            actions: replaceBooks(changed))
    }

    private static func dedupeAchievements(
        _ issue: SentinelIssue,
        _ rule: SentinelRuleMetadata,
        _ snapshot: SentinelSnapshot
    ) -> SentinelRepairPlan? {
        let state = snapshot.libraryState
        var seen = Set<String>()
        let deduped = state.earnedAchievements.filter { seen.insert($0.kind.rawValue).inserted }
        guard deduped.count != state.earnedAchievements.count else { return nil }
        var updated = state
        updated.earnedAchievements = deduped
        return makePlan(
            "REP-009", "Remove duplicate earned achievements",
            issue: issue, rule: rule, snapshot: snapshot,
            summary: "Keeps one earned record per achievement kind.",
            preview: ["Remove \(state.earnedAchievements.count - deduped.count) duplicate achievement record(s)."],
            actions: [.replaceLibraryState(expected: state, replacement: updated)])
    }

    private static func stripDanglingCollections(
        _ issue: SentinelIssue,
        _ rule: SentinelRuleMetadata,
        _ snapshot: SentinelSnapshot,
        _ books: [Book]
    ) -> SentinelRepairPlan? {
        let valid = Set(snapshot.libraryState.collections.map(\.id))
        var changed: [(Book, Book)] = []
        var removed = 0
        for book in (books.isEmpty ? snapshot.books : books) {
            let kept = book.collectionIDs.filter { valid.contains($0) }
            guard kept.count != book.collectionIDs.count else { continue }
            var updated = book
            updated.collectionIDs = kept
            changed.append((book, updated))
            removed += book.collectionIDs.count - kept.count
        }
        return makePlan(
            "REP-010", "Remove references to deleted collections",
            issue: issue, rule: rule, snapshot: snapshot,
            summary: "Drops collection ids that no longer exist in the library.",
            preview: ["Remove \(removed) stale collection reference\(removed == 1 ? "" : "s")."],
            actions: replaceBooks(changed))
    }

    private static func pruneDeadlines(
        _ issue: SentinelIssue,
        _ rule: SentinelRuleMetadata,
        _ snapshot: SentinelSnapshot
    ) -> SentinelRepairPlan? {
        let state = snapshot.libraryState
        let bookIDs = Set(snapshot.books.map(\.id))
        var seen = Set<UUID>()
        let kept = state.deadlines.filter { deadline in
            guard bookIDs.contains(deadline.bookID) else { return false }
            return seen.insert(deadline.bookID).inserted
        }
        guard kept.count != state.deadlines.count else { return nil }
        var updated = state
        updated.deadlines = kept
        return makePlan(
            "REP-011", "Remove deadlines that cannot apply",
            issue: issue, rule: rule, snapshot: snapshot,
            summary: "Removes deadlines for missing books and keeps one deadline per book.",
            preview: ["Remove \(state.deadlines.count - kept.count) unusable deadline(s)."],
            actions: [.replaceLibraryState(expected: state, replacement: updated)])
    }

    private static func normalizeChapterRanges(
        _ issue: SentinelIssue,
        _ rule: SentinelRuleMetadata,
        _ snapshot: SentinelSnapshot,
        _ books: [Book]
    ) -> SentinelRepairPlan? {
        var changed: [(Book, Book)] = []
        var count = 0
        for book in books where book.totalPages > 0 {
            var updated = book
            var touched = false
            for index in updated.chapters.indices {
                var chapter = updated.chapters[index]
                let start = max(0, min(book.totalPages - 1, chapter.startPage))
                let end = max(start, min(book.totalPages - 1, chapter.endPage))
                if start != chapter.startPage || end != chapter.endPage {
                    chapter.startPage = start
                    chapter.endPage = end
                    updated.chapters[index] = chapter
                    touched = true
                    count += 1
                }
            }
            if touched { changed.append((book, updated)) }
        }
        return makePlan(
            "REP-017", "Keep chapter ranges inside the book",
            issue: issue, rule: rule, snapshot: snapshot,
            summary: "Clamps chapter start and end pages to the book and keeps end at or after start.",
            preview: ["Normalize \(count) chapter range\(count == 1 ? "" : "s")."],
            actions: replaceBooks(changed))
    }

    private static func dedupeNotes(
        _ issue: SentinelIssue,
        _ rule: SentinelRuleMetadata,
        _ snapshot: SentinelSnapshot,
        _ books: [Book]
    ) -> SentinelRepairPlan? {
        var changed: [(Book, Book)] = []
        var removed = 0
        for book in books {
            var seen = Set<UUID>()
            let kept = book.notes.filter { seen.insert($0.id).inserted }
            guard kept.count != book.notes.count else { continue }
            var updated = book
            updated.notes = kept
            changed.append((book, updated))
            removed += book.notes.count - kept.count
        }
        return makePlan(
            "REP-018", "Remove duplicate note records",
            issue: issue, rule: rule, snapshot: snapshot,
            summary: "Keeps the first copy of a note with a given id.",
            preview: ["Remove \(removed) duplicate note(s)."],
            actions: replaceBooks(changed))
    }

    private static func recomputeCachedSpeeds(
        _ issue: SentinelIssue,
        _ rule: SentinelRuleMetadata,
        _ snapshot: SentinelSnapshot
    ) -> SentinelRepairPlan? {
        var changed: [(Book, Book)] = []
        for book in snapshot.books {
            var updated = book
            var touched = false
            for index in updated.sessions.indices {
                let session = updated.sessions[index]
                guard session.pagesRead > 0 else { continue }
                let timed = session.pageTimes.filter { $0.duration > 0 }
                let computed: Double
                if !timed.isEmpty {
                    computed = timed.reduce(0) { $0 + $1.duration } / Double(timed.count)
                } else if session.duration > 0 {
                    computed = session.duration / Double(session.pagesRead)
                } else {
                    continue
                }
                if let cached = session.cachedAverageSecondsPerPage,
                   abs(cached - computed) < 0.05 { continue }
                updated.sessions[index].cachedAverageSecondsPerPage = computed
                touched = true
            }
            let bookAverage = updated.sessions
                .filter { $0.pagesRead > 0 && $0.endTime != nil }
                .map(\.averageSecondsPerPage)
                .filter { $0 > 0 }
            if !bookAverage.isEmpty {
                let mean = bookAverage.reduce(0, +) / Double(bookAverage.count)
                if let cached = updated.cachedSecondsPerPage, abs(cached - mean) < 0.05 {
                    // already correct
                } else {
                    updated.cachedSecondsPerPage = mean
                    touched = true
                }
            }
            if touched { changed.append((book, updated)) }
        }
        return makePlan(
            "REP-019", "Recompute cached reading speed",
            issue: issue, rule: rule, snapshot: snapshot,
            summary: "Recomputes cached seconds-per-page from the timings already on disk.",
            preview: ["Refresh cached speed on \(changed.count) book(s)."],
            actions: replaceBooks(changed))
    }

    private static func rebuildCoverFromEmbedded(
        _ issue: SentinelIssue,
        _ rule: SentinelRuleMetadata,
        _ snapshot: SentinelSnapshot,
        _ books: [Book]
    ) -> SentinelRepairPlan? {
        let actions: [SentinelRepairAction] = books.compactMap { book in
            guard let data = book.coverImageData, !data.isEmpty else { return nil }
            return .writeCover(bookID: book.id, data: data)
        }
        return makePlan(
            "REP-025", "Rebuild a cover from its embedded copy",
            issue: issue, rule: rule, snapshot: snapshot,
            summary: "Writes the cover file back from the copy stored inside the book record.",
            preview: ["Rebuild \(actions.count) cover file(s) from embedded data."],
            actions: actions)
    }

    // MARK: - Files

    private static func quarantineOrphanCover(
        _ issue: SentinelIssue,
        _ rule: SentinelRuleMetadata,
        _ snapshot: SentinelSnapshot
    ) -> SentinelRepairPlan? {
        guard let covers = snapshot.coversRoot,
              let subject = issue.subjects.first(where: { $0.kind == .cover }) else { return nil }
        let url = covers.appendingPathComponent(subject.id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return makePlan(
            "REP-012", "Quarantine an unused cover file",
            issue: issue, rule: rule, snapshot: snapshot,
            summary: "Moves a cover that belongs to no book into Sentinel's quarantine, where it can be restored.",
            preview: ["Move 1 unused cover file to quarantine."],
            actions: [.quarantineFile(source: url, name: "cover-\(subject.id)")])
    }

    private static func quarantineCorruptCover(
        _ issue: SentinelIssue,
        _ rule: SentinelRuleMetadata,
        _ snapshot: SentinelSnapshot
    ) -> SentinelRepairPlan? {
        guard let covers = snapshot.coversRoot,
              let subject = issue.subjects.first(where: { $0.kind == .cover }) else { return nil }
        let url = covers.appendingPathComponent(subject.id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return makePlan(
            "REP-013", "Quarantine a damaged cover file",
            issue: issue, rule: rule, snapshot: snapshot,
            summary: "Moves an unreadable cover aside so it is never shown as a broken image.",
            preview: ["Move 1 damaged cover file to quarantine."],
            actions: [.quarantineFile(source: url, name: "corrupt-cover-\(subject.id)")])
    }

    private static func quarantineBehaviorArchive(
        _ issue: SentinelIssue,
        _ rule: SentinelRuleMetadata,
        _ snapshot: SentinelSnapshot
    ) -> SentinelRepairPlan? {
        guard let url = snapshot.behaviorEvidenceURL,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return makePlan(
            "REP-024", "Quarantine a corrupt behavior archive",
            issue: issue, rule: rule, snapshot: snapshot,
            summary: "Moves an unreadable behavior archive aside; the engine starts a fresh one.",
            preview: ["Move the behavior archive to quarantine."],
            actions: [.quarantineFile(source: url, name: "behavior-evidence-corrupt.json")])
    }

    private static func quarantineOldBackups(
        _ issue: SentinelIssue,
        _ rule: SentinelRuleMetadata,
        _ snapshot: SentinelSnapshot
    ) -> SentinelRepairPlan? {
        guard let backups = snapshot.backupsRoot else { return nil }
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: backups.path)) ?? []
        let files = names.filter { $0.hasSuffix(".sqlite3") || $0.hasSuffix(".readingarchive") || $0.hasSuffix(".json") }
            .sorted()
        let keep = 10
        guard files.count > keep else { return nil }
        let stale = files.dropLast(keep)
        let actions: [SentinelRepairAction] = stale.map { name in
            .quarantineFile(source: backups.appendingPathComponent(name), name: "backup-\(name)")
        }
        return makePlan(
            "REP-021", "Prune old backups into quarantine",
            issue: issue, rule: rule, snapshot: snapshot,
            summary: "Keeps the ten newest backups and moves older ones to Sentinel's quarantine.",
            preview: ["Quarantine \(actions.count) old backup file(s)."],
            actions: actions)
    }

    private static func quarantineStaleTemp(
        _ issue: SentinelIssue,
        _ rule: SentinelRuleMetadata,
        _ snapshot: SentinelSnapshot,
        _ now: Date
    ) -> SentinelRepairPlan? {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: snapshot.tempRoot.path)) ?? []
        var actions: [SentinelRepairAction] = []
        for name in names where name.lowercased().contains("asterisma") {
            let url = snapshot.tempRoot.appendingPathComponent(name)
            guard let date = (try? manager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(date) > 86_400 else { continue }
            actions.append(.quarantineFile(source: url, name: "temp-\(name)"))
        }
        return makePlan(
            "REP-022", "Clean up stale import temp files",
            issue: issue, rule: rule, snapshot: snapshot,
            summary: "Moves abandoned import scratch files into Sentinel's quarantine.",
            preview: ["Quarantine \(actions.count) stale temp item(s)."],
            actions: actions)
    }

    // MARK: - System

    private static func checkpoint(
        _ issue: SentinelIssue,
        _ rule: SentinelRuleMetadata,
        _ snapshot: SentinelSnapshot
    ) -> SentinelRepairPlan? {
        guard snapshot.sqliteInUse else { return nil }
        return makePlan(
            "REP-014", "Checkpoint the database write-ahead log",
            issue: issue, rule: rule, snapshot: snapshot,
            summary: "Asks SQLite to fold the WAL back into the main database file.",
            preview: ["Checkpoint the write-ahead log."],
            actions: [.checkpointDatabase])
    }

    private static func trimJournal(
        _ issue: SentinelIssue,
        _ rule: SentinelRuleMetadata,
        _ snapshot: SentinelSnapshot
    ) -> SentinelRepairPlan? {
        makePlan(
            "REP-015", "Trim the Sentinel journal to its budget",
            issue: issue, rule: rule, snapshot: snapshot,
            summary: "Deletes the oldest journal segments until the size budget is met. The newest segment is kept.",
            preview: ["Remove oldest journal segments."],
            actions: [.trimJournal(maxBytes: 10 * 1_000_000)])
    }

    private static func trimDebugJournal(
        _ issue: SentinelIssue,
        _ rule: SentinelRuleMetadata,
        _ snapshot: SentinelSnapshot
    ) -> SentinelRepairPlan? {
        makePlan(
            "REP-020", "Trim the Debug detail journal",
            issue: issue, rule: rule, snapshot: snapshot,
            summary: "Drops debug-only detail beyond its retention. Safe journal records are untouched.",
            preview: ["Trim debug detail to its budget."],
            actions: [.trimDebugJournal(maxBytes: 5 * 1_000_000)])
    }

    private static func rebuildIssueStore(
        _ issue: SentinelIssue,
        _ rule: SentinelRuleMetadata,
        _ snapshot: SentinelSnapshot
    ) -> SentinelRepairPlan? {
        makePlan(
            "REP-016", "Rebuild Sentinel's issue memory from its journal",
            issue: issue, rule: rule, snapshot: snapshot,
            summary: "Archives the current state file and reconstructs issue identity from journal events.",
            preview: ["Archive state.json and replay the journal."],
            actions: [.rebuildIssueStore])
    }

    private static func resetNotifications(
        _ issue: SentinelIssue,
        _ rule: SentinelRuleMetadata,
        _ snapshot: SentinelSnapshot
    ) -> SentinelRepairPlan? {
        makePlan(
            "REP-023", "Reset Sentinel's notification bookkeeping",
            issue: issue, rule: rule, snapshot: snapshot,
            summary: "Clears Sentinel's own notification counters so a denied permission does not look like a delivered alert.",
            preview: ["Reset notification bookkeeping."],
            actions: [.resetNotificationState])
    }
}
