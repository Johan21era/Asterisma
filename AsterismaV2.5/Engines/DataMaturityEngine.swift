// DataMaturityEngine.swift
//  -----------------------------------------------------------------------------
//  MARK: - What this file is

//  -----------------------------------------------------------------------------
//
//  DataMaturityEngine is an authority layer, not an analysis layer.
//
//  Every other engine in this app (BehaviorContextEngine, WeatherAnalysisEngine,
//  InsightEngine, IntelligentNotificationEngine, MusicalAnalysisEngine, ...)
//  is free to keep computing correlations, scores, and confidence numbers
//  exactly as it always has. DataMaturityEngine does not touch any of that.
//
//  What it owns is the question that sits between "we noticed a pattern" and
//  "we told the user about it":
//
//      canWeSayThis() -> MaturityVerdict
//
//  It never:
//    - collects data
//    - modifies collected data
//    - changes analytics, session generation, or metrics
//    - changes persistence
//    - changes correlation calculations
//
//  It only decides, for a proposed claim:
//    - whether the claim may reach the UI at all (ClaimDecision / ClaimDisposition)
//    - the confidence ceiling it is allowed to carry (allowedConfidence)
//    - how strongly it may be worded (narrativeStrength)
//    - why (rationale — a plain-English audit trail)
//
//  -----------------------------------------------------------------------------
//  MARK: - Why evidence, never time

//  -----------------------------------------------------------------------------
//
//  Nothing in this file reads Date() and asks "how long has this account
//  existed" or "how many days since install." The only dates this engine
//  ever looks at are the timestamps ON THE EVIDENCE ITSELF — the oldest and
//  newest observations that support or contradict a claim, supplied fresh
//  by the caller every time. A user who reads compulsively for one very
//  long day produces a huge sample count but a near-zero observed span,
//  and this engine will correctly refuse to call that a "stable pattern."
//  A user who reads modestly across ninety calendar days builds span
//  whether or not the app was installed nine months ago. Maturity here is
//  a property of the evidence, not the clock.
//
//  ROADMAP 3.4 (RA-002 / F-13b CORRECTION): an earlier revision of this
//  header claimed the engine NEVER reads wall-clock time while the `expiry`
//  decision rule called Date() directly — breaking deterministic testing of
//  exactly the expiry decision. That rule now receives the SAME injected
//  `referenceDate` every evaluator already gets; callers still default to
//  `Date()` at their own boundary, but the engine's internals no longer read
//  the wall clock anywhere.
//
//  -----------------------------------------------------------------------------
//  MARK: - Why this file is domain-agnostic

//  -----------------------------------------------------------------------------
//
//  BehaviorContextEngine's narratives, InsightEngine's ReadingInsight cards,
//  WeatherAnalysisEngine's EnvironmentalCorrelation rows, and
//  IntelligentNotificationEngine's NotificationCandidate messages all have
//  completely different shapes. Rather than teach DataMaturityEngine about
//  four different vocabularies, every caller translates its own evidence
//  into one shared currency — MaturityEvidenceDigest — via small adapters
//  (see DataMaturityEngineAdapters.swift). This file never imports or
//  references Book, ReadingSession, WeatherSnapshot, or any other
//  app-domain type. That separation is what lets the same engine govern
//  every claim-producing system in the app without becoming a giant
//  switch statement keyed on "which engine called me."
//
//  -----------------------------------------------------------------------------
//  MARK: - Composition over one big switch

//  -----------------------------------------------------------------------------
//
//  Two things in this app are the "correct" answer for different reasons,
//  and both are implemented as ordered lists of small, independently
//  testable units rather than as one large conditional:
//
//    1. Scoring: a battery of `MaturityEvaluating` evaluators, each
//       responsible for exactly one evidentiary question (volume, recency,
//       consistency, contradiction, replication, historical depth, trend
//       stability, cross-domain corroboration). Adding a new evaluator
//       never requires touching the others.
//
//    2. Deciding: an ordered list of `ClaimRule`s, each a small pure
//       function that either returns a decision or defers to the next
//       rule. Adding a new decision path means adding a new rule, not
//       editing a switch statement that everything else also depends on.
//
//  ClaimDecision and NarrativeStrengthTier are themselves open, extensible
//  value types (string-identified, not closed enums) so new decision
//  kinds or new wording tiers can be introduced later without recompiling
//  every switch that touches them.
//

import Foundation

// MARK: - Maturity Domain

/// An open-ended identifier for a dimension of behavioral maturity
/// (reading history, environmental/weather context, routine timing,
/// device state, audio context, and so on).
///
/// This is a struct rather than an `enum` on purpose: the whole point of
/// "the engine should determine which maturity domains are relevant for
/// each inference" is that new domains (a future location-based domain,
/// a future social-reading domain) can be registered without touching
/// every piece of code that already switches on the existing ones.
public struct MaturityDomain: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue
    }

    // Known domains as of this integration pass. Every one of these maps
    // to an engine that already exists in this codebase today.
    public static let reading = MaturityDomain("reading") // Book/ReadingSession history
    public static let behaviorContext = MaturityDomain("behaviorContext") // BehaviorContextEngine environments/routines
    public static let environmental = MaturityDomain("environmental") // WeatherAnalysisEngine
    public static let audio = MaturityDomain("audio") // MusicalAnalysisEngine (AudioFactor 2.swift)
    public static let device = MaturityDomain("device") // Device-state influence (screen lock/sleep)
    public static let routine = MaturityDomain("routine") // Timing/recurrence routines
    public static let library = MaturityDomain("library") // Genre/book-level composition
    public static let session = MaturityDomain("session") // Per-session quality/consistency
    public static let notification = MaturityDomain("notification") // IntelligentNotificationEngine
}

// MARK: - Claim Type Identifier

/// Identifies *what kind* of statement is being proposed — "reading happens
/// at night", "temperature correlates with reading speed", "goal is behind
/// pace" — independent of which engine proposed it.
///
/// Claim types are namespaced strings (`"weather.correlation.temperature"`,
/// `"routine.timeOfDay"`) so new ones can be minted by any future adapter
/// without a shared enum needing a new case.
public struct ClaimTypeIdentifier: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue
    }
}

