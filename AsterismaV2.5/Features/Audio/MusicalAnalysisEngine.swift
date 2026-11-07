//  MusicalAnalysisEngine.swift
//  PURPOSE
//  Audio-reading intelligence layer. Pure analytics — no I/O, no side effects.
//  Analogous to WeatherAnalysisEngine for environmental correlations.
//
//  RESPONSIBILITIES
//  • Accepts [AudioSessionRecord] as input (assembled by buildSessionRecords)
//  • Produces AudioReadingProfile (correlations, conditions, habits, evolution)
//  • Produces AudioPredictiveContext (the structured data contract for all downstream engines)
//  • Acts as the authoritative source of audio-reading intelligence;
//    other engines consume AudioPredictiveContext rather than reimplementing audio analysis
//
//  DOES NOT
//  • Collect audio data — that is AudioMonitorService's responsibility
//  • Access DataStore directly
//  • Reimplement reading metrics — those come from AnalyticsEngine via AudioSessionRecord

import Foundation

// MARK: - AudioFactor

/// The audio-side dimensions this engine correlates against reading behavior metrics.
public enum AudioFactor: String, Codable, CaseIterable, Hashable, Sendable {
    case audioCategory // silence vs. music vs. podcast vs. …
    case audioSource // which application produced the audio
    case listeningIntensity // fraction of session with audio present
    case silenceFraction // complement of listeningIntensity
    case genreMood // inferred mood from genre metadata
    case genreEnergy // inferred energy from genre metadata
    case trackDiversity // number of distinct tracks heard
    case transitionFrequency // how often audio category or source changed
    case artistIdentity // a specific named artist
    case albumIdentity // a specific named album
    case genreCategory // audio genre string (e.g. "Classical", "Hip-Hop")
    case playlistIdentity // a named playlist (Music.app only)
    case hourOfDay // hour of day reading occurred
    case dayOfWeek // weekday reading occurred
    case season // seasonal period
}

// MARK: - AudioCorrelation

/// A statistically evaluated relationship between one audio factor and one reading behavior metric.
/// Mirrors EnvironmentalCorrelation from WeatherAnalysisEngine.
public struct AudioCorrelation: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let factor: AudioFactor
    public let metric: ReadingBehaviorMetric // public type from WeatherAnalysisEngine
    public let coefficient: Double // Pearson r, −1.0 to +1.0
    public let significance: Double // 0–1 composite significance
    public let influenceScore: Double // abs(coefficient) × significance
    public let lifecycle: CorrelationLifecycle // public type from WeatherAnalysisEngine
    public let confidence: ConfidenceReport // public type from WeatherAnalysisEngine
    public let firstObserved: Date
    public let lastObserved: Date
    public let supportingSampleCount: Int
    /// Human-readable value label (e.g. "Classical", "Spotify", "Silence").
    public let contextLabel: String?

    public init(
        id: UUID = UUID(),
        factor: AudioFactor,
        metric: ReadingBehaviorMetric,
        coefficient: Double,
        significance: Double,
        influenceScore: Double,
        lifecycle: CorrelationLifecycle,
        confidence: ConfidenceReport,
        firstObserved: Date,
        lastObserved: Date,
        supportingSampleCount: Int,
        contextLabel: String? = nil
    ) {
        self.id = id
        self.factor = factor
        self.metric = metric
        self.coefficient = coefficient
        self.significance = significance
        self.influenceScore = influenceScore
        self.lifecycle = lifecycle
        self.confidence = confidence
        self.firstObserved = firstObserved
        self.lastObserved = lastObserved
        self.supportingSampleCount = supportingSampleCount
        self.contextLabel = contextLabel
    }
}

// MARK: - AudioConditionProfile

/// A specific audio condition and its measured impact on reading performance.
public struct AudioConditionProfile: Codable, Hashable, Sendable {
    public let label: String
    public let category: AudioCategory
    public let averageReadingSpeed: Double
    public let averageSessionDuration: TimeInterval
    public let averageEngagement: Double
    public let averageSessionQuality: Double
    public let averageListeningIntensity: Double
    public let completionRate: Double
    public let supportingSessions: Int
    public let confidence: ConfidenceReport

    public init(
        label: String, category: AudioCategory,
        averageReadingSpeed: Double, averageSessionDuration: TimeInterval,
        averageEngagement: Double, averageSessionQuality: Double,
        averageListeningIntensity: Double, completionRate: Double,
        supportingSessions: Int, confidence: ConfidenceReport
    ) {
        self.label = label
        self.category = category
        self.averageReadingSpeed = averageReadingSpeed
        self.averageSessionDuration = averageSessionDuration
        self.averageEngagement = averageEngagement
        self.averageSessionQuality = averageSessionQuality
        self.averageListeningIntensity = averageListeningIntensity
        self.completionRate = completionRate
        self.supportingSessions = supportingSessions
        self.confidence = confidence
    }
}

// MARK: - AudioHourProfile

/// Typical audio environment at a specific hour of day, derived from session history.
public struct AudioHourProfile: Codable, Hashable, Sendable {
    public let hour: Int
    public let dominantCategory: AudioCategory
    public let categoryDistribution: [AudioCategory: Double]
    public let averageListeningIntensity: Double
    public let averageReadingQuality: Double
    public let averageReadingSpeed: Double
    public let sessionCount: Int
}

// MARK: - PreferredSoundtrackProfile

/// An audio context positively correlated with this reader's performance.
public struct PreferredSoundtrackProfile: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let label: String
    public let category: AudioCategory
    public let artistName: String?
    public let genreName: String?
    public let averageSessionQuality: Double
    public let averageReadingSpeed: Double
    public let averageSessionDuration: TimeInterval
    public let averageEngagement: Double
    public let supportingSessions: Int
    public let confidence: ConfidenceReport

    public init(
        id: UUID = UUID(), label: String, category: AudioCategory,
        artistName: String? = nil, genreName: String? = nil,
        averageSessionQuality: Double, averageReadingSpeed: Double,
        averageSessionDuration: TimeInterval, averageEngagement: Double,
        supportingSessions: Int, confidence: ConfidenceReport
    ) {
        self.id = id; self.label = label; self.category = category
        self.artistName = artistName; self.genreName = genreName
        self.averageSessionQuality = averageSessionQuality
        self.averageReadingSpeed = averageReadingSpeed
        self.averageSessionDuration = averageSessionDuration
        self.averageEngagement = averageEngagement
        self.supportingSessions = supportingSessions
        self.confidence = confidence
    }
}

// MARK: - AudioBehaviorEvolution

/// Long-term shift in the reader's audio-listening behavior.
public struct AudioBehaviorEvolution: Codable, Hashable, Sendable {
    public let hasMeaningfulData: Bool
    public let dominantShiftDescription: String?
    public let oldDominantCategory: AudioCategory?
    public let newDominantCategory: AudioCategory?
    /// Positive = listening intensity increasing over time; negative = decreasing.
    public let listeningIntensityTrend: Double?
    /// Positive = more varied audio; negative = more homogeneous.
    public let categorySwitchTrend: Double?
    /// Reuses BehaviorEvolutionState from WeatherAnalysisEngine.
    public let evolutionState: BehaviorEvolutionState

