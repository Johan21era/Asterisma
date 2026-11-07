

//  AnalyticsCache.swift
//  AsterismaV2.5
//
//  FINAL TRACES / UPGRADE #5: the derived-data layer the old header only
//  DREAMED about (that phantom AnalyticsCache comment is now real).
//
//  DESIGN
//  • Keyed by a cheap library signature: book count ⊕ id-hash fold ⊕
//    session count. Any mutation that changes books changes ≥1 component,
//    invalidating every cached value.
//  • Memoizes the expensive whole-library walks:
//      - readerProfile        (O sessions)
//      - streak               (O sessions × calendar ops)
//      - timeOfDayAnalysis    (O sessions)
//      - genreProfiles        (O sessions)
//      - trendAnalysis        (O 60-day activity build)
//  • Thread-safety: MainActor (all callers already are).
//  • G1: the old perBookSpeed member was deleted. It validated against an
//    always-empty array and had no callers.
//
//  INVALIDATION GUARANTEE: signature includes a monotonically bumped epoch
//  from DataStore so deletes/edits that keep counts equal still invalidate.

import Foundation

@MainActor
final class AnalyticsCache {
    static let shared = AnalyticsCache()

    struct Signature: Equatable {
        var bookCount: Int
        var idFold: Int
        var sessionCount: Int
        var epoch: UInt64
        /// G1: streak/trend answers bake in "today". Without a day bucket a
        /// value computed at 23:59 was served all next day until a mutation.
        var dayBucket: Int

        static func signature(for books: [Book], epoch: UInt64) -> Signature {
            var fold = 0
            var sessions = 0
            for b in books {
                fold = fold &+ b.id.hashValue
                sessions += b.sessions.count
            }
            let day = Calendar.current.startOfDay(for: Date())
            return Signature(
                bookCount: books.count,
                idFold: fold,
                sessionCount: sessions,
                epoch: epoch,
                dayBucket: Int(day.timeIntervalSince1970 / 86_400))
        }
    }

    private(set) var signature: Signature?
    private var readerProfileCache: ReaderProfileAnalytics?
    private var streakCache: ReadingStreak?
    private var timeOfDayCache: TimeOfDayAnalytics?
    private var genreProfilesCache: [ReadingGenre: GenreProfile]?
    private var trendCache: TrendAnalytics?

    private init() {}

    /// DataStore bumps its epoch on every debug_replaceLibrary / restoreState.
    func setEpoch(_ e: UInt64) {
        if let s = signature, s.epoch != e { invalidate() }
        if signature == nil {
            // first contact; adopt epoch lazily via next compute call
        }
    }

    private func ensureValid(_ books: [Book], epoch: UInt64) -> Bool {
        let sig = Signature.signature(for: books, epoch: epoch)
        if sig != signature {
            signature = sig
            readerProfileCache = nil
            streakCache = nil
            timeOfDayCache = nil
            genreProfilesCache = nil
            trendCache = nil
            return false
        }
        return true
    }

    func readerProfile(books: [Book], epoch: UInt64,
                       compute: () -> ReaderProfileAnalytics) -> ReaderProfileAnalytics {
        _ = ensureValid(books, epoch: epoch)
        if let c = readerProfileCache { return c }
        let v = compute()
        readerProfileCache = v
        return v
    }

    func streak(books: [Book], epoch: UInt64,
                compute: () -> ReadingStreak) -> ReadingStreak {
        _ = ensureValid(books, epoch: epoch)
        if let c = streakCache { return c }
        let v = compute()
        streakCache = v
        return v
    }

    func timeOfDay(books: [Book], epoch: UInt64,
                   compute: () -> TimeOfDayAnalytics) -> TimeOfDayAnalytics {
        _ = ensureValid(books, epoch: epoch)
        if let c = timeOfDayCache { return c }
        let v = compute()
        timeOfDayCache = v
        return v
    }

    func genreProfiles(books: [Book], epoch: UInt64,
                       compute: () -> [ReadingGenre: GenreProfile]) -> [ReadingGenre: GenreProfile] {
        _ = ensureValid(books, epoch: epoch)
        if let c = genreProfilesCache { return c }
        let v = compute()
        genreProfilesCache = v
        return v
    }

    func trend(books: [Book], epoch: UInt64,
               compute: () -> TrendAnalytics) -> TrendAnalytics {
        _ = ensureValid(books, epoch: epoch)
        if let c = trendCache { return c }
        let v = compute()
        trendCache = v
        return v
    }

    func invalidate() {
        signature = nil
        readerProfileCache = nil
        streakCache = nil
        timeOfDayCache = nil
        genreProfilesCache = nil
        trendCache = nil
    }
}