// MARK: - Narrative Strength Tier

/// How strongly a surviving claim is allowed to be worded.
///
/// Mirrors the progression the product spec calls out explicitly:
/// "occasionally" -> "often" -> "consistently" -> "consistently across
/// multiple months". Ordered by `rank` (not by declaration order, so new
/// tiers can be inserted anywhere in the ladder), and open-ended: a caller
/// can define a bespoke tier for a bespoke claim type without editing this
/// file, though the six below cover every wording ladder currently used
/// by ExplainabilityNarrativeBuilder.
public struct NarrativeStrengthTier: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public let rank: Int

    public init(_ rawValue: String, rank: Int) {
        self.rawValue = rawValue
        self.rank = rank
    }

    public var description: String {
        rawValue
    }

    /// Not enough evidence to say anything. Never used for display —
    /// a claim at this tier is, by construction, blocked.
    public static let insufficient = NarrativeStrengthTier("insufficient", rank: 0)
    /// "You have occasionally read more during evenings."
    public static let emerging = NarrativeStrengthTier("emerging", rank: 1)
    /// "You often read more during evenings."
    public static let moderate = NarrativeStrengthTier("moderate", rank: 2)
    /// "Evenings are consistently your strongest reading period."
    public static let established = NarrativeStrengthTier("established", rank: 3)
    /// A step past "established" for claims with unusually deep, unusually
    /// consistent replication — still short of the full-history ceiling.
    public static let strong = NarrativeStrengthTier("strong", rank: 4)
    /// "Evenings have remained your strongest reading period across
    /// multiple months."
    public static let definitive = NarrativeStrengthTier("definitive", rank: 5)

    /// A short adverbial phrase a narrative template can drop straight
    /// into a sentence. Falls back to a neutral phrase for any custom
    /// tier a future adapter defines, so this never needs updating just
    /// because a new tier was minted elsewhere.
    public var qualifier: String {
        switch rawValue {
        case "insufficient": return ""
        case "emerging": return "occasionally"
        case "moderate": return "often"
        case "established": return "consistently"
        case "strong": return "reliably"
        case "definitive": return "consistently across multiple months"
        default: return "recently"
        }
    }
}

extension NarrativeStrengthTier: Comparable {
    public static func < (lhs: NarrativeStrengthTier, rhs: NarrativeStrengthTier) -> Bool {
        lhs.rank < rhs.rank
    }
}

// MARK: - Claim Disposition

/// The one truly closed vocabulary in this file. Every `ClaimDecision`,
/// however many new ones get minted later, resolves to exactly one of
/// these three fundamental outcomes, because "may the UI show something
/// for this claim" only ever has three real answers.
public enum ClaimDisposition: String, Codable, Sendable, Hashable {
    /// Must not reach narrative generation or the UI in any form.
    case blocked
    /// May reach the UI, but only with hedged wording and a capped
    /// confidence — the claim is real but incomplete, narrow, or aging.
    case displayableSoftened
    /// May reach the UI at full strength.
    case displayableFull
}

// MARK: - Claim Decision

/// The engine's answer to "should this claim exist," expanded beyond a
/// boolean. Open-ended by design — `ClaimRegistry` or a future rule can
/// introduce a new decision (e.g. a domain-specific one) by constructing
/// a new `ClaimDecision` value; nothing that pattern-matches on the
/// existing ones needs to change, because callers should be switching on
/// `.disposition`, not on decision identity, unless they specifically
/// want to special-case one named decision (e.g. to log contradictions).
public struct ClaimDecision: Hashable, Codable, Sendable, CustomStringConvertible {
    public let identifier: String
    public let disposition: ClaimDisposition

    public init(identifier: String, disposition: ClaimDisposition) {
        self.identifier = identifier
        self.disposition = disposition
    }

    public var description: String {
        identifier
    }

    public static let approved = ClaimDecision(identifier: "approved", disposition: .displayableFull)
    public static let approvedSoftened = ClaimDecision(identifier: "approvedSoftened", disposition: .displayableSoftened)
    public static let contextSpecific = ClaimDecision(identifier: "contextSpecific", disposition: .displayableSoftened)
    public static let seasonalOnly = ClaimDecision(identifier: "seasonalOnly", disposition: .displayableSoftened)
    public static let recentlyChanged = ClaimDecision(identifier: "recentlyChanged", disposition: .displayableSoftened)
    public static let needsMoreEvidence = ClaimDecision(identifier: "needsMoreEvidence", disposition: .blocked)
    public static let postponed = ClaimDecision(identifier: "postponed", disposition: .blocked)
    public static let contradicted = ClaimDecision(identifier: "contradicted", disposition: .blocked)
    public static let unstablePattern = ClaimDecision(identifier: "unstablePattern", disposition: .blocked)
    public static let expired = ClaimDecision(identifier: "expired", disposition: .blocked)
    public static let rejected = ClaimDecision(identifier: "rejected", disposition: .blocked)
}

// MARK: - Evidence Observation

/// The finest-grained unit DataMaturityEngine understands: one timestamped
/// data point that either supported or contradicted a proposed claim.
///
/// Callers with rich per-event evidence (BehaviorContextEngine's
/// BehaviorEvidence, ContextEvidenceChain) can build an array of these and
/// aggregate it; callers with only summary statistics (a plain confidence
/// Double, a Pearson coefficient) skip straight to constructing a
/// `MaturityEvidenceDigest` directly. Both paths are first-class — see
/// `MaturityEvidenceDigest.aggregate(_:)` for the former.
public struct MaturityEvidenceObservation: Hashable, Codable, Sendable {
    public let date: Date
    public let supports: Bool
    /// A caller-defined key identifying *which* context this observation
    /// came from — a book id, a genre, an environment type, an hour
    /// bucket. Used only to count distinct replication contexts and to
    /// detect single-context dominance; never displayed.
    public let contextKey: String?
    /// Relative weight of this single observation, 0...1. Defaults to 1;
    /// a caller can down-weight a noisy or partial observation without
    /// discarding it outright.
    public let weight: Double

