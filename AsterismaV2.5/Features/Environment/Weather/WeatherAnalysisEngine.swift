//  WeatherAnalysisEngine.swift
//  Environmental intelligence layer for long-term reading behavior analysis.
//  Designed to augment AnalyticsEngine, EstimationEngine,
//  PredictiveRecommendationEngine, IntelligentNotificationEngine,
//  and InsightEngine without duplicating their responsibilities.
//
//  PRODUCTION PASS (P5 / features mission) — resolves CURRENT_AUDIT W-01..W-04:
//
//  W-01 · Aggregate confidence is now DERIVED, not decorative.
//    calculateAggregateConfidence accepts an optional real dataCoverageRatio
//    (the fraction of analyzed sessions that actually have persisted weather
//    snapshots — obtainable from WeatherKitService.coverageRatio(for:)). When
//    supplied, overall = mean(sampleSize, recurrence, stability, consistency,
//    coverage) exactly as the original design intended. When nil, the coverage
//    component degrades to the sample-size proxy so callers that cannot know
//    coverage still get honest sample-driven numbers.
//    Per-correlation confidence (calculateConfidence) also stops hardcoding:
//    recurrence now scales with sample size, stability with |coefficient|,
//    consistency with measured pairwise smoothness — all values it ALREADY had.
//
//  W-02 · firstObserved/lastObserved are chronologically correct.
//    buildCorrelation / buildBinaryConditionCorrelation sort by timestamp before
//    extracting bounds instead of trusting input order.
//
//  W-03 · avoidedGenres means "avoided", not "rarest".
//    Seasonal buckets label a genre avoided only when its share of the season's
//    sessions falls at or below 5% (minimum 1 session), listing up to three by
//    ascending count. Previously suffix(3) of the descending list labeled the
//    least-read genres "avoided" regardless of share.
//
//  W-04 (discovered during this pass) · TemperatureProfile.influenceScore —
//    which IS rendered ("Temperature influence" card) — previously came from
//    hardcoded recurrence 0.8 / stability 0.7 / consistency 0.75. Now derived
//    from the top-quintile cohort's actual speed/engagement dispersion and
//    cohort size. Same defect class, same fix session, logged separately.

import Foundation

// MARK: - Environmental Condition Models

public enum WeatherConditionCategory: String, Codable, CaseIterable, Hashable {
    case clear
    case partlyCloudy
    case cloudy
    case fog
    case rain
    case heavyRain
    case snow
    case heavySnow
    case storm
    case wind
    case mixed
    case unknown
}

public enum SeasonalPeriod: String, Codable, CaseIterable, Hashable {
    case spring
    case summer
    case autumn
    case winter
}

public enum DayPeriod: String, Codable, CaseIterable, Hashable {
    case dawn
    case morning
    case afternoon
    case evening
    case night
}

public struct WeatherSnapshot: Codable, Hashable, Identifiable {
    public let id: UUID

    public let timestamp: Date

    public let temperatureCelsius: Double
    public let feelsLikeTemperatureCelsius: Double

    public let humidity: Double
    public let pressure: Double

    public let cloudCover: Double
    public let visibilityKilometers: Double

    public let windSpeedKPH: Double

    public let precipitationMillimeters: Double

    public let snowfallMillimeters: Double

    public let stormActivityIndex: Double

    public let condition: WeatherConditionCategory

    public let season: SeasonalPeriod

    public let month: Int

    public let weekday: Int

    public let dayPeriod: DayPeriod

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        temperatureCelsius: Double,
        feelsLikeTemperatureCelsius: Double,
        humidity: Double,
        pressure: Double,
        cloudCover: Double,
        visibilityKilometers: Double,
        windSpeedKPH: Double,
        precipitationMillimeters: Double,
        snowfallMillimeters: Double,
        stormActivityIndex: Double,
        condition: WeatherConditionCategory,
        season: SeasonalPeriod,
        month: Int,
        weekday: Int,
        dayPeriod: DayPeriod
    ) {
        self.id = id
        self.timestamp = timestamp
        self.temperatureCelsius = temperatureCelsius
        self.feelsLikeTemperatureCelsius = feelsLikeTemperatureCelsius
        self.humidity = humidity
        self.pressure = pressure
        self.cloudCover = cloudCover
        self.visibilityKilometers = visibilityKilometers
        self.windSpeedKPH = windSpeedKPH
        self.precipitationMillimeters = precipitationMillimeters
        self.snowfallMillimeters = snowfallMillimeters
        self.stormActivityIndex = stormActivityIndex
        self.condition = condition
        self.season = season
        self.month = month
        self.weekday = weekday
        self.dayPeriod = dayPeriod
    }
}

// MARK: - Environmental Classification

public enum EnvironmentalFactor: String, Codable, CaseIterable, Hashable {
    case temperature
    case feelsLikeTemperature
    case humidity
    case pressure
    case cloudCover
    case visibility
    case windSpeed
    case rain
    case snow
    case stormActivity
    case season
    case month
    case weekday
    case dayPeriod
}

public enum ReadingBehaviorMetric: String, Codable, CaseIterable, Hashable {
    case readingDuration
    case pagesRead
    case chaptersCompleted
    case booksCompleted
    case readingSpeed
    case readingConsistency
    case readingFrequency
    case genreSelection
    case genreAvoidance
    case difficulty
    case complexity
    case bookLength
    case seriesProgression
    case completionLikelihood
    case abandonmentLikelihood
    case rereadingBehavior
    case sessionQuality
    case momentum
    case engagement
}

