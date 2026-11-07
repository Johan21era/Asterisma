//  DataMaturityEngineAdapters.swift
//  -----------------------------------------------------------------------------
//  MARK: - What this file is
//  -----------------------------------------------------------------------------
//
//  DataMaturityEngine.swift is deliberately domain-agnostic — it has never
//  heard of a Book, a ReadingSession, or a CitedContextNarrative. This file
//  is the glue: it teaches four existing, already-live pipelines how to
//  translate their own evidence into MaturityEvidenceDigest, ask
//  canWeSayThis(), and act on the answer.
//
//  Four call sites are wired end to end here, because these are the four
//  places a proposed behavioral claim is actually reachable by the user
//  today:
//
//    1. BehaviorContextEngine  — buildNarratives() (V1, live, feeds
//       ContextInsightPanel via @Published summary) and
//       ExplainabilityNarrativeBuilder.build() (V3, richer, currently
//       unreferenced by any View but wired here so it is gate-correct
//       the moment something calls analyzeWithIntelligence()).
//    2. InsightEngine.generateAll()            — feeds ReadingInsightsDashboard.
//    3. WeatherAnalysisEngine.analyzeCorrelations() — feeds WeatherInsightPanel.
//    4. IntelligentNotificationEngine candidates — feeds NotificationScheduler,
//       i.e. an actual push notification the user sees.
//
//  Three more claim-shaped surfaces exist in the codebase
//  (AnnualReportGenerator.ReaderNarrativeProfile / AudioAnnualReport,
//  PredictiveRecommendationEngine's book ranking, AchievementEngine's
//  milestones) and are intentionally NOT wired here. See
//  "Session Concept 1.md" for why each was deferred rather than rushed.
//
//  Every adapter in this file follows the same shape: read whatever real
//  counts/dates the source engine already has lying around, build a
//  MaturityEvidenceDigest from them (never inventing evidence, never
//  reading Date() for anything but "now"), ask the shared engine instance
//  below, and let the verdict decide inclusion/wording — never the other
//  way around.
//

import Foundation

// MARK: - App-Specific Claim Types

/// Every claim type this app currently proposes, namespaced by which
/// pipeline proposes it. Centralized here (not scattered across four
/// files) so the full claim vocabulary is visible in one place, exactly
/// as the product spec asks: "This registry becomes the application's
/// behavioral constitution."
public enum AppClaimType {
    // BehaviorContextEngine (V1 profiles + V3 narrative categories share
    // the same underlying claim types — a routine claim is a routine
    // claim whether it surfaces as a plain ContextNarrative or a cited
    // NarrativeCategory.routine entry).
    public static let routine = ClaimTypeIdentifier("behaviorContext.routine")
    public static let environment = ClaimTypeIdentifier("behaviorContext.environment")
    public static let transition = ClaimTypeIdentifier("behaviorContext.transition")
    public static let disruption = ClaimTypeIdentifier("behaviorContext.disruption")
    public static let productive = ClaimTypeIdentifier("behaviorContext.productive")
    public static let evolution = ClaimTypeIdentifier("behaviorContext.evolution")
    public static let device = ClaimTypeIdentifier("behaviorContext.device")
    public static let recovery = ClaimTypeIdentifier("behaviorContext.recovery")

    /// WeatherAnalysisEngine — one claim type for every factor/metric pair.
    /// The evidentiary bar is the same regardless of which two variables
    /// are being correlated (confounding risk is structural, not
    /// per-variable), so this stays a single registry entry rather than
    /// one per EnvironmentalFactor × ReadingBehaviorMetric combination.
    public static let weatherCorrelation = ClaimTypeIdentifier("environmental.correlation")

    // InsightEngine — one entry per InsightKind so each can be tuned
    // independently (a streak-risk claim and a genre-pattern claim do not
    // deserve the same evidentiary bar).
    public static let insightBestReadingTime = ClaimTypeIdentifier("insight.bestReadingTime")
    public static let insightReadingTrend = ClaimTypeIdentifier("insight.readingTrend")
    public static let insightDifficultyMatch = ClaimTypeIdentifier("insight.difficultyMatch")
    public static let insightStreakRisk = ClaimTypeIdentifier("insight.streakRisk")
    public static let insightSpeedImprovement = ClaimTypeIdentifier("insight.speedImprovement")
    public static let insightGoalOnTrack = ClaimTypeIdentifier("insight.goalOnTrack")
    public static let insightGoalBehind = ClaimTypeIdentifier("insight.goalBehind")
    public static let insightSessionLength = ClaimTypeIdentifier("insight.sessionLength")
    public static let insightPredictionQuality = ClaimTypeIdentifier("insight.predictionQuality")
    public static let insightGenrePattern = ClaimTypeIdentifier("insight.genrePattern")
    public static let insightMilestoneNear = ClaimTypeIdentifier("insight.milestoneNear")
    public static let insightConsistencyReward = ClaimTypeIdentifier("insight.consistencyReward")
    public static let insightDrySpell = ClaimTypeIdentifier("insight.drySpell")

    /// IntelligentNotificationEngine — one entry per NotificationCategory.
    public static let notification = ClaimTypeIdentifier("notification.candidate")

    /// MusicalAnalysisEngine — not wired to a live UI pathway yet (see file
    /// header), registered in advance so the bar is already correct the
    /// day something calls AudioFactor 2.swift's generateInsights(from:).
    public static let audioGenreInteraction = ClaimTypeIdentifier("audio.genreInteraction")
}

// MARK: - Populated Claim Registry

