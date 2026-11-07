//  DeveloperConsoleTypes.swift
//  AsterismaV2.5
//
//  DEVELOPER CONSOLE — Phase 1 (Foundation)
//
//  PURPOSE
//  Shared vocabulary for the Developer Console. Every other console file, and
//  every subsystem that reports into the console, uses these three types:
//
//    ConsoleSubsystemCategory  — what KIND of thing this is (manager, service, etc.)
//    ConsoleSubsystemStatus    — the current health, one of exactly 7 states
//    ConsoleSubsystemIdentity  — a stable "name tag" for a subsystem
//    ConsoleSubsystemSnapshot  — one read-only report card for a subsystem, at a moment in time
//
//  This file has ZERO knowledge of any specific subsystem (DataStore,
//  WeatherKitService, etc.). It only defines the shape those subsystems fill
//  in about themselves. That is what keeps the console from needing to be
//  edited every time a new subsystem is added — see DeveloperConsoleObservable.swift.
//
//  This whole file compiles out of Release builds. See the Developer Console
//  section of handoff.md for why #if DEBUG is the right gate for this project
//  (verified against this project's own build settings, not assumed).
//

#if DEBUG

import Foundation

// MARK: - ConsoleSubsystemCategory

/// What kind of thing a subsystem is. Purely descriptive — used to group and
/// label subsystems in the console's UI. Matches the vocabulary already used
/// in this codebase's own file/type naming (Manager, Service, Engine, etc.)
/// rather than inventing new terminology.
enum ConsoleSubsystemCategory: String, Sendable, CaseIterable, Hashable {
    case manager
    case service
    case engine
    case model
    case viewModel
    case view
    case utility
    case pipeline

    /// Plain-English label for display. Kept here (not computed inline in
    /// views) so every view that lists categories shows the same wording.
    var displayName: String {
        switch self {
        case .manager: return "Manager"
        case .service: return "Service"
        case .engine: return "Engine"
        case .model: return "Model"
        case .viewModel: return "ViewModel"
        case .view: return "View"
        case .utility: return "Utility"
        case .pipeline: return "Pipeline"
        }
    }
}

// MARK: - ConsoleSubsystemStatus

/// The health of a subsystem, at the moment it was asked. Every subsystem
/// that reports to the console reports exactly one of these seven states —
/// never a raw Bool, never a free-form string — so the Dashboard (Phase 2)
/// can render one consistent visual vocabulary for every subsystem, no
/// matter how different the subsystems are underneath.
///
/// NOTE: "Not yet instrumented" is deliberately NOT a case here. That state
/// means "this subsystem has no registration at all" — it is something the
/// Dashboard says about an EMPTY SLOT in the registry, not something a
/// conforming subsystem reports about itself. Keeping that distinction sharp
/// is what stops the console from ever claiming a subsystem is "healthy"
/// when really nobody has checked.
enum ConsoleSubsystemStatus: String, Sendable, CaseIterable, Hashable {
    case healthy
    case running
    case idle
    case initializing
    case warning
    case error
    case unavailable

    var displayName: String {
        switch self {
        case .healthy: return "Healthy"
        case .running: return "Running"
        case .idle: return "Idle"
        case .initializing: return "Initializing"
        case .warning: return "Warning"
        case .error: return "Error"
        case .unavailable: return "Unavailable"
        }
    }

    /// A short plain-English sentence describing what this status means to
    /// someone with no engineering background. Used by Learning Mode-style
    /// tooltips wherever status is shown.
    var plainEnglishMeaning: String {
        switch self {
        case .healthy:
            return "Working normally, nothing wrong."
        case .running:
            return "Actively doing work right now."
        case .idle:
            return "Working normally, just has nothing to do at this moment."
        case .initializing:
            return "Still starting up."
        case .warning:
            return "Working, but something is worth a second look."
        case .error:
            return "Something went wrong."
        case .unavailable:
            return "Not reachable right now (for example: no network, or a required permission was not granted)."
        }
    }
}

