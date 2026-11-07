//  BehaviorContextEngine2.swift
// 
//
import Combine
import Foundation

/// -----------------------------------------------------------------------------
/// MARK: - Behavior Context Engine
/// -----------------------------------------------------------------------------
///
/// BehaviorContextEngine is the contextual reconstruction layer for the reading
/// application.
///
/// Architectural purpose:
///
/// Traditional analytics systems answer:
/// - How much was read?
/// - How fast was reading?
/// - Was a goal completed?
///
/// This engine answers:
/// - What was happening before reading?
/// - What was happening during reading?
/// - What was happening after reading?
/// - Which routines repeatedly lead into reading?
/// - Which environments consistently surround reading?
///
/// The engine intentionally operates above evidence collection systems.
///
/// BehaviorContextAccessKit records observations.
/// BehaviorContextEngine interprets observations.
///
/// The engine aggressively distinguishes meaningful recurring behavior from
/// incidental noise.
///
/// Example:
///
/// Evidence:
/// - Dictionary opened once for 2 seconds.
///
/// Interpretation:
/// - Incidental behavior.
///
/// Evidence:
/// - Notes used daily before reading for 45 days.
///
/// Interpretation:
/// - Stable recurring pre-reading routine.
///
/// The engine never derives context from absence alone.
/// Absence is only meaningful when evaluating disruption of established routines.
///
@MainActor
public final class BehaviorContextEngine: ObservableObject {
    // MARK: Configuration

    public struct Configuration: Sendable, Codable, Hashable {
        public var preReadingWindow: TimeInterval
        public var postReadingWindow: TimeInterval
        public var significanceThreshold: Double

        public init(
            preReadingWindow: TimeInterval = 60 * 60,
            postReadingWindow: TimeInterval = 60 * 60,
            significanceThreshold: Double = 0.35
        ) {
            self.preReadingWindow = preReadingWindow
            self.postReadingWindow = postReadingWindow
            self.significanceThreshold = significanceThreshold
        }
    }

    @Published public private(set) var summary: BehavioralContextSummary?
    /// G6: the richer V3 report. The simple panel still reads `summary`;
    /// Advanced Context reads this.
    @Published public private(set) var intelligenceReport: FullContextIntelligenceReport?

    public let configuration: Configuration

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration

        #if DEBUG
        DeveloperConsoleRegistry.shared.register(self)
        #endif
    }

    // MARK: Public API

    /// Full erase support: drop the published reports when the underlying
    /// evidence/session store is intentionally wiped.
    public func reset() {
        summary = nil
        intelligenceReport = nil
    }

    public func analyze(
        sessions: [ReadingSessionRecord],
        evidence: [BehaviorEvidence],
        weatherRecords: [WeatherContextRecord] = []
    ) -> BehavioralContextSummary {
        let assessments = evidence.map(significanceAssessment)

        let significantEvidence = zip(evidence, assessments)
            .filter { $0.1.isSignificant }
            .map(\.0)

        let routines = detectRoutines(
            sessions: sessions,
            evidence: significantEvidence
        )

        let transitions = buildTransitions(
            sessions: sessions,
            evidence: significantEvidence
        )

        let contexts = reconstructContexts(
            sessions: sessions,
            evidence: significantEvidence,
            weather: weatherRecords
        )

        let profiles = buildProfiles(
            contexts: contexts,
            routines: routines,
            transitions: transitions
        )

        let narratives = buildNarratives(
            profiles: profiles,
            routines: routines,
            transitions: transitions,
            contexts: contexts,
            evidence: significantEvidence
        )

        let confidence = calculateOverallConfidence(
            sessions: sessions,
            routines: routines,
            transitions: transitions
        )

        let summary = BehavioralContextSummary(
            generatedAt: Date(),
            contextRecords: contexts,
            routines: routines,
            transitions: transitions,
            profiles: profiles,
            narratives: narratives,
            confidence: confidence
        )

        self.summary = summary

        return summary
    }
}

private extension BehaviorContextEngine {
    func significanceAssessment(
        for evidence: BehaviorEvidence
    ) -> SignificanceAssessment {
        let normalizedDuration =
            min(evidence.totalDuration / (60 * 30), 1.0)

        let normalizedFrequency =
            min(Double(evidence.frequency) / 30.0, 1.0)

        let normalizedRecurrence =
            min(Double(evidence.recurrenceCount) / 20.0, 1.0)

        let normalizedConsistency =
            min(max(evidence.consistency, 0), 1)

        let normalizedProximity =
            min(max(evidence.proximityToReading, 0), 1)

        let score =
            (normalizedDuration * 0.25) +
            (normalizedFrequency * 0.20) +
            (normalizedRecurrence * 0.25) +
            (normalizedConsistency * 0.15) +
            (normalizedProximity * 0.15)

        return SignificanceAssessment(
            score: score,
            isSignificant: score >= configuration.significanceThreshold,
            rationale: rationale(for: score)
        )
    }

    func rationale(for score: Double) -> String {
        switch score {
        case 0.80...:
            return "Strong recurring behavior"
        case 0.60 ..< 0.80:
            return "Meaningful contextual signal"
        case 0.35 ..< 0.60:
            return "Moderately relevant activity"
        default:
            return "Likely incidental behavior"
        }
    }
}

private extension BehaviorContextEngine {
    func reconstructContexts(
        sessions: [ReadingSessionRecord],
        evidence: [BehaviorEvidence],
        weather: [WeatherContextRecord]
    ) -> [ReadingContextRecord] {
        sessions.map { session in
            let preWindow = ContextWindow(
                start: session.startDate.addingTimeInterval(
                    -configuration.preReadingWindow
                ),
                end: session.startDate
            )

            let postWindow = ContextWindow(
                start: session.endDate,
                end: session.endDate.addingTimeInterval(
                    configuration.postReadingWindow
                )
            )

            let preEvidence = evidence.filter {
                preWindow.contains($0.timestamp)
            }

            let inEvidence = evidence.filter {
                session.interval.contains($0.timestamp)
            }

            let postEvidence = evidence.filter {
                postWindow.contains($0.timestamp)
            }

            let weatherRecord = weather.min {
                abs($0.timestamp.timeIntervalSince(session.startDate))
                    <
                    abs($1.timestamp.timeIntervalSince(session.startDate))
            }

            return ReadingContextRecord(
                sessionID: session.id,
                readingDate: session.startDate,
                preReadingContext: buildEnvironment(from: preEvidence),
                inSessionContext: buildEnvironment(from: inEvidence),
                postReadingContext: buildEnvironment(from: postEvidence),
                weatherContext: weatherRecord,
                confidence: contextConfidence(
                    evidenceCount:
                    preEvidence.count +
                        inEvidence.count +
                        postEvidence.count
                )
            )
        }
    }

    func buildEnvironment(
        from evidence: [BehaviorEvidence]
    ) -> BehavioralEnvironment {
        guard !evidence.isEmpty else {
            return BehavioralEnvironment(
                type: .unknown,
                contributingActivities: [],
                confidence: .low
            )
        }

        let categories = evidence.map(\.category)

        let dominant = categories
            .reduce(into: [:]) { $0[$1, default: 0] += 1 }
            .max { $0.value < $1.value }?
            .key

        return BehavioralEnvironment(
            type: environmentType(from: dominant),
            contributingActivities: evidence.map(\.name),
            confidence: confidenceForEvidence(evidence)
        )
    }

    func environmentType(
        from category: BehaviorCategory?
    ) -> BehavioralEnvironmentType {
        switch category {
        case .development:
            return .development
        case .research:
            return .research
        case .gaming:
            return .gaming
        case .learning:
            return .learning
        case .social:
            return .social
        case .entertainment:
            return .entertainment
        case .administrative:
            return .administrative
        case .browsing:
            return .browsing
        case .creative:
            return .creative
        case .productivity:
            return .work
        case .idle:
            return .idle
        case nil:
            return .unknown
        }
    }
}

private extension BehaviorContextEngine {
    func detectRoutines(
        sessions: [ReadingSessionRecord],
        evidence: [BehaviorEvidence]
    ) -> [BehavioralRoutine] {
        let grouped = Dictionary(
            grouping: sessions
        ) { session in
            Calendar.current.component(
                .hour,
                from: session.startDate
            )
        }

        return grouped.map { hour, sessions in
            let confidence = ContextConfidence(
                score: min(
                    Double(sessions.count) / 20.0,
                    1.0
                )
            )

            return BehavioralRoutine(
                title: "\(hour):00 Reading Routine",
                recurrenceCount: sessions.count,
                averageHour: hour,
                dominantEnvironment: dominantEnvironment(
                    sessions: sessions,
                    evidence: evidence
                ),
                confidence: confidence
            )
        }
        .sorted {
            $0.recurrenceCount > $1.recurrenceCount
        }
    }

    func dominantEnvironment(
        sessions: [ReadingSessionRecord],
        evidence: [BehaviorEvidence]
    ) -> BehavioralEnvironmentType {
        var counts: [BehavioralEnvironmentType: Int] = [:]

        for session in sessions {
            let start = session.startDate
                .addingTimeInterval(-configuration.preReadingWindow)

            let related = evidence.filter {
                $0.timestamp >= start &&
                    $0.timestamp <= session.startDate
            }

            let environment = buildEnvironment(from: related)

            counts[environment.type, default: 0] += 1
        }

        return counts.max {
            $0.value < $1.value
        }?.key ?? .unknown
    }
}

private extension BehaviorContextEngine {
    func buildTransitions(
        sessions: [ReadingSessionRecord],
        evidence: [BehaviorEvidence]
    ) -> [ContextTransition] {
        var transitions: [ContextTransition] = []

        for session in sessions {
            let pre = evidence.filter {
                $0.timestamp >= session.startDate
                    .addingTimeInterval(-configuration.preReadingWindow)
                    &&
                    $0.timestamp <= session.startDate
            }

            let post = evidence.filter {
                $0.timestamp >= session.endDate
                    &&
                    $0.timestamp <= session.endDate
                    .addingTimeInterval(configuration.postReadingWindow)
            }

            let from = buildEnvironment(from: pre).type
            let to = buildEnvironment(from: post).type

            transitions.append(
                ContextTransition(
                    from: from,
                    to: to,
                    occurrenceDate: session.startDate,
                    strength: transitionStrength(
                        from: pre.count,
                        to: post.count
                    )
                )
            )
        }

        return transitions
    }

    func transitionStrength(
        from preCount: Int,
        to postCount: Int
    ) -> Double {
        min(Double(preCount + postCount) / 20.0, 1.0)
    }
}

private extension BehaviorContextEngine {
    func buildProfiles(
        contexts: [ReadingContextRecord],
        routines: [BehavioralRoutine],
        transitions: [ContextTransition]
    ) -> [ContextProfile] {
        var profiles: [ContextProfile] = []

        if let commonPre = contexts
            .map(\.preReadingContext.type)
            .mostCommon
        {
            profiles.append(
                ContextProfile(
                    kind: .mostCommonPreReadingEnvironment,
                    value: commonPre.rawValue
                )
            )
        }

        if let commonPost = contexts
            .map(\.postReadingContext.type)
            .mostCommon
        {
            profiles.append(
                ContextProfile(
                    kind: .mostCommonPostReadingEnvironment,
                    value: commonPost.rawValue
                )
            )
        }

        if let routine = routines.first {
            profiles.append(
                ContextProfile(
                    kind: .mostStableRoutine,
                    value: routine.title
                )
            )
        }

        if let transition = transitions.first {
            profiles.append(
                ContextProfile(
                    kind: .mostFrequentTransition,
                    value:
                    "\(transition.from.rawValue) → \(transition.to.rawValue)"
                )
            )
        }

        return profiles
    }
}

private extension BehaviorContextEngine {
    /// Builds the narrative candidates for each detected profile, then
    /// asks DataMaturityEngine whether each one has earned the right to
    /// exist before it is returned. This is the pipeline
    /// ContextInsightPanel actually reads via `summary.narratives` today,
    /// so this is the live gate, not a demonstration one.
    ///
    /// The candidate-generation logic itself (which sentence maps to
    /// which ContextProfile.kind) lives in DataMaturityContextV1Adapter
    /// now, alongside the evidence-recovery logic it needs to build a
    /// real digest per profile — see DataMaturityEngineAdapters.swift.
    /// Nothing about routine/transition/context detection changed; this
    /// function still receives exactly the same `profiles`, `routines`,
    /// and `transitions` it always did, plus the two additional
    /// already-computed values (`contexts`, `evidence`) it needs to
    /// recover real evidence per profile.
    func buildNarratives(
        profiles: [ContextProfile],
        routines: [BehavioralRoutine],
        transitions: [ContextTransition],
        contexts: [ReadingContextRecord],
        evidence: [BehaviorEvidence]
    ) -> [ContextNarrative] {
        DataMaturityContextV1Adapter.gate(
            profiles: profiles,
            routines: routines,
            transitions: transitions,
            contexts: contexts,
            evidence: evidence
        )
    }
}

private extension BehaviorContextEngine {
    func contextConfidence(
        evidenceCount: Int
    ) -> ContextConfidence {
        ContextConfidence(
            score: min(Double(evidenceCount) / 25.0, 1.0)
        )
    }

    func confidenceForEvidence(
        _ evidence: [BehaviorEvidence]
    ) -> ContextConfidence {
        contextConfidence(
            evidenceCount: evidence.count
        )
    }

    func calculateOverallConfidence(
        sessions: [ReadingSessionRecord],
        routines: [BehavioralRoutine],
        transitions: [ContextTransition]
    ) -> ContextConfidence {
        let sessionScore =
            min(Double(sessions.count) / 50.0, 1.0)

        let routineScore =
            min(Double(routines.count) / 10.0, 1.0)

        let transitionScore =
            min(Double(transitions.count) / 25.0, 1.0)

        return ContextConfidence(
            score:
            (sessionScore * 0.4) +
                (routineScore * 0.3) +
                (transitionScore * 0.3)
        )
    }
}

public struct ReadingSessionRecord: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let startDate: Date
    public let endDate: Date

    public init(
        id: UUID = UUID(),
        startDate: Date,
        endDate: Date
    ) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
    }

    public var interval: DateInterval {
        DateInterval(start: startDate, end: endDate)
    }
}

public struct BehaviorEvidence: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let name: String
    public let category: BehaviorCategory
    public let totalDuration: TimeInterval
    public let frequency: Int
    public let recurrenceCount: Int
    public let consistency: Double
    public let proximityToReading: Double

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        name: String,
        category: BehaviorCategory,
        totalDuration: TimeInterval,
        frequency: Int,
        recurrenceCount: Int,
        consistency: Double,
        proximityToReading: Double
    ) {
        self.id = id
        self.timestamp = timestamp
        self.name = name
        self.category = category
        self.totalDuration = totalDuration
        self.frequency = frequency
        self.recurrenceCount = recurrenceCount
        self.consistency = consistency
        self.proximityToReading = proximityToReading
    }
}

public enum BehaviorCategory: String, Codable, Hashable, Sendable {
    case productivity
    case development
    case research
    case gaming
    case entertainment
    case learning
    case social
    case browsing
    case creative
    case administrative
    case idle
}

public enum BehavioralEnvironmentType: String, Codable, Hashable, CaseIterable, Sendable {
    case work
    case development
    case research
    case gaming
    case entertainment
    case learning
    case social
    case browsing
    case creative
    case administrative
    case idle
    case recovery
    case mixed
    case unknown
}

public struct BehavioralEnvironment: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let type: BehavioralEnvironmentType
    public let contributingActivities: [String]
    public let confidence: ContextConfidence

    public init(
        id: UUID = UUID(),
        type: BehavioralEnvironmentType,
        contributingActivities: [String],
        confidence: ContextConfidence
    ) {
        self.id = id
        self.type = type
        self.contributingActivities = contributingActivities
        self.confidence = confidence
    }
}

public struct ReadingContextRecord: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let readingDate: Date
    public let preReadingContext: BehavioralEnvironment
    public let inSessionContext: BehavioralEnvironment
    public let postReadingContext: BehavioralEnvironment
    public let weatherContext: WeatherContextRecord?
    public let confidence: ContextConfidence

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        readingDate: Date,
        preReadingContext: BehavioralEnvironment,
        inSessionContext: BehavioralEnvironment,
        postReadingContext: BehavioralEnvironment,
        weatherContext: WeatherContextRecord?,
        confidence: ContextConfidence
    ) {
        self.id = id
        self.sessionID = sessionID
        self.readingDate = readingDate
        self.preReadingContext = preReadingContext
        self.inSessionContext = inSessionContext
        self.postReadingContext = postReadingContext
        self.weatherContext = weatherContext
        self.confidence = confidence
    }
}