private extension ClaimRequirement {
    /// Shorthand used repeatedly below: start from the baseline and
    /// override only the fields that differ, so each registry entry reads
    /// as "what's different about this claim" rather than restating every
    /// knob every time.
    static func policy(
        minimumSampleCount: Int = 5,
        minimumDistinctDays: Int = 3,
        minimumReplication: Int = 0,
        minimumHistoricalSpanDays: Int = 0,
        requiredDomains: Set<MaturityDomain> = [],
        maximumContradictionRatio: Double = 0.35,
        maximumConfidence: Double = 0.9,
        maximumNarrativeStrength: NarrativeStrengthTier = .definitive,
        decayHalfLifeDays: Double = 60,
        requiresMultiSeasonCoverage: Bool = false,
        notes: String
    ) -> ClaimRequirement {
        ClaimRequirement(
            minimumSampleCount: minimumSampleCount,
            minimumDistinctDays: minimumDistinctDays,
            minimumReplication: minimumReplication,
            minimumHistoricalSpanDays: minimumHistoricalSpanDays,
            requiredDomains: requiredDomains,
            maximumContradictionRatio: maximumContradictionRatio,
            maximumConfidence: maximumConfidence,
            maximumNarrativeStrength: maximumNarrativeStrength,
            decayHalfLifeDays: decayHalfLifeDays,
            requiresMultiSeasonCoverage: requiresMultiSeasonCoverage,
            notes: notes
        )
    }
}

