//  ShootingStarManager.swift
//  Environment Engine — Phase D (Part 7 of the build spec)
//
//  Periodically decides whether to spawn a shooting star: randomized
//  45-120s evaluation interval, ~15-25% spawn chance per evaluation, never
//  more than one active at a time, and only evaluated at all when
//  starVisibility is high enough that one would be visible ("there is no
//  reason to run this system at noon" — Part 7).
//
//  ObservableObject + @MainActor, matching the same house convention
//  confirmed for EnvironmentEngine (and WeatherKitService itself).
//

import Combine
import Foundation
import CoreGraphics

@MainActor
final class ShootingStarManager: ObservableObject {

    @Published private(set) var active: ShootingStar?

    private var evaluationTask: Task<Void, Never>?
    private var generator = SeededGenerator(seed: UInt64(Date().timeIntervalSince1970))
    private var fieldSize: CGSize = .zero

    /// Below this, per Part 7, there's no reason to evaluate spawns at all —
    /// this lines up with roughly where stars have meaningfully started to
    /// appear during the Afternoon-end/Night blend zone.
    private static let minimumStarVisibilityToEvaluate = 0.2
    private static let spawnProbability = 0.20
    private static let evaluationIntervalRange: ClosedRange<Double> = 45...120

    func updateFieldSize(_ size: CGSize) {
        fieldSize = size
    }

    /// Begins the periodic evaluation loop. `starVisibility`/`reducedMotion`
    /// are read live on each tick via closures (not snapshotted at `start()`
    /// time) so the manager always evaluates against the current environment
    /// state, not whatever it was when the loop began.
    func start(starVisibility: @escaping @MainActor () -> Double, reducedMotion: @escaping @MainActor () -> Bool) {
        guard evaluationTask == nil else { return }
        evaluationTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let interval = Double.random(in: Self.evaluationIntervalRange, using: &self.generator)
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }

                guard !reducedMotion() else { continue } // reducedMotion disables shooting stars entirely (Part 11)
                guard starVisibility() >= Self.minimumStarVisibilityToEvaluate else { continue }
                guard self.active == nil else { continue } // never more than one active at once
                guard self.fieldSize.width > 0, self.fieldSize.height > 0 else { continue }

                let roll = Double.random(in: 0...1, using: &self.generator)
                guard roll <= Self.spawnProbability else { continue }

                self.spawn()
            }
        }
    }

    func stop() {
        evaluationTask?.cancel()
        evaluationTask = nil
    }

    // No deinit-based cancellation — see the identical note in
    // EnvironmentEngine.swift; the same reasoning applies here.

    private func spawn() {
        let star = ShootingStar.randomized(fieldSize: fieldSize, using: &generator)
        active = star

        let duration = star.duration
        let starID = star.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self else { return }
            // Only clear if this is still the same star — defensive against
            // a future reset/stop() racing this timer.
            if self.active?.id == starID {
                self.active = nil
            }
        }
    }
}