    public static let insufficient = AudioBehaviorEvolution(
        hasMeaningfulData: false, dominantShiftDescription: nil,
        oldDominantCategory: nil, newDominantCategory: nil,
        listeningIntensityTrend: nil, categorySwitchTrend: nil,
        evolutionState: .stable
    )

    public init(
        hasMeaningfulData: Bool, dominantShiftDescription: String?,
        oldDominantCategory: AudioCategory?, newDominantCategory: AudioCategory?,
        listeningIntensityTrend: Double?, categorySwitchTrend: Double?,
        evolutionState: BehaviorEvolutionState
    ) {
        self.hasMeaningfulData = hasMeaningfulData
        self.dominantShiftDescription = dominantShiftDescription
        self.oldDominantCategory = oldDominantCategory
        self.newDominantCategory = newDominantCategory
        self.listeningIntensityTrend = listeningIntensityTrend
        self.categorySwitchTrend = categorySwitchTrend
        self.evolutionState = evolutionState
    }
}

// MARK: - AudioReadingProfile

/// The complete analytical output of MusicalAnalysisEngine.buildAudioProfile(from:).
public struct AudioReadingProfile: Codable, Sendable {
    public let generatedAt: Date
    public let preferredReadingSoundtracks: [PreferredSoundtrackProfile]
    public let highFocusConditions: [AudioConditionProfile]
    public let distractionConditions: [AudioConditionProfile]
    public let optimalListeningCondition: AudioConditionProfile?
    /// Best audio condition per book reading genre. Key = ReadingGenre.rawValue.
    public let genreSpecificEnvironments: [String: AudioConditionProfile]
    public let listeningHabitsByHour: [Int: AudioHourProfile]
    public let behaviorEvolution: AudioBehaviorEvolution
    public let artistCorrelations: [AudioCorrelation]
    public let albumCorrelations: [AudioCorrelation]
    public let playlistCorrelations: [AudioCorrelation]
    public let genreCorrelations: [AudioCorrelation]
    public let audioCategoryCorrelations: [AudioCorrelation]
    public let listeningPatternCorrelations: [AudioCorrelation]
    public let silenceCorrelations: [AudioCorrelation]
    public let temporalCorrelations: [AudioCorrelation]
    public let overallConfidence: ConfidenceReport
    public let supportingSessionCount: Int
}

// MARK: - AudioInsight

/// A human-readable finding surfaced from the AudioReadingProfile.
public struct AudioInsight: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let category: InsightCategory
    public let title: String
    public let detail: String
    public let supportingEvidence: String
    public let influenceScore: Double
    public let confidence: ConfidenceReport

    public enum InsightCategory: String, Codable, CaseIterable, Sendable {
        case preferredSoundtrack
        case distractionPattern
        case optimalEnvironment
        case genrePreference
        case temporalPattern
        case behaviorShift
        case silenceAdvantage
    }

    public init(
        id: UUID = UUID(), category: InsightCategory,
        title: String, detail: String,
        supportingEvidence: String, influenceScore: Double,
        confidence: ConfidenceReport
    ) {
        self.id = id; self.category = category
        self.title = title; self.detail = detail
        self.supportingEvidence = supportingEvidence
        self.influenceScore = influenceScore; self.confidence = confidence
    }
}

// MARK: - AudioWeatherInteraction

/// Result of joining audio session records with weather session records.
/// Describes how audio category varies with weather conditions.
public struct AudioWeatherInteraction: Codable, Hashable, Sendable {
    public let rainyDayPreferredCategory: AudioCategory?
    public let clearDayPreferredCategory: AudioCategory?
    public let coldWeatherPreferredCategory: AudioCategory?
    public let warmWeatherPreferredCategory: AudioCategory?
    public let supportingSessions: Int
}

// MARK: - AudioAnnualReport

/// Per-year audio reading summary consumed by AnnualReportData.
public struct AudioAnnualReport: Codable, Hashable, Sendable {
    public let year: Int
    public let dominantListeningCategory: AudioCategory
    /// Sum of totalAudioDuration across all sessions in the year.
    public let totalEstimatedListeningTime: TimeInterval
    public let silenceFraction: Double
    public let topArtistsWhileReading: [String]
    public let bestAudioConditionForReading: AudioConditionProfile?
    /// Multiplier: audioSessions.avgSpeed / silenceSessions.avgSpeed (lower seconds/page = faster).
    public let audioImpactOnReadingSpeed: Double
    /// Multiplier: audioSessions.avgDuration / silenceSessions.avgDuration.
    public let audioImpactOnSessionLength: Double
    public let dominantListeningMood: InferredMood
    public let insightSummary: String
    public let totalSessionsWithAudioData: Int
}

// MARK: - AudioPredictiveContext

/// The unified output contract consumed by all downstream engines.
/// Single source of audio intelligence for the rest of the application.
public struct AudioPredictiveContext: Codable, Sendable {
    /// For PredictiveRecommendationEngine: best audio category by book reading genre.
    public let optimalAudioByBookGenre: [String: AudioCategory]
    /// For EstimationEngine: speed multiplier for the current audio context (1.0 = no effect).
    public let speedMultiplierForCurrentContext: Double
    /// For IntelligentNotificationEngine: hours of day that combine good audio + good reading quality.
    public let optimalReadingWindowsByAudio: [Int]
    /// For InsightEngine: top insights ready to surface to the user.
    public let surfaceableInsights: [AudioInsight]
    /// For WeatherAnalysisEngine: how weather conditions relate to audio category choice.
    public let audioWeatherInteraction: AudioWeatherInteraction?
    /// For ReadingGoalManager: estimated pace modifier based on audio environment.
    public let goalPaceAudioModifier: Double
    /// For AnnualReportData: the year's audio summary (nil if year not specified).
    public let annualAudioReport: AudioAnnualReport?
}

// MARK: - MusicalAnalysisEngine

/// Pure analytics engine. No I/O, no async, no side effects.
/// Call buildAudioProfile(from:) to produce all analytical outputs.
public final class MusicalAnalysisEngine {
    public init() {}

    // MARK: - Primary Entry Point

