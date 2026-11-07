//  EnvironmentAnchorPeriod.swift
//  AsterismaV2.5
//
//  Environment Engine — Phase B (Part 5.2 of the build spec)
//
//  The four named anchor periods in the Environment Engine's 24-hour cycle.
//  Night and Midday are described in the brief as points the system settles
//  at or briefly crosses rather than periods with their own internal
//  evolution — see the design note in EnvironmentPalette.keyframeTrack for
//  how that's represented without any special-cased branching.
//

import Foundation

enum EnvironmentAnchorPeriod: String, CaseIterable, Sendable {
    case night
    case morning
    case midday
    case afternoon

    /// Title-case label for the Debug studio's computed-state readout. The
    /// renderer itself never shows this — it reads colors and weights only.
    var displayName: String {
        switch self {
        case .night: return "Night"
        case .morning: return "Morning"
        case .midday: return "Midday"
        case .afternoon: return "Afternoon"
        }
    }
}

/// Converts wall-clock time into fractional minutes-since-midnight — the
/// unit `EnvironmentPalette.keyframeTrack` is indexed by. Kept fractional
/// (not rounded to whole minutes) so the eased interpolation is smooth even
/// though the engine only recomputes every 30-60s (Part 5.3): each tick
/// still lands at the precise "now," it just doesn't tick every frame.
///
/// This is the ONLY place in the Environment Engine that touches `Date()`
/// directly — every view reads `EnvironmentState`, never the wall clock, per
/// Part 5.1's explicit rule (verifiable by grepping this feature for
/// `Date()` once Phase B-E is complete: this file is the only hit besides
/// EnvironmentEngine's own `now: () -> Date` injection point).
enum AnchorClock {
    static func fractionalMinutesSinceMidnight(for date: Date, calendar: Calendar = .current) -> Double {
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        let hour = Double(components.hour ?? 0)
        let minute = Double(components.minute ?? 0)
        let second = Double(components.second ?? 0)
        return hour * 60 + minute + second / 60.0
    }
}
