//  BehaviorEvidenceBuilder.swift
//  AsterismaV2.5
//
//  Converts raw behavioral event data from BehaviorContextAccessKit into
//  [BehaviorEvidence] format for BehaviorContextEngine.analyze().
//
//  This is pure glue: no engine logic, no business rules. It only reshapes data.
//
//  Conversion:
//    [ApplicationUsageSession]  (from BehaviorContextAccessKit)
//    + [ReadingSession]         (from DataStore.books.flatMap(\.sessions))
//    →  [BehaviorEvidence]      (consumed by BehaviorContextEngine.analyze)
//    +  [ReadingSessionRecord]  (consumed by BehaviorContextEngine.analyze)
//

import Foundation

enum BehaviorEvidenceBuilder {
    // MARK: - ReadingSessionRecord

    /// Converts completed DataStore ReadingSessions to ReadingSessionRecord
    /// (BehaviorContextEngine's simplified session type: just id + date interval).
    static func readingSessionRecords(from sessions: [ReadingSession]) -> [ReadingSessionRecord] {
        sessions.compactMap { session -> ReadingSessionRecord? in
            guard let end = session.endTime else { return nil }
            return ReadingSessionRecord(
                id: session.id,
                startDate: session.startTime,
                endDate: end
            )
        }
    }

    // MARK: - BehaviorEvidence

    /// Aggregates ApplicationUsageSessions per app name and produces one
    /// BehaviorEvidence entry per unique application.
    static func evidence(
        from appSessions: [ApplicationUsageSession],
        readingSessions: [ReadingSession]
    ) -> [BehaviorEvidence] {
        let completed = appSessions.filter { $0.endTime != nil }
        guard !completed.isEmpty else { return [] }

        let grouped = Dictionary(grouping: completed) { $0.application.applicationName }
        let readingTimes = readingSessions.compactMap(\.endTime)
        let observedDays = max(1, daySpan(from: completed))

        return grouped.compactMap { appName, sessions -> BehaviorEvidence? in
            guard let firstSession = sessions.first else { return nil }

            let totalDuration = sessions.compactMap(\.duration).reduce(0, +)
            let distinctDays = Set(sessions.map { Calendar.current.startOfDay(for: $0.startTime) })
            let consistency = Double(distinctDays.count) / Double(observedDays)
            let proximity = averageProximity(appSessions: sessions, readingTimes: readingTimes)

            return BehaviorEvidence(
                id: UUID(),
                timestamp: firstSession.startTime,
                name: appName,
                category: mapCategory(firstSession.application.category),
                totalDuration: totalDuration,
                frequency: sessions.count,
                recurrenceCount: distinctDays.count,
                consistency: min(1.0, consistency),
                proximityToReading: proximity
            )
        }
    }

    // MARK: - Private

    private static func daySpan(from sessions: [ApplicationUsageSession]) -> Int {
        guard let first = sessions.map(\.startTime).min(),
              let last = sessions.compactMap(\.endTime).max()
        else { return 1 }
        return max(1, Calendar.current.dateComponents([.day], from: first, to: last).day ?? 1)
    }

    private static func averageProximity(
        appSessions: [ApplicationUsageSession],
        readingTimes: [Date]
    ) -> Double {
        guard !readingTimes.isEmpty else { return 0.5 }
        let scores = appSessions.map { s -> Double in
            guard let nearest = readingTimes.min(by: {
                abs($0.timeIntervalSince(s.startTime)) < abs($1.timeIntervalSince(s.startTime))
            }) else { return 0.5 }
            let deltaMinutes = abs(nearest.timeIntervalSince(s.startTime)) / 60
            return max(0, 1 - (deltaMinutes / 120)) // 0→close, decays over 2 hours
        }
        return scores.reduce(0, +) / Double(max(1, scores.count))
    }

    /// Maps BehavioralCategory (BehavioralCategory.swift) → BehaviorCategory (BehaviorContextEngine.swift).
    private static func mapCategory(_ src: BehavioralCategory) -> BehaviorCategory {
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