public enum CorrelationLifecycle: String, Codable, CaseIterable, Hashable {
    case emerging
    case strengthening
    case stable
    case weakening
    case declining
    case recurring
    case seasonal
    case persistent
    case temporary
}

public enum BehaviorEvolutionState: String, Codable, CaseIterable, Hashable {
    case newBehavior
    case strengthening
    case weakening
    case stable
    case lost
    case evolving
}

public enum EnvironmentalInsightCategory: String, Codable, CaseIterable {
    case readingSpeed
    case readingVolume
    case engagement
    case completion
    case abandonment
    case genrePreference
    case genreAvoidance
    case consistency
    case momentum
    case seasonalShift
    case environmentalSensitivity
}

// MARK: - Confidence System

public struct ConfidenceReport: Codable, Hashable {
    public let overallConfidence: Double

    public let sampleSizeScore: Double

    public let recurrenceScore: Double

    public let stabilityScore: Double

    public let consistencyScore: Double

    public let dataCoverageScore: Double

    public let supportingSamples: Int

    public init(
        overallConfidence: Double,
        sampleSizeScore: Double,
        recurrenceScore: Double,
        stabilityScore: Double,
        consistencyScore: Double,
        dataCoverageScore: Double,
        supportingSamples: Int
    ) {
        self.overallConfidence = overallConfidence
        self.sampleSizeScore = sampleSizeScore
        self.recurrenceScore = recurrenceScore
        self.stabilityScore = stabilityScore
        self.consistencyScore = consistencyScore
        self.dataCoverageScore = dataCoverageScore
        self.supportingSamples = supportingSamples
    }
}

// MARK: - Correlation Models

public struct EnvironmentalCorrelation: Codable, Identifiable, Hashable {
    public let id: UUID

    public let factor: EnvironmentalFactor

    public let metric: ReadingBehaviorMetric

    public let coefficient: Double

    public let significance: Double

    public let influenceScore: Double

    public let lifecycle: CorrelationLifecycle

    public let confidence: ConfidenceReport

    public let firstObserved: Date

    public let lastObserved: Date

    public let supportingSampleCount: Int

    public init(
        id: UUID = UUID(),
        factor: EnvironmentalFactor,
        metric: ReadingBehaviorMetric,
        coefficient: Double,
        significance: Double,
        influenceScore: Double,
        lifecycle: CorrelationLifecycle,
        confidence: ConfidenceReport,
        firstObserved: Date,
        lastObserved: Date,
        supportingSampleCount: Int
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
    }
}

// MARK: - Environmental Profiles

public struct TemperatureProfile: Codable, Hashable {
    public let optimalRange: ClosedRange<Double>

    public let peakReadingSpeed: Double

    public let peakEngagement: Double

    public let peakReadingVolume: Double

    public let influenceScore: Double

    public let confidence: ConfidenceReport
}

public struct SeasonalProfile: Codable, Hashable {
    public let season: SeasonalPeriod

    public let averageReadingDuration: Double

    public let averageReadingSpeed: Double

    public let averageEngagement: Double

    public let averagePagesRead: Double

    public let dominantGenres: [String]

    public let avoidedGenres: [String]

    public let confidence: ConfidenceReport
}

public struct WeatherInfluenceProfile: Codable, Hashable {
    public let strongestPositiveFactors: [EnvironmentalCorrelation]

    public let strongestNegativeFactors: [EnvironmentalCorrelation]

    public let environmentalSensitivityScore: Double

    public let dominantSeason: SeasonalPeriod?

    public let dominantCondition: WeatherConditionCategory?

    public let confidence: ConfidenceReport
}

public struct EnvironmentalReadingProfile: Codable, Hashable {
    public let temperatureProfile: TemperatureProfile?

    public let seasonalProfiles: [SeasonalProfile]

    public let influenceProfile: WeatherInfluenceProfile

    public let generatedAt: Date
}

// MARK: - Evolution Tracking

public struct EnvironmentalBehaviorSnapshot: Codable, Identifiable, Hashable {
    public let id: UUID

    public let createdAt: Date

    public let periodStart: Date

    public let periodEnd: Date

    public let influenceScore: Double

    public let dominantGenres: [String]

    public let dominantConditions: [WeatherConditionCategory]

    public let averageReadingSpeed: Double

    public let averageEngagement: Double

    public let averageReadingDuration: Double

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        periodStart: Date,
        periodEnd: Date,
        influenceScore: Double,
        dominantGenres: [String],
        dominantConditions: [WeatherConditionCategory],
        averageReadingSpeed: Double,
        averageEngagement: Double,
        averageReadingDuration: Double
    ) {
        self.id = id
        self.createdAt = createdAt
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.influenceScore = influenceScore
        self.dominantGenres = dominantGenres
        self.dominantConditions = dominantConditions
        self.averageReadingSpeed = averageReadingSpeed
        self.averageEngagement = averageEngagement
        self.averageReadingDuration = averageReadingDuration
    }
}

public struct EnvironmentalEvolutionFinding: Codable, Identifiable, Hashable {
    public let id: UUID