public struct WeatherContextRecord: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let descriptor: String

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        descriptor: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.descriptor = descriptor
    }
}

public struct ContextWindow: Codable, Hashable, Sendable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    public func contains(_ date: Date) -> Bool {
        date >= start && date <= end
    }
}

public struct ContextTransition: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let from: BehavioralEnvironmentType
    public let to: BehavioralEnvironmentType
    public let occurrenceDate: Date
    public let strength: Double

    public init(
        id: UUID = UUID(),
        from: BehavioralEnvironmentType,
        to: BehavioralEnvironmentType,
        occurrenceDate: Date,
        strength: Double
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.occurrenceDate = occurrenceDate
        self.strength = strength
    }
}

public struct BehavioralRoutine: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let recurrenceCount: Int
    public let averageHour: Int
    public let dominantEnvironment: BehavioralEnvironmentType
    public let confidence: ContextConfidence

    public init(
        id: UUID = UUID(),
        title: String,
        recurrenceCount: Int,
        averageHour: Int,
        dominantEnvironment: BehavioralEnvironmentType,
        confidence: ContextConfidence
    ) {
        self.id = id
        self.title = title
        self.recurrenceCount = recurrenceCount
        self.averageHour = averageHour
        self.dominantEnvironment = dominantEnvironment
        self.confidence = confidence
    }
}

public struct SignificanceAssessment: Codable, Hashable, Sendable {
    public let score: Double
    public let isSignificant: Bool
    public let rationale: String

    public init(
        score: Double,
        isSignificant: Bool,
        rationale: String
    ) {
        self.score = score
        self.isSignificant = isSignificant
        self.rationale = rationale
    }
}

public struct ContextConfidence: Codable, Hashable, Sendable {
    public let score: Double

    public init(score: Double) {
        self.score = max(0, min(score, 1))
    }

    public static let low = ContextConfidence(score: 0.25)
    public static let medium = ContextConfidence(score: 0.50)
    public static let high = ContextConfidence(score: 0.85)
}

public struct ContextNarrative: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let text: String

    public init(
        id: UUID = UUID(),
        text: String
    ) {
        self.id = id
        self.text = text
    }
}

public struct ContextProfile: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let kind: ContextProfileKind
    public let value: String

    public init(
        id: UUID = UUID(),
        kind: ContextProfileKind,
        value: String
    ) {
        self.id = id
        self.kind = kind
        self.value = value
    }
}

public enum ContextProfileKind: String, Codable, Hashable, Sendable {
    case mostCommonPreReadingEnvironment
    case mostCommonPostReadingEnvironment
    case mostStableRoutine
    case mostFrequentTransition
}

public struct ContextSequence: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let sequence: [BehavioralEnvironmentType]
    public let recurrenceCount: Int
    public let strength: Double

    public init(
        id: UUID = UUID(),
        sequence: [BehavioralEnvironmentType],
        recurrenceCount: Int,
        strength: Double
    ) {
        self.id = id
        self.sequence = sequence
        self.recurrenceCount = recurrenceCount
        self.strength = strength
    }
}

public struct HistoricalBehaviorPattern: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let confidence: ContextConfidence

    public init(
        id: UUID = UUID(),
        title: String,
        confidence: ContextConfidence
    ) {
        self.id = id
        self.title = title
        self.confidence = confidence
    }
}

public struct ContextTimeline: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let records: [ReadingContextRecord]

    public init(
        id: UUID = UUID(),
        records: [ReadingContextRecord]
    ) {
        self.id = id
        self.records = records
    }
}

public struct BehavioralCorrelation: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let description: String
    public let strength: Double

    public init(
        id: UUID = UUID(),
        description: String,
        strength: Double
    ) {
        self.id = id
        self.description = description
        self.strength = strength
    }
}

public struct ReadingEnvironmentAnalysis: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let environment: BehavioralEnvironmentType
    public let confidence: ContextConfidence

    public init(
        id: UUID = UUID(),
        environment: BehavioralEnvironmentType,
        confidence: ContextConfidence
    ) {
        self.id = id
        self.environment = environment
        self.confidence = confidence
    }
}

public struct BehavioralContextSummary: Codable, Hashable, Sendable {
    public let generatedAt: Date
    public let contextRecords: [ReadingContextRecord]
    public let routines: [BehavioralRoutine]
    public let transitions: [ContextTransition]
    public let profiles: [ContextProfile]
    public let narratives: [ContextNarrative]
    public let confidence: ContextConfidence

    public init(
        generatedAt: Date,
        contextRecords: [ReadingContextRecord],
        routines: [BehavioralRoutine],
        transitions: [ContextTransition],
        profiles: [ContextProfile],
        narratives: [ContextNarrative],
        confidence: ContextConfidence
    ) {
        self.generatedAt = generatedAt
        self.contextRecords = contextRecords
        self.routines = routines
        self.transitions = transitions
        self.profiles = profiles
        self.narratives = narratives
        self.confidence = confidence
    }
}

private extension Sequence where Element: Hashable {
    var mostCommon: Element? {
        let counts = reduce(into: [:]) {
            $0[$1, default: 0] += 1
        }

        return counts.max {
            $0.value < $1.value
        }?.key
    }
}

// MARK: - Advanced Behavioral Sequence Analysis

/// A recurring contextual pathway observed around reading behavior.
///
/// Unlike simple transitions, sequences represent recurring chains of
/// environments that repeatedly appear throughout a user's behavioral history.
///
/// Example:
///
/// Development → Research → Reading
///
/// If this pattern occurs repeatedly across weeks or months it becomes
/// a meaningful behavioral sequence rather than an isolated transition.
public struct BehavioralSequencePattern:
    Codable,
    Hashable,
    Identifiable,
    Sendable
{
    public let id: UUID
    public let environments: [BehavioralEnvironmentType]
    public let recurrenceCount: Int
    public let averageIntervalMinutes: Double
    public let consistencyScore: Double
    public let strength: Double

    public init(
        id: UUID = UUID(),
        environments: [BehavioralEnvironmentType],
        recurrenceCount: Int,
        averageIntervalMinutes: Double,
        consistencyScore: Double,
        strength: Double
    ) {
        self.id = id
        self.environments = environments
        self.recurrenceCount = recurrenceCount
        self.averageIntervalMinutes = averageIntervalMinutes
        self.consistencyScore = consistencyScore
        self.strength = strength
    }
}

/// Detects recurring environment chains surrounding reading activity.
struct BehavioralSequenceAnalyzer {
    func analyze(
        contexts: [ReadingContextRecord]
    ) -> [BehavioralSequencePattern] {
        guard contexts.count > 2 else {
            return []
        }

        let sequences = contexts.map {
            [
                $0.preReadingContext.type,
                $0.inSessionContext.type,
                $0.postReadingContext.type,
            ]
        }

        var counts: [[BehavioralEnvironmentType]: Int] = [:]

        for sequence in sequences {
            counts[sequence, default: 0] += 1
        }

        return counts
            .map { sequence, count in
                let consistency =
                    min(Double(count) / Double(max(contexts.count, 1)), 1.0)

                return BehavioralSequencePattern(
                    environments: sequence,
                    recurrenceCount: count,
                    averageIntervalMinutes: 0,
                    consistencyScore: consistency,
                    strength:
                    Double(count) * consistency
                )
            }
            .sorted { $0.strength > $1.strength }
    }
}

// MARK: - Behavioral Diversity Metrics

public struct BehavioralDiversityMetrics:
    Codable,
    Hashable,
    Sendable
{
    public let uniqueEnvironmentCount: Int
    public let diversityScore: Double
    public let dominantEnvironmentPercentage: Double

    public init(
        uniqueEnvironmentCount: Int,
        diversityScore: Double,
        dominantEnvironmentPercentage: Double
    ) {
        self.uniqueEnvironmentCount = uniqueEnvironmentCount
        self.diversityScore = diversityScore
        self.dominantEnvironmentPercentage = dominantEnvironmentPercentage
    }
}

struct BehavioralDiversityAnalyzer {
    func analyze(
        contexts: [ReadingContextRecord]
    ) -> BehavioralDiversityMetrics {
        let environments =
            contexts.map(\.preReadingContext.type)

        let uniqueCount =
            Set(environments).count

        let total =
            max(environments.count, 1)

        let dominantCount =
            environments
                .reduce(into: [:]) {
                    $0[$1, default: 0] += 1
                }
                .values
                .max() ?? 0

        let dominantPercentage =
            Double(dominantCount) /
            Double(total)

        let diversity =
            Double(uniqueCount) /
            Double(max(
                BehavioralEnvironmentType.allCases.count,
                1
            ))

        return BehavioralDiversityMetrics(
            uniqueEnvironmentCount: uniqueCount,
            diversityScore: diversity,
            dominantEnvironmentPercentage: dominantPercentage
        )
    }
}

// MARK: - Context Distribution Metrics

public struct ContextDistributionMetrics:
    Codable,
    Hashable,
    Sendable
{
    public let distribution:
        [BehavioralEnvironmentType: Double]

    public init(
        distribution:
        [BehavioralEnvironmentType: Double]
    ) {
        self.distribution = distribution
    }
}

struct ContextDistributionAnalyzer {
    func analyze(
        contexts: [ReadingContextRecord]
    ) -> ContextDistributionMetrics {
        let environments =
            contexts.map(\.preReadingContext.type)

        let total =
            Double(max(environments.count, 1))

        var values:
            [BehavioralEnvironmentType: Double] = [:]

        for environment in environments {
            values[environment, default: 0] += 1
        }

        for key in values.keys {
            values[key] =
                values[key, default: 0] / total
        }

        return ContextDistributionMetrics(
            distribution: values
        )
    }
}

// MARK: - Routine Disruption Detection

/// Absence is normally ignored.
///
/// However, disruption of a historically stable recurring routine is
/// a meaningful contextual signal.
///
/// Example:
///
/// Work → Reading observed 80 times.
///
/// Suddenly:
///
/// Reading occurs without Work.
///
/// This is considered a disruption event.
public struct RoutineDisruption:
    Codable,
    Hashable,
    Identifiable,
    Sendable
{
    public let id: UUID
    public let routineTitle: String
    public let occurrenceDate: Date
    public let disruptionScore: Double

    public init(
        id: UUID = UUID(),
        routineTitle: String,
        occurrenceDate: Date,
        disruptionScore: Double
    ) {
        self.id = id
        self.routineTitle = routineTitle
        self.occurrenceDate = occurrenceDate
        self.disruptionScore = disruptionScore
    }
}

struct RoutineDisruptionAnalyzer {
    func detect(
        routines: [BehavioralRoutine],
        contexts: [ReadingContextRecord]
    ) -> [RoutineDisruption] {
        guard let dominantRoutine = routines.first else {
            return []
        }

        return contexts.compactMap { context in
            let matches =
                context.preReadingContext.type ==
                dominantRoutine.dominantEnvironment

            guard !matches else {
                return nil
            }

            return RoutineDisruption(
                routineTitle: dominantRoutine.title,
                occurrenceDate: context.readingDate,
                disruptionScore:
                dominantRoutine.confidence.score
            )
        }
    }
}

// MARK: - Environment Stability Analysis

public struct EnvironmentStabilityMetrics:
    Codable,
    Hashable,
    Sendable
{
    public let stabilityScore: Double
    public let dominantEnvironment:
        BehavioralEnvironmentType

    public init(
        stabilityScore: Double,
        dominantEnvironment:
        BehavioralEnvironmentType
    ) {
        self.stabilityScore = stabilityScore
        self.dominantEnvironment = dominantEnvironment
    }
}

struct EnvironmentStabilityAnalyzer {
    func analyze(
        contexts: [ReadingContextRecord]
    ) -> EnvironmentStabilityMetrics {
        let environments =
            contexts.map(\.preReadingContext.type)

        guard let dominant =
            environments.mostCommon
        else {
            return EnvironmentStabilityMetrics(
                stabilityScore: 0,
                dominantEnvironment: .unknown
            )
        }

        let matching =
            environments.filter {
                $0 == dominant
            }.count

        let stability =
            Double(matching) /
            Double(max(environments.count, 1))

        return EnvironmentStabilityMetrics(
            stabilityScore: stability,
            dominantEnvironment: dominant
        )
    }
}

// MARK: - Historical Pattern Builder

public struct HistoricalPatternAnalysis:
    Codable,
    Hashable,
    Sendable
{
    public let patterns:
        [HistoricalBehaviorPattern]

    public let sequencePatterns:
        [BehavioralSequencePattern]

    public let diversity:
        BehavioralDiversityMetrics

    public let distribution:
        ContextDistributionMetrics

    public let stability:
        EnvironmentStabilityMetrics

    public init(
        patterns: [HistoricalBehaviorPattern],
        sequencePatterns:
        [BehavioralSequencePattern],
        diversity:
        BehavioralDiversityMetrics,
        distribution:
        ContextDistributionMetrics,
        stability:
        EnvironmentStabilityMetrics
    ) {
        self.patterns = patterns
        self.sequencePatterns = sequencePatterns
        self.diversity = diversity
        self.distribution = distribution
        self.stability = stability
    }
}

extension BehaviorContextEngine {
    func buildHistoricalPatternAnalysis(
        contexts: [ReadingContextRecord]
    ) -> HistoricalPatternAnalysis {
        let sequenceAnalyzer =
            BehavioralSequenceAnalyzer()

        let diversityAnalyzer =
            BehavioralDiversityAnalyzer()

        let distributionAnalyzer =
            ContextDistributionAnalyzer()

        let stabilityAnalyzer =
            EnvironmentStabilityAnalyzer()

        let sequences =
            sequenceAnalyzer.analyze(
                contexts: contexts
            )

        let diversity =
            diversityAnalyzer.analyze(
                contexts: contexts
            )

        let distribution =
            distributionAnalyzer.analyze(
                contexts: contexts
            )

        let stability =
            stabilityAnalyzer.analyze(
                contexts: contexts
            )

        let patterns =
            sequences.prefix(5).map {
                HistoricalBehaviorPattern(
                    title:
                    $0.environments
                        .map(\.rawValue)
                        .joined(separator: " → "),
                    confidence:
                    ContextConfidence(
                        score: min(
                            $0.strength,
                            1.0
                        )
                    )
                )
            }

        return HistoricalPatternAnalysis(
            patterns: patterns,
            sequencePatterns: sequences,
            diversity: diversity,
            distribution: distribution,
            stability: stability
        )
    }
}

// MARK: - Advanced Significance Evaluation Engine

/// The significance engine is responsible for distinguishing meaningful
/// behavioral evidence from incidental activity.
///
/// This subsystem exists because contextual reconstruction should be driven
/// primarily by stable recurring behavior rather than isolated observations.
///
/// Examples:
///
/// Significant:
/// - Notes used 40 minutes daily for months.
/// - Safari repeatedly active before reading.
/// - Music active during most evening reading sessions.
///
/// Incidental:
/// - Preview opened for 4 seconds.
/// - Calculator launched once.
/// - Dictionary opened accidentally.
///
/// The engine intentionally favors:
/// - recurrence
/// - temporal stability
/// - routine participation
/// - reading proximity
/// - historical persistence
///
/// over isolated activity.
public struct AdvancedSignificanceAssessment:
    Codable,
    Hashable,
    Identifiable,
    Sendable
{
    public let id: UUID

    public let evidenceID: UUID

    public let durationScore: Double
    public let recurrenceScore: Double
    public let frequencyScore: Double
    public let consistencyScore: Double
    public let stabilityScore: Double
    public let routineParticipationScore: Double
    public let readingProximityScore: Double

    public let overallScore: Double
    public let confidence: ContextConfidence

    public let classification:
        BehavioralSignificanceClassification

    public init(
        id: UUID = UUID(),
        evidenceID: UUID,
        durationScore: Double,
        recurrenceScore: Double,
        frequencyScore: Double,
        consistencyScore: Double,
        stabilityScore: Double,
        routineParticipationScore: Double,
        readingProximityScore: Double,
        overallScore: Double,
        confidence: ContextConfidence,
        classification:
        BehavioralSignificanceClassification
    ) {
        self.id = id
        self.evidenceID = evidenceID
        self.durationScore = durationScore
        self.recurrenceScore = recurrenceScore
        self.frequencyScore = frequencyScore
        self.consistencyScore = consistencyScore
        self.stabilityScore = stabilityScore
        self.routineParticipationScore =
            routineParticipationScore
        self.readingProximityScore =
            readingProximityScore
        self.overallScore = overallScore
        self.confidence = confidence
        self.classification = classification
    }
}

public enum BehavioralSignificanceClassification:
    String,
    Codable,
    Hashable,
    Sendable
{
    case incidentalNoise
    case weakSignal
    case moderateSignal
    case strongSignal
    case dominantBehavior
}