    /// Builds the complete AudioReadingProfile from all audio session records.
    public func buildAudioProfile(from records: [AudioSessionRecord]) -> AudioReadingProfile {
        let catCorrs = analyzeCategoryCorrelations(from: records)
        let artistCorrs = analyzeArtistCorrelations(from: records)
        let albumCorrs = analyzeAlbumCorrelations(from: records)
        let playlistCorrs = analyzePlaylistCorrelations(from: records)
        let genreCorrs = analyzeGenreCorrelations(from: records)
        let patternCorrs = analyzeListeningPatternCorrelations(from: records)
        let silenceCorrs = analyzeSilenceCorrelations(from: records)
        let temporalCorrs = analyzeTemporalCorrelations(from: records)

        let conditionProfiles = buildConditionProfiles(from: records)
        let highFocus = identifyHighFocusConditions(from: conditionProfiles)
        let distraction = identifyDistractionConditions(from: conditionProfiles)
        let optimal = conditionProfiles.max { $0.averageSessionQuality < $1.averageSessionQuality }
        let soundtracks = buildPreferredSoundtracks(from: records)
        let genreEnvs = buildGenreSpecificEnvironments(from: records)
        let hourlyHabits = buildHourlyListeningHabits(from: records)
        let evolution = buildBehaviorEvolution(from: records)

        let allCorrs = catCorrs + artistCorrs + albumCorrs + playlistCorrs +
            genreCorrs + patternCorrs + silenceCorrs + temporalCorrs
        let overallConf = makeConfidence(
            sampleCount: records.count,
            recurrence: allCorrs.isEmpty ? 0 : allCorrs.map { abs($0.coefficient) }.average,
            stability: 0.75, consistency: 0.75
        )

        return AudioReadingProfile(
            generatedAt: Date(),
            preferredReadingSoundtracks: soundtracks,
            highFocusConditions: highFocus,
            distractionConditions: distraction,
            optimalListeningCondition: optimal,
            genreSpecificEnvironments: genreEnvs,
            listeningHabitsByHour: hourlyHabits,
            behaviorEvolution: evolution,
            artistCorrelations: artistCorrs,
            albumCorrelations: albumCorrs,
            playlistCorrelations: playlistCorrs,
            genreCorrelations: genreCorrs,
            audioCategoryCorrelations: catCorrs,
            listeningPatternCorrelations: patternCorrs,
            silenceCorrelations: silenceCorrs,
            temporalCorrelations: temporalCorrs,
            overallConfidence: overallConf,
            supportingSessionCount: records.count
        )
    }

    // MARK: - Insights

    /// Generates human-readable insights from a completed AudioReadingProfile.
    public func generateInsights(from profile: AudioReadingProfile) -> [AudioInsight] {
        var insights: [AudioInsight] = []

        // Silence advantage
        let silenceQCor = profile.silenceCorrelations.first {
            $0.metric == .sessionQuality && $0.factor == .silenceFraction
        }
        if let cor = silenceQCor, cor.coefficient > 0.2 {
            let pct = Int(cor.coefficient * 100)
            insights.append(AudioInsight(
                category: .silenceAdvantage,
                title: "Silence is your strongest reading environment",
                detail: "Sessions in silence correlate with \(pct)% higher reading quality.",
                supportingEvidence: "\(cor.supportingSampleCount) sessions analyzed",
                influenceScore: cor.influenceScore,
                confidence: cor.confidence
            ))
        }

        // Best soundtrack
        if let top = profile.preferredReadingSoundtracks.first,
           top.supportingSessions >= 5, top.confidence.overallConfidence > 0.4
        {
            let label = top.artistName ?? top.label
            insights.append(AudioInsight(
                category: .preferredSoundtrack,
                title: "You read best with \(label)",
                detail: "Sessions featuring \(label) average \(Int(top.averageSessionQuality * 100))% quality — your highest.",
                supportingEvidence: "\(top.supportingSessions) sessions",
                influenceScore: top.averageSessionQuality,
                confidence: top.confidence
            ))
        }

        // Distraction pattern
        if let worst = profile.distractionConditions.first, worst.supportingSessions >= 5 {
            insights.append(AudioInsight(
                category: .distractionPattern,
                title: "\(worst.label) appears to reduce your reading focus",
                detail: "Your session quality is lowest when \(worst.label.lowercased()) is playing.",
                supportingEvidence: "\(worst.supportingSessions) sessions",
                influenceScore: 1.0 - worst.averageSessionQuality,
                confidence: worst.confidence
            ))
        }

        // Behavior shift
        if profile.behaviorEvolution.hasMeaningfulData,
           let shift = profile.behaviorEvolution.dominantShiftDescription
        {
            let trend = abs(profile.behaviorEvolution.listeningIntensityTrend ?? 0)
            insights.append(AudioInsight(
                category: .behaviorShift,
                title: "Your listening habits are shifting",
                detail: shift,
                supportingEvidence: "Based on your full reading history",
                influenceScore: trend,
                confidence: makeConfidence(
                    sampleCount: profile.supportingSessionCount,
                    recurrence: 0.7, stability: 0.6, consistency: 0.7
                )
            ))
        }

        // Genre-specific environment
        if let (genreKey, env) = profile.genreSpecificEnvironments
            .max(by: { $0.value.averageSessionQuality < $1.value.averageSessionQuality }),
            env.supportingSessions >= 3
        {
            insights.append(AudioInsight(
                category: .genrePreference,
                title: "For \(genreKey) books, \(env.label.lowercased()) works best",
                detail: "This combination produces \(Int(env.averageSessionQuality * 100))% average quality.",
                supportingEvidence: "\(env.supportingSessions) sessions",
                influenceScore: env.averageSessionQuality,
                confidence: env.confidence
            ))
        }

        // Temporal pattern
        if let best = profile.listeningHabitsByHour.values
            .max(by: { $0.averageReadingQuality < $1.averageReadingQuality }),
            best.sessionCount >= 3
        {
            let h12 = best.hour == 0 ? 12 : (best.hour > 12 ? best.hour - 12 : best.hour)
            let ampm = best.hour < 12 ? "AM" : "PM"
            insights.append(AudioInsight(
                category: .temporalPattern,
                title: "Your best audio-assisted reading happens around \(h12) \(ampm)",
                detail: "\(best.dominantCategory.displayName) at this hour gives you the highest quality scores.",
                supportingEvidence: "\(best.sessionCount) sessions",
                influenceScore: best.averageReadingQuality,
                confidence: makeConfidence(
                    sampleCount: best.sessionCount,
                    recurrence: 0.6, stability: best.averageReadingQuality, consistency: 0.6
                )
            ))
        }

        return insights.sorted { $0.influenceScore > $1.influenceScore }
    }

    // MARK: - Predictive Context (consumed by all downstream engines)

    /// Produces the unified AudioPredictiveContext for downstream engine consumption.
    ///
    /// - Parameters:
    ///   - profile: Output of buildAudioProfile(from:).
    ///   - currentContext: The AudioContextProfile for the session in progress (if any).
    ///   - weatherRecords: EnvironmentalSessionRecord array from WeatherAnalysisEngine (optional).
    ///   - allAudioRecords: All audio session records (for annual report generation).
    ///   - year: If provided, an AudioAnnualReport is generated for that year.
    public func generatePredictiveContext(
        from profile: AudioReadingProfile,
        currentContext: AudioContextProfile?,
        weatherRecords: [WeatherAnalysisEngine.EnvironmentalSessionRecord] = [],
        allAudioRecords: [AudioSessionRecord] = [],
        year: Int? = nil
    ) -> AudioPredictiveContext {
        let optimalByGenre = profile.genreSpecificEnvironments.mapValues(\.category)

        let speedMultiplier = computeSpeedMultiplier(
            currentContext: currentContext,
            profile: profile,
            records: allAudioRecords
        )

        let bestWindows = profile.listeningHabitsByHour
            .filter { $0.value.averageReadingQuality > 0.6 && $0.value.sessionCount >= 2 }
            .sorted { $0.value.averageReadingQuality > $1.value.averageReadingQuality }
            .prefix(3).map(\.key).sorted()

        let insights = generateInsights(from: profile)

        let weatherInteraction = buildAudioWeatherInteraction(
            audioRecords: allAudioRecords,
            weatherRecords: weatherRecords
        )

        let annualReport: AudioAnnualReport? = year.flatMap { y -> AudioAnnualReport? in
            let yearRecords = allAudioRecords.filter { record in
                Calendar.current.component(.year, from: record.timestamp) == y
            }
            let target = yearRecords.isEmpty ? allAudioRecords : yearRecords
            guard !target.isEmpty else { return nil }
            return generateAnnualReport(year: y, records: target)
        }

        return AudioPredictiveContext(
            optimalAudioByBookGenre: optimalByGenre,
            speedMultiplierForCurrentContext: speedMultiplier,
            optimalReadingWindowsByAudio: Array(bestWindows),
            surfaceableInsights: Array(insights.prefix(5)),
            audioWeatherInteraction: weatherInteraction,
            goalPaceAudioModifier: speedMultiplier,
            annualAudioReport: annualReport
        )
    }