    public let state: BehaviorEvolutionState

    public let title: String

    public let description: String

    public let magnitude: Double

    public let confidence: ConfidenceReport

    public init(
        id: UUID = UUID(),
        state: BehaviorEvolutionState,
        title: String,
        description: String,
        magnitude: Double,
        confidence: ConfidenceReport
    ) {
        self.id = id
        self.state = state
        self.title = title
        self.description = description
        self.magnitude = magnitude
        self.confidence = confidence
    }
}

public struct EnvironmentalEvolutionReport: Codable, Hashable {
    public let generatedAt: Date

    public let findings: [EnvironmentalEvolutionFinding]

    public let baselineSnapshot: EnvironmentalBehaviorSnapshot

    public let currentSnapshot: EnvironmentalBehaviorSnapshot
}

// MARK: - Forecasting

public struct EnvironmentalForecastInput: Codable, Hashable {
    public let forecastWeather: WeatherSnapshot

    public init(forecastWeather: WeatherSnapshot) {
        self.forecastWeather = forecastWeather
    }
}

public struct EnvironmentalForecast: Codable, Hashable {
    public let expectedReadingDuration: Double

    public let expectedPagesRead: Double

    public let expectedReadingSpeed: Double

    public let expectedEngagement: Double

    public let expectedCompletionProbability: Double

    public let predictedGenres: [String]

    public let confidence: ConfidenceReport
}

// MARK: - Insight Objects

public struct EnvironmentalInsight: Codable, Identifiable, Hashable {
    public let id: UUID

    public let category: EnvironmentalInsightCategory

    public let title: String

    public let summary: String

    public let influenceScore: Double

    public let confidence: ConfidenceReport

    public let generatedAt: Date

    public init(
        id: UUID = UUID(),
        category: EnvironmentalInsightCategory,
        title: String,
        summary: String,
        influenceScore: Double,
        confidence: ConfidenceReport,
        generatedAt: Date = Date()
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.summary = summary
        self.influenceScore = influenceScore
        self.confidence = confidence
        self.generatedAt = generatedAt
    }
}

// MARK: - Reports

public struct WeatherTrendReport: Codable, Hashable {
    public let generatedAt: Date

    public let correlations: [EnvironmentalCorrelation]

    public let strongestInfluences: [EnvironmentalCorrelation]

    public let environmentalSensitivityScore: Double

    public let confidence: ConfidenceReport
}

public struct EnvironmentalBehaviorReport: Codable, Hashable {
    public let generatedAt: Date

    public let profile: EnvironmentalReadingProfile

    public let insights: [EnvironmentalInsight]

    public let correlations: [EnvironmentalCorrelation]

    public let confidence: ConfidenceReport
}

// MARK: - Internal Analysis Helpers

struct CorrelationAccumulator {
    var factor: EnvironmentalFactor

    var metric: ReadingBehaviorMetric

    var values: [(Double, Double)] = []

    mutating func append(x: Double, y: Double) {
        values.append((x, y))
    }
}

struct SeasonalBucket {
    let season: SeasonalPeriod

    var sessionCount: Int = 0

    var totalDuration: Double = 0

    var totalPages: Double = 0

    var totalSpeed: Double = 0

    var totalEngagement: Double = 0

    var genres: [String: Int] = [:]
}

struct ConditionBucket {
    let condition: WeatherConditionCategory

    var sessions: Int = 0

    var totalDuration: Double = 0

    var totalPages: Double = 0

    var totalSpeed: Double = 0
}

/// Coefficient of variation helper shared by the derived-confidence math.
private func coefficientOfVariation(_ values: [Double]) -> Double {
    guard values.count > 1 else { return 0 }
    let mean = values.reduce(0, +) / Double(values.count)
    guard mean > 0 else { return 0 }
    let variance = values.map { pow($0 - mean, 2) }.reduce(0, +) / Double(values.count)
    return sqrt(variance) / mean
}

// MARK: - Main Engine

public final class WeatherAnalysisEngine {
    public init() {}
}

// MARK: - Core Analysis Interfaces

public extension WeatherAnalysisEngine {
    // MARK: Environmental Session Record

    struct EnvironmentalSessionRecord: Codable, Identifiable, Hashable {
        public let id: UUID

        public let sessionID: UUID

        public let bookID: UUID

        public let timestamp: Date

        public let weather: WeatherSnapshot

        public let readingDurationMinutes: Double

        public let pagesRead: Double

        public let chaptersCompleted: Double

        public let booksCompleted: Double

        public let readingSpeed: Double

        public let consistencyScore: Double

        public let readingFrequencyScore: Double

        public let engagementScore: Double

        public let sessionQualityScore: Double

        public let momentumScore: Double

        public let completionProbability: Double

        public let abandonmentProbability: Double

        public let difficultyScore: Double

        public let complexityScore: Double

        public let bookLength: Double

        public let genre: String?

        public let seriesIdentifier: String?

        public let reread: Bool