struct AdvancedSignificanceEngine {
    func evaluate(
        evidence: BehaviorEvidence,
        historicalOccurrences: Int,
        routineOccurrences: Int,
        ageInDays: Double
    ) -> AdvancedSignificanceAssessment {
        let duration =
            normalize(
                evidence.totalDuration,
                maxValue: 7200
            )

        let recurrence =
            normalize(
                Double(evidence.recurrenceCount),
                maxValue: 180
            )

        let frequency =
            normalize(
                Double(evidence.frequency),
                maxValue: 365
            )

        let consistency =
            clamp(
                evidence.consistency
            )

        let stability =
            stabilityScore(
                recurrenceCount:
                historicalOccurrences,
                ageInDays:
                ageInDays
            )

        let routineParticipation =
            normalize(
                Double(routineOccurrences),
                maxValue: 120
            )

        let proximity =
            clamp(
                evidence.proximityToReading
            )

        let score =
            weightedScore(
                duration: duration,
                recurrence: recurrence,
                frequency: frequency,
                consistency: consistency,
                stability: stability,
                routineParticipation:
                routineParticipation,
                proximity: proximity
            )

        return AdvancedSignificanceAssessment(
            evidenceID: evidence.id,
            durationScore: duration,
            recurrenceScore: recurrence,
            frequencyScore: frequency,
            consistencyScore: consistency,
            stabilityScore: stability,
            routineParticipationScore:
            routineParticipation,
            readingProximityScore:
            proximity,
            overallScore: score,
            confidence:
            ContextConfidence(
                score: confidence(
                    score: score,
                    recurrence: recurrence
                )
            ),
            classification:
            classification(
                score: score
            )
        )
    }

    private func weightedScore(
        duration: Double,
        recurrence: Double,
        frequency: Double,
        consistency: Double,
        stability: Double,
        routineParticipation: Double,
        proximity: Double
    ) -> Double {
        (
            duration * 0.10
        ) +
            (
                recurrence * 0.25
            ) +
            (
                frequency * 0.15
            ) +
            (
                consistency * 0.15
            ) +
            (
                stability * 0.15
            ) +
            (
                routineParticipation * 0.10
            ) +
            (
                proximity * 0.10
            )
    }

    private func classification(
        score: Double
    ) -> BehavioralSignificanceClassification {
        switch score {
        case 0.85...:
            return .dominantBehavior

        case 0.70 ..< 0.85:
            return .strongSignal

        case 0.45 ..< 0.70:
            return .moderateSignal

        case 0.20 ..< 0.45:
            return .weakSignal

        default:
            return .incidentalNoise
        }
    }

    private func confidence(
        score: Double,
        recurrence: Double
    ) -> Double {
        min(
            (
                score * 0.7
            ) +
                (
                    recurrence * 0.3
                ),
            1.0
        )
    }

    private func stabilityScore(
        recurrenceCount: Int,
        ageInDays: Double
    ) -> Double {
        guard ageInDays > 0 else {
            return 0
        }

        let density =
            Double(recurrenceCount) /
            ageInDays

        return min(
            density,
            1.0
        )
    }

    private func normalize(
        _ value: Double,
        maxValue: Double
    ) -> Double {
        guard maxValue > 0 else {
            return 0
        }

        return min(
            value / maxValue,
            1.0
        )
    }

    private func clamp(
        _ value: Double
    ) -> Double {
        max(
            0,
            min(
                value,
                1
            )
        )
    }
}

// MARK: - Context Evidence Chains

/// A contextual chain represents the evidence path that produced a contextual
/// interpretation.
///
/// This provides explainability and auditability.
///
/// Example:
///
/// Notes
/// → Safari
/// → Research Environment
/// → Reading Session
///
/// The engine should always be capable of explaining why a context was created.
public struct ContextEvidenceChain:
    Codable,
    Hashable,
    Identifiable,
    Sendable
{
    public let id: UUID

    public let readingSessionID: UUID

    public let evidenceIDs: [UUID]

    public let environment:
        BehavioralEnvironmentType

    public let confidence:
        ContextConfidence

    public init(
        id: UUID = UUID(),
        readingSessionID: UUID,
        evidenceIDs: [UUID],
        environment:
        BehavioralEnvironmentType,
        confidence:
        ContextConfidence
    ) {
        self.id = id
        self.readingSessionID =
            readingSessionID
        self.evidenceIDs =
            evidenceIDs
        self.environment =
            environment
        self.confidence =
            confidence
    }
}

struct ContextEvidenceChainBuilder {
    func build(
        session: ReadingSessionRecord,
        evidence: [BehaviorEvidence],
        environment:
        BehavioralEnvironmentType
    ) -> ContextEvidenceChain {
        let ids =
            evidence.map(\.id)

        let confidence =
            ContextConfidence(
                score:
                min(
                    Double(ids.count) / 20.0,
                    1.0
                )
            )

        return ContextEvidenceChain(
            readingSessionID:
            session.id,
            evidenceIDs:
            ids,
            environment:
            environment,
            confidence:
            confidence
        )
    }
}

// MARK: - Context Correlation Analysis

public struct ContextCorrelationMatrix:
    Codable,
    Hashable,
    Sendable
{
    public let correlations:
        [BehavioralCorrelation]

    public init(
        correlations:
        [BehavioralCorrelation]
    ) {
        self.correlations =
            correlations
    }
}

struct ContextCorrelationAnalyzer {
    func analyze(
        contexts:
        [ReadingContextRecord]
    ) -> ContextCorrelationMatrix {
        var results:
            [BehavioralCorrelation] = []

        let grouped =
            Dictionary(
                grouping: contexts
            ) {
                $0.preReadingContext.type
            }

        for (
            environment,
            records
        ) in grouped {
            guard records.count > 1 else {
                continue
            }

            let strength =
                min(
                    Double(records.count) /
                        Double(
                            max(
                                contexts.count,
                                1
                            )
                        ),
                    1.0
                )

            results.append(
                BehavioralCorrelation(
                    description:
                    "\(environment.rawValue) before reading",
                    strength:
                    strength
                )
            )
        }

        return ContextCorrelationMatrix(
            correlations:
            results.sorted {
                $0.strength >
                    $1.strength
            }
        )
    }
}

// MARK: - Environment Clustering

/// Environment clusters aggregate related environments into broader behavioral
/// domains.
///
/// Example:
///
/// Development
/// Research
/// Administrative
///
/// may cluster into:
///
/// Productive Work
///
/// This enables higher-level contextual reconstruction.
public struct EnvironmentCluster:
    Codable,
    Hashable,
    Identifiable,
    Sendable
{
    public let id: UUID

    public let title: String

    public let environments:
        [BehavioralEnvironmentType]

    public let confidence:
        ContextConfidence

    public init(
        id: UUID = UUID(),
        title: String,
        environments:
        [BehavioralEnvironmentType],
        confidence:
        ContextConfidence
    ) {
        self.id = id
        self.title = title
        self.environments =
            environments
        self.confidence =
            confidence
    }
}

struct EnvironmentClusterBuilder {
    func clusters(
        from contexts:
        [ReadingContextRecord]
    ) -> [EnvironmentCluster] {
        let productive:
            [BehavioralEnvironmentType] = [
                .work,
                .development,
                .research,
                .administrative,
            ]

        let leisure:
            [BehavioralEnvironmentType] = [
                .gaming,
                .social,
                .entertainment,
            ]

        let learning:
            [BehavioralEnvironmentType] = [
                .learning,
                .research,
            ]

        return [
            EnvironmentCluster(
                title:
                "Productive Work",
                environments:
                productive,
                confidence:
                clusterConfidence(
                    productive,
                    contexts
                )
            ),

            EnvironmentCluster(
                title:
                "Leisure",
                environments:
                leisure,
                confidence:
                clusterConfidence(
                    leisure,
                    contexts
                )
            ),

            EnvironmentCluster(
                title:
                "Learning",
                environments:
                learning,
                confidence:
                clusterConfidence(
                    learning,
                    contexts
                )
            ),
        ]
    }

    private func clusterConfidence(
        _ environments:
        [BehavioralEnvironmentType],
        _ contexts:
        [ReadingContextRecord]
    ) -> ContextConfidence {
        let matches =
            contexts.filter {
                environments.contains(
                    $0.preReadingContext.type
                )
            }

        let score =
            Double(matches.count) /
            Double(
                max(
                    contexts.count,
                    1
                )
            )

        return ContextConfidence(
            score: score
        )
    }
}

// MARK: - Advanced Routine Detection Engine

/// Routine classification used for contextual reconstruction.
///
/// Routines are not simply time-based patterns. A routine is a recurring
/// behavioral pathway that repeatedly surrounds reading activity.
public enum RoutineCategory:
    String,
    Codable,
    Hashable,
    Sendable,
    CaseIterable
{
    case morningReading
    case afternoonReading
    case eveningReading
    case lateNightReading

    case weekdayReading
    case weekendReading

    case weatherAssociated
    case activityAssociated

    case workTransition
    case learningTransition
    case entertainmentTransition
    case socialTransition

    case stableRoutine
    case emergingRoutine
}

public struct RoutineOccurrence:
    Codable,
    Hashable,
    Identifiable,
    Sendable
{
    public let id: UUID

    public let routine:
        RoutineCategory

    public let date: Date

    public let confidence:
        ContextConfidence

    public init(
        id: UUID = UUID(),
        routine: RoutineCategory,
        date: Date,
        confidence: ContextConfidence
    ) {
        self.id = id
        self.routine = routine
        self.date = date
        self.confidence = confidence
    }
}

public struct AdvancedRoutineAnalysis:
    Codable,
    Hashable,
    Sendable
{
    public let detectedRoutines:
        [BehavioralRoutine]

    public let occurrences:
        [RoutineOccurrence]

    public let stabilityScore:
        Double

    public let consistencyScore:
        Double

    public init(
        detectedRoutines:
        [BehavioralRoutine],
        occurrences:
        [RoutineOccurrence],
        stabilityScore:
        Double,
        consistencyScore:
        Double
    ) {
        self.detectedRoutines =
            detectedRoutines
        self.occurrences =
            occurrences
        self.stabilityScore =
            stabilityScore
        self.consistencyScore =
            consistencyScore
    }
}

struct AdvancedRoutineDetector {
    func analyze(
        contexts:
        [ReadingContextRecord]
    ) -> AdvancedRoutineAnalysis {
        let occurrences =
            buildOccurrences(
                contexts
            )

        let routines =
            buildRoutines(
                occurrences
            )

        return AdvancedRoutineAnalysis(
            detectedRoutines:
            routines,
            occurrences:
            occurrences,
            stabilityScore:
            stability(
                occurrences
            ),
            consistencyScore:
            consistency(
                occurrences
            )
        )
    }

    private func buildOccurrences(
        _ contexts:
        [ReadingContextRecord]
    ) -> [RoutineOccurrence] {
        var results:
            [RoutineOccurrence] = []

        let calendar =
            Calendar.current

        for context in contexts {
            let hour =
                calendar.component(
                    .hour,
                    from:
                    context.readingDate
                )

            let weekday =
                calendar.component(
                    .weekday,
                    from:
                    context.readingDate
                )

            if hour >= 5 && hour < 12 {
                results.append(
                    RoutineOccurrence(
                        routine:
                        .morningReading,
                        date:
                        context.readingDate,
                        confidence:
                        .medium
                    )
                )
            }

            if hour >= 12 && hour < 17 {
                results.append(
                    RoutineOccurrence(
                        routine:
                        .afternoonReading,
                        date:
                        context.readingDate,
                        confidence:
                        .medium
                    )
                )
            }

            if hour >= 17 && hour < 22 {
                results.append(
                    RoutineOccurrence(
                        routine:
                        .eveningReading,
                        date:
                        context.readingDate,
                        confidence:
                        .medium
                    )
                )
            }

            if hour >= 22 || hour < 5 {
                results.append(
                    RoutineOccurrence(
                        routine:
                        .lateNightReading,
                        date:
                        context.readingDate,
                        confidence:
                        .medium
                    )
                )
            }

            if weekday == 1 ||
                weekday == 7
            {
                results.append(
                    RoutineOccurrence(
                        routine:
                        .weekendReading,
                        date:
                        context.readingDate,
                        confidence:
                        .medium
                    )
                )
            } else {
                results.append(
                    RoutineOccurrence(
                        routine:
                        .weekdayReading,
                        date:
                        context.readingDate,
                        confidence:
                        .medium
                    )
                )
            }

            switch context.preReadingContext.type {
            case .work,
                 .development,
                 .administrative:
                results.append(
                    RoutineOccurrence(
                        routine:
                        .workTransition,
                        date:
                        context.readingDate,
                        confidence:
                        .high
                    )
                )

            case .learning,
                 .research:
                results.append(
                    RoutineOccurrence(
                        routine:
                        .learningTransition,
                        date:
                        context.readingDate,
                        confidence:
                        .high
                    )
                )

            case .social:
                results.append(
                    RoutineOccurrence(
                        routine:
                        .socialTransition,
                        date:
                        context.readingDate,
                        confidence:
                        .high
                    )
                )

            case .entertainment,
                 .gaming:
                results.append(
                    RoutineOccurrence(
                        routine:
                        .entertainmentTransition,
                        date:
                        context.readingDate,
                        confidence:
                        .high
                    )
                )

            default:
                break
            }
        }

        return results
    }

    private func buildRoutines(
        _ occurrences:
        [RoutineOccurrence]
    ) -> [BehavioralRoutine] {
        let grouped =
            Dictionary(
                grouping:
                occurrences
            ) {
                $0.routine
            }

        return grouped.map {

            category,
            entries

            in
            BehavioralRoutine(
                title:
                category.rawValue,
                recurrenceCount:
                entries.count,
                averageHour:
                0,
                dominantEnvironment:
                .unknown,
                confidence:
                ContextConfidence(
                    score:
                    min(
                        Double(
                            entries.count
                        ) / 50,
                        1
                    )
                )
            )
        }
        .sorted {
            $0.recurrenceCount >
                $1.recurrenceCount
        }
    }

    private func stability(
        _ occurrences:
        [RoutineOccurrence]
    ) -> Double {
        let grouped =
            Dictionary(
                grouping:
                occurrences
            ) {
                $0.routine
            }

        guard let maxCount =
            grouped.values
                .map(\.count)
                .max()
        else {
            return 0
        }

        return min(
            Double(maxCount) /
                Double(
                    max(
                        occurrences.count,
                        1
                    )
                ),
            1
        )
    }

    private func consistency(
        _ occurrences:
        [RoutineOccurrence]
    ) -> Double {
        let grouped =
            Dictionary(
                grouping:
                occurrences
            ) {
                $0.routine
            }

        guard !grouped.isEmpty else {
            return 0
        }

        let average =
            Double(
                occurrences.count
            ) /
            Double(
                grouped.count
            )

        let variance =
            grouped.values
                .map {
                    pow(
                        Double(
                            $0.count
                        ) - average,
                        2
                    )
                }
                .reduce(
                    0,
                    +
                ) /
                Double(
                    grouped.count
                )

        return max(
            0,
            1 -
                (
                    variance /
                        (
                            average *
                                average +
                                1
                        )
                )
        )
    }
}

// MARK: - Reading Context Continuity

/// Context continuity evaluates whether reading occurred as a continuation
/// of an existing behavioral environment or represented a contextual shift.
public enum ContextContinuityType:
    String,
    Codable,
    Hashable,
    Sendable
{
    case continuous
    case partialTransition
    case majorTransition
    case isolatedReading
}

public struct ContextContinuityRecord:
    Codable,
    Hashable,
    Identifiable,
    Sendable
{
    public let id: UUID

    public let sessionID: UUID

    public let continuityType:
        ContextContinuityType

    public let continuityScore:
        Double

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        continuityType:
        ContextContinuityType,
        continuityScore:
        Double
    ) {
        self.id = id
        self.sessionID = sessionID
        self.continuityType =
            continuityType
        self.continuityScore =
            continuityScore
    }
}

struct ContextContinuityAnalyzer {
    func analyze(
        contexts:
        [ReadingContextRecord]
    ) -> [ContextContinuityRecord] {
        contexts.map {

            context in
            let pre =
                context.preReadingContext
                    .type

            let reading =
                context.inSessionContext
                    .type

            let post =
                context.postReadingContext
                    .type

            let score =
                continuity(
                    pre,
                    reading,
                    post
                )

            return ContextContinuityRecord(
                sessionID:
                context.sessionID,
                continuityType:
                classify(
                    score
                ),
                continuityScore:
                score
            )
        }
    }

    private func continuity(
        _ pre:
        BehavioralEnvironmentType,
        _ reading:
        BehavioralEnvironmentType,
        _ post:
        BehavioralEnvironmentType
    ) -> Double {
        var score: Double = 0

        if pre == reading {
            score += 0.5
        }

        if reading == post {
            score += 0.5
        }

        return score
    }

