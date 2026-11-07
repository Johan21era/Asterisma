//  FatigueAnalyzerTests.swift
//  AsterismaV2.5Tests
//
//  Phase 2 regression battery — pins AUDIT F-06.
//
//  Defect class being pinned: the fatigue analyzer sorted gaps BY DURATION and
//  then counted "consecutive increases" inside that sorted array — a near-
//  tautology that fired on almost any ≥3-gap input regardless of chronology.
//  These fixtures prove chronological discrimination: interleaved timelines that
//  the old code flagged must now stay silent, and genuine chronological runs
//  must fire, dated from real gap boundaries instead of Date().

import Foundation
import Testing

@testable import AsterismaV2_5

@Suite("Behavior Context — F-06 fatigue analyzer pins")
struct FatigueAnalyzerTests {

    private let cal = Calendar(identifier: .gregorian)

    /// Convenience: a gap on a specific day at a specific hour with a duration.
    private func gap(day: Int, hour: Int, minutes: Double,
                     type: InactivityGapType,
                     followedBy: UUID? = nil) -> InactivityGapRecord {
        let start = cal.date(from: DateComponents(year: 2025, month: 3, day: day, hour: hour))!
        return InactivityGapRecord(
            startDate: start,
            endDate: start.addingTimeInterval(minutes * 60),
            gapDuration: minutes * 60,
            precededSession: followedBy,
            followedSession: nil,
            gapType: type
        )
    }

    // MARK: - The tautology killer

    @Test("F-06: interleaved chronology with big durations stays SILENT (old code fired here)")
    func interleavedTimelineDoesNotFire() {
        // Chronology: 5min → 60min → 6min → 70min. Duration-sorted (old behavior)
        // reads [5,6,60,70] → three consecutive "increases" → false signal.
        let gaps = [
            gap(day: 1, hour: 8, minutes: 5, type: .moderate),
            gap(day: 2, hour: 9, minutes: 60, type: .extended),
            gap(day: 3, hour: 8, minutes: 6, type: .moderate),
            gap(day: 4, hour: 9, minutes: 70, type: .extended),
        ]
        let signals = FatigueIndicatorAnalyzer().analyze(gaps: gaps)
        #expect(!signals.contains { $0.signalType == .increasingGaps },
                "duration-sorted tautology must not resurrect")
    }

    @Test("F-06: a genuinely increasing CHRONOLOGICAL run fires exactly once, dated at the run's end")
    func genuineIncreasingRunFires() {
        let gaps = [
            gap(day: 1, hour: 20, minutes: 40, type: .moderate),      // Mar 1 late
            gap(day: 2, hour: 21, minutes: 50, type: .extended),      // Mar 2
            gap(day: 3, hour: 22, minutes: 65, type: .extended),      // Mar 3
        ]
        let signals = FatigueIndicatorAnalyzer().analyze(gaps: gaps)
        let increasing = signals.filter { $0.signalType == .increasingGaps }
        #expect(increasing.count == 1)
        #expect(increasing.first?.date == gaps[2].endDate)
    }

    // MARK: - Per-day extended-gap grouping

    @Test("F-06: two extended gaps on the SAME day → one per-day signal dated that day")
    func sameDayExtendedFiresOnce() {
        let gaps = [
            gap(day: 5, hour: 10, minutes: 45, type: .extended),
            gap(day: 5, hour: 18, minutes: 90, type: .longBreak),
        ]
        let signals = FatigueIndicatorAnalyzer().analyze(gaps: gaps)
        let multi = signals.filter { $0.signalType == .multipleExtendedGaps }
        #expect(multi.count == 1)
        #expect(multi.first?.date == cal.startOfDay(for: gaps[0].startDate))
    }

    @Test("F-06: extended gaps spread across different days do NOT group")
    func spreadExtendedDoesNotFire() {
        let gaps = [
            gap(day: 5, hour: 10, minutes: 45, type: .extended),
            gap(day: 6, hour: 10, minutes: 90, type: .longBreak),
            gap(day: 7, hour: 10, minutes: 100, type: .longBreak),
        ]
        let signals = FatigueIndicatorAnalyzer().analyze(gaps: gaps)
        #expect(!signals.contains { $0.signalType == .multipleExtendedGaps })
    }

    // MARK: - Overnight dating + precondition

    @Test("F-06: overnight gap with a following session emits, dated at gap end")
    func overnightEmitsDatedAtGapEnd() {
        let followingSessionID = UUID()
        let g = gap(day: 9, hour: 23, minutes: 600, type: .overnight, followedBy: followingSessionID)
        let signals = FatigueIndicatorAnalyzer().analyze(gaps: [g])
        let overnight = signals.filter { $0.signalType == .overnightFollowedByBrief }
        #expect(overnight.count == 1)
        #expect(overnight.first?.date == g.endDate)
    }

    @Test("F-06: overnight gap without a following session stays silent")
    func overnightWithoutFollowingStaysSilent() {
        let g = gap(day: 9, hour: 23, minutes: 600, type: .overnight, followedBy: nil)
        let signals = FatigueIndicatorAnalyzer().analyze(gaps: [g])
        #expect(signals.isEmpty)
    }

    @Test("F-06: empty input yields zero signals")
    func emptyInputYieldsNothing() {
        #expect(FatigueIndicatorAnalyzer().analyze(gaps: []).isEmpty)
    }
}