    public init(date: Date, supports: Bool, contextKey: String? = nil, weight: Double = 1.0) {
        self.date = date
        self.supports = supports
        self.contextKey = contextKey
        self.weight = max(0, min(weight, 1))
    }
}

// MARK: - Evidence Digest

/// The shared currency every adapter translates its own evidence into.
///
/// Fields with an "unknown" state (`nil`) are treated neutrally rather
/// than punitively by the evaluators below — a source that doesn't track
/// contradictions isn't assumed to have zero contradictions, but it also
/// isn't assumed to be lying. See `ContradictionEvaluator`.
public struct MaturityEvidenceDigest: Hashable, Codable, Sendable {
    /// Total observations backing this claim, supporting and contradicting.
    public var sampleCount: Int
    /// Observations that support the claim.
    public var supportingCount: Int
    /// Observations that contradict the claim. `nil` = not tracked by the
    /// source, not "zero contradictions observed."
    public var contradictingCount: Int?

    /// Distinct calendar days on which evidence was observed.
    public var distinctDayCount: Int
    /// Distinct contexts (books, genres, environments, hours — whatever
    /// the claim type's replication dimension is) the pattern has held
    /// across. Generalizes "unique books", "unique genres", "repeated
    /// environments" from the product spec into one field per claim.
    public var distinctContextCount: Int
    /// Fraction of *supporting* observations attributable to the single
    /// most common context, 0...1. High values mean the pattern is real
    /// but has only really been seen in one place — the signal behind the
    /// "Context Specific" decision. 0 when unknown/untracked (treated as
    /// perfectly diverse, i.e. not penalized).
    public var dominantContextShare: Double

    /// Oldest and newest timestamps among all observations (supporting or
    /// contradicting). These are the ONLY dates this engine ever looks
    /// at — never wall-clock account age.
    public var firstObservedAt: Date?
    public var lastObservedAt: Date?

    /// Distinct broader calendar periods (e.g. months or seasons)
    /// observed, when the caller tracks it. `nil` = not tracked, in which
    /// case the seasonal-coverage rule is simply skipped rather than
    /// penalizing the claim.
    public var distinctCalendarPeriodsObserved: Int?

    /// Support/contradiction counts restricted to a recent trailing
    /// window, used to detect a strengthening, weakening, or reversing
    /// pattern without needing any engine-side history store.
    public var recentSupportingCount: Int
    public var recentContradictingCount: Int?
    public var recentWindowDays: Int

    /// Which domains actually contributed evidence to this specific
    /// claim instance. Compared against a claim type's `requiredDomains`
    /// to enforce cross-dimensional replication (e.g. a claim that
    /// legitimately needs both audio-context AND genre evidence).
    public var involvedDomains: Set<MaturityDomain>

    /// Advisory only. Some source engines already compute their own
    /// confidence number; it is never trusted as-is, but it can break
    /// ties or seed a rationale message. DataMaturityEngine always
    /// computes its own authoritative confidence from the fields above.
    public var priorConfidenceHint: Double?

    public init(
        sampleCount: Int = 0,
        supportingCount: Int = 0,
        contradictingCount: Int? = nil,
        distinctDayCount: Int = 0,
        distinctContextCount: Int = 0,
        dominantContextShare: Double = 0,
        firstObservedAt: Date? = nil,
        lastObservedAt: Date? = nil,
        distinctCalendarPeriodsObserved: Int? = nil,
        recentSupportingCount: Int = 0,
        recentContradictingCount: Int? = nil,
        recentWindowDays: Int = 30,
        involvedDomains: Set<MaturityDomain> = [],
        priorConfidenceHint: Double? = nil
    ) {
        self.sampleCount = max(0, sampleCount)
        self.supportingCount = max(0, supportingCount)
        self.contradictingCount = contradictingCount.map { max(0, $0) }
        self.distinctDayCount = max(0, distinctDayCount)
        self.distinctContextCount = max(0, distinctContextCount)
        self.dominantContextShare = max(0, min(dominantContextShare, 1))
        self.firstObservedAt = firstObservedAt
        self.lastObservedAt = lastObservedAt
        self.distinctCalendarPeriodsObserved = distinctCalendarPeriodsObserved
        self.recentSupportingCount = max(0, recentSupportingCount)
        self.recentContradictingCount = recentContradictingCount.map { max(0, $0) }
        self.recentWindowDays = max(1, recentWindowDays)
        self.involvedDomains = involvedDomains
        self.priorConfidenceHint = priorConfidenceHint
    }

    public static let empty = MaturityEvidenceDigest()

    /// Observed span in days between the first and last evidence — how
    /// long the pattern has actually been visible in the data, never how
    /// old the account or install is.
    public var observedSpanDays: Int {
        guard let first = firstObservedAt, let last = lastObservedAt else { return 0 }
        return max(0, Calendar.current.dateComponents([.day], from: first, to: last).day ?? 0)
    }

