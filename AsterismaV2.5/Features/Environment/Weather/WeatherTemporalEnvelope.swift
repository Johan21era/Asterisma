//  WeatherTemporalEnvelope.swift
//  AsterismaV2.5 — Environment Engine
//
//  Real precipitation rarely holds one intensity for its whole pass. A shower
//  builds, eases, rebuilds, and eventually loses its feed. The environment
//  previously drew the snapshot's instantaneous rate until the next 15-minute
//  fetch, so a two-hour rain read as a static particle curtain.
//
//  This is a VISUAL envelope, not a forecast and not new weather data. The
//  observed snapshot still sets the ceiling: the multiplier never exceeds 1.0,
//  so the engine can thin an observed rate but never invent a heavier one.
//  Two slow sine components (37 and 17 minutes) give the pass a visible pulse
//  over a two-hour window; an eight-minute onset keeps a newly started event
//  from snapping to full strength.
//
//  Pure and deterministic: no Date, no I/O, no view state. The engine supplies
//  the elapsed seconds since the current precipitation event began.
//
//  The curve is bounded to 0.55...1.0. At the floor a heavy storm still reads
//  as weather rather than disappearing, and the ceiling keeps the real
//  observation in charge.

import Foundation

nonisolated enum WeatherTemporalEnvelope {

    /// Time from the first wet tick to the settled pulse.
    static let onsetDuration: TimeInterval = 8 * 60

    /// The two slow components that make a long pass breathe. A ~37-minute
    /// primary carries the broad swell; a ~17-minute secondary adds the
    /// shorter surges a watcher notices inside it.
    static let primaryPeriod: TimeInterval = 37 * 60
    static let secondaryPeriod: TimeInterval = 17 * 60

    static let minimumMultiplier = 0.55
    static let maximumMultiplier = 1.0

    /// The intensity multiplier at `elapsed` seconds into a precipitation
    /// event. Values are clamped to 0.55...1.0 for every input.
    static func multiplier(elapsed: TimeInterval) -> Double {
        let t = max(0, elapsed)
        let onset = EnvironmentMath.smoothstep(t / onsetDuration)

        let primary = sin(2.0 * Double.pi * t / primaryPeriod)
        let secondary = sin(2.0 * Double.pi * t / secondaryPeriod + 1.7)
        let pulse = 0.5 + 0.5 * (0.7 * primary + 0.3 * secondary)

        let settled = minimumMultiplier
            + (maximumMultiplier - minimumMultiplier) * pulse

        // At the moment rain is first observed, start at the floor and climb
        // into the pulse over the onset window instead of appearing at full.
        return minimumMultiplier + (settled - minimumMultiplier) * onset
    }
}