public extension ClaimRegistry {
    /// The app's actual behavioral constitution. Calibrated directly
    /// against the product spec's own worked examples: a time-of-night
    /// routine claim needs "very little evidence"; a genre-speed
    /// comparison needs "moderate evidence"; a weather correlation needs
    /// "high evidence"; a cross-dimensional audio+genre claim needs "very
    /// high evidence" and explicit cross-domain corroboration.
    static let appStandard: ClaimRegistry = ClaimRegistry.standard
        // ── BehaviorContextEngine ────────────────────────────────────
        .registering(.policy(
            minimumSampleCount: 4, minimumDistinctDays: 3, minimumHistoricalSpanDays: 7,
            maximumConfidence: 0.85,
            notes: "Timing routines ('you usually read around 8pm') — the spec's own low-evidence example. A handful of recurrences across less than a week is enough to say something soft."
        ), for: AppClaimType.routine)
        .registering(.policy(
            minimumSampleCount: 6, minimumDistinctDays: 4, minimumHistoricalSpanDays: 10,
            maximumConfidence: 0.85,
            notes: "Pre/post-reading environment association. Moderate bar — environments repeat quickly but a single day's coincidence shouldn't become a claim."
        ), for: AppClaimType.environment)
        .registering(.policy(
            minimumSampleCount: 5, minimumDistinctDays: 3, minimumHistoricalSpanDays: 7,
            maximumConfidence: 0.8,
            notes: "Recurring behavioral transition immediately surrounding reading sessions."
        ), for: AppClaimType.transition)
        .registering(.policy(
            minimumSampleCount: 3, minimumDistinctDays: 2,
            maximumConfidence: 0.75, maximumNarrativeStrength: .established,
            notes: "Departure from an established routine. Low volume is fine — a disruption claim is about deviation, not depth — but it should never claim definitive strength; it is describing an exception, not a law."
        ), for: AppClaimType.disruption)
        .registering(.policy(
            minimumSampleCount: 9, minimumDistinctDays: 5, minimumReplication: 3, minimumHistoricalSpanDays: 14,
            maximumConfidence: 0.85,
            notes: "\"This environment produces your best sessions\" is a comparative quality claim across environments — needs real replication (matches ProductiveContextFinder's own guard qualities.count >= 3), not just volume in one environment."
        ), for: AppClaimType.productive)
        .registering(.policy(
            minimumSampleCount: 6, minimumDistinctDays: 4,
            maximumConfidence: 0.8, maximumNarrativeStrength: .established,
            notes: "\"Sessions were largely uninterrupted\" — a device-focus claim. Capped below definitive because device state is inherently noisy session to session."
        ), for: AppClaimType.device)
        .registering(.policy(
            minimumSampleCount: 3, minimumDistinctDays: 2,
            maximumConfidence: 0.75, maximumNarrativeStrength: .established,
            notes: "\"Reading follows inactivity\" recovery pattern — meaningful with modest volume, capped below definitive."
        ), for: AppClaimType.recovery)
        .registering(.policy(
            minimumSampleCount: 2, minimumDistinctDays: 2, minimumHistoricalSpanDays: 21,
            maximumConfidence: 0.8, maximumNarrativeStrength: .established,
            notes: "\"Your dominant environment shifted\" — an evolution claim is inherently about change over a real span; two snapshots is the floor, but it needs weeks, not days, to mean anything."
        ), for: AppClaimType.evolution)
        // ── WeatherAnalysisEngine ─────────────────────────────────────
        .registering(.policy(
            minimumSampleCount: 12, minimumDistinctDays: 8, minimumReplication: 4, minimumHistoricalSpanDays: 21,
            maximumContradictionRatio: 0.3, maximumConfidence: 0.8,
            requiresMultiSeasonCoverage: false,
            notes: "\"Cold weather improves reading speed\" — the spec's own high-evidence example. Environmental correlations are exactly the kind of claim easiest to get from a coincidence, so the floor sits well above WeatherAnalysisEngine's own internal minimum of 5 sessions."
        ), for: AppClaimType.weatherCorrelation)
        // ── InsightEngine ─────────────────────────────────────────────
        .registering(.policy(
            minimumSampleCount: 5, minimumDistinctDays: 4,
            maximumConfidence: 0.85,
            notes: "Best-reading-time-of-day. Low-to-moderate bar, matching the spec's 'you usually read at night' example."
        ), for: AppClaimType.insightBestReadingTime)
        .registering(.policy(
            minimumSampleCount: 6, minimumDistinctDays: 5, minimumHistoricalSpanDays: 14,
            maximumConfidence: 0.85,
            notes: "Growing/slowing pace trend — needs enough span to distinguish a trend from a single good or bad week."
        ), for: AppClaimType.insightReadingTrend)
        .registering(.policy(
            minimumSampleCount: 8, minimumDistinctDays: 5, minimumReplication: 3,
            maximumConfidence: 0.8,
            notes: "Not yet constructed anywhere in InsightEngine today (reserved InsightKind case) — registered in advance so whoever implements it inherits a calibrated bar instead of the conservative unregistered default."
        ), for: AppClaimType.insightDifficultyMatch)
        .registering(.policy(
            minimumSampleCount: 1, minimumDistinctDays: 1,
            maximumContradictionRatio: 0.9, maximumConfidence: 0.95,
            decayHalfLifeDays: 3,
            notes: "Streak-at-risk is a same-day factual read of streak state, not an inferred pattern — the bar is deliberately almost nonexistent, but it decays fast (half-life days, not weeks) since it is only meaningful today."
        ), for: AppClaimType.insightStreakRisk)
        .registering(.policy(
            minimumSampleCount: 10, minimumDistinctDays: 6, minimumHistoricalSpanDays: 14,
            maximumConfidence: 0.85,
            notes: "\"You're reading N% faster\" compares recent to earlier sessions — needs enough on both sides of that comparison to be trustworthy."
        ), for: AppClaimType.insightSpeedImprovement)
        .registering(.policy(
            minimumSampleCount: 1, minimumDistinctDays: 1,
            maximumConfidence: 0.95,
            notes: "Goal-period progress is deterministic arithmetic against a target the user set, not a behavioral inference — treated permissively and registered explicitly rather than silently skipped, so the constitution says why."
        ), for: AppClaimType.insightGoalOnTrack)
        .registering(.policy(
            minimumSampleCount: 1, minimumDistinctDays: 1,
            maximumConfidence: 0.9,
            notes: "Same reasoning as goalOnTrack — factual progress-vs-target, not pattern inference."
        ), for: AppClaimType.insightGoalBehind)
        .registering(.policy(
            minimumSampleCount: 6, minimumDistinctDays: 4,
            maximumConfidence: 0.8,
            notes: "Session-length pattern (too short / lengthening) — moderate-low bar."
        ), for: AppClaimType.insightSessionLength)
        .registering(.policy(
            minimumSampleCount: 1, minimumDistinctDays: 1,
            maximumConfidence: 0.7, maximumNarrativeStrength: .moderate,
            notes: "\"Predictions will improve\" is a meta-statement about estimate reliability for one active book, not a behavioral claim — capped at moderate strength since it is inherently a hedge."
        ), for: AppClaimType.insightPredictionQuality)
        .registering(.policy(
            minimumSampleCount: 10, minimumDistinctDays: 6, minimumReplication: 3,
            maximumConfidence: 0.85,
            notes: "\"You read fantasy faster than literary fiction\" — the spec's own moderate-evidence example. Not yet constructed anywhere in InsightEngine today; registered in advance."
        ), for: AppClaimType.insightGenrePattern)
        .registering(.policy(
            minimumSampleCount: 1, minimumDistinctDays: 1,
            maximumConfidence: 0.85,
            notes: "Achievement-proximity is a deterministic count-vs-threshold read, not an inference — same permissive treatment as goal insights."
        ), for: AppClaimType.insightMilestoneNear)
        .registering(.policy(
            minimumSampleCount: 7, minimumDistinctDays: 7,
            maximumConfidence: 0.9,
            notes: "A streak IS its own evidence by construction (N consecutive days) — the sample/day floor matches the engine's own >= 7 threshold for surfacing this insight at all."
        ), for: AppClaimType.insightConsistencyReward)
        .registering(.policy(
            minimumSampleCount: 1, minimumDistinctDays: 1,
            maximumConfidence: 0.95,
            notes: "A dry spell is a direct read of 'days since last session' — factual, not inferred. Permissive by design."
        ), for: AppClaimType.insightDrySpell)
        // ── IntelligentNotificationEngine ─────────────────────────────
        .registering(.policy(
            minimumSampleCount: 4, minimumDistinctDays: 3,
            maximumConfidence: 0.85, decayHalfLifeDays: 14,
            notes: "A notification candidate is a real-time targeting decision, not a durable claim, so evidence expectations stay light — but recency decays fast, since a candidate is only ever evaluated against 'right now'."
        ), for: AppClaimType.notification)
}

/// Registers the one claim type that needs to reference `ClaimRequirement`
/// fields not expressible through the terse `.policy` helper (cross-domain
/// corroboration) — kept separate so the dense table above stays scannable.
extension ClaimRegistry {
    fileprivate static let audioGenreRequirement = ClaimRequirement(
        minimumSampleCount: 15,
        minimumDistinctDays: 10,
        minimumReplication: 5,
        minimumHistoricalSpanDays: 30,
        requiredDomains: [.audio, .library],
        maximumContradictionRatio: 0.25,
        maximumConfidence: 0.8,
        decayHalfLifeDays: 45,
        notes: "\"Music consistently improves Action Fantasy reading\" — the spec's own very-high-evidence example. Requires independent corroboration from BOTH the audio domain and the library/genre domain; volume in only one is not enough."
    )