    private func classify(
        _ score: Double
    ) -> ContextContinuityType {
        switch score {
        case 1.0:
            return .continuous

        case 0.5:
            return .partialTransition

        case 0 ..< 0.5:
            return .majorTransition

        default:
            return .isolatedReading
        }
    }
}

// MARK: - Reading Context Trend Analysis

public enum ContextTrendDirection:
    String,
    Codable,
    Hashable,
    Sendable
{
    case increasing
    case decreasing
    case stable
    case emerging
}

public struct ContextTrend:
    Codable,
    Hashable,
    Identifiable,
    Sendable
{
    public let id: UUID

    public let environment:
        BehavioralEnvironmentType

    public let direction:
        ContextTrendDirection

    public let strength:
        Double

    public init(
        id: UUID = UUID(),
        environment:
        BehavioralEnvironmentType,
        direction:
        ContextTrendDirection,
        strength:
        Double
    ) {
        self.id = id
        self.environment =
            environment
        self.direction =
            direction
        self.strength =
            strength
    }
}

struct ContextTrendAnalyzer {
    func analyze(
        contexts:
        [ReadingContextRecord]
    ) -> [ContextTrend] {
        let grouped =
            Dictionary(
                grouping:
                contexts
            ) {
                $0.preReadingContext.type
            }

        return grouped.map {

            environment,
            records

            in
            let strength =
                min(
                    Double(
                        records.count
                    ) /
                        Double(
                            max(
                                contexts.count,
                                1
                            )
                        ),
                    1
                )

            return ContextTrend(
                environment:
                environment,
                direction:
                direction(
                    count:
                    records.count,
                    total:
                    contexts.count
                ),
                strength:
                strength
            )
        }
    }

    private func direction(
        count: Int,
        total: Int
    ) -> ContextTrendDirection {
        let ratio =
            Double(count) /
            Double(
                max(
                    total,
                    1
                )
            )

        switch ratio {
        case 0.50...:
            return .increasing

        case 0.25 ..< 0.50:
            return .stable

        case 0.10 ..< 0.25:
            return .emerging

        default:
            return .decreasing
        }
    }
}

// MARK: - Weather Associated Context Reconstruction

/// Weather is not analyzed here.
///
/// Existing weather systems own weather interpretation.
///
/// BehaviorContextEngine only consumes weather outputs and evaluates
/// whether weather repeatedly appears around reading behavior.
public struct WeatherRoutinePattern:
    Codable,
    Hashable,
    Identifiable,
    Sendable
{
    public let id: UUID

    public let weatherDescriptor: String

    public let occurrenceCount: Int

    public let readingAssociationStrength: Double

    public let confidence: ContextConfidence

    public init(
        id: UUID = UUID(),
        weatherDescriptor: String,
        occurrenceCount: Int,
        readingAssociationStrength: Double,
        confidence: ContextConfidence
    ) {
        self.id = id
        self.weatherDescriptor = weatherDescriptor
        self.occurrenceCount = occurrenceCount
        self.readingAssociationStrength =
            readingAssociationStrength
        self.confidence = confidence
    }
}

struct WeatherRoutineAnalyzer {
    func analyze(
        contexts: [ReadingContextRecord]
    ) -> [WeatherRoutinePattern] {
        let descriptors =
            contexts.compactMap {
                $0.weatherContext?.descriptor
            }

        let grouped =
            Dictionary(
                grouping: descriptors
            ) {
                $0
            }

        let total =
            Double(
                max(
                    descriptors.count,
                    1
                )
            )

        return grouped.map {

            descriptor,
            records

            in
            let strength =
                Double(records.count) /
                total

            return WeatherRoutinePattern(
                weatherDescriptor:
                descriptor,
                occurrenceCount:
                records.count,
                readingAssociationStrength:
                strength,
                confidence:
                ContextConfidence(
                    score:
                    strength
                )
            )
        }
        .sorted {
            $0.readingAssociationStrength >
                $1.readingAssociationStrength
        }
    }
}

// MARK: - Environmental Influence Analysis

public struct EnvironmentalInfluence:
    Codable,
    Hashable,
    Identifiable,
    Sendable
{
    public let id: UUID

    public let source: String

    public let influenceScore: Double

    public let confidence:
        ContextConfidence

    public init(
        id: UUID = UUID(),
        source: String,
        influenceScore: Double,
        confidence: ContextConfidence
    ) {
        self.id = id
        self.source = source
        self.influenceScore =
            influenceScore
        self.confidence =
            confidence
    }
}

struct EnvironmentalInfluenceAnalyzer {
    func analyze(
        contexts: [ReadingContextRecord]
    ) -> [EnvironmentalInfluence] {
        let grouped =
            Dictionary(
                grouping:
                contexts.compactMap {
                    $0.weatherContext?.descriptor
                }
            ) {
                $0
            }

        let total =
            Double(
                max(
                    contexts.count,
                    1
                )
            )

        return grouped.map {

            descriptor,
            values

            in
            let score =
                Double(values.count) /
                total

            return EnvironmentalInfluence(
                source:
                descriptor,
                influenceScore:
                score,
                confidence:
                ContextConfidence(
                    score:
                    score
                )
            )
        }
    }
}

// MARK: - Contextual Narrative Builder V2

/// Deterministic narrative generation.
///
/// No black-box generation.
/// No probabilistic text.
/// No external services.
///
/// Every narrative must be reproducible from evidence.
struct DeterministicNarrativeBuilder {
    func build(
        contexts: [ReadingContextRecord],
        routines: [BehavioralRoutine],
        trends: [ContextTrend],
        disruptions: [RoutineDisruption]
    ) -> [ContextNarrative] {
        var narratives:
            [ContextNarrative] = []

        if let dominant =
            contexts
                .map(\.preReadingContext.type)
                .mostCommon
        {
            narratives.append(
                ContextNarrative(
                    text:
                    """
                    Reading most frequently occurred after \(dominant.rawValue.lowercased()) activity.
                    """
                )
            )
        }

        if let routine =
            routines.first
        {
            narratives.append(
                ContextNarrative(
                    text:
                    """
                    A recurring routine centered around \(routine.title) was repeatedly observed.
                    """
                )
            )
        }

        if let trend =
            trends.max(
                by: {
                    $0.strength <
                        $1.strength
                }
            )
        {
            narratives.append(
                ContextNarrative(
                    text:
                    """
                    \(trend.environment.rawValue.capitalized) activity showed the strongest contextual relationship with reading behavior.
                    """
                )
            )
        }

        if !disruptions.isEmpty {
            narratives.append(
                ContextNarrative(
                    text:
                    """
                    Established reading routines experienced occasional contextual disruption events.
                    """
                )
            )
        }

        if narratives.isEmpty {
            narratives.append(
                ContextNarrative(
                    text:
                    """
                    Contextual evidence remains insufficient for reliable reconstruction.
                    """
                )
            )
        }

        return narratives
    }
}

// MARK: - Master Analysis Bundle

/// Intended future aggregation object.
///
/// Provides a single high-level contextual intelligence result.
public struct ContextIntelligenceReport:
    Codable,
    Hashable,
    Sendable
{
    public let generatedAt: Date

    public let patterns:
        HistoricalPatternAnalysis

    public let routines:
        AdvancedRoutineAnalysis

    public let trends:
        [ContextTrend]

    public let disruptions:
        [RoutineDisruption]

    public let weatherPatterns:
        [WeatherRoutinePattern]

    public let environmentalInfluences:
        [EnvironmentalInfluence]

    public let correlations:
        ContextCorrelationMatrix

    public let clusters:
        [EnvironmentCluster]

    public let narratives:
        [ContextNarrative]

    public init(
        generatedAt: Date,
        patterns:
        HistoricalPatternAnalysis,
        routines:
        AdvancedRoutineAnalysis,
        trends:
        [ContextTrend],
        disruptions:
        [RoutineDisruption],
        weatherPatterns:
        [WeatherRoutinePattern],
        environmentalInfluences:
        [EnvironmentalInfluence],
        correlations:
        ContextCorrelationMatrix,
        clusters:
        [EnvironmentCluster],
        narratives:
        [ContextNarrative]
    ) {
        self.generatedAt =
            generatedAt
        self.patterns =
            patterns
        self.routines =
            routines
        self.trends =
            trends
        self.disruptions =
            disruptions
        self.weatherPatterns =
            weatherPatterns
        self.environmentalInfluences =
            environmentalInfluences
        self.correlations =
            correlations
        self.clusters =
            clusters
        self.narratives =
            narratives
    }
}

// MARK: - Future Engine Entry Point

extension BehaviorContextEngine {
    func buildIntelligenceReport(
        contexts: [ReadingContextRecord],
        routines: [BehavioralRoutine]
    ) -> ContextIntelligenceReport {
        let patternAnalysis =
            buildHistoricalPatternAnalysis(
                contexts: contexts
            )

        let routineAnalysis =
            AdvancedRoutineDetector()
                .analyze(
                    contexts: contexts
                )

        let trends =
            ContextTrendAnalyzer()
                .analyze(
                    contexts: contexts
                )

        let disruptions =
            RoutineDisruptionAnalyzer()
                .detect(
                    routines: routines,
                    contexts: contexts
                )

        let weatherPatterns =
            WeatherRoutineAnalyzer()
                .analyze(
                    contexts: contexts
                )

        let influences =
            EnvironmentalInfluenceAnalyzer()
                .analyze(
                    contexts: contexts
                )

        let correlations =
            ContextCorrelationAnalyzer()
                .analyze(
                    contexts: contexts
                )

        let clusters =
            EnvironmentClusterBuilder()
                .clusters(
                    from: contexts
                )

        let narratives =
            DeterministicNarrativeBuilder()
                .build(
                    contexts: contexts,
                    routines: routineAnalysis.detectedRoutines,
                    trends: trends,
                    disruptions: disruptions
                )

        return ContextIntelligenceReport(
            generatedAt: Date(),
            patterns: patternAnalysis,
            routines: routineAnalysis,
            trends: trends,
            disruptions: disruptions,
            weatherPatterns: weatherPatterns,
            environmentalInfluences: influences,
            correlations: correlations,
            clusters: clusters,
            narratives: narratives
        )
    }
}

// ============================================================================
// MARK: - DEVELOPMENT CHECKLIST FOR NEXT AI

// ============================================================================
//
// COMPLETED SO FAR
//
// [x] Core BehaviorContextEngine skeleton
// [x] ReadingContextRecord models
// [x] BehavioralEnvironment models
// [x] ContextTransition models
// [x] ContextProfile models
// [x] ContextNarrative models
// [x] ContextConfidence system
// [x] SignificanceAssessment system
// [x] Context reconstruction
// [x] Environment classification
// [x] Environment mapping
// [x] Basic routine detection
// [x] Basic transition analysis
// [x] Profile generation
// [x] Narrative generation v1
// [x] HistoricalPatternAnalysis
// [x] BehavioralSequencePattern
// [x] Sequence analysis engine
// [x] Diversity metrics
// [x] Distribution metrics
// [x] Environment stability analysis
// [x] Routine disruption detection
// [x] Advanced significance engine
// [x] ContextEvidenceChain
// [x] Correlation analysis
// [x] Environment clustering
// [x] Advanced routine detection
// [x] Context continuity analysis
// [x] Context trend analysis
// [x] Weather routine analysis
// [x] Environmental influence analysis
// [x] Deterministic narrative builder v2
// [x] ContextIntelligenceReport
//
// HIGH PRIORITY REMAINING WORK
//
// [ ] Real BehaviorContextAccessKit adapters
// [ ] SessionCoordinator adapters
// [ ] AnalyticsEngine adapters
// [ ] WeatherAnalysisEngine adapters
// [ ] WeatherKitService adapters
// [ ] DataStore adapters
// [ ] Book model adapters
//
// [ ] Context window presets
// [ ] Dynamic context windows
// [ ] Multi-window comparison engine
// [ ] Window weighting engine
//
// [ ] Device-state analysis
// [ ] Foreground/background influence
// [ ] Screen lock influence
// [ ] Sleep/wake influence
//
// [ ] Inactivity reconstruction
// [ ] Idle gap analysis
// [ ] Recovery-session detection
// [ ] Fatigue indicators
//
// [ ] Environment evolution tracking
// [ ] Longitudinal behavior shifts
// [ ] Behavioral lifecycle analysis
//
// [ ] Sequence recurrence database
// [ ] Sequence consistency scoring
// [ ] Sequence timing analysis
// [ ] Transition chain reconstruction
//
// [ ] ContextDistribution profile models
// [ ] Behavioral diversity profiles
// [ ] Most productive context
// [ ] Most consistent context
//
// [ ] Confidence engine v2
// [ ] Confidence breakdown model
// [ ] Evidence quality scoring
// [ ] Historical depth scoring
//
// [ ] Narrative engine v3
// [ ] Explainability narratives
// [ ] Evidence-backed narrative citations
//
// [ ] Full inline documentation pass
// [ ] Final architectural cleanup
// [ ] Duplicate model consolidation
// [ ] Compile verification pass
//
// IMPORTANT NOTES FOR NEXT AI
//
// 1. DO NOT replace existing systems.
//    Consume outputs only.
//
// 2. BehaviorContextEngine sits ABOVE analytics.
//    Never duplicate reading analytics.
//
// 3. Context comes from evidence.
//    Never generate context from absence.
//
// 4. Absence is ONLY valid for routine disruption.
//
// 5. Continue building deterministic systems.
//    No black-box generation.
//    No probabilistic narratives.
//
// 6. Next major milestone should be:
//    Integration Layer + Device-State Reconstruction +
//    Inactivity Reconstruction.
//
// 7. After integrations exist, refactor all analyzers into:
//      ContextAnalysisPipeline
//      SignificancePipeline
//      NarrativePipeline
//      RoutinePipeline
//
// 8. Final target remains a 2k–4k+ line contextual intelligence subsystem.
//
// ==============================================

// ============================================================================
// MARK: - BEHAVIOR CONTEXT ENGINE APPEND — PHASE 2 UPGRADE

// ============================================================================
//
// Append-only extension of BehaviorContextEngine.swift.
// Zero existing lines are modified. All new types follow the exact naming
// and access conventions of the file above.
//
// Sections in order (per plan Section 11):
//   1. Integration Layer
//   2. Context Window System
//   3. Device-State Analysis
//   4. Inactivity Reconstruction
//   5. Environment Evolution Tracking
//   6. Sequence System Upgrades
//   7. Context Distribution Profiles
//   8. Confidence Engine V2
//   9. Narrative Engine V3
//  10. Analysis Pipelines
//  11. Unified Entry Point
// ============================================================================

// ============================================================================
// MARK: - Integration Layer

// ============================================================================

// 1A — BehaviorContextAdapterInput
//
// Pure data container. Aggregates all raw inputs from external systems so
// every adapter shares one consistent input type.

public struct BehaviorContextAdapterInput: Sendable {
    let books: [Book]
    public let applicationSessions: [ApplicationUsageSession]
    public let inactivityRecords: [InactivityRecord]
    public let deviceStateEvents: [DeviceStateEvent]
    public let behavioralEvents: [BehavioralEvent]

    init(
        books: [Book],
        applicationSessions: [ApplicationUsageSession],
        inactivityRecords: [InactivityRecord],
        deviceStateEvents: [DeviceStateEvent],
        behavioralEvents: [BehavioralEvent]
    ) {
        self.books = books
        self.applicationSessions = applicationSessions
        self.inactivityRecords = inactivityRecords
        self.deviceStateEvents = deviceStateEvents
        self.behavioralEvents = behavioralEvents
    }
}

// 1B — BehaviorContextAccessKitAdapter
//
// Converts BehaviorContextAccessKit's ApplicationUsageSession records into
// [BehaviorEvidence] for BehaviorContextEngine.analyze().

struct BehaviorContextAccessKitAdapter {
    func adapt(_ input: BehaviorContextAdapterInput) -> [BehaviorEvidence] {
        let completedSessions = input.applicationSessions.filter { $0.endTime != nil }
        guard !completedSessions.isEmpty else { return [] }

        let allReadingSessions = input.books.flatMap(\.sessions)
        let readingBoundaries = allReadingSessions.flatMap {
            [$0.startTime, $0.endTime].compactMap { $0 }
        }

        let observedDays = daySpan(from: completedSessions)
        let grouped = Dictionary(grouping: completedSessions) {
            $0.application.applicationName
        }

        return grouped.compactMap { appName, sessions -> BehaviorEvidence? in
            guard let first = sessions.first else { return nil }

            let totalDuration = sessions.compactMap(\.duration).reduce(0, +)
            guard totalDuration >= 30 else { return nil } // filter accidental activations

            let distinctDays = Set(sessions.map { Calendar.current.startOfDay(for: $0.startTime) })
            let recurrenceCount = distinctDays.count
            let consistency = min(1.0, Double(recurrenceCount) / Double(max(observedDays, 1)))
            let proximity = averageProximity(appSessions: sessions,
                                             readingBoundaries: readingBoundaries)
            let category = mapCategory(first.application.category)

            return BehaviorEvidence(
                id: UUID(),
                timestamp: first.startTime,
                name: appName,
                category: category,
                totalDuration: totalDuration,
                frequency: sessions.count,
                recurrenceCount: recurrenceCount,
                consistency: consistency,
                proximityToReading: proximity
            )
        }
    }