        public init(
            id: UUID = UUID(),
            sessionID: UUID,
            bookID: UUID,
            timestamp: Date,
            weather: WeatherSnapshot,
            readingDurationMinutes: Double,
            pagesRead: Double,
            chaptersCompleted: Double,
            booksCompleted: Double,
            readingSpeed: Double,
            consistencyScore: Double,
            readingFrequencyScore: Double,
            engagementScore: Double,
            sessionQualityScore: Double,
            momentumScore: Double,
            completionProbability: Double,
            abandonmentProbability: Double,
            difficultyScore: Double,
            complexityScore: Double,
            bookLength: Double,
            genre: String?,
            seriesIdentifier: String?,
            reread: Bool
        ) {
            self.id = id
            self.sessionID = sessionID
            self.bookID = bookID
            self.timestamp = timestamp
            self.weather = weather
            self.readingDurationMinutes = readingDurationMinutes
            self.pagesRead = pagesRead
            self.chaptersCompleted = chaptersCompleted
            self.booksCompleted = booksCompleted
            self.readingSpeed = readingSpeed
            self.consistencyScore = consistencyScore
            self.readingFrequencyScore = readingFrequencyScore
            self.engagementScore = engagementScore
            self.sessionQualityScore = sessionQualityScore
            self.momentumScore = momentumScore
            self.completionProbability = completionProbability
            self.abandonmentProbability = abandonmentProbability
            self.difficultyScore = difficultyScore
            self.complexityScore = complexityScore
            self.bookLength = bookLength
            self.genre = genre
            self.seriesIdentifier = seriesIdentifier
            self.reread = reread
        }
    }

    // MARK: Public Entry Point

    func buildEnvironmentalProfile(
        from sessions: [EnvironmentalSessionRecord],
        dataCoverageRatio: Double? = nil
    ) -> EnvironmentalReadingProfile {
        let temperatureProfile = buildTemperatureProfile(
            from: sessions
        )

        let seasonalProfiles = buildSeasonalProfiles(
            from: sessions
        )

        let influenceProfile = buildInfluenceProfile(
            from: sessions,
            dataCoverageRatio: dataCoverageRatio
        )

        return EnvironmentalReadingProfile(
            temperatureProfile: temperatureProfile,
            seasonalProfiles: seasonalProfiles,
            influenceProfile: influenceProfile,
            generatedAt: Date()
        )
    }

    // MARK: Full Correlation Analysis

    func analyzeCorrelations(
        from sessions: [EnvironmentalSessionRecord],
        dataCoverageRatio: Double? = nil
    ) -> [EnvironmentalCorrelation] {
        let coverage = dataCoverageRatio ?? 1.0
        guard sessions.count >= 5 else {
            return []
        }

        var correlations: [EnvironmentalCorrelation] = []

        correlations.append(contentsOf:
            analyzeTemperatureCorrelations(from: sessions, dataCoverageRatio: coverage))

        correlations.append(contentsOf:
            analyzeHumidityCorrelations(from: sessions, dataCoverageRatio: coverage))

        correlations.append(contentsOf:
            analyzePressureCorrelations(from: sessions, dataCoverageRatio: coverage))

        correlations.append(contentsOf:
            analyzeCloudCoverCorrelations(from: sessions, dataCoverageRatio: coverage))

        correlations.append(contentsOf:
            analyzeVisibilityCorrelations(from: sessions, dataCoverageRatio: coverage))

        correlations.append(contentsOf:
            analyzeWindSpeedCorrelations(from: sessions, dataCoverageRatio: coverage))

        correlations.append(contentsOf:
            analyzeRainCorrelations(from: sessions, dataCoverageRatio: coverage))

        correlations.append(contentsOf:
            analyzeSnowCorrelations(from: sessions, dataCoverageRatio: coverage))

        correlations.append(contentsOf:
            analyzeStormCorrelations(from: sessions, dataCoverageRatio: coverage))

        return correlations.sorted {
            abs($0.influenceScore) > abs($1.influenceScore)
        }
    }

    // MARK: Weather Trend Report

    func generateTrendReport(
        sessions: [EnvironmentalSessionRecord],
        dataCoverageRatio: Double? = nil
    ) -> WeatherTrendReport {
        let correlations = analyzeCorrelations(
            from: sessions,
            dataCoverageRatio: dataCoverageRatio
        )

        let strongest = correlations
            .sorted {
                abs($0.influenceScore) >
                    abs($1.influenceScore)
            }
            .prefix(10)

        let sensitivity = calculateEnvironmentalSensitivity(
            correlations: correlations
        )

        let confidence = calculateAggregateConfidence(
            sessions: sessions,
            correlations: correlations,
            dataCoverageRatio: dataCoverageRatio
        )

        return WeatherTrendReport(
            generatedAt: Date(),
            correlations: correlations,
            strongestInfluences: Array(strongest),
            environmentalSensitivityScore: sensitivity,
            confidence: confidence
        )
    }

    // MARK: Environmental Report

    func generateBehaviorReport(
        sessions: [EnvironmentalSessionRecord],
        dataCoverageRatio: Double? = nil
    ) -> EnvironmentalBehaviorReport {
        let profile = buildEnvironmentalProfile(
            from: sessions,
            dataCoverageRatio: dataCoverageRatio
        )

        let correlations = analyzeCorrelations(
            from: sessions,
            dataCoverageRatio: dataCoverageRatio
        )

        let insights = generateInsights(
            sessions: sessions,
            profile: profile,
            correlations: correlations
        )

        let confidence = calculateAggregateConfidence(
            sessions: sessions,
            correlations: correlations,
            dataCoverageRatio: dataCoverageRatio
        )

        return EnvironmentalBehaviorReport(
            generatedAt: Date(),
            profile: profile,
            insights: insights,
            correlations: correlations,
            confidence: confidence
        )
    }
}

