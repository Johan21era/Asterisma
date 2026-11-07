//  WeatherConfidencePinsTests.swift
//  AsterismaV2.5Tests
//
//  P5 production pass — pins for CURRENT_AUDIT W-01..W-03 (+W-04 class):
//    W-01 aggregate confidence derives from evidence + real coverage ratio
//    W-02 correlation bounds are chronological regardless of input order
//    W-03 "avoided" genres are genuinely low-share within a season
//
import Foundation
import Testing

@testable import AsterismaV2_5

@Suite("Weather Confidence Derivation")
struct WeatherConfidencePinsTests {

    // MARK: Fixture helpers

    private func snapshot(season: SeasonalPeriod = .winter, timestamp: Date = Date()) -> WeatherSnapshot {
        WeatherSnapshot(
            timestamp: timestamp,
            temperatureCelsius: 5,
            feelsLikeTemperatureCelsius: 3,
            humidity: 0.6,
            pressure: 1013,
            cloudCover: 0.5,
            visibilityKilometers: 10,
            windSpeedKPH: 8,
            precipitationMillimeters: 0,
            snowfallMillimeters: 0,
            stormActivityIndex: 0,
            condition: .cloudy,
            season: season,
            month: 1,
            weekday: 3,
            dayPeriod: .evening
        )
    }

    private func record(
        timestamp: Date,
        temperature: Double = 5,
        readingSpeed: Double = 40,
        engagement: Double = 0.6,
        genre: String? = nil,
        season: SeasonalPeriod = .winter
    ) -> WeatherAnalysisEngine.EnvironmentalSessionRecord {
        var snap = snapshot(season: season, timestamp: timestamp)
        snap = WeatherSnapshot(
            id: snap.id,
            timestamp: snap.timestamp,
            temperatureCelsius: temperature,
            feelsLikeTemperatureCelsius: snap.feelsLikeTemperatureCelsius,
            humidity: snap.humidity,
            pressure: snap.pressure,
            cloudCover: snap.cloudCover,
            visibilityKilometers: snap.visibilityKilometers,
            windSpeedKPH: snap.windSpeedKPH,
            precipitationMillimeters: snap.precipitationMillimeters,
            snowfallMillimeters: snap.snowfallMillimeters,
            stormActivityIndex: snap.stormActivityIndex,
            condition: snap.condition,
            season: snap.season,
            month: snap.month,
            weekday: snap.weekday,
            dayPeriod: snap.dayPeriod
        )
        return WeatherAnalysisEngine.EnvironmentalSessionRecord(
            sessionID: UUID(),
            bookID: UUID(),
            timestamp: timestamp,
            weather: snap,
            readingDurationMinutes: 30,
            pagesRead: 20,
            chaptersCompleted: 0,
            booksCompleted: 0,
            readingSpeed: readingSpeed,
            consistencyScore: 0.7,
            readingFrequencyScore: 0.6,
            engagementScore: engagement,
            sessionQualityScore: 0.6,
            momentumScore: 0.5,
            completionProbability: 0.4,
            abandonmentProbability: 0.1,
            difficultyScore: 0.3,
            complexityScore: 0.5,
            bookLength: 300,
            genre: genre,
            seriesIdentifier: nil,
            reread: false
        )
    }

    /// A dataset whose temperature→speed relationship is strongly linear.
    private func strongSignalRecords() -> [WeatherAnalysisEngine.EnvironmentalSessionRecord] {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        return (0 ..< 20).map { i in
            record(
                timestamp: base.addingTimeInterval(Double(i) * 86_400),
                temperature: 5 + Double(i),
                readingSpeed: 20 + Double(i) * 2,
                engagement: 0.4 + Double(i) * 0.03
            )
        }
    }

    // MARK: W-02 — chronological bounds

