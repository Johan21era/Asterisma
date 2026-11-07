//  DeveloperConsoleObservable.swift
//  AsterismaV2.5
//
//  DEVELOPER CONSOLE — Phase 1 (Foundation)
//
//  This file names and defines the "one lightweight protocol every subsystem
//  opts into" that the console's Observability Instrumentation Policy calls
//  for. There are two variants, because this codebase genuinely has two
//  different subsystem shapes (confirmed by inspection this session, not
//  assumed):
//
//   1. Instance-based subsystems — @MainActor classes with a live object
//      (DataStore, SessionCoordinator, WeatherKitService, etc.). These
//      conform to `DeveloperConsoleObservable` and register ONE line at the
//      end of their own init().
//
//   2. Stateless "Engine" namespaces — enums with only static func, no
//      instance at all (AchievementEngine, EstimationEngine, InsightEngine,
//      etc.). These conform to `DeveloperConsoleStaticObservable` instead,
//      since there is no object to hold a reference to and no init() to
//      hook a registration call into.
//
//  HONEST LIMITATION (documented here rather than glossed over, per the
//  contract's own Anti-Hallucination standard): for shape 1, registration is
//  fully automatic — the console's own code never lists instance subsystems
//  anywhere. For shape 2, Swift has no "run this automatically at launch"
//  mechanism for a static-only type nobody has touched yet, so those need
//  one line in DeveloperConsoleRegistry.swift's static engine manifest. That
//  manifest is still not the console's Dashboard/Explorer/Graph code being
//  hand-edited per subsystem — it's a single, small, clearly-labeled list
//  colocated with the registry — but it is a real, narrower exception to
//  "fully automatic," and it is called out as such rather than implied away.
//

#if DEBUG

import Foundation

// MARK: - DeveloperConsoleObservable (instance-based subsystems)

/// Adopt this on any class-based subsystem that has a live, long-lived
/// instance (a manager, a service, a ViewModel, an engine implemented as a
/// class). Conforming is always additive: it must never change what the
/// subsystem already does — only add a way for it to describe itself.
///
/// Usage (added to the subsystem's OWN file, same commit as the subsystem):
///
///     #if DEBUG
///     extension DataStore: DeveloperConsoleObservable {
///         static var consoleIdentity: ConsoleSubsystemIdentity { ... }
///         var consoleSnapshot: ConsoleSubsystemSnapshot { ... }
///     }
///     #endif
///
/// ...and, inside the subsystem's existing init(), one appended line:
///
///     #if DEBUG
///     DeveloperConsoleRegistry.shared.register(self)
///     #endif
///
/// `@MainActor` here matches how every instance-based subsystem in this
/// codebase already runs (DataStore, SessionCoordinator, SessionEventRouter,
/// BehaviorContextEngine, EnvironmentEngine, GoalProgressViewModel are all
/// `@MainActor final class` — confirmed by direct inspection). Requiring
/// `consoleSnapshot` to be read on the MainActor is what satisfies the
/// contract's concurrency rule: the console can only ever read this value
/// from the same isolation domain the subsystem itself already publishes
/// its `@Published` state on, so there is no way for the console to
/// introduce a race in the thing it's observing.
@MainActor
protocol DeveloperConsoleObservable: AnyObject {
    /// Fixed identity for this TYPE (not this instance). Every instance of
    /// the same subsystem type reports the same identity.
    static var consoleIdentity: ConsoleSubsystemIdentity { get }

    /// A fresh, read-only snapshot of THIS instance's current state.
    /// Computed on demand — must be cheap and must never mutate anything.
    var consoleSnapshot: ConsoleSubsystemSnapshot { get }
}

// MARK: - DeveloperConsoleStaticObservable (stateless engine namespaces)

/// Adopt this on a stateless "Engine" enum (static func only, no instance)
/// to make it visible in the console. See the honest-limitation note at the
/// top of this file for why these need one line in the static engine
/// manifest rather than being fully self-registering like the instance-based
/// protocol above.
@MainActor
protocol DeveloperConsoleStaticObservable {
    static var consoleIdentity: ConsoleSubsystemIdentity { get }
    static var consoleSnapshot: ConsoleSubsystemSnapshot { get }
}

#endif