    /// The fully populated registry, including the cross-domain audio
    /// entry that needs the richer initializer above.
    public static let appStandardFull: ClaimRegistry = ClaimRegistry.appStandard
        .registering(audioGenreRequirement, for: AppClaimType.audioGenreInteraction)
}

// MARK: - Shared Engine Instance

/// The single authority every adapter below calls into. DataMaturityEngine
/// is stateless, so one shared instance is exactly as safe as constructing
/// a fresh one per call — this just avoids re-registering the claim table
/// on every evaluation.
public enum DataMaturityAuthority {
    public static let shared = DataMaturityEngine(registry: .appStandardFull)
}

// MARK: - Shared Helpers

private extension Date {
    /// Distinct "year-month" bucket, used when an adapter can cheaply
    /// derive multi-period coverage without a dedicated field.
    var calendarPeriodKey: String {
        let comps = Calendar.current.dateComponents([.year, .month], from: self)
        return "\(comps.year ?? 0)-\(comps.month ?? 0)"
    }
}

// =============================================================================
// MARK: - Adapter 1: BehaviorContextEngine (V1 — buildNarratives)

// =============================================================================

/// Bridges BehaviorContextEngine's V1 pipeline (ContextProfile ->
/// ContextNarrative, the pipeline actually wired to ContextInsightPanel
/// today) to DataMaturityEngine.
///
/// V1's ContextProfile carries no confidence or evidence of its own — it
/// is just a `(kind, value)` pair, the winner of a "most common" or
/// "first" pick. This adapter recovers real supporting evidence by
/// matching `profile.value` back against the routines/transitions/contexts
/// arrays that were in scope when the profile was built (the exact same
/// data `buildProfiles` used to pick a winner in the first place — see
/// BehaviorContextEngine.swift's `buildProfiles`).
enum DataMaturityContextV1Adapter {
    static func gate(
        profiles: [ContextProfile],
        routines: [BehavioralRoutine],
        transitions: [ContextTransition],
        contexts: [ReadingContextRecord],
        evidence: [BehaviorEvidence],
        asOf referenceDate: Date = Date()
    ) -> [ContextNarrative] {
        var results: [ContextNarrative] = []

        for profile in profiles {
            let claim = proposedClaim(for: profile, routines: routines, transitions: transitions, contexts: contexts, evidence: evidence)
            let verdict = DataMaturityAuthority.shared.canWeSayThis(claim, asOf: referenceDate)

            guard verdict.maySurface else { continue }
            results.append(phrase(profile: profile, verdict: verdict))
        }

        if results.isEmpty {
            results.append(ContextNarrative(
                text: "Insufficient recurring evidence exists to establish reliable contextual patterns."
            ))
        }

        return results
    }

    // MARK: Evidence recovery per profile kind

    private static func proposedClaim(
        for profile: ContextProfile,
        routines: [BehavioralRoutine],
        transitions: [ContextTransition],
        contexts: [ReadingContextRecord],
        evidence: [BehaviorEvidence]
    ) -> ProposedClaim {
        switch profile.kind {
        case .mostCommonPreReadingEnvironment:
            let matching = contexts.filter { $0.preReadingContext.type.rawValue == profile.value }
            let observations = matching.map {
                MaturityEvidenceObservation(date: $0.readingDate, supports: true, contextKey: $0.preReadingContext.type.rawValue)
            }
            let digest = MaturityEvidenceDigest.aggregate(observations, involvedDomains: [.behaviorContext])
            return ProposedClaim(claimType: AppClaimType.environment, digest: digest)

        case .mostCommonPostReadingEnvironment:
            let matching = contexts.filter { $0.postReadingContext.type.rawValue == profile.value }
            let observations = matching.map {
                MaturityEvidenceObservation(date: $0.readingDate, supports: true, contextKey: $0.postReadingContext.type.rawValue)
            }
            let digest = MaturityEvidenceDigest.aggregate(observations, involvedDomains: [.behaviorContext])
            return ProposedClaim(claimType: AppClaimType.environment, digest: digest)

        case .mostStableRoutine:
            guard let routine = routines.first(where: { $0.title == profile.value }) else {
                return ProposedClaim(claimType: AppClaimType.routine, digest: .empty)
            }
            // BehavioralRoutine carries no per-occurrence dates of its own;
            // the evidence corpus that fed routine detection is the best
            // available temporal backdrop for "how long has this held."
            let backdrop = evidenceBackdrop(evidence)
            var digest = backdrop
            digest.sampleCount = routine.recurrenceCount
            digest.supportingCount = routine.recurrenceCount
            digest.priorConfidenceHint = routine.confidence.score
            digest.involvedDomains.insert(.routine)
            return ProposedClaim(claimType: AppClaimType.routine, digest: digest)

        case .mostFrequentTransition:
            guard let transition = transitions.first(where: {
                profile.value == "\($0.from.rawValue) → \($0.to.rawValue)"
            }) else {
                return ProposedClaim(claimType: AppClaimType.transition, digest: .empty)
            }
            let matching = transitions.filter { $0.from == transition.from && $0.to == transition.to }
            let observations = matching.map {
                MaturityEvidenceObservation(date: $0.occurrenceDate, supports: true, contextKey: "\($0.from.rawValue)>\($0.to.rawValue)", weight: $0.strength)
            }
            let digest = MaturityEvidenceDigest.aggregate(observations, involvedDomains: [.behaviorContext])
            return ProposedClaim(claimType: AppClaimType.transition, digest: digest)
        }
    }

