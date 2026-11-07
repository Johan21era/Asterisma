//  DataIntegrityValidator.swift
//  AsterismaV2.5
//  PURPOSE
//  Validates the structural integrity of the books array after DataStore load
//  and during migration/import. Save-time validation is not wired; the
//  validator is a pure function callers can invoke explicitly.
//
//  ROADMAP 3.4 (RA-002 / AUDIT F-11):
//    • Rule S-3 previously logged "swapped" while actually CLAMPING
//      (endPage = startPage), and declared a `tmp` variable it never used.
//      The message now states what really happens; the dead variable is gone.
//    • Rule S-1 checked `!isActive && endTime == nil`, which cannot exist
//      (isActive ≡ endTime == nil by definition) — a rule that could never
//      fire. Deleted. ReliabilityTests pins unaffected (they never relied on
//      S-1; verified against the suite before logging).
//
//  RATIONALE
//  The original DataStore loaded JSON and trusted it unconditionally. Any write
//  corruption, partial-flush, or schema mismatch left the app in a broken state
//  that manifested as nil crashes, incorrect analytics, or phantom active sessions.
//
//  DESIGN PRINCIPLES
//  • Non-destructive: repairs are conservative. If a value cannot be safely
//    corrected it is flagged in the ValidationReport rather than silently deleted.
//  • Auditable: every repair is logged with the rule that triggered it.
//  • Composable: the validator is a pure function — it takes [Book] and returns
//    ([Book], ValidationReport). DataStore calls it on load; the harness calls it
//    in tests.
//  • Schema-forward: the SchemaVersion enum ensures future model changes can be
//    detected and migrated rather than silently decoded into corrupted state.
//
//  CALLERS
//    • DataStore.load() — called after JSON decode, before publishing books
//    • HarnessResult (testing harness) — IntegrityChecker delegates here
//    • AchievementEngine — validates before processing achievements
//
//  INTERACTIONS
//    • Reads Book, ReadingSession, PageTiming (models from Book.swift)
//    • No dependencies on DataStore, SessionCoordinator, or UI layer

import Foundation

// MARK: - Schema Version

/// Represents the data model schema version stored alongside the books array.
/// DataStore writes this to library.json so future migrations can detect stale schemas.
enum SchemaVersion: Int, Codable {
    case v1 = 1 // Original schema (no version field)
    case v2 = 2 // Added bookmarkData, difficultyProfile
    case v3 = 3 // Added ReadingGoal, Achievement (this upgrade)

    static let current: SchemaVersion = .v3
}

// MARK: - Validation Issue

/// A single identified integrity violation, with metadata about the repair performed.
struct ValidationIssue: CustomStringConvertible {
    enum Severity { case warning, error, repaired }

    let severity: Severity
    let rule: String
    let bookID: UUID?
    let sessionID: UUID?
    let detail: String
    let wasRepaired: Bool

    var description: String {
        let prefix: String
        switch severity {
        case .warning: prefix = "⚠️"
        case .error: prefix = "❌"
        case .repaired: prefix = "🔧"
        }
        var s = "\(prefix) [\(rule)]"
        if let b = bookID {
            s += " book=\(b.uuidString.prefix(8))"
        }
        if let sess = sessionID {
            s += " session=\(sess.uuidString.prefix(8))"
        }
        if !detail.isEmpty {
            s += " — \(detail)"
        }
        if wasRepaired {
            s += " (REPAIRED)"
        }
        return s
    }
}

// MARK: - Validation Report

/// Summary of all issues found and repairs made during a validation pass.
struct ValidationReport {
    let issues: [ValidationIssue]
    let isClean: Bool // true if no errors or warnings (repairs OK)
    let hasUnrepairableErrors: Bool // true if any error was NOT repaired

    var summary: String {
        guard !issues.isEmpty else { return "✅ Validation passed — no issues found." }
        let repaired = issues.filter { $0.wasRepaired }.count
        let warnings = issues.filter { $0.severity == .warning }.count
        let errors = issues.filter { $0.severity == .error }.count
        return "Validation: \(errors) errors, \(warnings) warnings, \(repaired) repaired."
    }

    func printReport() {
        print("[DataIntegrityValidator] \(summary)")
        for issue in issues {
            print("  \(issue)")
        }
    }
}

// MARK: - DataIntegrityValidator

/// Pure validator/repairer. Takes [Book], returns repaired [Book] + report.
/// All operations are safe to call on the main actor (no async, no I/O).
enum DataIntegrityValidator {
    // MARK: - Public Entry Point