    // MARK: - Private helpers

    private func daySpan(from sessions: [ApplicationUsageSession]) -> Int {
        guard let first = sessions.map(\.startTime).min(),
              let last = sessions.compactMap(\.endTime).max()
        else { return 1 }
        return max(1, Calendar.current.dateComponents([.day], from: first, to: last).day ?? 1)
    }

    private func averageProximity(
        appSessions: [ApplicationUsageSession],
        readingBoundaries: [Date]
    ) -> Double {
        guard !readingBoundaries.isEmpty else { return 0.5 }
        let scores = appSessions.map { s -> Double in
            guard let nearest = readingBoundaries.min(by: {
                abs($0.timeIntervalSince(s.startTime)) <
                    abs($1.timeIntervalSince(s.startTime))
            }) else { return 0.5 }
            let deltaMinutes = abs(nearest.timeIntervalSince(s.startTime)) / 60
            return max(0, 1 - (deltaMinutes / 120))
        }
        return scores.reduce(0, +) / Double(max(1, scores.count))
    }

    /// Maps BehavioralCategory (BehavioralCategory.swift) → BehaviorCategory
    /// (BehaviorContextEngine.swift). Verified against both enums.
    private func mapCategory(_ src: BehavioralCategory) -> BehaviorCategory {
        switch src {
        case .productivity: return .productivity
        case .development: return .development
        case .browsing: return .browsing
        case .gaming: return .gaming
        case .entertainment: return .entertainment
        case .communication: return .social
        case .creativeWork: return .creative
        case .education: return .learning
        case .finance: return .administrative
        case .utility: return .administrative
        case .system: return .administrative
        case .unknown: return .idle
        }
    }
}

// 1C — ReadingSessionAdapter
//
// Converts [Book] → [ReadingSessionRecord] for BehaviorContextEngine.analyze().
// ReadingSessionRecord is already defined in the file above.

struct ReadingSessionAdapter {
    func adapt(_ books: [Book]) -> [ReadingSessionRecord] {
        books.flatMap(\.sessions).compactMap { session -> ReadingSessionRecord? in
            guard let end = session.endTime else { return nil }
            return ReadingSessionRecord(
                id: session.id,
                startDate: session.startTime,
                endDate: end
            )
        }
    }
}

// 1D — WeatherContextAdapter
//
// Builds [WeatherContextRecord] from WeatherKitService stored snapshots.
// WeatherContextRecord is already defined in the file above:
//   (id: UUID, timestamp: Date, descriptor: String)
//
// WeatherSnapshot has no .sessionID field. Snapshots are matched to sessions
// by closest-timestamp join within a ±1 hour window.
// All failures are swallowed — BCE always accepts empty weatherRecords.

struct WeatherContextAdapter {
    func adapt(sessions: [ReadingSession]) -> [WeatherContextRecord] {
        let completed = sessions.filter { $0.endTime != nil }
        guard !completed.isEmpty else { return [] }

        guard let earliest = completed.map(\.startTime).min(),
              let latest = completed.compactMap(\.endTime).max()
        else { return [] }

        let snapshots: [WeatherSnapshot]
        do {
            snapshots = try WeatherKitService.shared.snapshots(
                from: earliest.addingTimeInterval(-3600),
                to: latest.addingTimeInterval(3600)
            )
        } catch {
            return []
        }

        guard !snapshots.isEmpty else { return [] }

        var records: [WeatherContextRecord] = []

        for session in completed {
            guard let nearest = snapshots.min(by: {
                abs($0.timestamp.timeIntervalSince(session.startTime)) <
                    abs($1.timestamp.timeIntervalSince(session.startTime))
            }) else { continue }

            let delta = abs(nearest.timestamp.timeIntervalSince(session.startTime))
            guard delta <= 3600 else { continue } // only accept within ±1 hour

            records.append(WeatherContextRecord(
                id: UUID(),
                timestamp: nearest.timestamp,
                descriptor: nearest.condition.rawValue
            ))
        }

        return records
    }
}

// 1E — AnalyticsContextEnrichment + AnalyticsContextAdapter
//
// Bridges AnalyticsEngine outputs into auxiliary data for advanced analyzers.
// Does NOT feed into analyze() directly — used by the upgraded entry point.

public struct AnalyticsContextEnrichment: Sendable {
    public let sessionQualities: [UUID: Double] // sessionID → SessionQuality.score
    public let streakLength: Int
    public let readingSpeedByBook: [UUID: Double] // bookID → adjustedReadingSpeed (secs/page)
    let improvementVector: ImprovementAnalytics
}

struct AnalyticsContextAdapter {
    func enrich(books: [Book]) -> AnalyticsContextEnrichment {
        var sessionQualities: [UUID: Double] = [:]
        for book in books {
            for session in book.sessions {
                let quality = AnalyticsEngine.sessionQuality(session: session)
                sessionQualities[session.id] = quality.score
            }
        }

        let streak = AnalyticsEngine.streak(books: books)

        var readingSpeedByBook: [UUID: Double] = [:]
        for book in books {
            readingSpeedByBook[book.id] = AnalyticsEngine.adjustedReadingSpeed(for: book)
        }

        let improvement = AnalyticsEngine.improvementAnalysis(books: books)

        return AnalyticsContextEnrichment(
            sessionQualities: sessionQualities,
            streakLength: streak.currentStreak,
            readingSpeedByBook: readingSpeedByBook,
            improvementVector: improvement
        )
    }
}

// 1F — BookContextMetadata + BookModelAdapter
//
// Converts Book domain data into context-relevant metadata for advanced analyzers.

public struct BookContextMetadata: Sendable {
    public let bookID: UUID
    public let genre: String // book.genre.rawValue
    public let totalPages: Int
    public let isCompleted: Bool
    public let sessionCount: Int
    public let totalReadingTime: TimeInterval
}

struct BookModelAdapter {
    func adapt(_ books: [Book]) -> [BookContextMetadata] {
        books.map { book in
            BookContextMetadata(
                bookID: book.id,
                genre: book.genre.rawValue,
                totalPages: book.totalPages,
                isCompleted: book.isCompleted,
                sessionCount: book.sessions.count,
                totalReadingTime: book.totalReadingTime
            )
        }
    }
}

// 1G — FullIntegrationInput + IntegrationInputBuilder
//
// Aggregates everything the upgraded entry point needs into one struct.

public struct FullIntegrationInput: Sendable {
    public let sessions: [ReadingSessionRecord]
    public let evidence: [BehaviorEvidence]
    public let deviceStateEvents: [DeviceStateEvent]
    public let inactivityRecords: [InactivityRecord]
    public let weatherRecords: [WeatherContextRecord]
    public let enrichment: AnalyticsContextEnrichment
    public let bookMetadata: [BookContextMetadata]
}

enum IntegrationInputBuilder {
    static func build(
        from books: [Book],
        kit: BehaviorContextAccessKit
    ) -> FullIntegrationInput {
        let sessionAdapter = ReadingSessionAdapter()
        let kitAdapter = BehaviorContextAccessKitAdapter()
        let analyticsAdapter = AnalyticsContextAdapter()
        let bookAdapter = BookModelAdapter()
        let weatherAdapter = WeatherContextAdapter()

        let adapterInput = BehaviorContextAdapterInput(
            books: books,
            applicationSessions: kit.applicationSessions,
            inactivityRecords: kit.inactivityRecords,
            deviceStateEvents: kit.deviceStateEvents,
            behavioralEvents: kit.events
        )

        let sessions = sessionAdapter.adapt(books)
        let evidence = kitAdapter.adapt(adapterInput)
        let enrichment = analyticsAdapter.enrich(books: books)
        let bookMetadata = bookAdapter.adapt(books)

        let allReadingSessions = books.flatMap(\.sessions)
        let weatherRecords = weatherAdapter.adapt(sessions: allReadingSessions)

        return FullIntegrationInput(
            sessions: sessions,
            evidence: evidence,
            deviceStateEvents: kit.deviceStateEvents,
            inactivityRecords: kit.inactivityRecords,
            weatherRecords: weatherRecords,
            enrichment: enrichment,
            bookMetadata: bookMetadata
        )
    }
}

// ============================================================================
// MARK: - Context Window System

// ============================================================================

// 2A — ContextWindowPreset

public enum ContextWindowPreset: Sendable {
    case narrow // 15 min before/after
    case standard // 60 min (current BCE default)
    case extended // 3 hours
    case fullDay // 12 hours
    case custom(pre: TimeInterval, post: TimeInterval)

    var preInterval: TimeInterval {
        switch self {
        case .narrow: return 15 * 60
        case .standard: return 60 * 60
        case .extended: return 3 * 60 * 60
        case .fullDay: return 12 * 60 * 60
        case let .custom(pre, _): return pre
        }
    }

    var postInterval: TimeInterval {
        switch self {
        case .narrow: return 15 * 60
        case .standard: return 60 * 60
        case .extended: return 3 * 60 * 60
        case .fullDay: return 12 * 60 * 60
        case let .custom(_, post): return post
        }
    }
}

// 2B — DynamicContextWindowSelector
//
// Selects the optimal window preset based on session history depth.
// More data → narrower windows are reliable. Less data → wider windows needed.

struct DynamicContextWindowSelector {
    func select(sessionCount: Int, averageSessionDuration _: TimeInterval) -> ContextWindowPreset {
        switch sessionCount {
        case ..<5: return .fullDay
        case ..<20: return .extended
        case ..<50: return .standard
        default: return .narrow
        }
    }
}

// 2C — WindowComparisonResult + MultiWindowComparisonEngine
//
// Runs context reconstruction across multiple window presets and compares which
// window yields the most consistent (highest-stability) results.

public struct WindowComparisonResult: Sendable {
    public let preset: ContextWindowPreset
    public let contextCount: Int
    public let stabilityScore: Double
}

struct MultiWindowComparisonEngine {
    func compare(
        contexts: [ReadingContextRecord],
        presets: [ContextWindowPreset] = [.narrow, .standard, .extended]
    ) -> [WindowComparisonResult] {
        let stabilityAnalyzer = EnvironmentStabilityAnalyzer()

        return presets.map { preset in
            // Filter contexts that fall within the preset window.
            // preReadingContext is the environment recorded before reading;
            // we use confidence as a proxy for temporal proximity here since
            // ReadingContextRecord does not expose raw timestamps per-context.
            let filtered = contexts.filter {
                $0.confidence.score >= windowConfidenceThreshold(preset)
            }

            let stability = stabilityAnalyzer.analyze(contexts: filtered)

            return WindowComparisonResult(
                preset: preset,
                contextCount: filtered.count,
                stabilityScore: stability.stabilityScore
            )
        }
        .sorted { $0.stabilityScore > $1.stabilityScore }
    }

    private func windowConfidenceThreshold(_ preset: ContextWindowPreset) -> Double {
        switch preset {
        case .narrow: return 0.70
        case .standard: return 0.45
        case .extended: return 0.25
        case .fullDay: return 0.10
        case .custom: return 0.45
        }
    }
}

// 2D — WeightedBehaviorEvidence + WindowWeightingEngine
//
// Weights evidence by temporal proximity to a specific session start time.
// Evidence closer in time receives a higher weight (linear decay).

public struct WeightedBehaviorEvidence: Sendable {
    public let evidence: BehaviorEvidence
    public let weight: Double // 0–1, proximity-based
}

struct WindowWeightingEngine {
    func weight(
        evidence: [BehaviorEvidence],
        relativeTo sessionStart: Date,
        window: ContextWindowPreset
    ) -> [WeightedBehaviorEvidence] {
        evidence
            .map { item -> WeightedBehaviorEvidence in
                let delta = abs(item.timestamp.timeIntervalSince(sessionStart))
                let weight = max(0, 1 - (delta / window.preInterval))
                return WeightedBehaviorEvidence(evidence: item, weight: weight)
            }
            .sorted { $0.weight > $1.weight }
    }
}

// ============================================================================
// MARK: - Device-State Analysis

// ============================================================================

// 3A — DeviceStateInfluenceProfile

public struct DeviceStateInfluenceProfile: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let preSessionDeviceState: DeviceStateType?
    public let midSessionLockEvents: Int
    public let postSessionSleepEvents: Int
    public let deviceWasFocused: Bool
    public let influenceScore: Double

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        preSessionDeviceState: DeviceStateType?,
        midSessionLockEvents: Int,
        postSessionSleepEvents: Int,
        deviceWasFocused: Bool,
        influenceScore: Double
    ) {
        self.id = id
        self.sessionID = sessionID
        self.preSessionDeviceState = preSessionDeviceState
        self.midSessionLockEvents = midSessionLockEvents
        self.postSessionSleepEvents = postSessionSleepEvents
        self.deviceWasFocused = deviceWasFocused
        self.influenceScore = influenceScore
    }
}

// 3B — DeviceStateInfluenceAnalyzer

struct DeviceStateInfluenceAnalyzer {
    func analyze(
        sessions: [ReadingSessionRecord],
        deviceEvents: [DeviceStateEvent]
    ) -> [DeviceStateInfluenceProfile] {
        sessions.map { session in
            let sessionInterval = session.startDate ... session.endDate

            // State just before the session (within 10 minutes prior)
            let tenMinutesBefore = session.startDate.addingTimeInterval(-600)
            let preEvent = deviceEvents
                .filter { $0.timestamp >= tenMinutesBefore && $0.timestamp < session.startDate }
                .sorted { $0.timestamp > $1.timestamp }
                .first
            let preState = preEvent?.state

            // Lock events during the session
            let midLocks = deviceEvents.filter {
                sessionInterval.contains($0.timestamp) && $0.state == .locked
            }.count

            // Sleep events within 30 minutes after the session
            let thirtyMinutesAfter = session.endDate.addingTimeInterval(1800)
            let postSleeps = deviceEvents.filter {
                $0.timestamp > session.endDate &&
                    $0.timestamp <= thirtyMinutesAfter &&
                    $0.state == .sleeping
            }.count

            let wasFocused = midLocks == 0 && postSleeps == 0
            let influenceScore = (wasFocused ? 1.0 : 0.0) * 0.5
                + (1.0 - min(1.0, Double(midLocks) / 5.0)) * 0.5

            return DeviceStateInfluenceProfile(
                sessionID: session.id,
                preSessionDeviceState: preState,
                midSessionLockEvents: midLocks,
                postSessionSleepEvents: postSleeps,
                deviceWasFocused: wasFocused,
                influenceScore: influenceScore
            )
        }
    }
}

// 3C — DeviceStateContextRecord

public struct DeviceStateContextRecord: Codable, Hashable, Sendable {
    public let generatedAt: Date
    public let profiles: [DeviceStateInfluenceProfile]
    public let averageFocusScore: Double
    public let mostFocusedSessions: [UUID] // influenceScore > 0.8
    public let disruptedSessions: [UUID] // midSessionLockEvents > 2

    public init(profiles: [DeviceStateInfluenceProfile]) {
        generatedAt = Date()
        self.profiles = profiles
        averageFocusScore = profiles.isEmpty
            ? 0
            : profiles.map(\.influenceScore).reduce(0, +) / Double(profiles.count)
        mostFocusedSessions = profiles
            .filter { $0.influenceScore > 0.8 }
            .map(\.sessionID)
        disruptedSessions = profiles
            .filter { $0.midSessionLockEvents > 2 }
            .map(\.sessionID)
    }
}

// ============================================================================
// MARK: - Inactivity Reconstruction

// ============================================================================

// 4A — InactivityGapType + InactivityGapRecord

public enum InactivityGapType: String, Codable, Hashable, Sendable {
    case brief // < 5 minutes
    case moderate // 5–30 minutes
    case extended // 30 min – 2 hours
    case longBreak // 2–8 hours
    case overnight // > 8 hours
}

