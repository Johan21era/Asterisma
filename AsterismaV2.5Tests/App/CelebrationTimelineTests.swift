//  CelebrationTimelineTests.swift
//  AsterismaV2.5Tests
//
//  Phase 1 regression battery — pins AUDIT F-02.
//
//  Defect class being pinned: the old overlay chained Timer→Task→Timer with a
//  cleanup() that could only invalidate whichever Timers existed *at its instant*;
//  dismissal landing between one timer firing and its Task hop orphaned the next
//  phase (and eventually a repeating particle timer) on a dead view. The extracted
//  CelebrationTimeline makes that race deterministically testable: an injected
//  sleeper that "dismisses" mid-sequence must provably silence every later step.

import Foundation
import Testing

@testable import AsterismaV2_5

/// Mutable cancellation flag shared between the test and the fake sleeper.
private final class DismissalFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var dismissed = false

    func dismiss() {
        lock.lock()
        dismissed = true
        lock.unlock()
    }

    var isDismissed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return dismissed
    }
}

@Suite("New Year Celebration — F-02 regression pins")
struct CelebrationTimelineTests {

    private static let timeline = CelebrationTimeline.standard

    @Test("F-02: full, undismissed run reaches all three steps in order")
    func fullRunReachesEveryStep() async {
        var steps: [CelebrationTimeline.Step] = []
        await Self.timeline.run { steps.append($0) }
            sleep: { _ in true }   // every dwell completes normally

        #expect(steps == [.expand, .fullscreen, .autoExit])
    }

    @Test("F-02: dismissal during toast dwell silences ALL later steps (the §8.1 race)")
    func dismissDuringToastSilencesEverything() async {
        let flag = DismissalFlag()
        var calls = 0
        var steps: [CelebrationTimeline.Step] = []

        await Self.timeline.run { steps.append($0) }
            sleep: { _ in
                calls += 1
                if calls == 1 {
                    // The view disappears during the FIRST dwell — cleanup() runs,
                    // cancelling whatever the old code would have scheduled next.
                    flag.dismiss()
                    return false
                }
                return !flag.isDismissed
            }

        #expect(steps.isEmpty,
                "no step may fire after dismissal during the first phase")
    }

    @Test("F-02: dismissal between expand and fullscreen cannot reach autoExit")
    func dismissMidExpandCannotReachAutoExit() async {
        let flag = DismissalFlag()
        var calls = 0
        var steps: [CelebrationTimeline.Step] = []

        await Self.timeline.run { steps.append($0) }
            sleep: { _ in
                calls += 1
                if calls == 2 {
                    flag.dismiss()   // gone before fullscreen dwell begins
                    return false
                }
                return !flag.isDismissed
            }

        #expect(steps == [.expand])
        #expect(!steps.contains(.autoExit))
        #expect(!steps.contains(.fullscreen))
    }

    @Test("F-02: dismissal during fullscreen dwell blocks autoExit but keeps prior phases")
    func dismissDuringFullscreenBlocksAutoExit() async {
        let flag = DismissalFlag()
        var calls = 0
        var steps: [CelebrationTimeline.Step] = []

        await Self.timeline.run { steps.append($0) }
            sleep: { _ in
                calls += 1
                if calls == 3 {
                    flag.dismiss()
                    return false
                }
                return !flag.isDismissed
            }

        #expect(steps == [.expand, .fullscreen])
        #expect(!steps.contains(.autoExit),
                "auto-exit must not fire on a dismissed overlay")
    }

    @Test("F-02: standard durations match the documented spec (2s / 1.5s / 10s)")
    func standardDurationsMatchSpec() {
        #expect(Self.timeline.toastDwell == 2.0)
        #expect(Self.timeline.expandDwell == 1.5)
        #expect(Self.timeline.fullscreenDwell == 10.0)
    }
}