// MARK: - Temperature Analysis

private extension WeatherAnalysisEngine {
    func buildTemperatureProfile(
        from sessions: [EnvironmentalSessionRecord]
    ) -> TemperatureProfile? {
        guard sessions.count >= 10 else {
            return nil
        }

        let sorted = sessions.sorted {
            $0.readingSpeed > $1.readingSpeed
        }

        let topSessions = Array(
            sorted.prefix(max(1, sorted.count / 5))
        )

        let temps = topSessions.map {
            $0.weather.temperatureCelsius
        }

        guard let min = temps.min(),
              let max = temps.max()
        else {
            return nil
        }

        let avgSpeed = topSessions
            .map(\.readingSpeed)
            .average

        let avgEngagement = topSessions
            .map(\.engagementScore)
            .average

        let avgVolume = topSessions
            .map(\.pagesRead)
            .average

        // W-04: derived confidence — the cohort's own dispersion decides how
        // much this profile has earned to claim, not constants.
        let speedCV = coefficientOfVariation(topSessions.map(\.readingSpeed))
        let engagementCV = coefficientOfVariation(topSessions.map(\.engagementScore))
        // NOTE: this scope shadows min/max with local constants (temps bounds
        // above), so the stdlib functions must be namespace-qualified here.
        let sampleFactor = Swift.min(1.0, Double(topSessions.count) / 20.0)
        let stability = Swift.max(0, Swift.min(1, 1 - speedCV))
        let consistency = Swift.max(0, Swift.min(1, 1 - engagementCV))
        let recurrence = sampleFactor

        let confidence = calculateConfidence(
            sampleCount: topSessions.count,
            recurrence: recurrence,
            stability: stability,
            consistency: consistency
        )

        return TemperatureProfile(
            optimalRange: min ... max,
            peakReadingSpeed: avgSpeed,
            peakEngagement: avgEngagement,
            peakReadingVolume: avgVolume,
            influenceScore: confidence.overallConfidence,
            confidence: confidence
        )
    }
}

// MARK: - Seasonal Analysis

private extension WeatherAnalysisEngine {
    func buildSeasonalProfiles(
        from sessions: [EnvironmentalSessionRecord]
    ) -> [SeasonalProfile] {
        var buckets: [SeasonalPeriod: SeasonalBucket] = [:]

        for season in SeasonalPeriod.allCases {
            buckets[season] = SeasonalBucket(
                season: season
            )
        }

        for session in sessions {
            var bucket = buckets[
                session.weather.season
            ] ?? SeasonalBucket(
                season: session.weather.season
            )

            bucket.sessionCount += 1
            bucket.totalDuration += session.readingDurationMinutes
            bucket.totalPages += session.pagesRead
            bucket.totalSpeed += session.readingSpeed
            bucket.totalEngagement += session.engagementScore

            if let genre = session.genre {
                bucket.genres[genre, default: 0] += 1
            }

            buckets[session.weather.season] = bucket
        }

        return buckets.values.compactMap { bucket in
            guard bucket.sessionCount > 0 else {
                return nil
            }

            // W-03: "avoided" means the genre barely appears in this season —
            // share ≤ 5% (at least 1 session) — listed weakest-first, max 3.
            let threshold = max(1, Int(Double(bucket.sessionCount) * 0.05))
            let avoidedCandidates = bucket.genres
                .filter { $0.value <= threshold }
                .sorted {
                    $0.value != $1.value
                        ? $0.value < $1.value
                        : $0.key < $1.key // deterministic tie-break
                }
            let avoidedGenres = avoidedCandidates.prefix(3).map(\.key)

            let dominantGenres = bucket.genres
                .sorted { $0.value > $1.value }
                .prefix(5)
                .map(\.key)

            // Derived per-season confidence: speed/engagement dispersion across
            // the season's sessions (was hardcoded 0.8/0.8/0.8 — same W-class).
            let seasonSessions = sessions.filter { $0.weather.season == bucket.season }
            let speedCV = coefficientOfVariation(seasonSessions.map(\.readingSpeed))
            let engagementCV = coefficientOfVariation(seasonSessions.map(\.engagementScore))
            let confidence = calculateConfidence(
                sampleCount: bucket.sessionCount,
                recurrence: min(1.0, Double(bucket.sessionCount) / 25.0),
                stability: max(0, min(1, 1 - speedCV)),
                consistency: max(0, min(1, 1 - engagementCV))
            )

            return SeasonalProfile(
                season: bucket.season,
                averageReadingDuration:
                bucket.totalDuration /
                    Double(bucket.sessionCount),
                averageReadingSpeed:
                bucket.totalSpeed /
                    Double(bucket.sessionCount),
                averageEngagement:
                bucket.totalEngagement /
                    Double(bucket.sessionCount),
                averagePagesRead:
                bucket.totalPages /
                    Double(bucket.sessionCount),
                dominantGenres: dominantGenres,
                avoidedGenres: avoidedGenres,
                confidence: confidence
            )
        }
        .sorted {
            $0.season.rawValue <
                $1.season.rawValue
        }
    }
}