    /// Aggregates fine-grained observations into a digest. This is the
    /// path for adapters that have per-event evidence (BehaviorContextEngine)
    /// rather than only summary statistics.
    public static func aggregate(
        _ observations: [MaturityEvidenceObservation],
        asOf referenceDate: Date = Date(),
        recentWindowDays: Int = 30,
        involvedDomains: Set<MaturityDomain> = [],
        priorConfidenceHint: Double? = nil
    ) -> MaturityEvidenceDigest {
        guard !observations.isEmpty else { return .empty }

        let sorted = observations.sorted { $0.date < $1.date }
        let supporting = sorted.filter(\.supports)
        let contradicting = sorted.filter { !$0.supports }

        let distinctDays = Set(sorted.map { Calendar.current.startOfDay(for: $0.date) })
        let contextKeys = sorted.compactMap(\.contextKey)
        let distinctContexts = Set(contextKeys)

        let dominantShare: Double
        if !contextKeys.isEmpty {
            let counts = Dictionary(grouping: contextKeys, by: { $0 }).mapValues(\.count)
            let dominant = counts.values.max() ?? 0
            dominantShare = Double(dominant) / Double(contextKeys.count)
        } else {
            dominantShare = 0
        }

        let recentCutoff = referenceDate.addingTimeInterval(-Double(recentWindowDays) * 86400)
        let recentSupporting = supporting.filter { $0.date >= recentCutoff }
        let recentContradicting = contradicting.filter { $0.date >= recentCutoff }

        let calendarPeriods = Set(sorted.map { observation -> DateComponents in
            Calendar.current.dateComponents([.year, .month], from: observation.date)
        }.map { "\($0.year ?? 0)-\($0.month ?? 0)" })

        return MaturityEvidenceDigest(
            sampleCount: sorted.count,
            supportingCount: supporting.count,
            contradictingCount: contradicting.count,
            distinctDayCount: distinctDays.count,
            distinctContextCount: distinctContexts.count,
            dominantContextShare: dominantShare,
            firstObservedAt: sorted.first?.date,
            lastObservedAt: sorted.last?.date,
            distinctCalendarPeriodsObserved: calendarPeriods.isEmpty ? nil : calendarPeriods.count,
            recentSupportingCount: recentSupporting.count,
            recentContradictingCount: recentContradicting.count,
            recentWindowDays: recentWindowDays,
            involvedDomains: involvedDomains,
            priorConfidenceHint: priorConfidenceHint
        )
    }
}

// MARK: - Maturity Signal

/// One evaluator's opinion: a 0...1 score, its relative weight in the
/// composite, and a short human-readable reason (safe to log; not
/// necessarily phrased for an end user).
public struct MaturitySignal: Hashable, Codable, Sendable {
    public let name: String
    public let score: Double
    public let weight: Double
    public let rationale: String

    public init(name: String, score: Double, weight: Double, rationale: String) {
        self.name = name
        self.score = max(0, min(score, 1))
        self.weight = max(0, weight)
        self.rationale = rationale
    }
}

// MARK: - Composable Evaluators

/// One evaluator answers exactly one evidentiary question. The engine's
/// default battery composes eight of these; a claim type can supply its
/// own smaller or larger battery via `ClaimRequirement.customEvaluators`
/// without any of the built-in evaluators needing to change.
public protocol MaturityEvaluating: Sendable {
    var name: String { get }
    func evaluate(
        digest: MaturityEvidenceDigest,
        requirement: ClaimRequirement,
        referenceDate: Date
    ) -> MaturitySignal
}

/// How much raw evidence exists, scaled so that meeting the bare minimum
/// (already enforced separately as a hard gate) scores modestly — real
/// confidence growth requires meaningfully more than the floor.
public struct EvidenceVolumeEvaluator: MaturityEvaluating {
    public init() {}
    public let name = "evidenceVolume"

    public func evaluate(digest: MaturityEvidenceDigest, requirement: ClaimRequirement, referenceDate _: Date) -> MaturitySignal {
        let floor = max(requirement.minimumSampleCount, 1)
        // Reaching 3x the required minimum is treated as "comfortable" (1.0).
        let comfortable = Double(floor) * 3.0
        let score = comfortable > 0 ? min(1.0, Double(digest.sampleCount) / comfortable) : 0
        return MaturitySignal(
            name: name,
            score: score,
            weight: 1.0,
            rationale: "\(digest.sampleCount) observations against a floor of \(requirement.minimumSampleCount)"
        )
    }
}

/// How fresh the supporting evidence still is, via exponential decay from
/// the claim type's configured half-life. A claim whose last supporting
/// observation is old scores low here even if its lifetime sample count
/// was once large — this is the evidence-decay requirement from the
/// spec ("older observations should gradually contribute less").
public struct RecencyDecayEvaluator: MaturityEvaluating {
    public init() {}
    public let name = "recencyDecay"

    public func evaluate(digest: MaturityEvidenceDigest, requirement: ClaimRequirement, referenceDate: Date) -> MaturitySignal {
        guard let last = digest.lastObservedAt else {
            return MaturitySignal(name: name, score: 0, weight: 1.0, rationale: "no observed evidence dates")
        }
        let daysSince = max(0, referenceDate.timeIntervalSince(last) / 86400)
        let halfLife = max(requirement.decayHalfLifeDays, 1)
        let score = pow(0.5, daysSince / halfLife)
        return MaturitySignal(
            name: name,
            score: score,
            weight: 1.0,
            rationale: "\(Int(daysSince)) days since last supporting observation (half-life \(Int(halfLife))d)"
        )
    }
}

/// What fraction of all evidence supports (vs. contradicts) the claim.
public struct ConsistencyEvaluator: MaturityEvaluating {
    public init() {}
    public let name = "consistency"

    public func evaluate(digest: MaturityEvidenceDigest, requirement _: ClaimRequirement, referenceDate _: Date) -> MaturitySignal {
        guard digest.sampleCount > 0 else {
            return MaturitySignal(name: name, score: 0, weight: 1.0, rationale: "no evidence")
        }
        let ratio = Double(digest.supportingCount) / Double(digest.sampleCount)
        return MaturitySignal(
            name: name,
            score: ratio,
            weight: 1.0,
            rationale: "\(digest.supportingCount)/\(digest.sampleCount) observations support the claim"
        )
    }
}

/// Penalizes contradicting evidence relative to the claim type's
/// tolerance. Sources that don't track contradictions at all receive a
/// flat, neutral, non-punitive score rather than an assumed-perfect one —
/// see the file header for why "unknown" is not "zero."
public struct ContradictionEvaluator: MaturityEvaluating {
    public init() {}
    public let name = "contradiction"

    public func evaluate(digest: MaturityEvidenceDigest, requirement: ClaimRequirement, referenceDate _: Date) -> MaturitySignal {
        guard let contradicting = digest.contradictingCount else {
            return MaturitySignal(name: name, score: 0.6, weight: 0.75, rationale: "source does not track contradictions")
        }
        guard digest.sampleCount > 0 else {
            return MaturitySignal(name: name, score: 1.0, weight: 1.0, rationale: "no evidence to contradict")
        }
        let ratio = Double(contradicting) / Double(digest.sampleCount)
        let tolerance = max(requirement.maximumContradictionRatio, 0.0001)
        let score = max(0, 1 - (ratio / tolerance))
        return MaturitySignal(
            name: name,
            score: score,
            weight: 1.0,
            rationale: "\(contradicting)/\(digest.sampleCount) contradicting (tolerance \(Int(tolerance * 100))%)"
        )
    }
}