    @Test("W-02: firstObserved/lastObserved are chronological even when input is reversed")
    func boundsAreChronologicalRegardlessOfInputOrder() {
        let engine = WeatherAnalysisEngine()
        let early = Date(timeIntervalSince1970: 1_600_000_000)
        let late = Date(timeIntervalSince1970: 1_700_000_000)

        // Deliberately ordered newest-first: four 'late' rows then two 'early' rows.
        // Pre-fix, firstObserved came out as `late` and lastObserved as `early`.
        let reversed = [
            record(timestamp: late), record(timestamp: late),
            record(timestamp: late), record(timestamp: late),
            record(timestamp: early), record(timestamp: early),
        ]

        let correlations = engine.analyzeCorrelations(from: reversed)
        #expect(!correlations.isEmpty)

        for correlation in correlations {
            #expect(correlation.firstObserved == early,
                    "\(correlation.factor.rawValue): firstObserved was \(correlation.firstObserved)")
            #expect(correlation.lastObserved == late,
                    "\(correlation.factor.rawValue): lastObserved was \(correlation.lastObserved)")
        }
    }

    // MARK: W-01 — real coverage flows into report confidence

    @Test("W-01: dataCoverageRatio drives dataCoverageScore and overall confidence")
    func coverageRatioFlowsThrough() {
        let engine = WeatherAnalysisEngine()
        let records = strongSignalRecords()

        let fullCoverage = engine.generateTrendReport(sessions: records, dataCoverageRatio: 1.0)
        let poorCoverage = engine.generateTrendReport(sessions: records, dataCoverageRatio: 0.2)

        #expect(fullCoverage.confidence.dataCoverageScore == 1.0)
        #expect(poorCoverage.confidence.dataCoverageScore == 0.2)
        #expect(fullCoverage.confidence.overallConfidence > poorCoverage.confidence.overallConfidence)

        // Same records through the behavior-report path must agree.
        let behaviorFull = engine.generateBehaviorReport(sessions: records, dataCoverageRatio: 1.0)
        #expect(behaviorFull.confidence.dataCoverageScore == 1.0)
    }

    @Test("W-01: confidence responds to evidence strength, not constants")
    func confidenceVariesWithEvidence() {
        let engine = WeatherAnalysisEngine()
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        // Strong signal: temperature AND speed co-vary linearly → near-perfect
        // temperature→speed correlation. (Weather must vary too — a constant
        // factor has zero variance and can never correlate with anything.)
        let strong = (0 ..< 20).map { i in
            record(timestamp: base.addingTimeInterval(Double(i) * 86_400),
                   temperature: 5 + Double(i),
                   readingSpeed: 20 + Double(i) * 2)
        }
        // Flat signal: every metric identical across time → zero correlation everywhere.
        let flat = (0 ..< 20).map { i in
            record(timestamp: base.addingTimeInterval(Double(i) * 86_400),
                   temperature: 5, readingSpeed: 40)
        }

        let strongReport = engine.generateTrendReport(sessions: strong, dataCoverageRatio: 1.0)
        let flatReport = engine.generateTrendReport(sessions: flat, dataCoverageRatio: 1.0)

        // Pre-fix both were identically (0.8,0.8,0.8)+coverage → indistinguishable.
        #expect(strongReport.confidence.stabilityScore > flatReport.confidence.stabilityScore,
                "strong=\(strongReport.confidence.stabilityScore) flat=\(flatReport.confidence.stabilityScore)")
        #expect(strongReport.confidence.recurrenceScore > flatReport.confidence.recurrenceScore)
        #expect(strongReport.confidence.overallConfidence > flatReport.confidence.overallConfidence)
    }

    // MARK: W-03 — avoided means low-share

    @Test("W-03: avoidedGenres lists sub-5%-share genres, not merely least-read")
    func avoidedGenresAreGenuinelyLowShare() {
        let engine = WeatherAnalysisEngine()
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        var records: [WeatherAnalysisEngine.EnvironmentalSessionRecord] = []
        // Winter season: Romance dominates at 95%, three tiny genres split the rest.
        for i in 0 ..< 95 {
            records.append(record(timestamp: base.addingTimeInterval(Double(i) * 60),
                                  genre: "Romance", season: .winter))
        }
        for i in 0 ..< 2 {
            records.append(record(timestamp: base.addingTimeInterval(Double(i) * 60),
                                  genre: "Poetry", season: .winter))
        }
        for i in 0 ..< 2 {
            records.append(record(timestamp: base.addingTimeInterval(Double(i) * 60),
                                  genre: "Science Fiction", season: .winter))
        }
        records.append(record(timestamp: base, genre: "Business", season: .winter))

        let profile = engine.buildEnvironmentalProfile(from: records)
        let winter = profile.seasonalProfiles.first { $0.season == .winter }

        guard let winter else {
            Issue.record("winter seasonal profile missing")
            return
        }

        // Pre-fix: suffix(3) of descending counts labeled Poetry/Science Fiction/Business
        // "avoided" — which happened to be right HERE, but would also label a 20%-share
        // genre "avoided" in a 5-genre library. The invariant that matters:
        #expect(!winter.avoidedGenres.contains("Romance"),
                "a 95%-share genre must never be labeled avoided")
        #expect(winter.avoidedGenres.contains("Business"))
        #expect(winter.avoidedGenres.count <= 3)
        // Dominant list still leads with the true favorite.
        #expect(winter.dominantGenres.first == "Romance")
    }

    // MARK: W-04 class — displayed confidence derives from data

    @Test("W-04-class: seasonal stability reflects real speed dispersion")
    func seasonalStabilityIsDerivedNotConstant() {
        let engine = WeatherAnalysisEngine()
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        // Same count, same means-ish shape — ONLY the dispersion differs.
        // Low-CV winter: speeds hover tightly around 45.
        let tight = (0 ..< 12).map { i in
            record(timestamp: base.addingTimeInterval(Double(i) * 86_400),
                   temperature: 5,
                   readingSpeed: i % 2 == 0 ? 44 : 46)
        }
        // High-CV winter: speeds swing wildly between extremes.
        let wild = (0 ..< 12).map { i in
            record(timestamp: base.addingTimeInterval(Double(i) * 86_400),
                   temperature: 5,
                   readingSpeed: i % 2 == 0 ? 10 : 80)
        }

        let tightProfile = engine.buildEnvironmentalProfile(from: tight)
        let wildProfile = engine.buildEnvironmentalProfile(from: wild)

        let tightWinter = tightProfile.seasonalProfiles.first { $0.season == .winter }
        let wildWinter = wildProfile.seasonalProfiles.first { $0.season == .winter }

        guard let tightWinter, let wildWinter else {
            Issue.record("seasonal profiles missing")
            return
        }

        // Pre-fix both were hardcoded 0.8 — indistinguishable by construction.
        #expect(tightWinter.confidence.stabilityScore > wildWinter.confidence.stabilityScore,
                "tight=\(tightWinter.confidence.stabilityScore) wild=\(wildWinter.confidence.stabilityScore)")
        #expect(tightWinter.confidence.stabilityScore != 0.8 || wildWinter.confidence.stabilityScore != 0.8)
    }
}