// MARK: - Influence Profile

private extension WeatherAnalysisEngine {
    func buildInfluenceProfile(
        from sessions: [EnvironmentalSessionRecord],
        dataCoverageRatio: Double? = nil
    ) -> WeatherInfluenceProfile {
        let correlations = analyzeCorrelations(
            from: sessions,
            dataCoverageRatio: dataCoverageRatio
        )

        let strongestPositive = correlations
            .filter { $0.coefficient > 0 }
            .sorted {
                abs($0.coefficient) >
                    abs($1.coefficient)
            }
            .prefix(10)

        let strongestNegative = correlations
            .filter { $0.coefficient < 0 }
            .sorted {
                abs($0.coefficient) >
                    abs($1.coefficient)
            }
            .prefix(10)

        let confidence = calculateAggregateConfidence(
            sessions: sessions,
            correlations: correlations,
            dataCoverageRatio: dataCoverageRatio
        )

        let dominantSeason = determineDominantSeason(
            sessions: sessions
        )

        let dominantCondition = determineDominantCondition(
            sessions: sessions
        )

        return WeatherInfluenceProfile(
            strongestPositiveFactors:
            Array(strongestPositive),
            strongestNegativeFactors:
            Array(strongestNegative),
            environmentalSensitivityScore:
            calculateEnvironmentalSensitivity(
                correlations: correlations
            ),
            dominantSeason: dominantSeason,
            dominantCondition: dominantCondition,
            confidence: confidence
        )
    }
}

// MARK: - Correlation Analysis Core

private extension WeatherAnalysisEngine {
    // MARK: Temperature Correlations

    func analyzeTemperatureCorrelations(
        from sessions: [EnvironmentalSessionRecord],
        dataCoverageRatio: Double
    ) -> [EnvironmentalCorrelation] {
        return buildCorrelation(
            sessions: sessions,
            factorExtractor: { $0.weather.temperatureCelsius },
            metricExtractor: { $0.readingSpeed },
            factor: .temperature,
            metric: .readingSpeed,
            dataCoverageRatio: dataCoverageRatio
        )
    }

    func analyzeHumidityCorrelations(
        from sessions: [EnvironmentalSessionRecord],
        dataCoverageRatio: Double
    ) -> [EnvironmentalCorrelation] {
        return buildCorrelation(
            sessions: sessions,
            factorExtractor: { $0.weather.humidity },
            metricExtractor: { $0.engagementScore },
            factor: .humidity,
            metric: .engagement,
            dataCoverageRatio: dataCoverageRatio
        )
    }

    func analyzePressureCorrelations(
        from sessions: [EnvironmentalSessionRecord],
        dataCoverageRatio: Double
    ) -> [EnvironmentalCorrelation] {
        return buildCorrelation(
            sessions: sessions,
            factorExtractor: { $0.weather.pressure },
            metricExtractor: { $0.consistencyScore },
            factor: .pressure,
            metric: .readingConsistency,
            dataCoverageRatio: dataCoverageRatio
        )
    }

    func analyzeCloudCoverCorrelations(
        from sessions: [EnvironmentalSessionRecord],
        dataCoverageRatio: Double
    ) -> [EnvironmentalCorrelation] {
        return buildCorrelation(
            sessions: sessions,
            factorExtractor: { $0.weather.cloudCover },
            metricExtractor: { $0.engagementScore },
            factor: .cloudCover,
            metric: .engagement,
            dataCoverageRatio: dataCoverageRatio
        )
    }

    func analyzeVisibilityCorrelations(
        from sessions: [EnvironmentalSessionRecord],
        dataCoverageRatio: Double
    ) -> [EnvironmentalCorrelation] {
        return buildCorrelation(
            sessions: sessions,
            factorExtractor: { $0.weather.visibilityKilometers },
            metricExtractor: { $0.readingDurationMinutes },
            factor: .visibility,
            metric: .readingDuration,
            dataCoverageRatio: dataCoverageRatio
        )
    }

    func analyzeWindSpeedCorrelations(
        from sessions: [EnvironmentalSessionRecord],
        dataCoverageRatio: Double
    ) -> [EnvironmentalCorrelation] {
        return buildCorrelation(
            sessions: sessions,
            factorExtractor: { $0.weather.windSpeedKPH },
            metricExtractor: { $0.momentumScore },
            factor: .windSpeed,
            metric: .momentum,
            dataCoverageRatio: dataCoverageRatio
        )
    }

    func analyzeRainCorrelations(
        from sessions: [EnvironmentalSessionRecord],
        dataCoverageRatio: Double
    ) -> [EnvironmentalCorrelation] {
        return buildBinaryConditionCorrelation(
            sessions: sessions,
            conditionExtractor: { $0.weather.precipitationMillimeters > 0 },
            metricExtractor: { $0.readingDurationMinutes },
            factor: .rain,
            metric: .readingDuration,
            dataCoverageRatio: dataCoverageRatio
        )
    }

    func analyzeSnowCorrelations(
        from sessions: [EnvironmentalSessionRecord],
        dataCoverageRatio: Double
    ) -> [EnvironmentalCorrelation] {
        return buildBinaryConditionCorrelation(
            sessions: sessions,
            conditionExtractor: { $0.weather.snowfallMillimeters > 0 },
            metricExtractor: { $0.readingDurationMinutes },
            factor: .snow,
            metric: .readingDuration,
            dataCoverageRatio: dataCoverageRatio
        )
    }