// MARK: - ConsoleSubsystemIdentity

/// A stable "name tag" for a subsystem. Identity is separate from live state
/// (ConsoleSubsystemSnapshot) because identity never changes across a run of
/// the app, while state changes constantly — keeping them separate is what
/// lets Phase 7/8 build a dependency graph and a registry from the same
/// underlying identities without re-deriving them from live state each time.
struct ConsoleSubsystemIdentity: Sendable, Hashable {
    /// Stable lookup key. Not shown to the user raw — used for sorting,
    /// diffing, and as a dictionary key. Convention: lowercase-hyphenated,
    /// e.g. "data-store", "weather-kit-service".
    let id: String

    /// Human-readable name shown in the console, e.g. "Data Store".
    let displayName: String

    let category: ConsoleSubsystemCategory

    /// One sentence, plain English: what this subsystem is for. Shown in
    /// Phase 3 (Subsystem Explorer) and Phase 4 ("Explain This"). Optional
    /// here because Phase 1/2 do not require it, but subsystems are
    /// encouraged to fill it in now since Phase 4 will read it directly.
    let purpose: String?

    init(
        id: String,
        displayName: String,
        category: ConsoleSubsystemCategory,
        purpose: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.category = category
        self.purpose = purpose
    }
}

// MARK: - ConsoleSubsystemSnapshot

/// One read-only report card for a subsystem, valid at the moment it was
/// produced. This is the ONLY thing the console ever reads from a
/// subsystem — never the subsystem's private state directly. That is what
/// satisfies the contract's concurrency rule: every field here is a plain
/// Sendable value copied out at the moment of the call, so the console can
/// never race with the thing it is observing.
///
/// Every field is a direct, observed fact about the subsystem (a count, a
/// message, a timestamp) — nothing here is a synthesized/derived number like
/// a 0-100 health score. Derived metrics (Health Score, Confidence, etc.)
/// belong to later phases and must follow the Derived Metrics Protocol
/// before they exist; Phase 1/2 deliberately stay direct-passthrough only.
struct ConsoleSubsystemSnapshot: Sendable, Identifiable {
    var id: String { identity.id }

    let identity: ConsoleSubsystemIdentity
    let status: ConsoleSubsystemStatus

    /// One short, plain-English sentence: what is this subsystem doing right
    /// now? e.g. "Holding 42 books in memory" or "Not called yet this session".
    /// Never nil in practice — subsystems should always have SOMETHING true
    /// to say, even if it's "Idle, nothing to report."
    let currentActivity: String

    /// When this subsystem last changed state, from the subsystem's own
    /// point of view. Nil is a legitimate, honest answer ("never has, this
    /// session") — the console must not invent a timestamp to fill this in.
    let lastUpdated: Date?

    /// Short, human-readable warning messages. Empty array means none —
    /// never padded with a placeholder "no warnings" string.
    let warnings: [String]

    /// Short, human-readable error messages. Empty array means none.
    let errors: [String]

    /// Small key → value bag of whatever else this subsystem wants to show
    /// on its Dashboard tile / Subsystem Explorer page (Phase 3), e.g.
    /// ["Books in library": "42"]. Deliberately untyped/free-form so any
    /// subsystem shape (class, actor, stateless engine) can fill it in
    /// without the console needing a new field for every new subsystem.
    let metrics: [String: String]

    init(
        identity: ConsoleSubsystemIdentity,
        status: ConsoleSubsystemStatus,
        currentActivity: String,
        lastUpdated: Date?,
        warnings: [String] = [],
        errors: [String] = [],
        metrics: [String: String] = [:]
    ) {
        self.identity = identity
        self.status = status
        self.currentActivity = currentActivity
        self.lastUpdated = lastUpdated
        self.warnings = warnings
        self.errors = errors
        self.metrics = metrics
    }
}

#endif
