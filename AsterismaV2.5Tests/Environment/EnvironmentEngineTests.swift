//  EnvironmentEngineTests.swift
//  AsterismaV2.5Tests
//
//  Phase 2 regression battery — pins the §8.2 shared-engine refcount gate.
//
//  Defect class being pinned: a single shared EnvironmentEngine consumed by
//  multiple views, where any one consumer's .onDisappear → stop() cancelled the
//  recompute loop out from under every remaining reader (frozen EnvironmentState
//  until an unrelated start()). The probe is the DEBUG console snapshot's status,
//  which reflects exactly whether the recompute task exists — no private-state
//  exposure needed.

import Foundation
import Testing
import SwiftUI

@testable import AsterismaV2_5

@Suite("Environment Engine — §8.2 shared-instance lifecycle")
@MainActor
struct EnvironmentEngineTests {

    @Test("init computes its first state synchronously from the injected clock")
    func initialStateReflectsInjectedClock() {
        // NOTE: asserting `state != .fallback` would be WRONG — .fallback IS the
        // night palette, so at night the computed state legitimately equals it.
        // The real guarantee: init runs recompute() against the clock, so an
        // injected NOON instant must produce a non-night anchor blend.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let noonUTC = cal.date(from: DateComponents(year: 2025, month: 6, day: 15,
                                                    hour: 12, minute: 0))!

        let engine = EnvironmentEngine(calendar: cal, now: { noonUTC })

        let blend = engine.state.currentAnchorBlend
        #expect(blend[.night] == nil || blend[.night] == 0,
                "noon must not resolve to the flat-night anchor")
        #expect(abs((blend.values.reduce(0, +)) - 1.0) < 0.001,
                "anchor weights must be normalized")
        #expect(engine.state.weatherModifier == .neutral)
    }

    @Test("§8.2: single consumer start/stop behaves as before")
    func singleConsumerLifecycle() {
        let engine = EnvironmentEngine()
        let identity = "environment-engine"

        // Probe via the console subsystem registry's snapshot shape.
        func isRunning() -> Bool {
            if case .running = engine.consoleSnapshot.status { return true }
            return false
        }
        _ = identity

        #expect(!isRunning(), "loop must not run before first start()")
        engine.start()
        #expect(isRunning())
        engine.stop()
        #expect(!isRunning(), "loop must stop when the only consumer releases")
    }

    @Test("§8.2: THE regression — one consumer's stop must not freeze another reader")
    func oneConsumerStopDoesNotFreezeRemainingReader() {
        let engine = EnvironmentEngine()

        func isRunning() -> Bool {
            if case .running = engine.consoleSnapshot.status { return true }
            return false
        }

        // Background view and library explorer both appear.
        engine.start()   // consumer A (EnvironmentBackgroundView)
        engine.start()   // consumer B (future LibraryExplorerView)

        // A disappears — pre-fix this killed the loop for B. Post-fix: still alive.
        engine.stop()
        #expect(isRunning(),
                "§8.2 regression: last-checked-in consumer lost its recompute loop")

        // B disappears — now the loop legitimately stops.
        engine.stop()
        #expect(!isRunning())
    }

    @Test("§8.2: over-release is a harmless no-op, never underflows into immortality")
    func overReleaseIsSafe() {
        let engine = EnvironmentEngine()
        func isRunning() -> Bool {
            if case .running = engine.consoleSnapshot.status { return true }
            return false
        }

        engine.start()
        engine.stop()
        engine.stop()   // stray extra release — must not resurrect or crash
        engine.stop()
        #expect(!isRunning())

        // And the engine remains fully reusable afterwards.
        engine.start()
        #expect(isRunning())
        engine.stop()
        #expect(!isRunning())
    }
}