/// How well the pattern has replicated across distinct contexts, relative
/// to what this claim type requires. Claim types that don't require
/// replication (minimumReplication == 0) are fully satisfied trivially.
public struct ReplicationEvaluator: MaturityEvaluating {
    public init() {}
    public let name = "replication"

    public func evaluate(digest: MaturityEvidenceDigest, requirement: ClaimRequirement, referenceDate _: Date) -> MaturitySignal {
        guard requirement.minimumReplication > 0 else {
            return MaturitySignal(name: name, score: 1.0, weight: 0.5, rationale: "replication not required for this claim type")
        }
        let comfortable = Double(requirement.minimumReplication) * 2.0
        let score = comfortable > 0 ? min(1.0, Double(digest.distinctContextCount) / comfortable) : 0
        return MaturitySignal(
            name: name,
            score: score,
            weight: 1.0,
            rationale: "\(digest.distinctContextCount) distinct contexts against a floor of \(requirement.minimumReplication)"
        )
    }
}

/// How long the pattern has actually been visible in the evidence
/// (oldest-to-newest observed span), never how old the app install is.
public struct HistoricalDepthEvaluator: MaturityEvaluating {
    public init() {}
    public let name = "historicalDepth"

    public func evaluate(digest: MaturityEvidenceDigest, requirement: ClaimRequirement, referenceDate _: Date) -> MaturitySignal {
        guard requirement.minimumHistoricalSpanDays > 0 else {
            return MaturitySignal(name: name, score: 1.0, weight: 0.5, rationale: "historical span not required for this claim type")
        }
        let comfortable = Double(requirement.minimumHistoricalSpanDays) * 2.0
        let score = comfortable > 0 ? min(1.0, Double(digest.observedSpanDays) / comfortable) : 0
        return MaturitySignal(
            name: name,
            score: score,
            weight: 0.75,
            rationale: "evidence observed across \(digest.observedSpanDays) days (floor \(requirement.minimumHistoricalSpanDays)d)"
        )
    }
}

/// Compares the recent-window support ratio against the lifetime support
/// ratio to detect strengthening, stable, weakening, or reversing
/// patterns — feeds the "recently changed" / "unstable pattern" decisions.
public struct TrendStabilityEvaluator: MaturityEvaluating {
    public init() {}
    public let name = "trendStability"

    public func evaluate(digest: MaturityEvidenceDigest, requirement: ClaimRequirement, referenceDate _: Date) -> MaturitySignal {
        guard digest.sampleCount > 0 else {
            return MaturitySignal(name: name, score: 0.5, weight: 0.5, rationale: "no evidence for trend comparison")
        }
        let lifetimeRatio = Double(digest.supportingCount) / Double(digest.sampleCount)
        let recentTotal = digest.recentSupportingCount + (digest.recentContradictingCount ?? 0)
        let recentRatio = recentTotal > 0
            ? Double(digest.recentSupportingCount) / Double(recentTotal)
            : lifetimeRatio

        let delta = recentRatio - lifetimeRatio
        let threshold = max(requirement.recentWeakeningThreshold, 0.01)

        let score: Double
        if delta >= -threshold {
            score = 1.0
        } else {
            score = max(0, 1.0 + (delta + threshold) / threshold)
        }

        return MaturitySignal(
            name: name,
            score: score,
            weight: 1.0,
            rationale: "recent support ratio \(String(format: "%.2f", recentRatio)) vs lifetime \(String(format: "%.2f", lifetimeRatio))"
        )
    }
}

/// Confirms independent corroboration across domains a claim type
/// declares as required (e.g. a claim that needs both audio-context and
/// genre evidence before it means anything). Fully satisfied trivially
/// when a claim type requires no cross-domain corroboration.
public struct CrossDomainCorroborationEvaluator: MaturityEvaluating {
    public init() {}
    public let name = "crossDomainCorroboration"

    public func evaluate(digest: MaturityEvidenceDigest, requirement: ClaimRequirement, referenceDate _: Date) -> MaturitySignal {
        guard !requirement.requiredDomains.isEmpty else {
            return MaturitySignal(name: name, score: 1.0, weight: 0.5, rationale: "no cross-domain corroboration required")
        }
        let matched = requirement.requiredDomains.intersection(digest.involvedDomains)
        let score = Double(matched.count) / Double(requirement.requiredDomains.count)
        return MaturitySignal(
            name: name,
            score: score,
            weight: 1.25,
            rationale: "corroborated by \(matched.count)/\(requirement.requiredDomains.count) required domains"
        )
    }
}

// MARK: - Claim Requirement

/// One entry in the Claim Registry — the evidentiary bar a specific kind
/// of claim must clear before DataMaturityEngine will let it exist.
/// Every field here is one of the dimensions the product spec calls out
/// by name: minimum evidence, required repetition, acceptable
/// contradiction, maximum confidence, maximum wording strength,
/// expiration/decay behavior, and required corroborating context.
public struct ClaimRequirement: Sendable {
    public var minimumSampleCount: Int
    public var minimumDistinctDays: Int
    public var minimumReplication: Int
    public var minimumHistoricalSpanDays: Int
    public var requiredDomains: Set<MaturityDomain>
    public var maximumContradictionRatio: Double
    public var maximumConfidence: Double
    public var maximumNarrativeStrength: NarrativeStrengthTier
    public var decayHalfLifeDays: Double
    public var recentWeakeningThreshold: Double
    public var contextConcentrationThreshold: Double
    public var requiresMultiSeasonCoverage: Bool
    public var postponeProximityRatio: Double
    public var expiryHalfLifeMultiplier: Double
    public var customEvaluators: [MaturityEvaluating]?
    public var notes: String