    func analyzeStormCorrelations(
        from sessions: [EnvironmentalSessionRecord],
        dataCoverageRatio: Double
    ) -> [EnvironmentalCorrelation] {
        return buildCorrelation(
            sessions: sessions,
            factorExtractor: { $0.weather.stormActivityIndex },
            metricExtractor: { $0.engagementScore },
            factor: .stormActivity,
            metric: .engagement,
            dataCoverageRatio: dataCoverageRatio
        )
    }
}

// MARK: - Generic Correlation Engine

private extension WeatherAnalysisEngine {
    /// W-02: chronological bounds are extracted from the timestamp-sorted array,
    /// never from input order.
    func chronologicalBounds(
        _ sessions: [EnvironmentalSessionRecord]
    ) -> (first: Date, last: Date)? {
        guard let earliest = sessions.map(\.timestamp).min(),
              let latest = sessions.map(\.timestamp).max() else { return nil }
        return (earliest, latest)
    }

    func buildCorrelation(
        sessions: [EnvironmentalSessionRecord],
        factorExtractor: (EnvironmentalSessionRecord) -> Double,
        metricExtractor: (EnvironmentalSessionRecord) -> Double,
        factor: EnvironmentalFactor,
        metric: ReadingBehaviorMetric,
        dataCoverageRatio: Double = 1.0
    ) -> [EnvironmentalCorrelation] {
        guard sessions.count >= 5 else { return [] }

        let pairs = sessions.map {
            (factorExtractor($0), metricExtractor($0), $0.timestamp)
        }

        let coefficient = pearsonCorrelation(pairs.map { $0.0 }, pairs.map { $0.1 })

        let significance = calculateSignificance(
            sampleSize: sessions.count,
            coefficient: coefficient
        )

        let influenceScore = abs(coefficient) * significance

        let lifecycle = determineLifecycle(
            coefficient: coefficient,
            significance: significance
        )

        let confidence = calculateConfidence(
            sampleCount: sessions.count,
            recurrence: significance,
            stability: abs(coefficient),
            consistency: averageConsistency(pairs),
            dataCoverageScore: dataCoverageRatio
        )

        guard let bounds = chronologicalBounds(sessions) else { return [] }

        return [
            EnvironmentalCorrelation(
                factor: factor,
                metric: metric,
                coefficient: coefficient,
                significance: significance,
                influenceScore: influenceScore,
                lifecycle: lifecycle,
                confidence: confidence,
                firstObserved: bounds.first,
                lastObserved: bounds.last,
                supportingSampleCount: sessions.count
            ),
        ]
    }

    func buildBinaryConditionCorrelation(
        sessions: [EnvironmentalSessionRecord],
        conditionExtractor: (EnvironmentalSessionRecord) -> Bool,
        metricExtractor: (EnvironmentalSessionRecord) -> Double,
        factor: EnvironmentalFactor,
        metric: ReadingBehaviorMetric,
        dataCoverageRatio: Double = 1.0
    ) -> [EnvironmentalCorrelation] {
        guard sessions.count >= 5 else { return [] }

        let trueGroup = sessions.filter(conditionExtractor)
        let falseGroup = sessions.filter { !conditionExtractor($0) }

        guard !trueGroup.isEmpty, !falseGroup.isEmpty else {
            return []
        }

        let trueAvg = trueGroup.map(metricExtractor).average
        let falseAvg = falseGroup.map(metricExtractor).average

        let coefficient = (trueAvg - falseAvg) / max(trueAvg + falseAvg, 0.0001)

        let significance = calculateSignificance(
            sampleSize: sessions.count,
            coefficient: coefficient
        )

        let influenceScore = abs(coefficient) * significance

        let confidence = calculateConfidence(
            sampleCount: sessions.count,
            recurrence: significance,
            stability: abs(coefficient),
            // Measured group separation stands in for consistency here —
            // larger separation = more consistent discrimination.
            consistency: max(0, min(1, abs(coefficient))),
            dataCoverageScore: dataCoverageRatio
        )

        guard let bounds = chronologicalBounds(sessions) else { return [] }

        return [
            EnvironmentalCorrelation(
                factor: factor,
                metric: metric,
                coefficient: coefficient,
                significance: significance,
                influenceScore: influenceScore,
                lifecycle: determineLifecycle(
                    coefficient: coefficient,
                    significance: significance
                ),
                confidence: confidence,
                firstObserved: bounds.first,
                lastObserved: bounds.last,
                supportingSampleCount: sessions.count
            ),
        ]
    }
}

// MARK: - Statistical Core

private extension WeatherAnalysisEngine {
    func pearsonCorrelation(
        _ x: [Double],
        _ y: [Double]
    ) -> Double {
        guard x.count == y.count,
              x.count > 1
        else { return 0 }

        let n = Double(x.count)

        let sumX = x.reduce(0, +)
        let sumY = y.reduce(0, +)

        let sumXY = zip(x, y).map(*).reduce(0, +)
        let sumX2 = x.map { $0 * $0 }.reduce(0, +)
        let sumY2 = y.map { $0 * $0 }.reduce(0, +)

        let numerator = n * sumXY - sumX * sumY
        let denominator = sqrt(
            (n * sumX2 - sumX * sumX) *
                (n * sumY2 - sumY * sumY)
        )

        guard denominator != 0 else { return 0 }

        return numerator / denominator
    }