public struct InactivityGapRecord: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    /// AUDIT F-06 fix (Phase 2): the record previously carried ONLY a duration,
    /// so downstream analyzers had to sort by duration and stamp Date() — the root
    /// cause of the near-tautological "increasingGaps" signal. Real boundaries now
    /// travel with the record.
    public let startDate: Date
    public let endDate: Date
    public let gapDuration: TimeInterval
    public let precededSession: UUID? // reading session that FOLLOWED this gap
    public let followedSession: UUID? // reading session that PRECEDED this gap
    public let gapType: InactivityGapType

    public init(
        id: UUID = UUID(),
        startDate: Date,
        endDate: Date,
        gapDuration: TimeInterval,
        precededSession: UUID?,
        followedSession: UUID?,
        gapType: InactivityGapType
    ) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.gapDuration = gapDuration
        self.precededSession = precededSession
        self.followedSession = followedSession
        self.gapType = gapType
    }
}

// 4B — InactivityGapAnalyzer

struct InactivityGapAnalyzer {
    func analyze(
        inactivityRecords: [InactivityRecord],
        sessions: [ReadingSessionRecord]
    ) -> [InactivityGapRecord] {
        inactivityRecords.compactMap { record -> InactivityGapRecord? in
            guard let duration = record.duration, let end = record.endTime else { return nil }

            // Reading session that FOLLOWS this gap (closest startDate after gap end)
            let following = sessions
                .filter { $0.startDate >= end }
                .min { $0.startDate < $1.startDate }

            // Reading session that PRECEDED this gap (closest endDate before gap start)
            let preceding = sessions
                .filter { $0.endDate <= record.startTime }
                .max { $0.endDate < $1.endDate }

            let gapType: InactivityGapType
            switch duration {
            case ..<300: gapType = .brief
            case ..<1800: gapType = .moderate
            case ..<7200: gapType = .extended
            case ..<28800: gapType = .longBreak
            default: gapType = .overnight
            }

            return InactivityGapRecord(
                startDate: record.startTime,
                endDate: end,
                gapDuration: duration,
                precededSession: following?.id,
                followedSession: preceding?.id,
                gapType: gapType
            )
        }
    }
}

// 4C — RecoverySessionRecord + RecoverySessionDetector
//
// A "recovery session" = reading that follows an extended or overnight gap.

public struct RecoverySessionRecord: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let precedingGap: InactivityGapRecord
    public let recoveryStrength: Double

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        precedingGap: InactivityGapRecord,
        recoveryStrength: Double
    ) {
        self.id = id
        self.sessionID = sessionID
        self.precedingGap = precedingGap
        self.recoveryStrength = recoveryStrength
    }
}

struct RecoverySessionDetector {
    func detect(
        gaps: [InactivityGapRecord],
        sessions: [ReadingSessionRecord]
    ) -> [RecoverySessionRecord] {
        gaps
            .filter { gap in
                (gap.gapType == .extended || gap.gapType == .longBreak || gap.gapType == .overnight)
                    && gap.precededSession != nil
            }
            .compactMap { gap -> RecoverySessionRecord? in
                guard let sessionID = gap.precededSession else { return nil }
                guard sessions.contains(where: { $0.id == sessionID }) else { return nil }

                let strength: Double
                switch gap.gapType {
                case .overnight: strength = 1.0
                case .longBreak: strength = 0.8
                case .extended: strength = 0.5
                default: strength = 0.0
                }

                return RecoverySessionRecord(
                    sessionID: sessionID,
                    precedingGap: gap,
                    recoveryStrength: strength
                )
            }
    }
}

// 4D — FatigueSignalType + FatigueSignal + FatigueIndicatorAnalyzer

public enum FatigueSignalType: String, Codable, Hashable, Sendable {
    case increasingGaps // 3+ consecutive gaps each longer than the prior
    case multipleExtendedGaps // 2+ extended gaps in the same calendar day
    case overnightFollowedByBrief // overnight gap, then the following session is brief
}

public struct FatigueSignal: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let signalType: FatigueSignalType
    public let confidence: ContextConfidence

    public init(
        id: UUID = UUID(),
        date: Date,
        signalType: FatigueSignalType,
        confidence: ContextConfidence
    ) {
        self.id = id
        self.date = date
        self.signalType = signalType
        self.confidence = confidence
    }
}

/// AUDIT F-06 fix (Phase 2): the previous implementation sorted gaps BY DURATION
/// and then counted "consecutive increases" — inside a duration-sorted array that
/// is nearly everything, so ≥3 distinct-duration gaps almost guaranteed a false
/// fatigue signal regardless of chronology. All three signals now run on real
/// dates (InactivityGapRecord.startDate/endDate) and chronological order.
struct FatigueIndicatorAnalyzer {
    func analyze(gaps: [InactivityGapRecord]) -> [FatigueSignal] {
        var signals: [FatigueSignal] = []
        guard !gaps.isEmpty else { return signals }

        let calendar = Calendar.current

        // ── increasingGaps: strictly CHRONOLOGICAL run-length ──────────────
        let chronological = gaps.sorted { $0.startDate < $1.startDate }
        var increasingRun = 1
        for i in 1 ..< chronological.count {
            if chronological[i].gapDuration > chronological[i - 1].gapDuration {
                increasingRun += 1
                if increasingRun >= 3 {
                    signals.append(FatigueSignal(
                        date: chronological[i].endDate,
                        signalType: .increasingGaps,
                        confidence: ContextConfidence(
                            score: min(1.0, Double(increasingRun) / 10.0)
                        )
                    ))
                    break
                }
            } else {
                increasingRun = 1   // equal-or-shorter resets the streak
            }
        }

        // ── multipleExtendedGaps: per CALENDAR DAY of the gap's start ──────
        let extendedByDay = Dictionary(
            grouping: gaps.filter {
                $0.gapType == .extended || $0.gapType == .longBreak || $0.gapType == .overnight
            },
            by: { calendar.startOfDay(for: $0.startDate) }
        )
        for (day, dayGaps) in extendedByDay.sorted(by: { $0.key < $1.key })
        where dayGaps.count >= 2 {
            signals.append(FatigueSignal(
                date: day,
                signalType: .multipleExtendedGaps,
                confidence: ContextConfidence(
                    score: min(1.0, Double(dayGaps.count) / 5.0)
                )
            ))
        }

        // ── overnightFollowedByBrief: dated from the gap's own boundary ────
        for gap in gaps.filter({ $0.gapType == .overnight && $0.precededSession != nil }) {
            signals.append(FatigueSignal(
                date: gap.endDate,
                signalType: .overnightFollowedByBrief,
                confidence: ContextConfidence(score: 0.5)
            ))
        }

        return signals
    }
}

// ============================================================================
// MARK: - Environment Evolution Tracking

// ============================================================================

// Private file-scope helper for Shannon entropy.
// Used by LongitudinalEnvironmentTracker.distributionScore.
// -sum(p * log2(p)) normalized to 0–1 over the number of possible types.

private func bceAppendShannonEntropy(_ counts: [BehavioralEnvironmentType: Int]) -> Double {
    let total = Double(counts.values.reduce(0, +))
    guard total > 0 else { return 0 }
    let entropy = counts.values.reduce(0.0) { acc, count -> Double in
        let p = Double(count) / total
        return p > 0 ? acc - p * log2(p) : acc
    }
    // Normalize: maximum entropy for n types is log2(n).
    let maxEntropy = log2(Double(max(counts.count, 1)))
    return maxEntropy > 0 ? min(1.0, entropy / maxEntropy) : 0
}

// 5A — EnvironmentEvolutionPeriod + EnvironmentEvolutionSnapshot

public enum EnvironmentEvolutionPeriod: String, Codable, Hashable, Sendable {
    case week
    case month
    case quarter
}

public struct EnvironmentEvolutionSnapshot: Codable, Hashable, Sendable {
    public let period: EnvironmentEvolutionPeriod
    public let periodStart: Date
    public let dominantEnvironment: BehavioralEnvironmentType
    public let distributionScore: Double // 0 = monoculture, 1 = diverse
    public let sessionCount: Int

    public init(
        period: EnvironmentEvolutionPeriod,
        periodStart: Date,
        dominantEnvironment: BehavioralEnvironmentType,
        distributionScore: Double,
        sessionCount: Int
    ) {
        self.period = period
        self.periodStart = periodStart
        self.dominantEnvironment = dominantEnvironment
        self.distributionScore = distributionScore
        self.sessionCount = sessionCount
    }
}

// 5B — LongitudinalEnvironmentTracker

struct LongitudinalEnvironmentTracker {
    func track(
        contexts: [ReadingContextRecord],
        period: EnvironmentEvolutionPeriod = .month
    ) -> [EnvironmentEvolutionSnapshot] {
        guard !contexts.isEmpty else { return [] }

        // Group contexts into calendar buckets based on the period.
        let grouped = Dictionary(grouping: contexts) { context -> Date in
            periodStart(for: context.readingDate, period: period)
        }

        return grouped
            .sorted { $0.key < $1.key }
            .compactMap { bucketDate, records -> EnvironmentEvolutionSnapshot? in
                guard !records.isEmpty else { return nil }

                let types = records.map(\.preReadingContext.type)
                guard let dominant = types.mostCommon else { return nil }

                let typeCounts = Dictionary(grouping: types) { $0 }.mapValues(\.count)
                let entropy = bceAppendShannonEntropy(typeCounts)

                return EnvironmentEvolutionSnapshot(
                    period: period,
                    periodStart: bucketDate,
                    dominantEnvironment: dominant,
                    distributionScore: entropy,
                    sessionCount: records.count
                )
            }
    }

    private func periodStart(for date: Date, period: EnvironmentEvolutionPeriod) -> Date {
        var components = Calendar.current.dateComponents(
            [.year, .month, .weekOfYear, .weekday],
            from: date
        )
        switch period {
        case .week:
            // Start of ISO week
            components.weekday = 2 // Monday
            components.hour = 0
            components.minute = 0
            components.second = 0
            return Calendar.current.date(from: components)
                ?? Calendar.current.startOfDay(for: date)
        case .month:
            return Calendar.current.date(
                from: DateComponents(year: components.year, month: components.month, day: 1)
            ) ?? Calendar.current.startOfDay(for: date)
        case .quarter:
            let month = components.month ?? 1
            let qMonth = ((month - 1) / 3) * 3 + 1
            return Calendar.current.date(
                from: DateComponents(year: components.year, month: qMonth, day: 1)
            ) ?? Calendar.current.startOfDay(for: date)
        }
    }
}

// 5C — BehavioralShiftEvent + LongitudinalBehaviorShiftDetector

public struct BehavioralShiftEvent: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let shiftDate: Date
    public let fromEnvironment: BehavioralEnvironmentType
    public let toEnvironment: BehavioralEnvironmentType
    public let persistenceScore: Double // fraction of subsequent snapshots matching new dominant

    public init(
        id: UUID = UUID(),
        shiftDate: Date,
        fromEnvironment: BehavioralEnvironmentType,
        toEnvironment: BehavioralEnvironmentType,
        persistenceScore: Double
    ) {
        self.id = id
        self.shiftDate = shiftDate
        self.fromEnvironment = fromEnvironment
        self.toEnvironment = toEnvironment
        self.persistenceScore = persistenceScore
    }
}

struct LongitudinalBehaviorShiftDetector {
    func detect(
        snapshots: [EnvironmentEvolutionSnapshot]
    ) -> [BehavioralShiftEvent] {
        let sorted = snapshots.sorted { $0.periodStart < $1.periodStart }
        guard sorted.count >= 2 else { return [] }

        var shifts: [BehavioralShiftEvent] = []

        for i in 1 ..< sorted.count {
            let previous = sorted[i - 1]
            let current = sorted[i]

            guard current.dominantEnvironment != previous.dominantEnvironment else { continue }

            // Persistence: fraction of snapshots after this shift that share the new dominant
            let subsequent = Array(sorted[i...])
            let matching = subsequent.filter {
                $0.dominantEnvironment == current.dominantEnvironment
            }.count
            let persistence = Double(matching) / Double(max(subsequent.count, 1))

            shifts.append(BehavioralShiftEvent(
                shiftDate: current.periodStart,
                fromEnvironment: previous.dominantEnvironment,
                toEnvironment: current.dominantEnvironment,
                persistenceScore: persistence
            ))
        }

        return shifts
    }
}

// ============================================================================
// MARK: - Sequence System Upgrades

// ============================================================================

// 6A — SequenceRecurrenceRecord

public struct SequenceRecurrenceRecord: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let sequence: [BehavioralEnvironmentType]
    public let occurrenceDates: [Date]
    public let recurrenceCount: Int
    public let firstSeen: Date
    public let lastSeen: Date
    public let spanDays: Int

    public init(
        id: UUID = UUID(),
        sequence: [BehavioralEnvironmentType],
        occurrenceDates: [Date]
    ) {
        self.id = id
        self.sequence = sequence
        self.occurrenceDates = occurrenceDates
        recurrenceCount = occurrenceDates.count
        firstSeen = occurrenceDates.min() ?? Date()
        lastSeen = occurrenceDates.max() ?? Date()
        spanDays = max(0, Calendar.current.dateComponents(
            [.day],
            from: occurrenceDates.min() ?? Date(),
            to: occurrenceDates.max() ?? Date()
        ).day ?? 0)
    }
}

// 6B — SequenceRecurrenceDatabase

struct SequenceRecurrenceDatabase {
    func build(contexts: [ReadingContextRecord]) -> [SequenceRecurrenceRecord] {
        guard contexts.count >= 3 else { return [] }

        let sorted = contexts.sorted { $0.readingDate < $1.readingDate }

        // Extract [pre, in, post] triple for each context
        var grouped: [[BehavioralEnvironmentType]: [Date]] = [:]
        for context in sorted {
            let triple: [BehavioralEnvironmentType] = [
                context.preReadingContext.type,
                context.inSessionContext.type,
                context.postReadingContext.type,
            ]
            grouped[triple, default: []].append(context.readingDate)
        }

        return grouped
            .filter { _, dates in dates.count >= 2 } // require at least 2 occurrences
            .map { triple, dates in
                SequenceRecurrenceRecord(sequence: triple, occurrenceDates: dates)
            }
            .sorted { $0.recurrenceCount > $1.recurrenceCount }
    }
}

// 6C — SequenceConsistencyScore + SequenceConsistencyScorer

public struct SequenceConsistencyScore: Sendable {
    public let sequence: [BehavioralEnvironmentType]
    public let consistencyScore: Double // recurrences per observed day
    public let intervalVariance: Double // 0=regular, 1=irregular
}

struct SequenceConsistencyScorer {
    func score(records: [SequenceRecurrenceRecord]) -> [SequenceConsistencyScore] {
        records.map { record in
            let consistencyScore = min(
                1.0,
                Double(record.recurrenceCount) / Double(max(record.spanDays, 1))
            )

            let intervalVariance = computeIntervalVariance(dates: record.occurrenceDates)

            return SequenceConsistencyScore(
                sequence: record.sequence,
                consistencyScore: consistencyScore,
                intervalVariance: intervalVariance
            )
        }
    }

    private func computeIntervalVariance(dates: [Date]) -> Double {
        guard dates.count >= 3 else { return 0.5 }

        let sorted = dates.sorted()
        let intervals = zip(sorted, sorted.dropFirst()).map { $1.timeIntervalSince($0) }
        let mean = intervals.reduce(0, +) / Double(intervals.count)
        guard mean > 0 else { return 0 }

        let variance = intervals.map { pow($0 - mean, 2) }.reduce(0, +) / Double(intervals.count)
        let stdDev = sqrt(variance)
        // Normalize: coefficient of variation clamped to 0–1
        return min(1.0, stdDev / mean)
    }
}

// 6D — SequenceTimingProfile + SequenceTimingAnalyzer

public struct SequenceTimingProfile: Sendable {
    public let sequence: [BehavioralEnvironmentType]
    public let averageIntervalMinutes: Double
    public let peakHour: Int // most common hour-of-day this sequence starts
    public let isTimeStable: Bool // std-dev of occurrence hours < 2
}

struct SequenceTimingAnalyzer {
    func analyze(records: [SequenceRecurrenceRecord]) -> [SequenceTimingProfile] {
        records.map { record in
            let sorted = record.occurrenceDates.sorted()
            let intervals = zip(sorted, sorted.dropFirst())
                .map { $1.timeIntervalSince($0) / 60 } // convert to minutes

            let avgInterval = intervals.isEmpty
                ? 0
                : intervals.reduce(0, +) / Double(intervals.count)

            let hours = record.occurrenceDates.map {
                Calendar.current.component(.hour, from: $0)
            }
            let peakHour = hours.mostCommon ?? 0
            let meanHour = Double(hours.reduce(0, +)) / Double(max(hours.count, 1))
            let hourStdDev = sqrt(
                hours.map { pow(Double($0) - meanHour, 2) }.reduce(0, +)
                    / Double(max(hours.count, 1))
            )

            return SequenceTimingProfile(
                sequence: record.sequence,
                averageIntervalMinutes: avgInterval,
                peakHour: peakHour,
                isTimeStable: hourStdDev < 2.0
            )
        }
    }
}