    /// Builds a digest from the full evidence corpus — used as a temporal
    /// backdrop for claim types whose own model (BehavioralRoutine) does
    /// not carry per-occurrence dates.
    private static func evidenceBackdrop(_ evidence: [BehaviorEvidence]) -> MaturityEvidenceDigest {
        let observations = evidence.map {
            MaturityEvidenceObservation(date: $0.timestamp, supports: true, contextKey: $0.category.rawValue, weight: $0.consistency)
        }
        return MaturityEvidenceDigest.aggregate(observations, involvedDomains: [.behaviorContext])
    }

    // MARK: Wording

    /// Keeps every existing V1 sentence exactly as written; only adds a
    /// tier-appropriate qualifier when the verdict is softened, so a
    /// claim that survives at `.emerging` doesn't read with the same
    /// certainty as one that survives at `.definitive`. Text choice is
    /// otherwise untouched — DataMaturityEngine decided whether and how
    /// strongly to speak, not what to say.
    private static func phrase(profile: ContextProfile, verdict: MaturityVerdict) -> ContextNarrative {
        let base: String
        switch profile.kind {
        case .mostCommonPreReadingEnvironment:
            base = "Reading most often followed \(profile.value.lowercased()) activity."
        case .mostCommonPostReadingEnvironment:
            base = "Reading commonly transitioned into \(profile.value.lowercased()) activity."
        case .mostStableRoutine:
            base = "A stable recurring reading routine was observed."
        case .mostFrequentTransition:
            base = "A recurring behavioral transition frequently surrounded reading sessions."
        }

        guard verdict.disposition == .displayableSoftened else {
            return ContextNarrative(text: base)
        }
        return ContextNarrative(text: "So far, \(verdict.narrativeStrength.qualifier), \(base.prefix(1).lowercased())\(base.dropFirst())")
    }
}

// =============================================================================
// MARK: - Adapter 2: BehaviorContextEngine (V3 — ExplainabilityNarrativeBuilder)

// =============================================================================