    // MARK: - Annual Report

    /// Generates the annual audio reading summary for a specific year.
    public func generateAnnualReport(
        year: Int,
        records: [AudioSessionRecord]
    ) -> AudioAnnualReport {
        guard !records.isEmpty else {
            return AudioAnnualReport(
                year: year,
                dominantListeningCategory: .silence,
                totalEstimatedListeningTime: 0,
                silenceFraction: 1.0,
                topArtistsWhileReading: [],
                bestAudioConditionForReading: nil,
                audioImpactOnReadingSpeed: 1.0,
                audioImpactOnSessionLength: 1.0,
                dominantListeningMood: .unavailable,
                insightSummary: "No audio data available for \(year).",
                totalSessionsWithAudioData: 0
            )
        }

        let dominant = dominantAudioCategory(in: records)

        let totalListening = records.map(\.audioContext.totalAudioDuration).reduce(0, +)
        let totalSession = records.map(\.audioContext.sessionDuration).reduce(0, +)
        let silenceFraction = totalSession > 0
            ? max(0, min(1, (totalSession - totalListening) / totalSession)) : 1.0

        let allArtists = records.flatMap(\.audioContext.artistsHeard)
        let artistCounts = Dictionary(grouping: allArtists, by: { $0 }).mapValues(\.count)
        let topArtists = Array(artistCounts.sorted { $0.value > $1.value }.prefix(5).map(\.key))

        let conditionProfiles = buildConditionProfiles(from: records)
        let bestCondition = conditionProfiles.max { $0.averageSessionQuality < $1.averageSessionQuality }

        let audioRecs = records.filter(\.audioContext.wasAudioPresent)
        let silenceRecs = records.filter { !$0.audioContext.wasAudioPresent }
        let audioSpeed = audioRecs.isEmpty ? 0 : audioRecs.map(\.readingSpeed).average
        let silSpeed = silenceRecs.isEmpty ? 0 : silenceRecs.map(\.readingSpeed).average
        // Lower seconds/page = faster. speedImpact > 1 means audio context was faster.
        let speedImpact = silSpeed > 0 && audioSpeed > 0 ? silSpeed / audioSpeed : 1.0

        let audioLen = audioRecs.isEmpty ? 0 : audioRecs.map(\.readingDurationMinutes).average
        let silLen = silenceRecs.isEmpty ? 0 : silenceRecs.map(\.readingDurationMinutes).average
        let lenImpact = silLen > 0 && audioLen > 0 ? audioLen / silLen : 1.0

        let allMoods = records.flatMap { $0.audioContext.snapshots.filter(\.isPlaying).map(\.characteristics.inferredMood) }
        let moodCounts = Dictionary(grouping: allMoods, by: { $0 }).mapValues(\.count)
        let domMood = moodCounts.max(by: { $0.value < $1.value })?.key ?? .unavailable

        let summary = buildAnnualSummary(
            dominant: dominant, silenceFraction: silenceFraction,
            topArtists: topArtists, totalSessions: records.count
        )

        return AudioAnnualReport(
            year: year,
            dominantListeningCategory: dominant,
            totalEstimatedListeningTime: totalListening,
            silenceFraction: silenceFraction,
            topArtistsWhileReading: topArtists,
            bestAudioConditionForReading: bestCondition,
            audioImpactOnReadingSpeed: max(0.5, min(2.0, speedImpact)),
            audioImpactOnSessionLength: max(0.5, min(2.0, lenImpact)),
            dominantListeningMood: domMood,
            insightSummary: summary,
            totalSessionsWithAudioData: records.count
        )
    }

    // MARK: - Session Record Assembly

    /// Assembles [AudioSessionRecord] from raw DataStore data.
    /// Call this before buildAudioProfile(from:) to prepare input data.
    ///
    /// - Parameters:
    ///   - books: Books whose sessions should be included (e.g. booksRead in year).
    ///   - audioProfiles: All AudioContextProfile objects from AudioProfileStore.
    ///   - allBooks: The complete library (used for momentum calculation).
    static func buildSessionRecords(
        books: [Book],
        audioProfiles: [AudioContextProfile],
        allBooks: [Book]
    ) -> [AudioSessionRecord] {
        // Index profiles by sessionID for O(1) lookup.
        let profilesBySession = Dictionary(
            uniqueKeysWithValues: audioProfiles.map { ($0.sessionID, $0) }
        )

        // All completed sessions across the full library for frequency/momentum calculations.
        let allCompletedSessions = allBooks
            .flatMap(\.sessions)
            .filter { $0.endTime != nil }

        var records: [AudioSessionRecord] = []

        for book in books {
            for session in book.sessions where session.endTime != nil {
                // Only include sessions that have a captured audio context.
                guard let audioContext = profilesBySession[session.id] else { continue }

                let consistency = computeConsistency(session: session)
                let engagement = computeEngagement(session: session)
                let quality = (consistency * 0.55 + engagement * 0.45)
                    .clamped(to: 0 ... 1)
                let frequency = computeReadingFrequency(
                    session: session, allSessions: allCompletedSessions
                )
                let momentum = computeMomentum(
                    session: session, allSessions: allCompletedSessions
                )

                let completionProb = book.progressFraction.clamped(to: 0 ... 1)

                let chaptersCompleted = Double(book.chapters.filter { chapter in
                    chapter.startPage >= session.startPage && chapter.endPage <= session.endPage
                }.count)

                let isLastSession = book.sessions
                    .filter { $0.endTime != nil }
                    .sorted { ($0.endTime ?? .distantPast) < ($1.endTime ?? .distantPast) }
                    .last?.id == session.id
                let booksCompleted = (book.isCompleted && isLastSession) ? 1.0 : 0.0

                let sessionEnd = session.endTime ?? Date()
                let notesInWindow = book.notes.filter {
                    $0.createdAt >= session.startTime && $0.createdAt <= sessionEnd
                }.count

                let difficulty = book.difficultyProfile?.difficultyMultiplier ?? 1.0
                let complexity = min(1.0, max(0.0, (difficulty - 0.5) / 1.5))

                // reread: book was completed before this session started
                let priorCompletionExists = book.sessions.contains { s in
                    s.id != session.id &&
                        s.endTime != nil &&
                        (s.endTime! < session.startTime) &&
                        s.endPage >= (book.totalPages - 2)
                }

                records.append(AudioSessionRecord(
                    sessionID: session.id,
                    bookID: book.id,
                    timestamp: session.startTime,
                    audioContext: audioContext,
                    readingDurationMinutes: session.duration / 60.0,
                    pagesRead: Double(session.pagesRead),
                    chaptersCompleted: chaptersCompleted,
                    booksCompleted: booksCompleted,
                    readingSpeed: session.averageSecondsPerPage,
                    consistencyScore: consistency,
                    readingFrequencyScore: frequency,
                    engagementScore: engagement,
                    sessionQualityScore: quality,
                    momentumScore: momentum,
                    completionProbability: completionProb,
                    abandonmentProbability: (1.0 - completionProb).clamped(to: 0 ... 1),
                    difficultyScore: difficulty.clamped(to: 0 ... 2),
                    complexityScore: complexity,
                    bookLength: Double(book.totalPages),
                    genre: book.genre.rawValue,
                    annotationCount: notesInWindow,
                    reread: priorCompletionExists
                ))
            }
        }

        return records.sorted { $0.timestamp < $1.timestamp }
    }
}