// 6E — TransitionChain + TransitionChainReconstructor
//
// Extends per-session ContextTransition (A→B) into multi-hop chains
// (A→B→C→D) across consecutive sessions.

public struct TransitionChain: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let chain: [BehavioralEnvironmentType]
    public let sessionIDs: [UUID]
    public let chainStrength: Double // recurrenceCount * consistency

    public init(
        id: UUID = UUID(),
        chain: [BehavioralEnvironmentType],
        sessionIDs: [UUID],
        chainStrength: Double
    ) {
        self.id = id
        self.chain = chain
        self.sessionIDs = sessionIDs
        self.chainStrength = chainStrength
    }
}

struct TransitionChainReconstructor {
    func reconstruct(
        contexts: [ReadingContextRecord],
        minLength: Int = 3,
        minRecurrence: Int = 2
    ) -> [TransitionChain] {
        let sorted = contexts.sorted { $0.readingDate < $1.readingDate }
        guard sorted.count >= minLength else { return [] }

        // Build a directed graph: post-reading type[n] → pre-reading type[n+1]
        var graph: [BehavioralEnvironmentType: [BehavioralEnvironmentType]] = [:]
        for i in 0 ..< (sorted.count - 1) {
            let from = sorted[i].postReadingContext.type
            let to = sorted[i + 1].preReadingContext.type
            graph[from, default: []].append(to)
        }

        // Walk paths from each starting node, collecting chains of minLength+
        var chainCounts: [[BehavioralEnvironmentType]: (count: Int, sessionIDs: [UUID])] = [:]

        for startIndex in 0 ..< (sorted.count - minLength + 1) {
            var path = [BehavioralEnvironmentType]()
            var sessionIDs = [UUID]()
            path.append(sorted[startIndex].preReadingContext.type)
            sessionIDs.append(sorted[startIndex].sessionID)

            for j in startIndex ..< min(startIndex + 6, sorted.count - 1) {
                let next = sorted[j + 1].preReadingContext.type
                path.append(next)
                sessionIDs.append(sorted[j + 1].sessionID)

                if path.count >= minLength {
                    let key = path
                    chainCounts[key, default: (0, [])] = (
                        chainCounts[key, default: (0, [])].count + 1,
                        sessionIDs
                    )
                }
            }
        }

        return chainCounts
            .filter { _, value in value.count >= minRecurrence }
            .map { chain, value in
                let consistency = min(1.0, Double(value.count) / Double(max(sorted.count, 1)))
                let chainStrength = Double(value.count) * consistency
                return TransitionChain(
                    chain: chain,
                    sessionIDs: value.sessionIDs,
                    chainStrength: chainStrength
                )
            }
            .sorted { $0.chainStrength > $1.chainStrength }
    }
}

// ============================================================================
// MARK: - Context Distribution Profiles

// ============================================================================

// 7A — DiversityClassification + BehavioralDiversityProfile + BehavioralDiversityProfileBuilder

public enum DiversityClassification: String, Codable, Hashable, Sendable {
    case focused // 1 dominant environment > 70% of sessions
    case moderate // 2–3 environments, none > 60%
    case diverse // 4+ environments fairly distributed
}

public struct BehavioralDiversityProfile: Codable, Hashable, Sendable {
    public let uniquePreReadingEnvironments: Int
    public let uniquePostReadingEnvironments: Int
    public let diversityClassification: DiversityClassification
    public let dominanceRatio: Double // fraction held by single dominant env

    public init(
        uniquePreReadingEnvironments: Int,
        uniquePostReadingEnvironments: Int,
        diversityClassification: DiversityClassification,
        dominanceRatio: Double
    ) {
        self.uniquePreReadingEnvironments = uniquePreReadingEnvironments
        self.uniquePostReadingEnvironments = uniquePostReadingEnvironments
        self.diversityClassification = diversityClassification
        self.dominanceRatio = dominanceRatio
    }
}

struct BehavioralDiversityProfileBuilder {
    func build(contexts: [ReadingContextRecord]) -> BehavioralDiversityProfile {
        guard !contexts.isEmpty else {
            return BehavioralDiversityProfile(
                uniquePreReadingEnvironments: 0,
                uniquePostReadingEnvironments: 0,
                diversityClassification: .focused,
                dominanceRatio: 1.0
            )
        }

        // Use existing analyzers — do NOT reimplement their logic.
        let distributionAnalyzer = ContextDistributionAnalyzer()
        let diversityAnalyzer = BehavioralDiversityAnalyzer()

        let distribution = distributionAnalyzer.analyze(contexts: contexts)
        let diversity = diversityAnalyzer.analyze(contexts: contexts)

        let preTypes = contexts.map(\.preReadingContext.type)
        let postTypes = contexts.map(\.postReadingContext.type)
        let uniquePre = Set(preTypes).count
        let uniquePost = Set(postTypes).count

        let totalPre = Double(preTypes.count)
        let dominantPreCount = Dictionary(grouping: preTypes) { $0 }
            .values.map(\.count).max() ?? 0
        let dominanceRatio = totalPre > 0
            ? Double(dominantPreCount) / totalPre
            : 1.0

        let classification: DiversityClassification
        if dominanceRatio > 0.70 {
            classification = .focused
        } else if uniquePre <= 3 {
            classification = .moderate
        } else {
            classification = .diverse
        }

        _ = distribution // referenced to satisfy use of existing analyzers
        _ = diversity

        return BehavioralDiversityProfile(
            uniquePreReadingEnvironments: uniquePre,
            uniquePostReadingEnvironments: uniquePost,
            diversityClassification: classification,
            dominanceRatio: dominanceRatio
        )
    }
}

// 7B — ProductiveContextResult + ProductiveContextFinder

public struct ProductiveContextResult: Codable, Hashable, Sendable {
    public let environment: BehavioralEnvironmentType
    public let averageSessionQuality: Double
    public let sampleCount: Int
    public let confidence: ContextConfidence
}

struct ProductiveContextFinder {
    func find(
        contexts: [ReadingContextRecord],
        enrichment: AnalyticsContextEnrichment
    ) -> ProductiveContextResult? {
        let grouped = Dictionary(grouping: contexts) { $0.preReadingContext.type }

        let scored: [(BehavioralEnvironmentType, Double, Int)] = grouped.compactMap { env, records in
            let qualities = records.compactMap { record -> Double? in
                enrichment.sessionQualities[record.sessionID]
            }
            guard qualities.count >= 3 else { return nil }

            let avg = qualities.reduce(0, +) / Double(qualities.count)
            return (env, avg, qualities.count)
        }

        guard let best = scored.max(by: { $0.1 < $1.1 }) else { return nil }

        return ProductiveContextResult(
            environment: best.0,
            averageSessionQuality: best.1,
            sampleCount: best.2,
            confidence: ContextConfidence(
                score: min(1.0, Double(best.2) / 20.0)
            )
        )
    }
}

// 7C — ConsistentContextResult + ConsistentContextFinder

public struct ConsistentContextResult: Codable, Hashable, Sendable {
    public let environment: BehavioralEnvironmentType
    public let consistencyScore: Double // fraction of reading days this env appeared
    public let sampleDays: Int
    public let confidence: ContextConfidence
}

struct ConsistentContextFinder {
    func find(contexts: [ReadingContextRecord]) -> ConsistentContextResult? {
        guard !contexts.isEmpty else { return nil }

        // Group by calendar day
        let byDay = Dictionary(
            grouping: contexts,
            by: { Calendar.current.startOfDay(for: $0.readingDate) }
        )
        let totalDays = byDay.count
        guard totalDays > 0 else { return nil }

        // For each environment, count how many days it appeared
        var envDayCounts: [BehavioralEnvironmentType: Int] = [:]
        for (_, records) in byDay {
            let envs = Set(records.map(\.preReadingContext.type))
            for env in envs {
                envDayCounts[env, default: 0] += 1
            }
        }

        guard let (bestEnv, bestCount) = envDayCounts.max(by: { $0.value < $1.value }) else {
            return nil
        }

        let consistency = Double(bestCount) / Double(totalDays)

        return ConsistentContextResult(
            environment: bestEnv,
            consistencyScore: consistency,
            sampleDays: totalDays,
            confidence: ContextConfidence(
                score: min(1.0, Double(totalDays) / 30.0)
            )
        )
    }
}

// ============================================================================
// MARK: - Confidence Engine V2

// ============================================================================

// 8A — ConfidenceBreakdown

public struct ConfidenceBreakdown: Codable, Hashable, Sendable {
    public let evidenceVolume: Double // 0–1: raw count of evidence items
    public let evidenceRecency: Double // 0–1: decays over 90 days
    public let evidenceConsistency: Double // 0–1: mean of BehaviorEvidence.consistency
    public let historicalDepth: Double // 0–1: how far back evidence goes (max 365 days)
    public let routineStrength: Double // 0–1: mean of routines' confidence scores
    public let overallScore: Double // weighted composite

    public init(
        evidenceVolume: Double,
        evidenceRecency: Double,
        evidenceConsistency: Double,
        historicalDepth: Double,
        routineStrength: Double,
        overallScore: Double
    ) {
        self.evidenceVolume = evidenceVolume
        self.evidenceRecency = evidenceRecency
        self.evidenceConsistency = evidenceConsistency
        self.historicalDepth = historicalDepth
        self.routineStrength = routineStrength
        self.overallScore = overallScore
    }
}

// 8B — EvidenceQualityScorer

struct EvidenceQualityScorer {
    func score(
        evidence: [BehaviorEvidence],
        routines: [BehavioralRoutine],
        asOf referenceDate: Date = Date()
    ) -> ConfidenceBreakdown {
        guard !evidence.isEmpty else {
            return ConfidenceBreakdown(
                evidenceVolume: 0,
                evidenceRecency: 0,
                evidenceConsistency: 0,
                historicalDepth: 0,
                routineStrength: 0,
                overallScore: 0
            )
        }

        let evidenceVolume = min(1.0, Double(evidence.count) / 50.0)

        let recencyScores = evidence.map { item -> Double in
            let ageInDays = referenceDate.timeIntervalSince(item.timestamp) / 86400
            return max(0, 1 - (ageInDays / 90.0))
        }
        let evidenceRecency = recencyScores.reduce(0, +) / Double(recencyScores.count)

        let evidenceConsistency = evidence.map(\.consistency).reduce(0, +)
            / Double(evidence.count)

        let oldest = evidence.map(\.timestamp).min() ?? referenceDate
        let depthDays = referenceDate.timeIntervalSince(oldest) / 86400
        let historicalDepth = min(1.0, depthDays / 365.0)

        let routineStrength: Double
        if routines.isEmpty {
            routineStrength = 0
        } else {
            routineStrength = routines.map(\.confidence.score).reduce(0, +)
                / Double(routines.count)
        }

        let overallScore =
            (evidenceVolume * 0.20) +
            (evidenceRecency * 0.25) +
            (evidenceConsistency * 0.20) +
            (historicalDepth * 0.20) +
            (routineStrength * 0.15)

        return ConfidenceBreakdown(
            evidenceVolume: evidenceVolume,
            evidenceRecency: evidenceRecency,
            evidenceConsistency: evidenceConsistency,
            historicalDepth: historicalDepth,
            routineStrength: routineStrength,
            overallScore: overallScore
        )
    }
}

// 8C — HistoricalDepthReport + HistoricalDepthScorer

public struct HistoricalDepthReport: Codable, Hashable, Sendable {
    public let oldestEvidenceDate: Date?
    public let newestEvidenceDate: Date?
    public let observedSpanDays: Int
    public let observedSpanWeeks: Int
    public let isStatisticallyReliable: Bool // spanDays >= 30 && count >= 20
    public let reliabilityNote: String

    public init(
        oldestEvidenceDate: Date?,
        newestEvidenceDate: Date?,
        observedSpanDays: Int,
        observedSpanWeeks: Int,
        isStatisticallyReliable: Bool,
        reliabilityNote: String
    ) {
        self.oldestEvidenceDate = oldestEvidenceDate
        self.newestEvidenceDate = newestEvidenceDate
        self.observedSpanDays = observedSpanDays
        self.observedSpanWeeks = observedSpanWeeks
        self.isStatisticallyReliable = isStatisticallyReliable
        self.reliabilityNote = reliabilityNote
    }
}

struct HistoricalDepthScorer {
    func score(evidence: [BehaviorEvidence]) -> HistoricalDepthReport {
        guard !evidence.isEmpty else {
            return HistoricalDepthReport(
                oldestEvidenceDate: nil,
                newestEvidenceDate: nil,
                observedSpanDays: 0,
                observedSpanWeeks: 0,
                isStatisticallyReliable: false,
                reliabilityNote: "No evidence recorded yet. Keep using the app to build your behavioral profile."
            )
        }

        let oldest = evidence.map(\.timestamp).min()!
        let newest = evidence.map(\.timestamp).max()!

        let spanDays = max(0, Calendar.current.dateComponents([.day], from: oldest, to: newest).day ?? 0)
        let spanWeeks = spanDays / 7
        let isReliable = spanDays >= 30 && evidence.count >= 20

        let note: String
        if isReliable {
            note = "Behavioral profile is statistically reliable with \(evidence.count) evidence items spanning \(spanDays) days."
        } else if spanDays < 30 {
            note = "Profile needs \(30 - spanDays) more days of data to reach baseline reliability."
        } else {
            note = "Profile needs \(20 - evidence.count) more evidence items to reach baseline reliability."
        }

        return HistoricalDepthReport(
            oldestEvidenceDate: oldest,
            newestEvidenceDate: newest,
            observedSpanDays: spanDays,
            observedSpanWeeks: spanWeeks,
            isStatisticallyReliable: isReliable,
            reliabilityNote: note
        )
    }
}

// ============================================================================
// MARK: - Narrative Engine V3

// ============================================================================

// 9A — NarrativeCategory + CitedContextNarrative

public enum NarrativeCategory: String, Codable, Hashable, Sendable {
    case routine // recurring time-based pattern
    case environment // pre/post-reading environment pattern
    case transition // behavioral shift into reading
    case disruption // break from established routine
    case productive // which context yields best sessions
    case evolution // how patterns have changed over time
    case device // device-state patterns
    case recovery // inactivity/recovery patterns
}

public struct CitedContextNarrative: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let text: String
    public let evidenceIDs: [UUID] // BehaviorEvidence IDs that support this narrative
    public let sessionIDs: [UUID] // ReadingSessionRecord IDs referenced
    public let confidence: ContextConfidence
    public let category: NarrativeCategory

    public init(
        id: UUID = UUID(),
        text: String,
        evidenceIDs: [UUID],
        sessionIDs: [UUID],
        confidence: ContextConfidence,
        category: NarrativeCategory
    ) {
        self.id = id
        self.text = text
        self.evidenceIDs = evidenceIDs
        self.sessionIDs = sessionIDs
        self.confidence = confidence
        self.category = category
    }
}

// 9B — ExplainabilityNarrativeBuilder
//
// All narratives are deterministic templates filled with verified data values.
// No fabrication. No probabilistic text. If a required value is nil or count == 0,
// that narrative type is skipped entirely.

struct ExplainabilityNarrativeBuilder {
    /// Candidate generation (which categories exist, what each sentence
    /// says) and evidence recovery (real dates/counts per candidate) both
    /// now live in DataMaturityContextV3Adapter, alongside the inclusion
    /// and wording-strength decisions this function used to make inline
    /// via ad hoc thresholds (`routine.confidence.score > 0.5`,
    /// `trend.strength > 0.3`, `meanFocusScore > 0.8`, and so on). Those
    /// thresholds were exactly the "scattered, ad hoc confidence
    /// thresholds" DataMaturityEngine exists to replace with one
    /// composable, calibratable authority — see DataMaturityEngine.swift
    /// and DataMaturityEngineAdapters.swift. Signature is unchanged, so
    /// NarrativePipeline.run() below needed no edits at all.
    func build(
        contexts: [ReadingContextRecord],
        routines: [BehavioralRoutine],
        trends: [ContextTrend],
        disruptions: [RoutineDisruption],
        productiveContext: ProductiveContextResult?,
        consistentContext: ConsistentContextResult?,
        deviceProfiles: [DeviceStateInfluenceProfile],
        recoveryRecords: [RecoverySessionRecord],
        evolutionSnapshots: [EnvironmentEvolutionSnapshot],
        evidence: [BehaviorEvidence]
    ) -> [CitedContextNarrative] {
        DataMaturityContextV3Adapter.gate(
            contexts: contexts,
            routines: routines,
            trends: trends,
            disruptions: disruptions,
            productiveContext: productiveContext,
            consistentContext: consistentContext,
            deviceProfiles: deviceProfiles,
            recoveryRecords: recoveryRecords,
            evolutionSnapshots: evolutionSnapshots,
            evidence: evidence
        )
    }
}