/// Bridges the richer V3 pipeline. Unlike V1, every input type here
/// (`RoutineDisruption.occurrenceDate`, `EnvironmentalCorrelation`-style
/// `EnvironmentEvolutionSnapshot.periodStart`, `ProductiveContextResult.
/// sampleCount`) already carries real evidentiary detail, so digests here
/// are more precise and rely less on a shared backdrop.
///
/// This pipeline is not called by any View today (see the investigation
/// notes in Session Concept 1.md) — it is still gated end to end so it is
/// correct the moment something starts calling
/// `BehaviorContextEngine.analyzeWithIntelligence`.
enum DataMaturityContextV3Adapter {
    static func gate(
        contexts: [ReadingContextRecord],
        routines: [BehavioralRoutine],
        trends: [ContextTrend],
        disruptions: [RoutineDisruption],
        productiveContext: ProductiveContextResult?,
        consistentContext _: ConsistentContextResult?,
        deviceProfiles: [DeviceStateInfluenceProfile],
        recoveryRecords: [RecoverySessionRecord],
        evolutionSnapshots: [EnvironmentEvolutionSnapshot],
        evidence: [BehaviorEvidence],
        asOf referenceDate: Date = Date()
    ) -> [CitedContextNarrative] {
        var narratives: [CitedContextNarrative] = []
        let allEvidenceIDs = evidence.map(\.id)
        let allSessionIDs = contexts.map(\.sessionID)
        let backdrop = evidenceBackdrop(evidence)
        let sessionDatesByID = Dictionary(contexts.map { ($0.sessionID, $0.readingDate) }, uniquingKeysWith: { first, _ in first })

        // ── Routine narratives ─────────────────────────────────────────
        for routine in routines {
            var digest = backdrop
            digest.sampleCount = routine.recurrenceCount
            digest.supportingCount = routine.recurrenceCount
            digest.priorConfidenceHint = routine.confidence.score
            digest.involvedDomains.insert(.routine)

            let verdict = DataMaturityAuthority.shared.canWeSayThis(
                ProposedClaim(claimType: AppClaimType.routine, digest: digest), asOf: referenceDate
            )
            guard verdict.maySurface else { continue }

            let text = "\(routine.recurrenceCount) reading sessions occurred at approximately \(routine.averageHour):00. \(routine.dominantEnvironment.rawValue.capitalized) activity was the most common preceding context."
            narratives.append(CitedContextNarrative(
                text: qualify(text, verdict: verdict),
                evidenceIDs: allEvidenceIDs,
                sessionIDs: allSessionIDs,
                confidence: ContextConfidence(score: verdict.allowedConfidence),
                category: .routine
            ))
        }

        // ── Environment trend narratives ───────────────────────────────
        for trend in trends where trend.direction == .increasing {
            var digest = backdrop
            digest.priorConfidenceHint = trend.strength
            digest.involvedDomains.insert(.behaviorContext)

            let verdict = DataMaturityAuthority.shared.canWeSayThis(
                ProposedClaim(claimType: AppClaimType.environment, digest: digest), asOf: referenceDate
            )
            guard verdict.maySurface else { continue }

            let pct = Int(trend.strength * 100)
            let text = "\(trend.environment.rawValue.capitalized) activity had the strongest association with reading sessions, appearing before \(pct)% of recorded sessions."
            narratives.append(CitedContextNarrative(
                text: qualify(text, verdict: verdict),
                evidenceIDs: allEvidenceIDs,
                sessionIDs: allSessionIDs,
                confidence: ContextConfidence(score: verdict.allowedConfidence),
                category: .environment
            ))
        }

        // ── Productive context narrative ───────────────────────────────
        if let prod = productiveContext {
            var digest = backdrop
            digest.sampleCount = prod.sampleCount
            digest.supportingCount = prod.sampleCount
            digest.priorConfidenceHint = prod.confidence.score
            digest.involvedDomains.insert(.behaviorContext)

            let verdict = DataMaturityAuthority.shared.canWeSayThis(
                ProposedClaim(claimType: AppClaimType.productive, digest: digest), asOf: referenceDate
            )
            if verdict.maySurface {
                let pct = Int(prod.averageSessionQuality * 100)
                let text = "Reading sessions preceded by \(prod.environment.rawValue) activity averaged a session quality score of \(pct)%, the highest across all observed environments."
                narratives.append(CitedContextNarrative(
                    text: qualify(text, verdict: verdict),
                    evidenceIDs: allEvidenceIDs,
                    sessionIDs: allSessionIDs,
                    confidence: ContextConfidence(score: verdict.allowedConfidence),
                    category: .productive
                ))
            }
        }

        // ── Disruption narrative ────────────────────────────────────────
        if !disruptions.isEmpty, let first = disruptions.first {
            let observations = disruptions.map {
                MaturityEvidenceObservation(date: $0.occurrenceDate, supports: true, contextKey: $0.routineTitle, weight: $0.disruptionScore)
            }
            let digest = MaturityEvidenceDigest.aggregate(observations, involvedDomains: [.behaviorContext, .routine])

            let verdict = DataMaturityAuthority.shared.canWeSayThis(
                ProposedClaim(claimType: AppClaimType.disruption, digest: digest), asOf: referenceDate
            )
            if verdict.maySurface {
                let text = "\(disruptions.count) sessions occurred outside the established \(first.routineTitle) routine window."
                narratives.append(CitedContextNarrative(
                    text: qualify(text, verdict: verdict),
                    evidenceIDs: allEvidenceIDs,
                    sessionIDs: disruptions.map(\.id),
                    confidence: ContextConfidence(score: verdict.allowedConfidence),
                    category: .disruption
                ))
            }
        }

        // ── Device focus narrative ──────────────────────────────────────
        if !deviceProfiles.isEmpty {
            let meanFocusScore = deviceProfiles.map(\.influenceScore).reduce(0, +) / Double(deviceProfiles.count)
            let observations = deviceProfiles.map { profileRecord -> MaturityEvidenceObservation in
                let date = sessionDatesByID[profileRecord.sessionID] ?? referenceDate
                return MaturityEvidenceObservation(date: date, supports: profileRecord.deviceWasFocused, contextKey: "device", weight: profileRecord.influenceScore)
            }
            let digest = MaturityEvidenceDigest.aggregate(observations, involvedDomains: [.device])

            let verdict = DataMaturityAuthority.shared.canWeSayThis(
                ProposedClaim(claimType: AppClaimType.device, digest: digest), asOf: referenceDate
            )
            if verdict.maySurface, meanFocusScore > 0.5 {
                let interruptedPct = Int((1 - meanFocusScore) * 100)
                let text = "Reading sessions were largely uninterrupted — screen lock events occurred in fewer than \(interruptedPct)% of sessions."
                narratives.append(CitedContextNarrative(
                    text: qualify(text, verdict: verdict),
                    evidenceIDs: allEvidenceIDs,
                    sessionIDs: deviceProfiles.map(\.sessionID),
                    confidence: ContextConfidence(score: verdict.allowedConfidence),
                    category: .device
                ))
            }
        }

        // ── Recovery narrative ───────────────────────────────────────────
        if !recoveryRecords.isEmpty {
            var digest = backdrop
            digest.sampleCount = recoveryRecords.count
            digest.supportingCount = recoveryRecords.count
            digest.involvedDomains.insert(.behaviorContext)

            let verdict = DataMaturityAuthority.shared.canWeSayThis(
                ProposedClaim(claimType: AppClaimType.recovery, digest: digest), asOf: referenceDate
            )
            if verdict.maySurface {
                let text = "\(recoveryRecords.count) reading sessions followed extended inactivity periods, suggesting reading is used as a re-engagement activity after breaks."
                narratives.append(CitedContextNarrative(
                    text: qualify(text, verdict: verdict),
                    evidenceIDs: allEvidenceIDs,
                    sessionIDs: recoveryRecords.map(\.sessionID),
                    confidence: ContextConfidence(score: verdict.allowedConfidence),
                    category: .recovery
                ))
            }
        }

        // ── Evolution narrative ──────────────────────────────────────────
        if evolutionSnapshots.count >= 2,
           let first = evolutionSnapshots.first,
           let last = evolutionSnapshots.last,
           first.dominantEnvironment != last.dominantEnvironment
        {
            let observations = evolutionSnapshots.map {
                MaturityEvidenceObservation(date: $0.periodStart, supports: true, contextKey: $0.dominantEnvironment.rawValue, weight: $0.distributionScore)
            }
            let digest = MaturityEvidenceDigest.aggregate(observations, involvedDomains: [.behaviorContext])

            let verdict = DataMaturityAuthority.shared.canWeSayThis(
                ProposedClaim(claimType: AppClaimType.evolution, digest: digest), asOf: referenceDate
            )
            if verdict.maySurface {
                let text = "The dominant pre-reading environment shifted from \(first.dominantEnvironment.rawValue) to \(last.dominantEnvironment.rawValue) over the observed period."
                narratives.append(CitedContextNarrative(
                    text: qualify(text, verdict: verdict),
                    evidenceIDs: allEvidenceIDs,
                    sessionIDs: allSessionIDs,
                    confidence: ContextConfidence(score: verdict.allowedConfidence),
                    category: .evolution
                ))
            }
        }

        return narratives
    }