// MARK: - Correlation Analysis

extension MusicalAnalysisEngine {
    func analyzeCategoryCorrelations(from records: [AudioSessionRecord]) -> [AudioCorrelation] {
        guard records.count >= 5 else { return [] }
        var out: [AudioCorrelation] = []
        for cat in AudioCategory.allCases {
            let metricsToTest: [ReadingBehaviorMetric] = [
                .sessionQuality, .readingDuration, .readingSpeed, .engagement,
            ]
            for metric in metricsToTest {
                if let c = binaryCorrelation(
                    records: records,
                    condition: { $0.audioContext.primaryCategory == cat },
                    metricFn: metricFn(metric),
                    factor: .audioCategory, metric: metric,
                    label: cat.rawValue
                ) {
                    out.append(c)
                }
            }
        }
        return out
    }

    func analyzeArtistCorrelations(from records: [AudioSessionRecord]) -> [AudioCorrelation] {
        guard records.count >= 5 else { return [] }
        var out: [AudioCorrelation] = []
        let artists = Set(records.flatMap(\.audioContext.artistsHeard)).filter { !$0.isEmpty }
        for artist in artists {
            guard records.filter({ $0.audioContext.artistsHeard.contains(artist) }).count >= 3
            else { continue }
            if let c = binaryCorrelation(
                records: records,
                condition: { $0.audioContext.artistsHeard.contains(artist) },
                metricFn: metricFn(.sessionQuality),
                factor: .artistIdentity, metric: .sessionQuality,
                label: artist
            ) {
                out.append(c)
            }
        }
        return out.sorted { $0.influenceScore > $1.influenceScore }
    }

    func analyzeAlbumCorrelations(from records: [AudioSessionRecord]) -> [AudioCorrelation] {
        guard records.count >= 5 else { return [] }
        var out: [AudioCorrelation] = []
        let albums = Set(records.flatMap(\.audioContext.albumsHeard)).filter { !$0.isEmpty }
        for album in albums {
            guard records.filter({ $0.audioContext.albumsHeard.contains(album) }).count >= 3
            else { continue }
            if let c = binaryCorrelation(
                records: records,
                condition: { $0.audioContext.albumsHeard.contains(album) },
                metricFn: metricFn(.sessionQuality),
                factor: .albumIdentity, metric: .sessionQuality,
                label: album
            ) {
                out.append(c)
            }
        }
        return out.sorted { $0.influenceScore > $1.influenceScore }
    }

    func analyzePlaylistCorrelations(from records: [AudioSessionRecord]) -> [AudioCorrelation] {
        guard records.count >= 5 else { return [] }
        var out: [AudioCorrelation] = []
        let playlists = Set(records.flatMap(\.audioContext.playlistsHeard)).filter { !$0.isEmpty }
        for pl in playlists {
            guard records.filter({ $0.audioContext.playlistsHeard.contains(pl) }).count >= 3
            else { continue }
            if let c = binaryCorrelation(
                records: records,
                condition: { $0.audioContext.playlistsHeard.contains(pl) },
                metricFn: metricFn(.sessionQuality),
                factor: .playlistIdentity, metric: .sessionQuality,
                label: pl
            ) {
                out.append(c)
            }
        }
        return out
    }

    func analyzeGenreCorrelations(from records: [AudioSessionRecord]) -> [AudioCorrelation] {
        guard records.count >= 5 else { return [] }
        var out: [AudioCorrelation] = []
        let genres = Set(records.flatMap(\.audioContext.genresHeard)).filter { !$0.isEmpty }
        for genre in genres {
            guard records.filter({ $0.audioContext.genresHeard.contains(genre) }).count >= 3
            else { continue }
            for metric in [ReadingBehaviorMetric.sessionQuality, .readingSpeed] {
                if let c = binaryCorrelation(
                    records: records,
                    condition: { $0.audioContext.genresHeard.contains(genre) },
                    metricFn: metricFn(metric),
                    factor: .genreCategory, metric: metric,
                    label: genre
                ) {
                    out.append(c)
                }
            }
        }
        return out.sorted { $0.influenceScore > $1.influenceScore }
    }

    func analyzeListeningPatternCorrelations(from records: [AudioSessionRecord]) -> [AudioCorrelation] {
        guard records.count >= 5 else { return [] }
        var out: [AudioCorrelation] = []
        // Listening intensity vs. quality and duration
        for metric in [ReadingBehaviorMetric.sessionQuality, .readingDuration] {
            if let c = continuousCorrelation(
                records: records,
                xFn: { $0.audioContext.listeningIntensity },
                yFn: metricFn(metric),
                factor: .listeningIntensity, metric: metric
            ) {
                out.append(c)
            }
        }
        // Track diversity vs. engagement
        if let c = continuousCorrelation(
            records: records,
            xFn: { Double($0.audioContext.trackTransitionCount) },
            yFn: metricFn(.engagement),
            factor: .trackDiversity, metric: .engagement
        ) {
            out.append(c)
        }
        // Category transition frequency vs. session quality
        if let c = continuousCorrelation(
            records: records,
            xFn: { Double($0.audioContext.categoryTransitionCount) },
            yFn: metricFn(.sessionQuality),
            factor: .transitionFrequency, metric: .sessionQuality
        ) {
            out.append(c)
        }
        return out
    }

    func analyzeSilenceCorrelations(from records: [AudioSessionRecord]) -> [AudioCorrelation] {
        guard records.count >= 5 else { return [] }
        var out: [AudioCorrelation] = []
        let metricsToTest: [ReadingBehaviorMetric] = [
            .sessionQuality, .readingDuration, .readingSpeed, .engagement,
        ]
        for metric in metricsToTest {
            if let c = continuousCorrelation(
                records: records,
                xFn: { 1.0 - $0.audioContext.listeningIntensity }, // silence fraction
                yFn: metricFn(metric),
                factor: .silenceFraction, metric: metric
            ) {
                out.append(c)
            }
        }
        return out
    }