    public init(
        minimumSampleCount: Int = 5,
        minimumDistinctDays: Int = 3,
        minimumReplication: Int = 0,
        minimumHistoricalSpanDays: Int = 0,
        requiredDomains: Set<MaturityDomain> = [],
        maximumContradictionRatio: Double = 0.35,
        maximumConfidence: Double = 0.9,
        maximumNarrativeStrength: NarrativeStrengthTier = .definitive,
        decayHalfLifeDays: Double = 60,
        recentWeakeningThreshold: Double = 0.25,
        contextConcentrationThreshold: Double = 0.75,
        requiresMultiSeasonCoverage: Bool = false,
        postponeProximityRatio: Double = 0.7,
        expiryHalfLifeMultiplier: Double = 3.0,
        customEvaluators: [MaturityEvaluating]? = nil,
        notes: String = ""
    ) {
        self.minimumSampleCount = minimumSampleCount
        self.minimumDistinctDays = minimumDistinctDays
        self.minimumReplication = minimumReplication
        self.minimumHistoricalSpanDays = minimumHistoricalSpanDays
        self.requiredDomains = requiredDomains
        self.maximumContradictionRatio = maximumContradictionRatio
        self.maximumConfidence = maximumConfidence
        self.maximumNarrativeStrength = maximumNarrativeStrength
        self.decayHalfLifeDays = decayHalfLifeDays
        self.recentWeakeningThreshold = recentWeakeningThreshold
        self.contextConcentrationThreshold = contextConcentrationThreshold
        self.requiresMultiSeasonCoverage = requiresMultiSeasonCoverage
        self.postponeProximityRatio = postponeProximityRatio
        self.expiryHalfLifeMultiplier = expiryHalfLifeMultiplier
        self.customEvaluators = customEvaluators
        self.notes = notes
    }

    /// A conservative fallback for any claim type nobody has registered
    /// yet. Deliberately stricter than most of the pre-registered types
    /// below — an unrecognized claim should have to work a little harder
    /// to be believed, not less.
    public static let unregisteredDefault = ClaimRequirement(
        minimumSampleCount: 10,
        minimumDistinctDays: 7,
        minimumReplication: 3,
        minimumHistoricalSpanDays: 14,
        maximumContradictionRatio: 0.25,
        maximumConfidence: 0.75,
        maximumNarrativeStrength: .moderate,
        notes: "Fallback for a claim type with no explicit Claim Registry entry."
    )
}

// MARK: - Claim Registry

/// "This registry becomes the application's behavioral constitution."
///
/// A value type on purpose: the app configures one at launch (or accepts
/// `.standard` as-is) and hands it to `DataMaturityEngine` by value.
/// There is no shared mutable global registry to synchronize, no locking
/// concern, and no risk of one caller's runtime registration silently
/// changing another caller's already-computed verdicts.
public struct ClaimRegistry: Sendable {
    private var requirements: [ClaimTypeIdentifier: ClaimRequirement]
    public var fallback: ClaimRequirement

    public init(requirements: [ClaimTypeIdentifier: ClaimRequirement] = [:], fallback: ClaimRequirement = .unregisteredDefault) {
        self.requirements = requirements
        self.fallback = fallback
    }

    public func requirement(for claimType: ClaimTypeIdentifier) -> ClaimRequirement {
        requirements[claimType] ?? fallback
    }

    /// Returns a copy of this registry with one additional or replaced
    /// entry — used to extend `.standard` rather than mutate it in place.
    public func registering(_ requirement: ClaimRequirement, for claimType: ClaimTypeIdentifier) -> ClaimRegistry {
        var copy = self
        copy.requirements[claimType] = requirement
        return copy
    }

    public var registeredClaimTypes: [ClaimTypeIdentifier] {
        Array(requirements.keys)
    }

    /// The bare, domain-agnostic baseline: no app-specific claim types
    /// registered, every claim type judged against `.unregisteredDefault`.
    /// This file intentionally knows nothing about "insight.bestReadingTime"
    /// or "weather.correlation" — that vocabulary belongs to the app, not to
    /// the engine. See `ClaimRegistry.appStandard` in
    /// DataMaturityEngineAdapters.swift for the populated registry the app
    /// actually runs with.
    public static let standard = ClaimRegistry()
}

// MARK: - Proposed Claim

/// What a caller hands to the engine: not the narrative text itself
/// (DataMaturityEngine never writes prose), just enough to judge whether
/// prose is earned.
public struct ProposedClaim: Sendable {
    public let claimType: ClaimTypeIdentifier
    public let digest: MaturityEvidenceDigest
    /// Domains that actually contributed to this specific instance —
    /// usually equal to `digest.involvedDomains`, kept as a separate
    /// parameter so a caller can express "this instance only drew from
    /// domain X" even if the digest's involvedDomains field was built
    /// generically.
    public let candidateDomains: Set<MaturityDomain>

    public init(claimType: ClaimTypeIdentifier, digest: MaturityEvidenceDigest, candidateDomains: Set<MaturityDomain>? = nil) {
        self.claimType = claimType
        self.digest = digest
        self.candidateDomains = candidateDomains ?? digest.involvedDomains
    }
}

// MARK: - Maturity Breakdown

/// The full, inspectable scoring trace behind a verdict — every signal
/// that fed the composite, plus the composite itself.
public struct MaturityBreakdown: Hashable, Codable, Sendable {
    public let signals: [MaturitySignal]
    public let compositeScore: Double
}

// MARK: - Maturity Verdict

/// DataMaturityEngine's complete answer for one proposed claim.
public struct MaturityVerdict: Sendable {
    public let claimType: ClaimTypeIdentifier
    public let decision: ClaimDecision
    public let disposition: ClaimDisposition
    /// The confidence ceiling the caller MAY report for this claim.
    /// Callers must clamp to this value, never exceed it — this is the
    /// number InsightEngine, ExplainabilityNarrativeBuilder, etc. should
    /// display or use to pick a template, replacing whatever ad hoc
    /// confidence math they used to compute on their own.
    public let allowedConfidence: Double
    public let narrativeStrength: NarrativeStrengthTier
    public let breakdown: MaturityBreakdown
    /// Plain-English trace of why this verdict was reached. Safe to log;
    /// treat as debug/explainability material rather than user-facing
    /// copy unless a caller specifically wants to expose "why am I seeing
    /// this" detail.
    public let rationale: [String]
    public let evaluatedAt: Date