    private static func evidenceBackdrop(_ evidence: [BehaviorEvidence]) -> MaturityEvidenceDigest {
        let observations = evidence.map {
            MaturityEvidenceObservation(date: $0.timestamp, supports: true, contextKey: $0.category.rawValue, weight: $0.consistency)
        }
        return MaturityEvidenceDigest.aggregate(observations, involvedDomains: [.behaviorContext])
    }

    /// Prefixes a softened claim with its tier's qualifier; leaves fully
    /// approved text untouched. `text` values already read naturally as
    /// present-tense statements, so the qualifier is inserted as a
    /// leading clause rather than word-substituted into the sentence.
    private static func qualify(_ text: String, verdict: MaturityVerdict) -> String {
        guard verdict.disposition == .displayableSoftened else { return text }
        return "Based on the evidence so far (\(verdict.narrativeStrength.qualifier)): \(text)"
    }
}

// =============================================================================
// MARK: - Adapter 3: InsightEngine (ReadingInsight)

// =============================================================================

/// Bridges InsightEngine's flat, per-kind ad hoc confidence numbers to
/// DataMaturityEngine. InsightEngine's private builder functions only see
/// pre-aggregated AnalyticsEngine summaries (no raw per-session dates), so
/// this adapter reaches for the one place real session history is still
/// available — the `books` array `generateAll` already receives — rather
/// than widening every private builder's signature.
///
/// Each existing per-kind confidence formula is left completely alone
/// (that math is InsightEngine's own "Inference Proposal" self-assessment
/// and is passed through as `priorConfidenceHint`, advisory only).
/// DataMaturityEngine's `allowedConfidence` — never the original number —
/// is what a caller should treat as authoritative going forward.
enum DataMaturityInsightAdapter {
    static func gate(
        _ insights: [ReadingInsight],
        books: [Book],
        asOf referenceDate: Date = Date()
    ) -> [ReadingInsight] {
        let allSessions = books.flatMap(\.sessions)
        let generalDigest = generalReadingDigest(sessions: allSessions, asOf: referenceDate)

        let gated: [ReadingInsight] = insights.compactMap { insight in
            let resolvedClaimType = claimType(for: insight.kind)
            let resolvedDigest = digest(for: insight, generalDigest: generalDigest, books: books, sessions: allSessions, referenceDate: referenceDate)
            let verdict = DataMaturityAuthority.shared.canWeSayThis(
                ProposedClaim(claimType: resolvedClaimType, digest: resolvedDigest), asOf: referenceDate
            )
            guard verdict.maySurface else { return nil }

            // The insight's own confidence is replaced with the engine's
            // allowed ceiling — never the larger of the two.
            return ReadingInsight(
                id: insight.id,
                kind: insight.kind,
                title: insight.title,
                body: insight.body,
                actionSuggestion: insight.actionSuggestion,
                confidence: min(insight.confidence, verdict.allowedConfidence),
                priority: insight.priority
            )
        }

        return gated.sorted { $0.priority < $1.priority }
    }

    private static func claimType(for kind: ReadingInsight.InsightKind) -> ClaimTypeIdentifier {
        switch kind {
        case .bestReadingTime: return AppClaimType.insightBestReadingTime
        case .readingTrend: return AppClaimType.insightReadingTrend
        case .difficultyMatch: return AppClaimType.insightDifficultyMatch
        case .streakRisk: return AppClaimType.insightStreakRisk
        case .speedImprovement: return AppClaimType.insightSpeedImprovement
        case .goalOnTrack: return AppClaimType.insightGoalOnTrack
        case .goalBehind: return AppClaimType.insightGoalBehind
        case .sessionLength: return AppClaimType.insightSessionLength
        case .predictionQuality: return AppClaimType.insightPredictionQuality
        case .genrePattern: return AppClaimType.insightGenrePattern
        case .milestoneNear: return AppClaimType.insightMilestoneNear
        case .consistencyReward: return AppClaimType.insightConsistencyReward
        case .drySpell: return AppClaimType.insightDrySpell
        }
    }

    /// A shared digest built from the full session history — the
    /// reasonable default for any insight kind that is genuinely about
    /// overall reading behavior (time-of-day, trend, session length,
    /// speed) rather than about one narrower thing (a single book, the
    /// live streak, a goal period).
    private static func generalReadingDigest(sessions: [ReadingSession], asOf referenceDate: Date) -> MaturityEvidenceDigest {
        let observations = sessions.compactMap { session -> MaturityEvidenceObservation? in
            guard let end = session.endTime else { return nil }
            return MaturityEvidenceObservation(date: end, supports: true, contextKey: nil)
        }
        return MaturityEvidenceDigest.aggregate(observations, asOf: referenceDate, involvedDomains: [.reading, .session])
    }