    func analyzeTemporalCorrelations(from records: [AudioSessionRecord]) -> [AudioCorrelation] {
        guard records.count >= 5 else { return [] }
        var out: [AudioCorrelation] = []
        if let c = continuousCorrelation(
            records: records,
            xFn: { Double($0.audioContext.snapshots.first?.hourOfDay ?? 12) },
            yFn: metricFn(.sessionQuality),
            factor: .hourOfDay, metric: .sessionQuality
        ) {
            out.append(c)
        }
        if let c = continuousCorrelation(
            records: records,
            xFn: { Double($0.audioContext.snapshots.first?.dayOfWeek ?? 4) },
            yFn: metricFn(.engagement),
            factor: .dayOfWeek, metric: .engagement
        ) {
            out.append(c)
        }
        return out
    }
}

// MARK: - Profile Building

extension MusicalAnalysisEngine {
    func buildConditionProfiles(from records: [AudioSessionRecord]) -> [AudioConditionProfile] {
        AudioCategory.allCases.compactMap { cat -> AudioConditionProfile? in
            let group = records.filter { $0.audioContext.primaryCategory == cat }
            guard group.count >= 3 else { return nil }
            let conf = makeConfidence(
                sampleCount: group.count,
                recurrence: min(1.0, Double(group.count) / 30.0),
                stability: group.map(\.sessionQualityScore).average,
                consistency: group.map(\.engagementScore).average
            )
            return AudioConditionProfile(
                label: cat.displayName,
                category: cat,
                averageReadingSpeed: group.map(\.readingSpeed).average,
                averageSessionDuration: group.map(\.readingDurationMinutes).average * 60,
                averageEngagement: group.map(\.engagementScore).average,
                averageSessionQuality: group.map(\.sessionQualityScore).average,
                averageListeningIntensity: group.map(\.audioContext.listeningIntensity).average,
                completionRate: group.map(\.completionProbability).average,
                supportingSessions: group.count,
                confidence: conf
            )
        }
    }

    func identifyHighFocusConditions(
        from profiles: [AudioConditionProfile]
    ) -> [AudioConditionProfile] {
        guard !profiles.isEmpty else { return [] }
        let mean = profiles.map(\.averageSessionQuality).average
        return profiles
            .filter { $0.averageSessionQuality >= mean + 0.1 && $0.supportingSessions >= 3 }
            .sorted { $0.averageSessionQuality > $1.averageSessionQuality }
    }

    func identifyDistractionConditions(
        from profiles: [AudioConditionProfile]
    ) -> [AudioConditionProfile] {
        guard !profiles.isEmpty else { return [] }
        let mean = profiles.map(\.averageSessionQuality).average
        return profiles
            .filter { $0.averageSessionQuality <= mean - 0.1 && $0.supportingSessions >= 3 }
            .sorted { $0.averageSessionQuality < $1.averageSessionQuality }
    }

    func buildPreferredSoundtracks(
        from records: [AudioSessionRecord]
    ) -> [PreferredSoundtrackProfile] {
        let audioRecs = records.filter(\.audioContext.wasAudioPresent)
        guard !audioRecs.isEmpty else { return [] }

        let artists = Set(audioRecs.flatMap(\.audioContext.artistsHeard)).filter { !$0.isEmpty }
        return artists.compactMap { artist -> PreferredSoundtrackProfile? in
            let group = audioRecs.filter { $0.audioContext.artistsHeard.contains(artist) }
            guard group.count >= 3 else { return nil }
            let avgQ = group.map(\.sessionQualityScore).average
            let cat = dominantAudioCategory(in: group)
            let conf = makeConfidence(
                sampleCount: group.count,
                recurrence: min(1.0, Double(group.count) / 20.0),
                stability: avgQ,
                consistency: group.map(\.engagementScore).average
            )
            return PreferredSoundtrackProfile(
                label: artist,
                category: cat,
                artistName: artist,
                genreName: group.flatMap(\.audioContext.genresHeard).first,
                averageSessionQuality: avgQ,
                averageReadingSpeed: group.map(\.readingSpeed).average,
                averageSessionDuration: group.map(\.readingDurationMinutes).average * 60,
                averageEngagement: group.map(\.engagementScore).average,
                supportingSessions: group.count,
                confidence: conf
            )
        }
        .sorted { $0.averageSessionQuality > $1.averageSessionQuality }
    }

    func buildGenreSpecificEnvironments(
        from records: [AudioSessionRecord]
    ) -> [String: AudioConditionProfile] {
        var result: [String: AudioConditionProfile] = [:]
        let bookGenres = Set(records.compactMap(\.genre)).filter { !$0.isEmpty }

        for bookGenre in bookGenres {
            let genreRecs = records.filter { $0.genre == bookGenre }
            guard genreRecs.count >= 5 else { continue }

            var bestCat = AudioCategory.silence
            var bestQ = -Double.infinity

            for audioCat in AudioCategory.allCases {
                let g = genreRecs.filter { $0.audioContext.primaryCategory == audioCat }
                guard g.count >= 2 else { continue }
                let q = g.map(\.sessionQualityScore).average
                if q > bestQ {
                    bestQ = q; bestCat = audioCat
                }
            }

            let bestGroup = genreRecs.filter { $0.audioContext.primaryCategory == bestCat }
            let conf = makeConfidence(
                sampleCount: bestGroup.count,
                recurrence: min(1.0, Double(bestGroup.count) / 20.0),
                stability: bestQ, consistency: bestGroup.map(\.engagementScore).average
            )
            result[bookGenre] = AudioConditionProfile(
                label: bestCat.displayName,
                category: bestCat,
                averageReadingSpeed: bestGroup.map(\.readingSpeed).average,
                averageSessionDuration: bestGroup.map(\.readingDurationMinutes).average * 60,
                averageEngagement: bestGroup.map(\.engagementScore).average,
                averageSessionQuality: bestQ,
                averageListeningIntensity: bestGroup.map(\.audioContext.listeningIntensity).average,
                completionRate: bestGroup.map(\.completionProbability).average,
                supportingSessions: bestGroup.count,
                confidence: conf
            )
        }
        return result
    }

    func buildHourlyListeningHabits(
        from records: [AudioSessionRecord]
    ) -> [Int: AudioHourProfile] {
        let byHour = Dictionary(grouping: records) { r -> Int in
            r.audioContext.snapshots.first?.hourOfDay ?? 12
        }
        var result: [Int: AudioHourProfile] = [:]
        for (hour, group) in byHour where group.count >= 2 {
            let cats = group.map(\.audioContext.primaryCategory)
            let dominant = Dictionary(grouping: cats, by: { $0 })
                .max(by: { $0.value.count < $1.value.count })?.key ?? .silence
            let dist = Dictionary(grouping: cats, by: { $0 })
                .mapValues { Double($0.count) / Double(group.count) }
            result[hour] = AudioHourProfile(
                hour: hour,
                dominantCategory: dominant,
                categoryDistribution: dist,
                averageListeningIntensity: group.map(\.audioContext.listeningIntensity).average,
                averageReadingQuality: group.map(\.sessionQualityScore).average,
                averageReadingSpeed: group.map(\.readingSpeed).average,
                sessionCount: group.count
            )
        }
        return result
    }