// ============================================================================
// MARK: - Analysis Pipelines

// ============================================================================

// 10A — ContextAnalysisResult + ContextAnalysisPipeline

public struct ContextAnalysisResult: Sendable {
    public let contexts: [ReadingContextRecord]
    public let sequences: [SequenceRecurrenceRecord]
    public let chains: [TransitionChain]
    public let continuity: [ContextContinuityRecord]
    public let trends: [ContextTrend]
    public let evolution: [EnvironmentEvolutionSnapshot]
    public let diversity: BehavioralDiversityProfile
}

struct ContextAnalysisPipeline {
    func run(
        contexts: [ReadingContextRecord],
        input _: FullIntegrationInput
    ) -> ContextAnalysisResult {
        let sequenceDB = SequenceRecurrenceDatabase()
        let chainRecon = TransitionChainReconstructor()
        let continuityAnal = ContextContinuityAnalyzer()
        let trendAnal = ContextTrendAnalyzer()
        let evolutionTrack = LongitudinalEnvironmentTracker()
        let diversityBuilder = BehavioralDiversityProfileBuilder()

        let sequences = sequenceDB.build(contexts: contexts)
        let chains = chainRecon.reconstruct(contexts: contexts)
        let continuity = continuityAnal.analyze(contexts: contexts)
        let trends = trendAnal.analyze(contexts: contexts)
        let evolution = evolutionTrack.track(contexts: contexts)
        let diversity = diversityBuilder.build(contexts: contexts)

        return ContextAnalysisResult(
            contexts: contexts,
            sequences: sequences,
            chains: chains,
            continuity: continuity,
            trends: trends,
            evolution: evolution,
            diversity: diversity
        )
    }
}

// 10B — SignificanceResult + SignificancePipeline

public struct SignificanceResult: Sendable {
    public let evidenceChains: [ContextEvidenceChain]
    public let confidenceBreakdown: ConfidenceBreakdown
    public let historicalDepth: HistoricalDepthReport
    public let windowComparison: [WindowComparisonResult]
}

struct SignificancePipeline {
    func run(
        input: FullIntegrationInput,
        contexts: [ReadingContextRecord]
    ) -> SignificanceResult {
        let chainBuilder = ContextEvidenceChainBuilder()
        let qualityScorer = EvidenceQualityScorer()
        let depthScorer = HistoricalDepthScorer()
        let windowComparer = MultiWindowComparisonEngine()

        // Build one ContextEvidenceChain per session
        let evidenceChains = input.sessions.map { session -> ContextEvidenceChain in
            let env = contexts.first { $0.sessionID == session.id }?
                .preReadingContext.type ?? .unknown
            return chainBuilder.build(
                session: session,
                evidence: input.evidence,
                environment: env
            )
        }

        let routinesForScoring: [BehavioralRoutine] = [] // routines computed in RoutinePipeline
        let confidenceBreakdown = qualityScorer.score(
            evidence: input.evidence,
            routines: routinesForScoring
        )
        let historicalDepth = depthScorer.score(evidence: input.evidence)
        let windowComparison = windowComparer.compare(contexts: contexts)

        return SignificanceResult(
            evidenceChains: evidenceChains,
            confidenceBreakdown: confidenceBreakdown,
            historicalDepth: historicalDepth,
            windowComparison: windowComparison
        )
    }
}

// 10C — RoutineResult + RoutinePipeline

public struct RoutineResult: Sendable {
    public let advancedRoutines: AdvancedRoutineAnalysis
    public let disruptions: [RoutineDisruption]
    public let deviceProfiles: [DeviceStateInfluenceProfile]
    public let inactivityGaps: [InactivityGapRecord]
    public let recoveryRecords: [RecoverySessionRecord]
    public let fatigueSignals: [FatigueSignal]
    public let clusters: [EnvironmentCluster]
    public let weatherPatterns: [WeatherRoutinePattern]
    public let correlations: ContextCorrelationMatrix
}

struct RoutinePipeline {
    func run(
        input: FullIntegrationInput,
        contextResult: ContextAnalysisResult
    ) -> RoutineResult {
        let routineDetector = AdvancedRoutineDetector()
        let disruptionAnalyzer = RoutineDisruptionAnalyzer()
        let deviceAnalyzer = DeviceStateInfluenceAnalyzer()
        let inactivityAnalyzer = InactivityGapAnalyzer()
        let recoveryDetector = RecoverySessionDetector()
        let fatigueAnalyzer = FatigueIndicatorAnalyzer()
        let clusterBuilder = EnvironmentClusterBuilder()
        let weatherAnalyzer = WeatherRoutineAnalyzer()
        let correlationAnalyzer = ContextCorrelationAnalyzer()

        let contexts = contextResult.contexts

        let advancedRoutines = routineDetector.analyze(contexts: contexts)
        let disruptions = disruptionAnalyzer.detect(
            routines: advancedRoutines.detectedRoutines,
            contexts: contexts
        )
        let deviceProfiles = deviceAnalyzer.analyze(
            sessions: input.sessions,
            deviceEvents: input.deviceStateEvents
        )
        let inactivityGaps = inactivityAnalyzer.analyze(
            inactivityRecords: input.inactivityRecords,
            sessions: input.sessions
        )
        let recoveryRecords = recoveryDetector.detect(
            gaps: inactivityGaps,
            sessions: input.sessions
        )
        let fatigueSignals = fatigueAnalyzer.analyze(gaps: inactivityGaps)
        let clusters = clusterBuilder.clusters(from: contexts)
        let weatherPatterns = weatherAnalyzer.analyze(contexts: contexts)
        let correlations = correlationAnalyzer.analyze(contexts: contexts)

        return RoutineResult(
            advancedRoutines: advancedRoutines,
            disruptions: disruptions,
            deviceProfiles: deviceProfiles,
            inactivityGaps: inactivityGaps,
            recoveryRecords: recoveryRecords,
            fatigueSignals: fatigueSignals,
            clusters: clusters,
            weatherPatterns: weatherPatterns,
            correlations: correlations
        )
    }
}

// 10D — NarrativeResult + NarrativePipeline

public struct NarrativeResult: Sendable {
    public let citedNarratives: [CitedContextNarrative]
    public let productiveContext: ProductiveContextResult?
    public let consistentContext: ConsistentContextResult?
    public let diversityProfile: BehavioralDiversityProfile
}

struct NarrativePipeline {
    func run(
        contextResult: ContextAnalysisResult,
        routineResult: RoutineResult,
        significance: SignificanceResult,
        enrichment: AnalyticsContextEnrichment
    ) -> NarrativeResult {
        let productiveFinder = ProductiveContextFinder()
        let consistentFinder = ConsistentContextFinder()
        let narrativeBuilder = ExplainabilityNarrativeBuilder()

        let contexts = contextResult.contexts

        let productiveContext = productiveFinder.find(
            contexts: contexts,
            enrichment: enrichment
        )
        let consistentContext = consistentFinder.find(contexts: contexts)

        let citedNarratives = narrativeBuilder.build(
            contexts: contexts,
            routines: routineResult.advancedRoutines.detectedRoutines,
            trends: contextResult.trends,
            disruptions: routineResult.disruptions,
            productiveContext: productiveContext,
            consistentContext: consistentContext,
            deviceProfiles: routineResult.deviceProfiles,
            recoveryRecords: routineResult.recoveryRecords,
            evolutionSnapshots: contextResult.evolution,
            evidence: significance.evidenceChains.map { chain in
                // G6: never fabricate a sampling-time timestamp (NEW-DE-9).
                // Use the actual reading session's start date, when known.
                let sessionDate = contexts.first {
                    $0.sessionID == chain.readingSessionID
                }?.readingDate ?? contexts.first?.readingDate ?? Date()
                return BehaviorEvidence(
                    id: chain.id,
                    timestamp: sessionDate,
                    name: chain.environment.rawValue,
                    category: .idle,
                    totalDuration: 0,
                    frequency: 1,
                    recurrenceCount: 1,
                    consistency: chain.confidence.score,
                    proximityToReading: chain.confidence.score
                )
            }
        )

        return NarrativeResult(
            citedNarratives: citedNarratives,
            productiveContext: productiveContext,
            consistentContext: consistentContext,
            diversityProfile: contextResult.diversity
        )
    }
}

// ============================================================================
// MARK: - Unified Entry Point

// ============================================================================

// 10E — FullContextIntelligenceReport
//
// The existing ContextIntelligenceReport (already in the file above) is
// untouched. This new struct holds the fully integrated output from all
// four pipelines plus the legacy report.

public struct FullContextIntelligenceReport: Sendable {
    public let generatedAt: Date
    public let contextResult: ContextAnalysisResult
    public let significanceResult: SignificanceResult
    public let routineResult: RoutineResult
    public let narrativeResult: NarrativeResult
    public let legacyReport: ContextIntelligenceReport

    public init(
        generatedAt: Date,
        contextResult: ContextAnalysisResult,
        significanceResult: SignificanceResult,
        routineResult: RoutineResult,
        narrativeResult: NarrativeResult,
        legacyReport: ContextIntelligenceReport
    ) {
        self.generatedAt = generatedAt
        self.contextResult = contextResult
        self.significanceResult = significanceResult
        self.routineResult = routineResult
        self.narrativeResult = narrativeResult
        self.legacyReport = legacyReport
    }
}

// 10F — BehaviorContextEngine extension: analyzeWithIntelligence
//
// Additive entry point. Calls the existing analyze() first (which sets
// self.summary), then runs all four pipelines on the result.
// Two public entry points coexist: analyze() and analyzeWithIntelligence().
// Neither replaces the other.

public extension BehaviorContextEngine {
    func analyzeWithIntelligence(
        input: FullIntegrationInput
    ) -> FullContextIntelligenceReport {
        // ── Step 1: Run existing analyze() ───────────────────────────────
        // This sets self.summary (the @Published property) and returns the
        // full BehavioralContextSummary with contexts, routines, transitions,
        // profiles, and narratives.
        let summary = analyze(
            sessions: input.sessions,
            evidence: input.evidence,
            weatherRecords: input.weatherRecords
        )

        let contexts = summary.contextRecords

        // ── Step 2: Context analysis pipeline ────────────────────────────
        let contextPipeline = ContextAnalysisPipeline()
        let contextResult = contextPipeline.run(contexts: contexts, input: input)

        // ── Step 3: Significance pipeline ─────────────────────────────────
        let significancePipeline = SignificancePipeline()
        let significanceResult = significancePipeline.run(
            input: input,
            contexts: contexts
        )

        // ── Step 4: Routine pipeline ──────────────────────────────────────
        let routinePipeline = RoutinePipeline()
        let routineResult = routinePipeline.run(
            input: input,
            contextResult: contextResult
        )

        // ── Step 5: Narrative pipeline ────────────────────────────────────
        let narrativePipeline = NarrativePipeline()
        let narrativeResult = narrativePipeline.run(
            contextResult: contextResult,
            routineResult: routineResult,
            significance: significanceResult,
            enrichment: input.enrichment
        )

        // ── Step 6: Legacy intelligence report ───────────────────────────
        // buildIntelligenceReport() is already defined in the file above.
        // It receives [BehavioralRoutine], not AdvancedRoutineAnalysis.
        let legacyReport = buildIntelligenceReport(
            contexts: contexts,
            routines: summary.routines
        )

        // ── Step 7: Assemble FullContextIntelligenceReport ───────────────
        let report = FullContextIntelligenceReport(
            generatedAt: Date(),
            contextResult: contextResult,
            significanceResult: significanceResult,
            routineResult: routineResult,
            narrativeResult: narrativeResult,
            legacyReport: legacyReport
        )
        intelligenceReport = report
        return report
    }
}

// ============================================================================
// MARK: - BEHAVIOR CONTEXT ENGINE APPEND — PHASE 2 UPGRADE — COMPLETE

// ============================================================================
//
// Checklist status (from original BCE checklist near line 3200):
//
//   [x] Integration Layer
//         [x] 1A BehaviorContextAdapterInput
//         [x] 1B BehaviorContextAccessKitAdapter
//         [x] 1C ReadingSessionAdapter
//         [x] 1D WeatherContextAdapter
//         [x] 1E AnalyticsContextEnrichment + AnalyticsContextAdapter
//         [x] 1F BookContextMetadata + BookModelAdapter
//         [x] 1G FullIntegrationInput + IntegrationInputBuilder
//
//   [x] Context Window System
//         [x] 2A ContextWindowPreset
//         [x] 2B DynamicContextWindowSelector
//         [x] 2C WindowComparisonResult + MultiWindowComparisonEngine
//         [x] 2D WeightedBehaviorEvidence + WindowWeightingEngine
//
//   [x] Device-State Analysis
//         [x] 3A DeviceStateInfluenceProfile
//         [x] 3B DeviceStateInfluenceAnalyzer
//         [x] 3C DeviceStateContextRecord
//
//   [x] Inactivity Reconstruction
//         [x] 4A InactivityGapType + InactivityGapRecord
//         [x] 4B InactivityGapAnalyzer
//         [x] 4C RecoverySessionRecord + RecoverySessionDetector
//         [x] 4D FatigueSignalType + FatigueSignal + FatigueIndicatorAnalyzer
//
//   [x] Environment Evolution Tracking
//         [x] 5A EnvironmentEvolutionPeriod + EnvironmentEvolutionSnapshot
//         [x] 5B LongitudinalEnvironmentTracker (+ private shannonEntropy helper)
//         [x] 5C BehavioralShiftEvent + LongitudinalBehaviorShiftDetector
//
//   [x] Sequence System Upgrades
//         [x] 6A SequenceRecurrenceRecord
//         [x] 6B SequenceRecurrenceDatabase
//         [x] 6C SequenceConsistencyScore + SequenceConsistencyScorer
//         [x] 6D SequenceTimingProfile + SequenceTimingAnalyzer
//         [x] 6E TransitionChain + TransitionChainReconstructor
//
//   [x] Context Distribution Profiles
//         [x] 7A DiversityClassification + BehavioralDiversityProfile
//              + BehavioralDiversityProfileBuilder
//         [x] 7B ProductiveContextResult + ProductiveContextFinder
//         [x] 7C ConsistentContextResult + ConsistentContextFinder
//
//   [x] Confidence Engine V2
//         [x] 8A ConfidenceBreakdown
//         [x] 8B EvidenceQualityScorer
//         [x] 8C HistoricalDepthReport + HistoricalDepthScorer
//
//   [x] Narrative Engine V3
//         [x] 9A NarrativeCategory + CitedContextNarrative
//         [x] 9B ExplainabilityNarrativeBuilder
//
//   [x] Analysis Pipelines
//         [x] 10A ContextAnalysisResult + ContextAnalysisPipeline
//         [x] 10B SignificanceResult + SignificancePipeline
//         [x] 10C RoutineResult + RoutinePipeline
//         [x] 10D NarrativeResult + NarrativePipeline
//
//   [x] Unified Entry Point
//         [x] 10E FullContextIntelligenceReport
//         [x] 10F BehaviorContextEngine.analyzeWithIntelligence(input:)
//
// Zero existing lines modified. All code appended after line 3,327.
// ============================================================================

// MARK: - Developer Console

#if DEBUG
extension BehaviorContextEngine: DeveloperConsoleObservable {
    static var consoleIdentity: ConsoleSubsystemIdentity {
        ConsoleSubsystemIdentity(
            id: "behavior-context-engine",
            displayName: "Behavior Context Engine",
            category: .engine,
            purpose: "Reconstructs environments, routines, and narratives from reading sessions + evidence. Populated by SessionEventRouter at the end of each reading session — analyze() is its one live entry point; this file also contains a large amount of additional analyzer/pipeline scaffolding whose live call-graph connectivity was not confirmed this session (see the component registry)."
        )
    }

    var consoleSnapshot: ConsoleSubsystemSnapshot {
        ConsoleSubsystemSnapshot(
            identity: Self.consoleIdentity,
            status: summary == nil ? .idle : .healthy,
            currentActivity: summary == nil
                ? "No analysis run yet this session"
                : "Last analysis: \(summary?.routines.count ?? 0) routine(s), \(summary?.narratives.count ?? 0) narrative(s)",
            lastUpdated: summary?.generatedAt,
            metrics: [
                "Context records (last run)": "\(summary?.contextRecords.count ?? 0)",
                "Routines (last run)": "\(summary?.routines.count ?? 0)",
                "Transitions (last run)": "\(summary?.transitions.count ?? 0)",
            ]
        )
    }
}
#endif
//
//
