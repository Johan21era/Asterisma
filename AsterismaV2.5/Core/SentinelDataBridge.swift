//  SentinelDataBridge.swift
//  AsterismaV2.5
//
//  P6: the one deliberate seam between SentinelEngine and the live app.
//  DataStore registers itself here at init; the engine reads through this so
//  the engine itself stays decoupled from SwiftUI/App lifecycle ownership.
//
//  SECURITY NOTE (S1): this is a READ bridge. It exposes only what probes
//  need; mutations always go through DataStore's own audited public APIs.

import Foundation

@MainActor
final class SentinelDataBridge {
    static let shared = SentinelDataBridge()

    /// Internal on purpose: SentinelEngine (same module) is the only writer,
    /// set once by DataStore at init. Read-only for probes.
    private(set) weak var store: DataStore?

    /// Only DataStore should call this. Last-attach-wins: production attaches
    /// exactly once; tests attach per-fixture and must be able to replace the
    /// reference (weak — dead stores drop out automatically).
    func attach(_ store: DataStore) {
        self.store = store
    }

    /// P6-HOTFIX: heavy mutations (demo installs) set this to keep Sentinel
    /// cycles from probing a half-swapped library. Auto-clears on swap end.
    private(set) var isMutationInFlight = false

    func beginMutation() { isMutationInFlight = true }
    func endMutation() { isMutationInFlight = false }

    private init() {}
}