    func buildBehaviorEvolution(from records: [AudioSessionRecord]) -> AudioBehaviorEvolution {
        guard records.count >= 20 else { return .insufficient }
        let sorted = records.sorted { $0.timestamp < $1.timestamp }
        let half = sorted.count / 2
        let early = Array(sorted.prefix(half))
        let recent = Array(sorted.suffix(half))

        let oldCat = dominantAudioCategory(in: early)
        let newCat = dominantAudioCategory(in: recent)

        let oldIntensity = early.map(\.audioContext.listeningIntensity).average
        let newIntensity = recent.map(\.audioContext.listeningIntensity).average
        let intensityTrend = newIntensity - oldIntensity

        let oldSwitches = early.map { Double($0.audioContext.categoryTransitionCount) }.average
        let newSwitches = recent.map { Double($0.audioContext.categoryTransitionCount) }.average
        let switchTrend = newSwitches - oldSwitches

        let state: BehaviorEvolutionState
        if abs(intensityTrend) < 0.05 && oldCat == newCat {
            state = .stable
        } else if intensityTrend > 0.10 {
            state = .strengthening
        } else if intensityTrend < -0.10 {
            state = .weakening
        } else if oldCat != newCat {
            state = .evolving
        } else {
            state = .stable
        }

        let shift: String? = oldCat != newCat
            ? "You've shifted from \(oldCat.displayName.lowercased()) to \(newCat.displayName.lowercased()) while reading."
            : abs(intensityTrend) >= 0.15
            ? "You're reading with \(intensityTrend > 0 ? "more" : "less") audio present over time (\(String(format: "%+.0f%%", intensityTrend * 100)))."
            : nil

        return AudioBehaviorEvolution(
            hasMeaningfulData: true,
            dominantShiftDescription: shift,
            oldDominantCategory: oldCat,
            newDominantCategory: newCat,
            listeningIntensityTrend: intensityTrend,
            categorySwitchTrend: switchTrend,
            evolutionState: state
        )
    }

    func buildAudioWeatherInteraction(
        audioRecords: [AudioSessionRecord],
        weatherRecords: [WeatherAnalysisEngine.EnvironmentalSessionRecord]
    ) -> AudioWeatherInteraction? {
        guard audioRecords.count >= 5, !weatherRecords.isEmpty else { return nil }

        let weatherBySession = Dictionary(
            uniqueKeysWithValues: weatherRecords.map { ($0.sessionID, $0) }
        )

        // Joined pairs: (audio, conditionLabel, tempCelsius)
        struct Joined {
            let audio: AudioSessionRecord
            let conditionLabel: String // String(describing:) for safe enum case access
            let tempCelsius: Double
        }

        let joined: [Joined] = audioRecords.compactMap { audio in
            guard let env = weatherBySession[audio.sessionID] else { return nil }
            return Joined(
                audio: audio,
                conditionLabel: String(describing: env.weather.condition).lowercased(),
                tempCelsius: env.weather.temperatureCelsius
            )
        }
        guard joined.count >= 5 else { return nil }

        let rainy = joined.filter {
            $0.conditionLabel.contains("rain") || $0.conditionLabel.contains("drizzle")
        }.map(\.audio)
        let clear = joined.filter {
            $0.conditionLabel.contains("clear") || $0.conditionLabel.contains("sun")
        }.map(\.audio)
        let cold = joined.filter { $0.tempCelsius < 10 }.map(\.audio)
        let warm = joined.filter { $0.tempCelsius > 20 }.map(\.audio)

        return AudioWeatherInteraction(
            rainyDayPreferredCategory: rainy.isEmpty ? nil : dominantAudioCategory(in: rainy),
            clearDayPreferredCategory: clear.isEmpty ? nil : dominantAudioCategory(in: clear),
            coldWeatherPreferredCategory: cold.isEmpty ? nil : dominantAudioCategory(in: cold),
            warmWeatherPreferredCategory: warm.isEmpty ? nil : dominantAudioCategory(in: warm),
            supportingSessions: joined.count
        )
    }
}

// MARK: - Statistical Core

extension MusicalAnalysisEngine {
    func continuousCorrelation(
        records: [AudioSessionRecord],
        xFn: (AudioSessionRecord) -> Double,
        yFn: (AudioSessionRecord) -> Double,
        factor: AudioFactor,
        metric: ReadingBehaviorMetric
    ) -> AudioCorrelation? {
        guard records.count >= 5 else { return nil }
        let x = records.map(xFn)
        let y = records.map(yFn)
        let r = pearson(x, y)
        let sig = significance(n: records.count, r: r)
        let inf = abs(r) * sig
        guard inf > 0.05 else { return nil }
        let conf = makeConfidence(
            sampleCount: records.count, recurrence: sig,
            stability: abs(r), consistency: consistency(x, y)
        )
        return AudioCorrelation(
            factor: factor, metric: metric,
            coefficient: r, significance: sig, influenceScore: inf,
            lifecycle: lifecycle(r: r, sig: sig), confidence: conf,
            firstObserved: records.first?.timestamp ?? Date(),
            lastObserved: records.last?.timestamp ?? Date(),
            supportingSampleCount: records.count
        )
    }

    func binaryCorrelation(
        records: [AudioSessionRecord],
        condition: (AudioSessionRecord) -> Bool,
        metricFn: (AudioSessionRecord) -> Double,
        factor: AudioFactor,
        metric: ReadingBehaviorMetric,
        label: String?
    ) -> AudioCorrelation? {
        guard records.count >= 5 else { return nil }
        let trueG = records.filter(condition)
        let falseG = records.filter { !condition($0) }
        guard !trueG.isEmpty, !falseG.isEmpty else { return nil }
        let tA = trueG.map(metricFn).average
        let fA = falseG.map(metricFn).average
        let denom = max(tA + fA, 1e-6)
        let r = (tA - fA) / denom
        let sig = significance(n: records.count, r: r)
        let inf = abs(r) * sig
        guard inf > 0.05 else { return nil }
        let conf = makeConfidence(
            sampleCount: records.count, recurrence: sig, stability: abs(r), consistency: 0.7
        )
        return AudioCorrelation(
            factor: factor, metric: metric,
            coefficient: r, significance: sig, influenceScore: inf,
            lifecycle: lifecycle(r: r, sig: sig), confidence: conf,
            firstObserved: records.first?.timestamp ?? Date(),
            lastObserved: records.last?.timestamp ?? Date(),
            supportingSampleCount: records.count,
            contextLabel: label
        )
    }

    func pearson(_ x: [Double], _ y: [Double]) -> Double {
        guard x.count == y.count, x.count > 1 else { return 0 }
        let n = Double(x.count)
        let sx = x.reduce(0, +); let sy = y.reduce(0, +)
        let sxy = zip(x, y).map(*).reduce(0, +)
        let sx2 = x.map { $0 * $0 }.reduce(0, +)
        let sy2 = y.map { $0 * $0 }.reduce(0, +)
        let num = n * sxy - sx * sy
        let den = sqrt((n * sx2 - sx * sx) * (n * sy2 - sy * sy))
        return den == 0 ? 0 : (num / den).clamped(to: -1 ... 1)
    }

