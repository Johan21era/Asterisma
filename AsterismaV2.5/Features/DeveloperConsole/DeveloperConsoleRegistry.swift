//  DeveloperConsoleRegistry.swift
//  AsterismaV2.5
//
//  DEVELOPER CONSOLE — Phase 1 (Foundation)
//
//  The single place subsystems register themselves and the Dashboard reads
//  from. This file is the only piece of "glue" in the whole console — and
//  even it never lists a specific subsystem by name for the instance-based
//  case. (The static-engine case has one small, explicit, documented
//  exception — see DeveloperConsoleObservable.swift and the manifest below.)
//

#if DEBUG

import Foundation
import Combine

// MARK: - DeveloperConsoleRegistry

@MainActor
final class DeveloperConsoleRegistry: ObservableObject {
    static let shared = DeveloperConsoleRegistry()
    private init() {
        // BUG FIX (session crash O-7): registerAll previously reached back into
        // DeveloperConsoleRegistry.shared from inside this init — i.e. from
        // inside .shared's own dispatch_once callout. Every Debug launch died
        // there (_dispatch_once_wait / EXC_BREAKPOINT, "trying to lock
        // recursively"). The instance is now passed down explicitly, so
        // initialization never touches the global it is initializing.
        DeveloperConsoleStaticEngineManifest.registerAll(into: self)
    }

    // Instance-based subsystems are held as weak boxes so the console can
    // never keep an otherwise-deallocated object alive, and so a subsystem
    // that has gone away simply stops appearing rather than crashing
    // anything. Keyed by identity.id so re-registering the same subsystem
    // (e.g. a SwiftUI preview re-creating an object) replaces, not duplicates.
    private var instanceProviders: [String: () -> ConsoleSubsystemSnapshot?] = [:]

    // Stateless engines, keyed the same way. Populated once via the static
    // engine manifest at first access (see init above).
    private var staticProviders: [String: () -> ConsoleSubsystemSnapshot] = [:]

    /// Bumped on every registration purely so the Dashboard can show
    /// "N subsystems registered" without recomputing it. Not used for
    /// anything else — never gates behavior.
    @Published private(set) var registeredCount: Int = 0

    /// Registers (or re-registers) an instance-based subsystem. Call once,
    /// at the end of the subsystem's own init(), wrapped in #if DEBUG.
    func register<T: DeveloperConsoleObservable>(_ subsystem: T) {
        let id = T.consoleIdentity.id
        instanceProviders[id] = { [weak subsystem] in subsystem?.consoleSnapshot }
        registeredCount = instanceProviders.count + staticProviders.count
    }

    /// Registers a stateless engine type. Called only from
    /// DeveloperConsoleStaticEngineManifest.registerAll() below — see that
    /// type for why this can't be fully self-triggering the way `register`
    /// above is.
    fileprivate func registerStatic<T: DeveloperConsoleStaticObservable>(_ type: T.Type) {
        let id = T.consoleIdentity.id
        staticProviders[id] = { type.consoleSnapshot }
        registeredCount = instanceProviders.count + staticProviders.count
    }

    /// Every registered subsystem's current snapshot, sorted by display name
    /// for a stable Dashboard ordering. Instance-based subsystems that have
    /// been deallocated are silently skipped (their provider returns nil) —
    /// this is expected, not an error condition.
    func currentSnapshots() -> [ConsoleSubsystemSnapshot] {
        let instanceSnapshots = instanceProviders.values.compactMap { $0() }
        let staticSnapshots = staticProviders.values.map { $0() }
        return (instanceSnapshots + staticSnapshots)
            .sorted { $0.identity.displayName < $1.identity.displayName }
    }

    /// Look up a single subsystem's latest snapshot by its stable id.
    /// Used by Phase 3 (Subsystem Explorer) when the Dashboard is asked to
    /// open a specific subsystem's page — added now so Phase 3 does not
    /// need to touch this file again to read a single subsystem.
    func snapshot(forID id: String) -> ConsoleSubsystemSnapshot? {
        if let provider = instanceProviders[id] { return provider() }
        if let provider = staticProviders[id] { return provider() }
        return nil
    }
}

// MARK: - DeveloperConsoleStaticEngineManifest

/// The one explicit, hand-maintained list in the entire console — and it is
/// deliberately narrow: it exists only because Swift gives stateless enum
/// namespaces no init() and no automatic "run at first touch" mechanism to
/// hook a self-registration call into. Every subsystem WITH a live instance
/// (the overwhelming majority of this app's Managers/Services/ViewModels)
/// registers itself with zero entries here — see `register` above.
///
/// Add one line here in the same commit a stateless engine adopts
/// `DeveloperConsoleStaticObservable`. This list does not need to be
/// touched by Phase 2, 3, 7, or 8's own code — they all read through
/// `currentSnapshots()` / `snapshot(forID:)` above, never this list directly.
enum DeveloperConsoleStaticEngineManifest {
    static let knownStaticEngines: [any DeveloperConsoleStaticObservable.Type] = [
        AchievementEngine.self,
    ]

    static func registerAll(into registry: DeveloperConsoleRegistry) {
        for engine in knownStaticEngines {
            registerOne(engine, into: registry)
        }
    }

    /// Broken out as its own generic function so the existential array above
    /// (`any DeveloperConsoleStaticObservable.Type`) can still be passed to
    /// `DeveloperConsoleRegistry.registerStatic`, which needs a concrete `T`.
    private static func registerOne<T: DeveloperConsoleStaticObservable>(
        _ type: T.Type,
        into registry: DeveloperConsoleRegistry
    ) {
        registry.registerStatic(type)
    }
}

#endif