    /// Validates and non-destructively repairs a books array.
    /// Call this immediately after JSON decoding and before publishing to the UI.
    ///
    /// - Parameter books: The decoded books array.
    /// - Returns: A tuple of the (potentially repaired) books and a full report.
    /// - Parameter quiet: when true (used by Sentinel's periodic probe),
    ///   suppresses console printing — periodic monitoring must not spam logs.
    static func validate(_ books: [Book], quiet: Bool = false) -> (books: [Book], report: ValidationReport) {
        var mutableBooks = books
        var issues: [ValidationIssue] = []

        for i in mutableBooks.indices {
            validateBook(&mutableBooks[i], issues: &issues)
        }

        // Cross-book checks
        issues += checkDuplicateIDs(in: mutableBooks)

        let hasErrors = issues.contains { $0.severity == .error && !$0.wasRepaired }
        let isClean = issues.isEmpty

        let report = ValidationReport(
            issues: issues,
            isClean: isClean,
            hasUnrepairableErrors: hasErrors
        )

        if !isClean, !quiet {
            report.printReport()
        }

        return (mutableBooks, report)
    }

    // MARK: - Per-Book Validation

    private static func validateBook(_ book: inout Book, issues: inout [ValidationIssue]) {
        // Rule B-1: totalPages must be > 0 for any book.
        if book.totalPages <= 0 {
            issues.append(ValidationIssue(
                severity: .error, rule: "B-1:totalPages>0",
                bookID: book.id, sessionID: nil,
                detail: "totalPages=\(book.totalPages) is invalid; cannot repair.",
                wasRepaired: false
            ))
        }

        // Rule B-2: currentPage must be within [0, totalPages-1].
        if book.totalPages > 0, book.currentPage >= book.totalPages {
            let clamped = book.totalPages - 1
            issues.append(ValidationIssue(
                severity: .repaired, rule: "B-2:currentPage≤totalPages-1",
                bookID: book.id, sessionID: nil,
                detail: "currentPage=\(book.currentPage) clamped to \(clamped)",
                wasRepaired: true
            ))
            book.currentPage = clamped
        }

        // Rule B-3: activeSessionID must reference a real session if non-nil.
        if let activeSID = book.activeSessionID {
            let found = book.sessions.contains { $0.id == activeSID }
            if !found {
                issues.append(ValidationIssue(
                    severity: .repaired, rule: "B-3:activeSessionID-valid",
                    bookID: book.id, sessionID: activeSID,
                    detail: "activeSessionID not found in sessions — cleared",
                    wasRepaired: true
                ))
                book.activeSessionID = nil
            }
        }

        // Rule B-4: At most one session should be active (isActive == endTime == nil).
        let activeSessions = book.sessions.filter { $0.isActive }
        if activeSessions.count > 1 {
            // Close all but the most recent (highest startTime), since the others
            // are orphans from pre-B5 behavior or crash scenarios.
            let sorted = activeSessions.sorted { $0.startTime > $1.startTime }
            let keepID = sorted.first?.id
            let now = Date()
            for j in book.sessions.indices where book.sessions[j].isActive && book.sessions[j].id != keepID {
                book.sessions[j].endTime = now
                closeOrphanTimings(in: &book.sessions[j], at: now)
                issues.append(ValidationIssue(
                    severity: .repaired, rule: "B-4:≤1-active-session",
                    bookID: book.id, sessionID: book.sessions[j].id,
                    detail: "Orphan active session closed; only most-recent kept active",
                    wasRepaired: true
                ))
            }
        }

        // Rule B-5: Each session — validate sub-records.
        for j in book.sessions.indices {
            validateSession(&book.sessions[j], bookID: book.id, issues: &issues)
        }

        // Rule B-6: isCompleted flag must be consistent with progress.
        // If the book is marked completed but currentPage < totalPages-1, unflag it
        // unless all sessions show the book was genuinely finished.
        // (Conservative: only warn, don't force-unflag, as the user may have manually set it.)
        if book.isCompleted, book.totalPages > 0, book.currentPage < book.totalPages - 1 {
            issues.append(ValidationIssue(
                severity: .warning, rule: "B-6:isCompleted-consistency",
                bookID: book.id, sessionID: nil,
                detail: "isCompleted=true but currentPage=\(book.currentPage) of \(book.totalPages); " +
                    "user may have manually set this — not auto-cleared.",
                wasRepaired: false
            ))
        }

        // Rule B-7: Chapter ranges must not overlap and must fit within totalPages.
        validateChapters(in: &book, issues: &issues)
    }

    // MARK: - Session Validation