    func significance(n: Int, r: Double) -> Double {
        let base = min(1.0, Double(n) / 50.0)
        let strength = abs(r)
        return (base * 0.6 + strength * 0.4).clamped(to: 0 ... 1)
    }

    func consistency(_ x: [Double], _: [Double]) -> Double {
        guard x.count > 2 else { return 0.5 }
        let diffs = zip(x.dropFirst(), x).map { abs($0 - $1) }
        return 1.0 / (1.0 + diffs.average)
    }

    func lifecycle(r: Double, sig: Double) -> CorrelationLifecycle {
        let s = abs(r)
        if sig < 0.2 {
            return .temporary
        }
        if s > 0.8 && sig > 0.7 {
            return .persistent
        }
        if s > 0.6 {
            return .strengthening
        }
        if s > 0.4 {
            return .stable
        }
        if s > 0.2 {
            return .weakening
        }
        return .emerging
    }

    func makeConfidence(
        sampleCount: Int,
        recurrence: Double,
        stability: Double,
        consistency: Double
    ) -> ConfidenceReport {
        let sampleScore = min(1.0, Double(sampleCount) / 100.0)
        let overall = ((sampleScore + recurrence + stability + consistency) / 4.0)
            .clamped(to: 0 ... 1)
        return ConfidenceReport(
            overallConfidence: overall,
            sampleSizeScore: sampleScore,
            recurrenceScore: recurrence.clamped(to: 0 ... 1),
            stabilityScore: stability.clamped(to: 0 ... 1),
            consistencyScore: consistency.clamped(to: 0 ... 1),
            dataCoverageScore: 1.0,
            supportingSamples: sampleCount
        )
    }
}

// MARK: - Private Helpers

extension MusicalAnalysisEngine {
    private func metricFn(_ metric: ReadingBehaviorMetric) -> (AudioSessionRecord) -> Double {
        switch metric {
        case .readingDuration: return { $0.readingDurationMinutes }
        case .pagesRead: return { $0.pagesRead }
        case .chaptersCompleted: return { $0.chaptersCompleted }
        case .booksCompleted: return { $0.booksCompleted }
        case .readingSpeed: return { $0.readingSpeed }
        case .readingConsistency: return { $0.consistencyScore }
        case .readingFrequency: return { $0.readingFrequencyScore }
        case .engagement: return { $0.engagementScore }
        case .sessionQuality: return { $0.sessionQualityScore }
        case .momentum: return { $0.momentumScore }
        case .completionLikelihood: return { $0.completionProbability }
        case .abandonmentLikelihood: return { $0.abandonmentProbability }
        case .difficulty: return { $0.difficultyScore }
        case .complexity: return { $0.complexityScore }
        case .bookLength: return { $0.bookLength }
        case .rereadingBehavior: return { $0.reread ? 1.0 : 0.0 }
        default: return { _ in 0 }
        }
    }

    private func computeSpeedMultiplier(
        currentContext: AudioContextProfile?,
        profile: AudioReadingProfile,
        records _: [AudioSessionRecord]
    ) -> Double {
        guard let ctx = currentContext else { return 1.0 }
        let cat = ctx.primaryCategory
        // Find binary correlation for this category vs. reading speed
        if let cor = profile.audioCategoryCorrelations.first(where: {
            $0.factor == .audioCategory &&
                $0.metric == .readingSpeed &&
                $0.contextLabel == cat.rawValue
        }) {
            // coefficient > 0 → faster reading speed with this category
            // Lower seconds/page = faster, so negative coefficient = faster
            return max(0.7, min(1.3, 1.0 - (cor.coefficient * 0.2)))
        }
        return 1.0
    }

    private func dominantAudioCategory(in records: [AudioSessionRecord]) -> AudioCategory {
        let cats = records.map(\.audioContext.primaryCategory)
        return Dictionary(grouping: cats, by: { $0 })
            .max(by: { $0.value.count < $1.value.count })?.key ?? .silence
    }

    private func buildAnnualSummary(
        dominant: AudioCategory,
        silenceFraction: Double,
        topArtists: [String],
        totalSessions: Int
    ) -> String {
        let audioPct = Int((1.0 - silenceFraction) * 100)
        let silPct = Int(silenceFraction * 100)
        if silenceFraction > 0.7 {
            return "You primarily read in silence in \(totalSessions) sessions (\(silPct)% of your reading time). Quiet is your natural reading state."
        }
        if dominant == .music, let first = topArtists.first {
            return "Music accompanied \(audioPct)% of your reading sessions. \(first) was your most frequent reading companion."
        }
        if dominant == .podcast {
            return "Podcasts or spoken-word content played during \(audioPct)% of your reading sessions."
        }
        return "Audio was present during \(audioPct)% of your sessions, primarily as \(dominant.displayName.lowercased())."
    }

    private static func computeConsistency(session: ReadingSession) -> Double {
        let durations = session.pageTimes.compactMap { t -> Double? in
            guard let end = t.endTime else { return nil }
            let d = end.timeIntervalSince(t.startTime)
            return d > 0 ? d : nil
        }
        guard durations.count > 1 else { return 0.5 }
        let mean = durations.reduce(0, +) / Double(durations.count)
        guard mean > 0 else { return 0.5 }
        let variance = durations.map { pow($0 - mean, 2) }.reduce(0, +) / Double(durations.count)
        let cv = sqrt(variance) / mean // coefficient of variation
        return max(0, 1.0 - min(1.0, cv)).clamped(to: 0 ... 1)
    }

    private static func computeEngagement(session: ReadingSession) -> Double {
        // 60 minutes = 1.0; 30 minutes = 0.5; scales linearly.
        let durationScore = min(1.0, session.duration / 3600.0)
        // Pages read contribution: 30 pages ≈ a good session.
        let pagesScore = min(1.0, Double(session.pagesRead) / 30.0)
        return (durationScore * 0.6 + pagesScore * 0.4).clamped(to: 0 ... 1)
    }

    private static func computeReadingFrequency(
        session: ReadingSession,
        allSessions: [ReadingSession]
    ) -> Double {
        let windowStart = session.startTime.addingTimeInterval(-7 * 86400)
        let recent = allSessions.filter {
            $0.endTime != nil &&
                $0.startTime >= windowStart &&
                $0.startTime < session.startTime
        }
        return min(1.0, Double(recent.count) / 7.0)
    }

    private static func computeMomentum(
        session: ReadingSession,
        allSessions: [ReadingSession]
    ) -> Double {
        let windowStart = session.startTime.addingTimeInterval(-7 * 86400)
        let recentDays = Set(
            allSessions.filter {
                $0.endTime != nil &&
                    $0.startTime >= windowStart &&
                    $0.startTime < session.startTime
            }.map { Calendar.current.startOfDay(for: $0.startTime) }
        )
        return min(1.0, Double(recentDays.count) / 7.0)
    }
}

// MARK: - Formatting helper

private extension Date {
    /// Returns a new date by subtracting the given number of seconds.
    func subtracting(seconds: TimeInterval) -> Date {
        addingTimeInterval(-seconds)
    }
}