    func calculateSignificance(
        sampleSize: Int,
        coefficient: Double
    ) -> Double {
        let base = min(1.0, Double(sampleSize) / 50.0)
        let strength = abs(coefficient)

        return (base * 0.6) + (strength * 0.4)
    }

    func averageConsistency(
        _ values: [(Double, Double, Date)]
    ) -> Double {
        guard values.count > 2 else { return 0.5 }

        let diffs = zip(values, values.dropFirst()).map { a, b in
            abs(a.0 - b.0) + abs(a.1 - b.1)
        }

        let avg = diffs.average

        return 1.0 / (1.0 + avg)
    }

    func determineLifecycle(
        coefficient: Double,
        significance: Double
    ) -> CorrelationLifecycle {
        let strength = abs(coefficient)

        if significance < 0.2 {
            return .temporary
        }
        if strength > 0.8 && significance > 0.7 {
            return .persistent
        }
        if strength > 0.6 {
            return .strengthening
        }
        if strength > 0.4 {
            return .stable
        }
        if strength > 0.2 {
            return .weakening
        }

        return .emerging
    }
}

// MARK: - Utilities

extension Array where Element == Double {
    var average: Double {
        guard !isEmpty else { return 0 }
        return reduce(0, +) / Double(count)
    }
}

private extension WeatherAnalysisEngine {
    func calculateConfidence(
        sampleCount: Int,
        recurrence: Double,
        stability: Double,
        consistency: Double,
        dataCoverageScore: Double = 1.0
    ) -> ConfidenceReport {
        let sampleSizeScore = min(1.0, Double(sampleCount) / 100.0)

        let overall =
            (sampleSizeScore +
                recurrence +
                stability +
                consistency +
                dataCoverageScore) / 5.0

        return ConfidenceReport(
            overallConfidence: overall,
            sampleSizeScore: sampleSizeScore,
            recurrenceScore: recurrence,
            stabilityScore: stability,
            consistencyScore: consistency,
            dataCoverageScore: dataCoverageScore,
            supportingSamples: sampleCount
        )
    }

    /// W-01: aggregate confidence reflects EVIDENCE.
    ///
    /// Components:
    ///   • sampleSizeScore — sessions/100 (unchanged definition)
    ///   • recurrence      — mean correlation significance (real, was 0.8)
    ///   • stability       — mean |coefficient|           (real, was 0.8)
    ///   • consistency     — mean pairwise-consistency    (real, was 0.8)
    ///   • coverage        — caller-supplied real ratio; falls back to the
    ///                       sample-size proxy when unknown.
    func calculateAggregateConfidence(
        sessions: [EnvironmentalSessionRecord],
        correlations: [EnvironmentalCorrelation],
        dataCoverageRatio: Double? = nil
    ) -> ConfidenceReport {
        let sampleSizeScore = min(1.0, Double(sessions.count) / 100.0)

        let recurrence = correlations.isEmpty
            ? 0.0
            : correlations.map { $0.confidence.recurrenceScore }.reduce(0, +) / Double(correlations.count)
        let stability = correlations.isEmpty
            ? 0.0
            : correlations.map { $0.confidence.stabilityScore }.reduce(0, +) / Double(correlations.count)
        let consistency = correlations.isEmpty
            ? 0.0
            : correlations.map { $0.confidence.consistencyScore }.reduce(0, +) / Double(correlations.count)

        // Real coverage when the caller knows it; sample-proxy otherwise.
        let coverage = dataCoverageRatio ?? sampleSizeScore

        let overall =
            (sampleSizeScore + recurrence + stability + consistency + coverage) / 5.0

        return ConfidenceReport(
            overallConfidence: overall,
            sampleSizeScore: sampleSizeScore,
            recurrenceScore: recurrence,
            stabilityScore: stability,
            consistencyScore: consistency,
            dataCoverageScore: coverage,
            supportingSamples: sessions.count
        )
    }

    func calculateEnvironmentalSensitivity(
        correlations: [EnvironmentalCorrelation]
    ) -> Double {
        guard !correlations.isEmpty else { return 0 }

        return correlations
            .map { abs($0.coefficient) }
            .average
    }

    func determineDominantSeason(
        sessions: [EnvironmentalSessionRecord]
    ) -> SeasonalPeriod? {
        Dictionary(
            grouping: sessions,
            by: { $0.weather.season }
        )
        .max { $0.value.count < $1.value.count }?
        .key
    }

    func determineDominantCondition(
        sessions: [EnvironmentalSessionRecord]
    ) -> WeatherConditionCategory? {
        Dictionary(
            grouping: sessions,
            by: { $0.weather.condition }
        )
        .max { $0.value.count < $1.value.count }?
        .key
    }

    func generateInsights(
        sessions _: [EnvironmentalSessionRecord],
        profile _: EnvironmentalReadingProfile,
        correlations _: [EnvironmentalCorrelation]
    ) -> [EnvironmentalInsight] {
        return []
    }
}