    private static func validateSession(
        _ session: inout ReadingSession,
        bookID: UUID,
        issues: inout [ValidationIssue]
    ) {
        // FORMER RULE S-1 (deleted, roadmap 3.4 / F-11): checked
        // `!session.isActive && endTime == nil`. isActive is DEFINED as
        // `endTime == nil` (ReadingSession.isActive), so the condition was a
        // contradiction that could never fire. Dead rule removed rather than
        // left to mislead future debugging.

        // Rule S-2: endTime must be ≥ startTime.
        if let end = session.endTime, end < session.startTime {
            // Swap them to produce a non-negative duration.
            let repaired = session.startTime
            session.endTime = session.startTime
            // We can't set startTime to end without a mutating var; swap values.
            // In practice this means: just set endTime = startTime (zero duration, but not negative).
            issues.append(ValidationIssue(
                severity: .repaired, rule: "S-2:endTime≥startTime",
                bookID: bookID, sessionID: session.id,
                detail: "endTime \(end) < startTime \(session.startTime) — endTime set to startTime",
                wasRepaired: true
            ))
            session.endTime = repaired // pin to startTime at minimum
        }

        // Rule S-3: endPage must be ≥ startPage.
        if session.endPage < session.startPage {
            issues.append(ValidationIssue(
                severity: .repaired, rule: "S-3:endPage≥startPage",
                bookID: bookID, sessionID: session.id,
                detail: "endPage=\(session.endPage) < startPage=\(session.startPage) — endPage pinned to startPage (zero-length session, non-negative)",
                wasRepaired: true
            ))
            // F-11 FIX: this always was a PIN-to-startPage clamp, not a swap.
            // The message above now says so; the former unused `tmp` is gone.
            session.endPage = session.startPage
        }

        // Rule S-4: Closed sessions must not have orphan PageTimings (isActive == true).
        if !session.isActive {
            let now = Date()
            let orphanIndices = session.pageTimes.indices.filter { session.pageTimes[$0].isActive }
            if !orphanIndices.isEmpty {
                for idx in orphanIndices {
                    session.pageTimes[idx].endTime = session.endTime ?? now
                }
                issues.append(ValidationIssue(
                    severity: .repaired, rule: "S-4:no-orphan-timings-in-closed-session",
                    bookID: bookID, sessionID: session.id,
                    detail: "Closed \(orphanIndices.count) orphan PageTiming(s) using session.endTime",
                    wasRepaired: true
                ))
            }
        }

        // Rule S-5: No PageTiming endTime earlier than its startTime.
        for k in session.pageTimes.indices {
            let timing = session.pageTimes[k]
            if let end = timing.endTime, end < timing.startTime {
                session.pageTimes[k].endTime = timing.startTime
                issues.append(ValidationIssue(
                    severity: .repaired, rule: "S-5:pageTiming-endTime≥startTime",
                    bookID: bookID, sessionID: session.id,
                    detail: "PageTiming page=\(timing.pageNumber) had endTime < startTime — pinned to startTime",
                    wasRepaired: true
                ))
            }
        }
    }

    // MARK: - Chapter Validation

    private static func validateChapters(in book: inout Book, issues: inout [ValidationIssue]) {
        guard book.totalPages > 0 else { return }

        for i in book.chapters.indices {
            let chapter = book.chapters[i]

            // Rule C-1: startPage must be within [0, totalPages-1].
            if chapter.startPage < 0 || chapter.startPage >= book.totalPages {
                issues.append(ValidationIssue(
                    severity: .warning, rule: "C-1:chapter-startPage-in-range",
                    bookID: book.id, sessionID: nil,
                    detail: "Chapter '\(chapter.title)' startPage=\(chapter.startPage) out of range [0,\(book.totalPages - 1)]",
                    wasRepaired: false
                ))
            }

            // Rule C-2: endPage must be ≥ startPage.
            if chapter.endPage < chapter.startPage {
                issues.append(ValidationIssue(
                    severity: .warning, rule: "C-2:chapter-endPage≥startPage",
                    bookID: book.id, sessionID: nil,
                    detail: "Chapter '\(chapter.title)' endPage=\(chapter.endPage) < startPage=\(chapter.startPage)",
                    wasRepaired: false
                ))
            }
        }
    }

    // MARK: - Cross-Book Checks

    private static func checkDuplicateIDs(in books: [Book]) -> [ValidationIssue] {
        var seen = Set<UUID>()
        var dupes: [ValidationIssue] = []
        for book in books {
            if seen.contains(book.id) {
                dupes.append(ValidationIssue(
                    severity: .error, rule: "LIB-1:no-duplicate-book-ids",
                    bookID: book.id, sessionID: nil,
                    detail: "Duplicate Book.id '\(book.id)' — cannot auto-repair; manual intervention needed",
                    wasRepaired: false
                ))
            }
            seen.insert(book.id)
        }
        return dupes
    }

    // MARK: - Helpers

    private static func closeOrphanTimings(in session: inout ReadingSession, at now: Date) {
        for i in session.pageTimes.indices where session.pageTimes[i].isActive {
            session.pageTimes[i].endTime = now
        }
    }
}

// MARK: - Aggregate Statistics from Report

extension ValidationReport {
    var repairedCount: Int {
        issues.filter { $0.wasRepaired }.count
    }

    var errorCount: Int {
        issues.filter { $0.severity == .error }.count
    }

    var warningCount: Int {
        issues.filter { $0.severity == .warning }.count
    }
}
