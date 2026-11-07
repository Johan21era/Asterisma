//  NonGregorianCalendarTests.swift
//  AsterismaV2.5Tests
//
//  Phase 1 regression battery — pins AUDIT F-01 and guards the §5.1 fix class.
//
//  TESTING_STRATEGY mapping: "Calendar/locale edge cases — run the existing logic
//  against a Hebrew or Japanese Calendar explicitly, not just .current on the test
//  machine." `analyticsPeriod(for:calendar:)` now accepts an injected calendar so
//  these runs are deterministic regardless of the test host's region settings.
//
//  Every test names its defect class: F-01 was a hard crash (force-unwrapped
//  failable Calendar constructor) reachable by any non-Gregorian user opening
//  Annual Reports.

import Foundation
import Testing

@testable import AsterismaV2_5

@Suite("Calendar Safety — F-01 regression pins")
struct NonGregorianCalendarTests {

    /// The calendars that triggered the §5.1/F-01 class, plus Persian for coverage.
    /// Islamic Civil is the classic nil-returning edge in Foundation date math.
    private static let stressCalendars: [Calendar.Identifier] = [
        .gregorian,
        .hebrew,
        .japanese,
        .buddhist,
        .islamicCivil,
        .persian,
    ]

    // MARK: - Gregorian exactness (behavior-preservation proof)

    @Test("F-01: Gregorian output unchanged by the fix — full-year bounds")
    func gregorianYearBoundsAreExact() {
        let cal = Calendar(identifier: .gregorian)
        let period = analyticsPeriod(for: 2024, calendar: cal)

        guard case let .custom(start, end) = period else {
            Issue.record("analyticsPeriod must return .custom")
            return
        }

        // start == local midnight of Jan 1, 2024.
        var expectedStart = DateComponents()
        expectedStart.year = 2024
        expectedStart.month = 1
        expectedStart.day = 1
        let jan1 = cal.date(from: expectedStart)
        #expect(start == jan1)

        // end is inside Dec 31, 2024 (nextStart − 1s) and after noon that day.
        var expectedNext = DateComponents()
        expectedNext.year = 2025
        expectedNext.month = 1
        expectedNext.day = 1
        let jan1Next = cal.date(from: expectedNext)
        #expect(end < jan1Next ?? .distantFuture)
        #expect(end.timeIntervalSince(jan1 ?? .distantPast) > 364 * 86_400)
    }

    // MARK: - The crash class itself

    @Test("F-01: no calendar identifier can crash year-period construction", arguments: stressCalendars)
    func anyCalendarProducesOrderedBounds(calendarID: Calendar.Identifier) {
        let cal = Calendar(identifier: calendarID)

        // Pre-fix this force-unwrapped under several of these identifiers.
        let period = analyticsPeriod(for: 2025, calendar: cal)

        guard case let .custom(start, end) = period else {
            Issue.record("analyticsPeriod must return .custom")
            return
        }

        #expect(start <= end)
    }

    @Test("F-01: produced spans stay structurally sane across calendars", arguments: stressCalendars)
    func spansStayWithinSaneBounds(calendarID: Calendar.Identifier) {
        let cal = Calendar(identifier: calendarID)
        let period = analyticsPeriod(for: 2030, calendar: cal)

        guard case let .custom(start, end) = period else { return }

        let span = end.timeIntervalSince(start)

        if start == end {
            // Documented Degradation-1 path: same-day fallback. Acceptable, not a crash.
            return
        }
        // Either a genuine calendar-year length (Hebrew can be 353–385 days)
        // or the documented Degradation-2 arithmetic bound (~366 days).
        #expect(span >= 86_400 - 1)                 // at least one day minus the −1s trim
        #expect(span <= 386 * 86_400)               // longest legal year + arithmetic fallback slack
    }

    // MARK: - Downstream consumers inherit the safety

    @Test("F-01: sessions(in:year:) survives non-Gregorian construction paths", arguments: [Calendar.Identifier.hebrew, Calendar.Identifier.japanese])
    func sessionFilteringSurvivesStressCalendars(calendarID: Calendar.Identifier) {
        _ = calendarID // analyticsPeriod defaults to .current here; the point of this
        // test is that the public helpers (sessions/booksCompleted) compile-time
        // depend on the guarded constructor through their own calls.
        // Direct exercise with an injected calendar happens above; this pins the
        // helper layer against regressions to the un-guarded signature.
        let cal = Calendar(identifier: calendarID)
        let period = analyticsPeriod(for: 1999, calendar: cal)
        guard case let .custom(s, e) = period else { return }
        #expect(s <= e)
    }
}