    /// Convenience: whether the caller may show anything at all for this
    /// claim. Prefer switching on `disposition` directly when the
    /// difference between full and softened display matters.
    public var maySurface: Bool {
        disposition != .blocked
    }

    public init(
        claimType: ClaimTypeIdentifier,
        decision: ClaimDecision,
        allowedConfidence: Double,
        narrativeStrength: NarrativeStrengthTier,
        breakdown: MaturityBreakdown,
        rationale: [String],
        evaluatedAt: Date
    ) {
        self.claimType = claimType
        self.decision = decision
        disposition = decision.disposition
        self.allowedConfidence = max(0, min(allowedConfidence, 1))
        self.narrativeStrength = narrativeStrength
        self.breakdown = breakdown
        self.rationale = rationale
        self.evaluatedAt = evaluatedAt
    }
}

// MARK: - Claim Rules (the decision chain)

/// A single decision rule: given everything the engine knows about a
/// proposed claim, either hand back a decision or defer (`nil`) to the
/// next rule in the chain. `DataMaturityEngine.decide(...)` runs these in
/// order and takes the first non-nil answer, falling back to a
/// composite-score approval/softening determination if every rule
/// defers. This is the "modular rule system" the spec asks for in place
/// of one large switch — inserting a new decision path is adding one
/// rule to the array, not editing the others.
///
/// ROADMAP 3.4 (F-13b): rules receive the evaluation's `referenceDate`
/// as a final argument, so time-relative decisions (expiry) are computed
/// against the same injected clock the evaluators use — never the wall
/// clock — keeping them deterministically testable.
public struct ClaimRule: Sendable {
    public let name: String
    public let evaluate: @Sendable (MaturityEvidenceDigest, ClaimRequirement, MaturityBreakdown, Set<MaturityDomain>, Date) -> ClaimDecision?

    public init(name: String, evaluate: @escaping @Sendable (MaturityEvidenceDigest, ClaimRequirement, MaturityBreakdown, Set<MaturityDomain>, Date) -> ClaimDecision?) {
        self.name = name
        self.evaluate = evaluate
    }
}

// MARK: - Data Maturity Engine

/// The authority layer itself.
///
/// Stateless and pure by design: every call to `evaluate` / `canWeSayThis`
/// recomputes its answer from the digest handed to it. There is no
/// engine-internal store of past verdicts, no cache, and nothing written
/// to disk — DataMaturityEngine never touches persistence, per the
/// product spec, and a caller that wants "confidence over time" gets it
/// by supplying a digest whose recent/lifetime fields already encode
/// that history (see `MaturityEvidenceDigest.aggregate`), not by asking
/// this engine to remember anything between calls.
public struct DataMaturityEngine: Sendable {
    public let registry: ClaimRegistry
    public let evaluators: [MaturityEvaluating]
    public let rules: [ClaimRule]

    public init(
        registry: ClaimRegistry = .standard,
        evaluators: [MaturityEvaluating] = DataMaturityEngine.defaultEvaluators,
        rules: [ClaimRule] = DataMaturityEngine.defaultRules
    ) {
        self.registry = registry
        self.evaluators = evaluators
        self.rules = rules
    }

    public static let defaultEvaluators: [MaturityEvaluating] = [
        EvidenceVolumeEvaluator(),
        RecencyDecayEvaluator(),
        ConsistencyEvaluator(),
        ContradictionEvaluator(),
        ReplicationEvaluator(),
        HistoricalDepthEvaluator(),
        TrendStabilityEvaluator(),
        CrossDomainCorroborationEvaluator(),
    ]

    // MARK: Public API

    /// "Every inference must ask: canWeSayThis()." This is that question,
    /// named exactly as specified. Identical to `evaluate(_:asOf:)` —
    /// provided under both names so call sites can use whichever reads
    /// better in context.
    public func canWeSayThis(_ claim: ProposedClaim, asOf referenceDate: Date = Date()) -> MaturityVerdict {
        evaluate(claim, asOf: referenceDate)
    }

    public func evaluate(_ claim: ProposedClaim, asOf referenceDate: Date = Date()) -> MaturityVerdict {
        let requirement = registry.requirement(for: claim.claimType)
        let activeEvaluators = requirement.customEvaluators ?? evaluators

        let signals = activeEvaluators.map {
            $0.evaluate(digest: claim.digest, requirement: requirement, referenceDate: referenceDate)
        }
        let breakdown = Self.composite(signals: signals)

        let decision = decide(
            digest: claim.digest,
            requirement: requirement,
            breakdown: breakdown,
            domains: claim.candidateDomains,
            referenceDate: referenceDate
        )

        let allowedConfidence = Self.allowedConfidence(
            decision: decision,
            breakdown: breakdown,
            requirement: requirement,
            digest: claim.digest
        )

        let strength = Self.narrativeStrength(
            for: allowedConfidence,
            decision: decision,
            requirement: requirement
        )

        let rationale = Self.rationale(
            signals: signals,
            decision: decision,
            requirement: requirement,
            digest: claim.digest
        )

        return MaturityVerdict(
            claimType: claim.claimType,
            decision: decision,
            allowedConfidence: allowedConfidence,
            narrativeStrength: strength,
            breakdown: breakdown,
            rationale: rationale,
            evaluatedAt: referenceDate
        )
    }

    // MARK: Decision chain

    private func decide(
        digest: MaturityEvidenceDigest,
        requirement: ClaimRequirement,
        breakdown: MaturityBreakdown,
        domains: Set<MaturityDomain>,
        referenceDate: Date
    ) -> ClaimDecision {
        for rule in rules {
            if let decision = rule.evaluate(digest, requirement, breakdown, domains, referenceDate) {
                return decision
            }
        }
        // No rule fired a block or a soften — fall through to a plain
        // composite-score approval/softening call.
        return breakdown.compositeScore >= 0.7 ? .approved : .approvedSoftened
    }