    private static func digest(
        for insight: ReadingInsight,
        generalDigest: MaturityEvidenceDigest,
        books: [Book],
        sessions _: [ReadingSession],
        referenceDate: Date
    ) -> MaturityEvidenceDigest {
        switch insight.kind {
        case .predictionQuality:
            // Scoped to whichever active book InsightEngine evaluated —
            // recovered by matching the book named in the insight body
            // rather than threading a book reference through ReadingInsight.
            if let book = books.first(where: { insight.body.contains($0.title) }) {
                let observations = book.sessions.compactMap { s -> MaturityEvidenceObservation? in
                    guard let end = s.endTime else { return nil }
                    return MaturityEvidenceObservation(date: end, supports: true, contextKey: book.id.uuidString)
                }
                return MaturityEvidenceDigest.aggregate(observations, asOf: referenceDate, involvedDomains: [.reading, .library])
            }
            return generalDigest

        case .streakRisk, .consistencyReward, .drySpell:
            // Streak/dry-spell claims are about recency, not depth — the
            // general digest's recentSupportingCount already captures
            // this well, and priorConfidenceHint carries InsightEngine's
            // own already-good streak-specific number.
            var digest = generalDigest
            digest.priorConfidenceHint = insight.confidence
            return digest

        case .goalOnTrack, .goalBehind, .milestoneNear:
            // Deterministic progress-vs-target reads — a single
            // observation "as of now" is sufficient by the registry's own
            // permissive policy for these claim types.
            return MaturityEvidenceDigest(
                sampleCount: 1,
                supportingCount: 1,
                distinctDayCount: 1,
                firstObservedAt: referenceDate,
                lastObservedAt: referenceDate,
                recentSupportingCount: 1,
                involvedDomains: [.reading],
                priorConfidenceHint: insight.confidence
            )

        default:
            var digest = generalDigest
            digest.priorConfidenceHint = insight.confidence
            return digest
        }
    }
}

// =============================================================================
// MARK: - Adapter 4: WeatherAnalysisEngine (EnvironmentalCorrelation)

// =============================================================================

/// Bridges WeatherAnalysisEngine's correlations. Unlike InsightEngine,
/// EnvironmentalCorrelation already carries real firstObserved/
/// lastObserved/supportingSampleCount fields, so this digest needs no
/// backdrop borrowing at all — it is built entirely from the correlation
/// itself. `analyzeCorrelations()` is never called or modified here; this
/// only gates its output before WeatherInsightPanel displays it.
enum DataMaturityWeatherAdapter {
    struct GatedCorrelation: Identifiable {
        var id: UUID {
            correlation.id
        }

        let correlation: EnvironmentalCorrelation
        let verdict: MaturityVerdict
    }

    static func gate(
        _ correlations: [EnvironmentalCorrelation],
        asOf referenceDate: Date = Date()
    ) -> [GatedCorrelation] {
        correlations.compactMap { correlation in
            let digest = MaturityEvidenceDigest(
                sampleCount: correlation.supportingSampleCount,
                supportingCount: correlation.supportingSampleCount,
                distinctDayCount: correlation.supportingSampleCount, // WeatherAnalysisEngine samples at session granularity; one weather reading per session in practice
                firstObservedAt: correlation.firstObserved,
                lastObservedAt: correlation.lastObserved,
                distinctCalendarPeriodsObserved: distinctPeriods(from: correlation.firstObserved, to: correlation.lastObserved),
                recentSupportingCount: correlation.lifecycle == .weakening || correlation.lifecycle == .declining ? 0 : correlation.supportingSampleCount,
                involvedDomains: [.environmental],
                priorConfidenceHint: correlation.confidence.overallConfidence
            )

            let verdict = DataMaturityAuthority.shared.canWeSayThis(
                ProposedClaim(claimType: AppClaimType.weatherCorrelation, digest: digest), asOf: referenceDate
            )
            guard verdict.maySurface else { return nil }
            return GatedCorrelation(correlation: correlation, verdict: verdict)
        }
    }

    private static func distinctPeriods(from start: Date, to end: Date) -> Int {
        guard start <= end else { return 1 }
        var count = Set<String>()
        var cursor = start
        var iterations = 0
        while cursor <= end, iterations < 64 {
            count.insert(cursor.calendarPeriodKey)
            guard let next = Calendar.current.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
            iterations += 1
        }
        return max(count.count, 1)
    }
}

// =============================================================================
// MARK: - Adapter 5: IntelligentNotificationEngine (NotificationCandidate)

// =============================================================================

/// Bridges a NotificationCandidate before SessionEventRouter hands it to
/// NotificationScheduler. A push notification is the one pathway in this
/// app where a "claim" reaches the user completely outside SwiftUI —
/// gating it here closes that gap.
enum DataMaturityNotificationAdapter {
    static func evaluate(_ candidate: NotificationCandidate, asOf referenceDate: Date = Date()) -> MaturityVerdict {
        let digest = MaturityEvidenceDigest(
            sampleCount: candidate.confidence.sessionCount,
            supportingCount: candidate.confidence.completedSessions,
            distinctDayCount: candidate.confidence.activeDays,
            firstObservedAt: nil,
            lastObservedAt: referenceDate, // NotificationConfidence is computed fresh at evaluation time; "now" is the only honest timestamp available.
            recentSupportingCount: candidate.confidence.activeDays,
            involvedDomains: [.notification, .session],
            priorConfidenceHint: candidate.confidence.score
        )
        return DataMaturityAuthority.shared.canWeSayThis(
            ProposedClaim(claimType: AppClaimType.notification, digest: digest), asOf: referenceDate
        )
    }
}