    public static let defaultRules: [ClaimRule] = [
        ClaimRule(name: "minimumSampleCount") { digest, requirement, _, _, _ in
            guard digest.sampleCount < requirement.minimumSampleCount else { return nil }
            let ratio = requirement.minimumSampleCount > 0
                ? Double(digest.sampleCount) / Double(requirement.minimumSampleCount)
                : 1
            return ratio >= requirement.postponeProximityRatio ? .postponed : .needsMoreEvidence
        },

        ClaimRule(name: "minimumDistinctDays") { digest, requirement, _, _, _ in
            guard digest.distinctDayCount < requirement.minimumDistinctDays else { return nil }
            let ratio = requirement.minimumDistinctDays > 0
                ? Double(digest.distinctDayCount) / Double(requirement.minimumDistinctDays)
                : 1
            return ratio >= requirement.postponeProximityRatio ? .postponed : .needsMoreEvidence
        },

        ClaimRule(name: "minimumHistoricalSpan") { digest, requirement, _, _, _ in
            guard requirement.minimumHistoricalSpanDays > 0,
                  digest.observedSpanDays < requirement.minimumHistoricalSpanDays else { return nil }
            let ratio = Double(digest.observedSpanDays) / Double(requirement.minimumHistoricalSpanDays)
            return ratio >= requirement.postponeProximityRatio ? .postponed : .needsMoreEvidence
        },

        ClaimRule(name: "minimumReplicationCount") { digest, requirement, _, _, _ in
            guard requirement.minimumReplication > 0,
                  digest.distinctContextCount < requirement.minimumReplication else { return nil }
            return .needsMoreEvidence
        },

        ClaimRule(name: "requiredDomainCorroboration") { _, requirement, _, domains, _ in
            guard !requirement.requiredDomains.isEmpty,
                  !requirement.requiredDomains.isSubset(of: domains) else { return nil }
            return .needsMoreEvidence
        },

        ClaimRule(name: "contradictionCeiling") { digest, requirement, _, _, _ in
            guard let contradicting = digest.contradictingCount, digest.sampleCount > 0 else { return nil }
            let ratio = Double(contradicting) / Double(digest.sampleCount)
            return ratio > requirement.maximumContradictionRatio ? .contradicted : nil
        },

        ClaimRule(name: "expiry") { digest, requirement, _, _, referenceDate in
            // ROADMAP 3.4 (F-13b): was Date(). Now uses the injected
            // referenceDate so expiry is deterministic under test clocks.
            guard let last = digest.lastObservedAt, digest.sampleCount > 0 else { return nil }
            let daysSince = referenceDate.timeIntervalSince(last) / 86400
            let expiryThreshold = requirement.decayHalfLifeDays * requirement.expiryHalfLifeMultiplier
            let recentTotal = digest.recentSupportingCount + (digest.recentContradictingCount ?? 0)
            guard daysSince > expiryThreshold, recentTotal == 0 else { return nil }
            return .expired
        },

        ClaimRule(name: "trendSeverity") { _, _, breakdown, _, _ in
            guard let trendSignal = breakdown.signals.first(where: { $0.name == "trendStability" }) else { return nil }
            if trendSignal.score < 0.3 {
                return .unstablePattern
            }
            if trendSignal.score < 0.6 {
                return .recentlyChanged
            }
            return nil
        },

        ClaimRule(name: "contextConcentration") { digest, requirement, _, _, _ in
            guard requirement.minimumReplication > 0 else { return nil }
            guard digest.dominantContextShare > requirement.contextConcentrationThreshold else { return nil }
            return .contextSpecific
        },

        ClaimRule(name: "seasonalCoverage") { digest, requirement, _, _, _ in
            guard requirement.requiresMultiSeasonCoverage,
                  let periods = digest.distinctCalendarPeriodsObserved else { return nil }
            return periods < 2 ? .seasonalOnly : nil
        },
    ]

    // MARK: Scoring helpers

    private static func composite(signals: [MaturitySignal]) -> MaturityBreakdown {
        let totalWeight = signals.reduce(0) { $0 + $1.weight }
        let weighted = totalWeight > 0
            ? signals.reduce(0) { $0 + ($1.score * $1.weight) } / totalWeight
            : 0
        return MaturityBreakdown(signals: signals, compositeScore: max(0, min(weighted, 1)))
    }

    private static func allowedConfidence(
        decision: ClaimDecision,
        breakdown: MaturityBreakdown,
        requirement: ClaimRequirement,
        digest _: MaturityEvidenceDigest
    ) -> Double {
        guard decision.disposition != .blocked else { return 0 }
        let base = breakdown.compositeScore * requirement.maximumConfidence
        // Softened decisions never claim the full ceiling, even if the
        // composite score alone would justify it — the whole point of
        // "softened" is that something about this claim (concentration,
        // recency, seasonal coverage) keeps it a notch below full trust.
        let softenPenalty = decision.disposition == .displayableSoftened ? 0.85 : 1.0
        return max(0, min(base * softenPenalty, requirement.maximumConfidence))
    }

    private static func narrativeStrength(
        for confidence: Double,
        decision: ClaimDecision,
        requirement: ClaimRequirement
    ) -> NarrativeStrengthTier {
        guard decision.disposition != .blocked else { return .insufficient }

        let tier: NarrativeStrengthTier
        switch confidence {
        case ..<0.35: tier = .emerging
        case ..<0.55: tier = .moderate
        case ..<0.72: tier = .established
        case ..<0.85: tier = .strong
        default: tier = .definitive
        }

        return min(tier, requirement.maximumNarrativeStrength)
    }

    private static func rationale(
        signals: [MaturitySignal],
        decision: ClaimDecision,
        requirement: ClaimRequirement,
        digest _: MaturityEvidenceDigest
    ) -> [String] {
        var lines = ["Decision: \(decision.identifier) (\(decision.disposition.rawValue))"]
        if !requirement.notes.isEmpty {
            lines.append("Claim policy: \(requirement.notes)")
        }
        lines.append(contentsOf: signals.map { "\($0.name): \(String(format: "%.2f", $0.score)) — \($0.rationale)" })
        return lines
    }
}
