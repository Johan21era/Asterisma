//  DemoDataService.swift
//  AsterismaV2.5 — DEVELOPER CONSOLE ONLY
//
//  LIVE-TEST LT-8 v2 (per Johan's follow-up): selectable fake reader PROFILES,
//  hosted exclusively inside the Developer Console's Demo Profile Lab.
//
//  ISOLATION CONTRACT:
//    • This entire file compiles ONLY under #if DEBUG.
//    • The only mutation path is DataStore.debug_replaceLibrary(with:) — itself
//      #if DEBUG-gated — which ALSO resets LibraryState (goals/achievements/
//      collections) so switching profiles never blends data between personas.
//    • Release builds contain none of these symbols: nothing can leak into the
//      shipping app because nothing here exists in it.
//
//  SYNTHESIS: seeded behavior is reproducible for a fixed reference date and
//  calendar/time zone; model IDs are deliberately fresh UUIDs on each run.
//
//  ROADMAP 3.4 / NA-8 (RA-002): two persona catalog entries previously wrote
//  `?? .fiction` / `?? .business` after NON-OPTIONAL ReadingGenre cases — a
//  left-over generation artifact whose right side could never apply (compiler
//  warned on every Debug build). The dead halves are removed; genres unchanged.

#if DEBUG
import Foundation

// MARK: - Deterministic RNG

struct SeededRNG {
    private var state: UInt64
    nonisolated init(seed: String) {
        var h: UInt64 = 0xcbf29ce484222325
        for b in seed.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        state = h
    }
    nonisolated mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    nonisolated mutating func double() -> Double { Double(next() % 1_000_000) / 1_000_000 }
    nonisolated mutating func int(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }
    nonisolated mutating func pickWeighted(_ weights: [Double]) -> Int {
        let total = weights.reduce(0, +)
        guard total > 0 else { return 0 }
        var roll = double() * total
        for (i, w) in weights.enumerated() {
            roll -= w
            if roll <= 0 { return i }
        }
        return weights.count - 1
    }
}

// MARK: - Persona model

struct DemoPersona: Identifiable {
    let id: String
    let name: String
    let blurb: String
    let catalog: [DemoBookSpec]
    /// Weighted hour-of-day buckets: (start, endExclusive, weight).
    let hourBuckets: [(start: Int, end: Int, weight: Double)]
    /// Month → reading-probability multiplier (seasonality). Absent months = 1.0.
    let monthWeights: [Int: Double]
    /// Weekday-only reading (Mon–Fri), if the persona demands it.
    let weekdaysOnly: Bool
    /// Probability any given day is a reading day (before seasonality).
    let readDayProbability: Double
    /// Session length range, in minutes.
    let sessionMinutes: ClosedRange<Double>
    /// Baseline pace range in seconds per page, before synthetic variation.
    let secondsPerPage: ClosedRange<Double>

    var totalCatalogHours: Double { catalog.reduce(0) { $0 + $1.totalHours } }

    init(
        id: String, name: String, blurb: String,
        hourBuckets: [(start: Int, end: Int, weight: Double)],
        monthWeights: [Int: Double] = [:],
        weekdaysOnly: Bool = false,
        readDayProbability: Double = 0.72,
        sessionMinutes: ClosedRange<Double> = 25...75,
        secondsPerPage: ClosedRange<Double> = 45...75,
        catalog: [DemoBookSpec]
    ) {
        self.id = id; self.name = name; self.blurb = blurb
        self.hourBuckets = hourBuckets; self.monthWeights = monthWeights
        self.weekdaysOnly = weekdaysOnly
        self.readDayProbability = readDayProbability
        self.sessionMinutes = sessionMinutes; self.secondsPerPage = secondsPerPage
        self.catalog = catalog
    }
}

struct DemoBookSpec {
    let title: String
    let author: String
    let genre: ReadingGenre
    let totalPages: Int
    let totalHours: Double
    let completed: Bool
    let series: String?
}

private nonisolated func spec(_ t: String, _ a: String, _ g: ReadingGenre, _ p: Int, _ h: Double, done: Bool = false, series: String? = nil) -> DemoBookSpec {
    DemoBookSpec(title: t, author: a, genre: g, totalPages: p, totalHours: h, completed: done, series: series)
}

// MARK: - The sixteen readers

enum DemoProfileCatalog {
    static let all: [DemoPersona] = [

        DemoPersona(
            id: "winter-romantic", name: "The Winter Romantic",
            blurb: "Romance concentrated in the cold months.",
            hourBuckets: [(18, 24, 3.0), (12, 18, 1.0), (0, 2, 1.5)],
            monthWeights: [12: 3.4, 1: 3.6, 2: 3.2, 11: 1.4, 3: 1.0, 10: 0.25, 6: 0.1, 7: 0.08,
                           4: 0.25, 5: 0.2, 8: 0.1, 9: 0.15],
            readDayProbability: 0.9, sessionMinutes: 65...170, secondsPerPage: 50...75,
            catalog: [
                spec("The Gilded Hour", "M. Castellano", .romance, 412, 245, series: "Ashbury"),
                spec("Letters to June", "R. Okafor", .romance, 338, 180),
                spec("A Season for Thorns", "H. Lindqvist", .romance, 296, 165, series: "Ashbury"),
                spec("Snowlight", "I. Varga", .romance, 372, 150),
                spec("The Winter Palace Letters", "A. Devereux", .romance, 444, 140),
                spec("Midnight in the Orangery", "C. Bellamy", .romance, 320, 120),
                spec("Thaw", "J. Mercer", .romance, 288, 95),
                spec("Cold Harbor Nights", "F. Adeyemi", .romance, 366, 80),
                spec("The Copper Valentine", "R. Solano", .romance, 310, 40, done: true),
            ]),

        DemoPersona(
            id: "afternoon-devotee", name: "The Afternoon Devotee",
            blurb: "Obsessed with afternoon reads — virtually every session lands between noon and five.",
            hourBuckets: [(12, 17, 12.0), (17, 19, 1.0), (11, 12, 0.8)],
            readDayProbability: 0.8, sessionMinutes: 35...90, secondsPerPage: 48...72,
            catalog: [
                spec("Teatime Mysteries", "G. Howell", .mystery, 342, 60),
                spec("The Sunroom", "P. Alcott", .fiction, 298, 45),
                spec("Lazy River Days", "M. Tanaka", .fiction, 264, 38),
                spec("Courtyard Essays", "V. Ilyin", .philosophy, 220, 22),
                spec("Afternoon of the Archivists", "D. Renner", .historical, 356, 40),
                spec("Picnic at Wrenfield", "L. Ashcombe", .romance, 280, 30),
            ]),

        DemoPersona(
            id: "fantasy-marathoner", name: "The Fantasy Marathoner",
            blurb: "Long fantasy sessions with enormous tomes.",
            hourBuckets: [(9, 13, 2.0), (13, 18, 2.5), (19, 23, 2.0)],
            monthWeights: [11: 1.4, 12: 1.5, 1: 1.4],
            readDayProbability: 0.62, sessionMinutes: 120...360, secondsPerPage: 42...65,
            catalog: [
                spec("Emberwake", "T. Valdry", .fantasy, 880, 160, series: "The Cinder Crown"),
                spec("Salt & Storm", "N. Ferrar", .fantasy, 742, 130, series: "The Cinder Crown"),
                spec("The Ninth Spire", "K. Aldwyn", .fantasy, 1010, 150),
                spec("Wyrmholt", "O. Brannagh", .fantasy, 664, 90),
                spec("Gods of the Pale Marsh", "Y. Chen", .fantasy, 592, 70),
            ]),

        DemoPersona(
            id: "commuter-snacker", name: "The Commuter Snacker",
            blurb: "Weekday rush-hours and short nonfiction sessions, with occasional interruptions.",
            hourBuckets: [(7, 9, 4.0), (17, 19, 4.0), (12, 13, 1.5)],
            weekdaysOnly: true, readDayProbability: 0.85, sessionMinutes: 8...15, secondsPerPage: 40...60,
            catalog: [
                spec("Atomic Chapters", "J. Clearwater", .selfHelp, 240, 22),
                spec("The Focus Economy", "R. Delgado", .business, 260, 20),
                spec("Deep Work, Short Bursts", "A. North", .education, 210, 18),
                spec("Negotiate Anything Twice", "S. Kroll", .business, 232, 16),
                spec("History in Hallways", "T. Mbeki", .historical, 198, 14),
                spec("Micro-Habits Macro-Lives", "F. Ogundimu", .selfHelp, 250, 15),
            ]),

        DemoPersona(
            id: "one-book-wonder", name: "The One-Book Wonder",
            blurb: "One enormous book, revisited across many sessions.",
            hourBuckets: [(20, 24, 3.0), (0, 1, 2.0)],
            readDayProbability: 0.78, sessionMinutes: 45...110, secondsPerPage: 48...72,
            catalog: [
                spec("The Vellum Sea", "E. Marlowe", .fantasy, 1420, 300),
            ]),

        DemoPersona(
            id: "completionist", name: "The Completionist",
            blurb: "Starts books only to finish them — every last page, across every genre.",
            hourBuckets: [(19, 23, 2.0), (7, 9, 1.2), (12, 14, 1.2)],
            readDayProbability: 0.82, sessionMinutes: 30...80, secondsPerPage: 48...72,
            catalog: [
                spec("Iron Harvest", "B. Novak", .scienceFiction, 380, 34, done: true),
                spec("The Cartographer's Daughter", "I. Salim", .historical, 340, 30, done: true),
                spec("Glass Anatomy", "W. Fenn", .mystery, 320, 28, done: true),
                spec("Cooking the Classics", "M. Duval", .nonFiction, 290, 24, done: true),
                spec("Run Silent Run Deep Blue", "H. Ortiz", .thriller, 310, 27, done: true),
                spec("Petals & Proof", "N. Barrow", .romance, 300, 26, done: true),
                spec("The Ledger of Small Gods", "T. Anansi", .fantasy, 330, 29, done: true),
            ]),

        DemoPersona(
            id: "serial-abandoner", name: "The Serial Abandoner",
            blurb: "Six books started and abandoned at different points.",
            hourBuckets: [(21, 24, 2.5), (12, 13, 1.5)],
            readDayProbability: 0.7, sessionMinutes: 15...40, secondsPerPage: 52...78,
            catalog: [
                spec("Ulysses, Again", "J. Joyce-Adjacent", .fiction, 780, 12),
                spec("Being & Boredom", "X. Sartre-Fan", .philosophy, 640, 9),
                spec("Infinite Backlog", "D. Foster-Wallower", .fiction, 900, 14),
                // NA-8: was `.historical ?? .fiction` — non-optional LHS made the RHS dead.
                spec("War & More War", "L. Tolstoy-Fan", .historical, 1100, 11),
                spec("Gravity's Raincheck", "T. Pynchonite", .scienceFiction, 720, 8),
                spec("The Count of Monte Crisp-o", "A. Dumas-Jr", .fiction, 850, 10),
            ]),

        DemoPersona(
            id: "night-owl-scholar", name: "The Night Owl Scholar",
            blurb: "Philosophy and science strictly after 10pm. Streaks measured in semesters.",
            hourBuckets: [(22, 24, 4.0), (0, 2, 3.5)],
            readDayProbability: 0.88, sessionMinutes: 50...110, secondsPerPage: 55...90,
            catalog: [
                spec("Meditations on Attention", "A. Kaur", .philosophy, 264, 55),
                spec("The Quantum Ladder", "V. Ramanujan-Rao", .science, 388, 48),
                spec("Ethics for Night Owls", "D. Kierkegaard-Cousin", .philosophy, 302, 40),
                spec("Entropy Is a Habit", "L. Boltzmann-Niece", .science, 350, 44),
                spec("On Becoming", "P. Ricoeur-Student", .philosophy, 280, 36),
            ]),

        DemoPersona(
            id: "poetry-dabbler", name: "The Poetry Dabbler",
            blurb: "Slim volumes, sporadic moods, short beautiful bursts.",
            hourBuckets: [(6, 8, 1.5), (21, 23, 2.0)],
            readDayProbability: 0.32, sessionMinutes: 10...30, secondsPerPage: 70...120,
            catalog: [
                spec("Brief Candle", "W. Odum", .poetry, 128, 9),
                spec("Saltwater Sonnets", "M. Reyes", .poetry, 96, 7),
                spec("Orchard Hours", "T. Lindgren", .poetry, 112, 8),
                spec("The Inventory of Rain", "K. Osei", .poetry, 88, 6),
            ]),

        DemoPersona(
            id: "business-grinder", name: "The Business Grinder",
            blurb: "Early mornings, mostly self-help and business, with occasional days off.",
            hourBuckets: [(5, 7, 10.0)],
            readDayProbability: 0.96, sessionMinutes: 40...70, secondsPerPage: 45...65,
            catalog: [
                spec("The Focused Investor", "L. Tran", .business, 310, 60),
                spec("Compound Mornings", "G. Winthrop", .selfHelp, 280, 55),
                spec("Scale Without Chaos", "P. Ramaswamy", .business, 300, 50),
                spec("The Negotiation Fieldbook", "H. Ozturk", .business, 266, 45),
                spec("Lead Quietly", "C. Bergström", .selfHelp, 254, 40),
            ]),

        DemoPersona(
            id: "seasonal-cyclist", name: "The Seasonal Cyclist",
            blurb: "Mystery in summer, horror in autumn, romance in spring, epic fantasy in winter.",
            hourBuckets: [(19, 23, 3.0), (14, 17, 1.5)],
            monthWeights: [6: 1.6, 7: 1.7, 8: 1.5, 9: 1.4, 10: 1.6, 12: 1.3, 4: 1.3, 5: 1.2],
            readDayProbability: 0.74, sessionMinutes: 35...95, secondsPerPage: 48...72,
            catalog: [
                spec("Beach House Alibis", "S. Marlow", .mystery, 340, 45),
                spec("The August Guest", "R. Calloway", .mystery, 318, 40),
                spec("Harvest of Whispers", "E. Grimshaw", .thriller, 372, 42),
                spec("October House", "V. Nightingale", .thriller, 356, 40),
                spec("Springtime in Provence", "A. Beaumont", .romance, 300, 35),
                spec("The Thawing", "J. Castellane", .romance, 288, 30),
                spec("Winterhold Saga Vol. 1", "G. Frostheim", .fantasy, 620, 55),
            ]),

        DemoPersona(
            id: "rereader", name: "The Rereader",
            blurb: "Three beloved books, endlessly revisited. Comfort over novelty.",
            hourBuckets: [(20, 23, 3.0), (8, 9, 1.0)],
            readDayProbability: 0.8, sessionMinutes: 30...75, secondsPerPage: 52...78,
            catalog: [
                spec("The Little Prince (Anniversary)", "A. de Saint-Exupéry", .fiction, 96, 60),
                spec("Pride & Prejudice (Annotated)", "J. Austen", .romance, 432, 80),
                spec("The Hobbit: A Lifetime Edition", "R. Tolkien-Heir", .fantasy, 380, 70),
            ]),

        DemoPersona(
            id: "speed-demon", name: "The Speed Demon",
            blurb: "A fast reader with a 30–40 second baseline pace per page.",
            hourBuckets: [(9, 12, 2.5), (13, 16, 2.0), (20, 22, 1.5)],
            readDayProbability: 0.85, sessionMinutes: 45...120, secondsPerPage: 30...40,
            catalog: [
                spec("Velocity", "J. Abrams-X", .thriller, 420, 55),
                spec("The Rapid Protocol", "K. Voss", .thriller, 396, 50),
                spec("Shelf Destruction Manual", "Anonymous", .technology, 350, 45),
                spec("Ten Thousand Pages a Year", "M. Swift-Reader", .selfHelp, 310, 40),
                spec("Blitzkrieg Fiction", "R. Cannon", .fiction, 380, 42),
            ]),

        DemoPersona(
            id: "slow-savorer", name: "The Slow Savorer",
            blurb: "A deliberate reader with a slower baseline pace per page.",
            hourBuckets: [(17, 19, 1.5), (20, 22, 2.5)],
            readDayProbability: 0.6, sessionMinutes: 40...90, secondsPerPage: 95...170,
            catalog: [
                spec("Ulysses (Savored)", "J. Joyce", .fiction, 780, 120),
                spec("Middlemarch (Chewed)", "G. Eliot", .fiction, 880, 100),
                spec("In Search of Lost Time: Swann's Way (Slowly)", "M. Proust", .fiction, 496, 80),
            ]),

        DemoPersona(
            id: "goal-crusher", name: "The Goal Crusher",
            blurb: "Usually reads around an hour, with occasional interruptions and missed days.",
            hourBuckets: [(6, 8, 2.0), (21, 23, 2.0)],
            readDayProbability: 0.93, sessionMinutes: 55...65, secondsPerPage: 48...72,
            catalog: [
                spec("The Consistency Engine", "D. Sterling", .selfHelp, 320, 40),
                spec("Atomic Attention", "J. Clearwick", .selfHelp, 300, 38),
                // NA-8: was `.education ?? .business` — non-optional LHS made the RHS dead.
                spec("Deep Reading", "C. Newport-Nephew", .education, 280, 35),
                spec("The Habit Compass", "N. Duhigg-Disciple", .selfHelp, 270, 32),
                spec("Systems Over Goals", "T. Adams-Admirer", .business, 290, 30),
            ]),

        DemoPersona(
            id: "comeback-story", name: "The Comeback Story",
            blurb: "A four-month break followed by a return to reading.",
            hourBuckets: [(20, 24, 3.0), (10, 13, 1.5)],
            readDayProbability: 0.9, sessionMinutes: 50...120, secondsPerPage: 48...72,
            catalog: [
                spec("Renaissance", "A. Phoenix", .fiction, 360, 60),
                spec("Second Wind", "M. Okafor-Reid", .fiction, 330, 55),
                spec("The Return of the Reader", "Z. Hartline", .fiction, 300, 50),
            ]),
    ]

    static func persona(withID id: String) -> DemoPersona? {
        all.first { $0.id == id }
    }
}
// MARK: - Session synthesis engine

extension DemoProfileCatalog {

    /// Deterministically synthesizes a full library for a persona.
    /// Sessions are closed and page positions stay within each catalog book.
    /// Synthetic behavior and its probabilities are not calibrated to people.
    nonisolated static func generateBooks(
        for persona: DemoPersona,
        referenceDate: Date = Date(),
        simulationSeed: String? = nil
    ) -> [Book] {
        guard !persona.catalog.isEmpty, !persona.hourBuckets.isEmpty else { return [] }
        var rng = SeededRNG(seed: simulationSeed.map { persona.id + ":" + $0 } ?? persona.id)
        let cal = Calendar(identifier: .gregorian)

        // Horizon sized so even 1,000-hour personas have room to breathe:
        // enough days that read-day probability × months can fit every session.
        let midSessionMinutes = (persona.sessionMinutes.lowerBound
            + persona.sessionMinutes.upperBound) / 2
        let neededSessions = Int(persona.totalCatalogHours * 60 / max(1, midSessionMinutes)) + 1
        let horizonDays = max(430, Int(Double(neededSessions) / persona.readDayProbability) + 90)

        let today = cal.startOfDay(for: referenceDate)

        let bookIDs = persona.catalog.map { _ in UUID() }
        var positions = Array(repeating: 0, count: persona.catalog.count)
        var completedBooks = Array(repeating: false, count: persona.catalog.count)
        var sessionsPerBook = (0..<persona.catalog.count).map { _ in [ReadingSession]() }
        // Fixed per-book variation and abandonment points, not measurements.
        let bookPace = persona.catalog.map { _ in 0.85 + rng.double() * 0.3 }
        let abandonAt = persona.catalog.map { book in
            max(1, Int(Double(book.totalPages - 1) * (0.12 + rng.double() * 0.43)))
        }
        let weights = persona.hourBuckets.map(\.weight)
        var lastSessionEnd: Date?

        for offset in (-horizonDays)...(-1) {
            guard let day = cal.date(byAdding: .day, value: offset, to: today) else { continue }
            let month = cal.component(.month, from: day)
            let monthFactor = persona.monthWeights[month] ?? 1.0

            // A quiet period before the comeback, ending 60 days ago.
            if persona.id == "comeback-story", (-180 ... -61).contains(offset) { continue }
            if rng.double() >= min(1, persona.readDayProbability * monthFactor) { continue }

            let weekday = cal.component(.weekday, from: day)
            if persona.weekdaysOnly, !(2...6).contains(weekday) { continue }

            // Hour-of-day via weighted buckets — this is what makes personas
            // like The Afternoon Devotee statistically unmistakable.
            let bucketIndex = rng.pickWeighted(weights)
            let bucket = persona.hourBuckets[bucketIndex]
            let spanHours = max(1, bucket.end - bucket.start)
            let hour = bucket.start + rng.int(in: 0...(spanHours - 1))
            let minute = rng.int(in: 0...59)
            guard let sessionStart = cal.date(
                bySettingHour: hour, minute: minute, second: 0, of: day
            ) else { continue }

            if let lastSessionEnd, sessionStart < lastSessionEnd { continue }

            let candidates = persona.catalog.indices.filter { index in
                if persona.id == "serial-abandoner" {
                    return positions[index] < abandonAt[index]
                }
                return !completedBooks[index]
            }
            let bookIndex: Int
            if candidates.isEmpty {
                // Rereading is an explicit behavior, not a forced consequence of
                // running out of books. Most readers revisit only occasionally.
                guard persona.id != "serial-abandoner" else { continue }
                let rereadChance = (persona.id == "rereader" || persona.id == "one-book-wonder" || persona.id == "winter-romantic") ? 0.8 : 0.08
                guard rng.double() < rereadChance else { continue }
                bookIndex = rng.int(in: 0...(persona.catalog.count - 1))
                if positions[bookIndex] >= persona.catalog[bookIndex].totalPages - 1 {
                    positions[bookIndex] = 0
                }
            } else if persona.id == "completionist" {
                bookIndex = candidates[0]
            } else {
                let preferred = candidates.filter { index in
                    guard persona.id == "seasonal-cyclist" else { return true }
                    switch month {
                    case 6...8: return persona.catalog[index].genre == .mystery
                    case 9...11: return persona.catalog[index].genre == .thriller
                    case 3...5: return persona.catalog[index].genre == .romance
                    default: return persona.catalog[index].genre == .fantasy
                    }
                }
                let pool = preferred.isEmpty ? candidates : preferred
                bookIndex = pool[rng.int(in: 0...(pool.count - 1))]
            }

            let bookSpec = persona.catalog[bookIndex]
            let maxPage = persona.id == "serial-abandoner" ? abandonAt[bookIndex] : bookSpec.totalPages - 1
            // A jump between sessions leaves skipped pages untimed rather than
            // pretending their distance was read during a session.
            if persona.id != "completionist", positions[bookIndex] > 0, rng.double() < 0.08 {
                positions[bookIndex] = min(maxPage, positions[bookIndex] + rng.int(in: 1...3))
            }
            let startPage = positions[bookIndex]
            let minutes = persona.sessionMinutes.lowerBound
                + rng.double() * (persona.sessionMinutes.upperBound - persona.sessionMinutes.lowerBound)
            // Some sessions end early, as when the reader gets interrupted.
            let interruptionRoll = rng.double()
            let interruptionFactor: Double
            if interruptionRoll < 0.03 {
                interruptionFactor = 0.002 + rng.double() * 0.008
            } else if interruptionRoll < 0.12 {
                interruptionFactor = 0.1 + rng.double() * 0.3
            } else {
                interruptionFactor = 1.0
            }
            let plannedEnd = min(today, sessionStart.addingTimeInterval(minutes * 60 * interruptionFactor))
            let pace = (persona.secondsPerPage.lowerBound
                + rng.double() * (persona.secondsPerPage.upperBound - persona.secondsPerPage.lowerBound))
                * bookPace[bookIndex]
            var page = startPage
            var cursor = sessionStart
            var timings: [PageTiming] = []
            while cursor < plannedEnd {
                let variation = 0.65 + rng.double() * 0.7
                let rereadDelay = rng.double() < 0.04 ? 1.5 + rng.double() : 1.0
                let end = min(plannedEnd, cursor.addingTimeInterval(max(1, pace * variation * rereadDelay)))
                timings.append(PageTiming(pageNumber: page, startTime: cursor, endTime: end))
                cursor = end
                if page == maxPage || cursor >= plannedEnd { break }
                // Occasionally go back a page and reread it, but never leave
                // the session with an end page before its start page.
                if persona.id != "completionist", page > startPage + 1, rng.double() < 0.015 {
                    page -= 1
                } else {
                    page += 1
                }
            }

            guard !timings.isEmpty else { continue }
            sessionsPerBook[bookIndex].append(ReadingSession(
                bookID: bookIDs[bookIndex], startTime: sessionStart, endTime: cursor,
                startPage: startPage, endPage: page, pageTimes: timings
            ))
            lastSessionEnd = cursor
            positions[bookIndex] = page
            if page >= bookSpec.totalPages - 1 { completedBooks[bookIndex] = true }
        }

        // Assemble books.
        return zip(persona.catalog, bookIDs).enumerated().map { index, pair in
            let (catalogEntry, id) = pair
            var book = Book(
                id: id,
                title: catalogEntry.title,
                author: catalogEntry.author,
                fileURL: URL(fileURLWithPath:
                    "/demo/\(persona.id)/\(catalogEntry.title.replacingOccurrences(of: " ", with: "_")).epub"),
                fileType: .epub,
                totalPages: catalogEntry.totalPages,
                chapters: demoChapters(totalPages: catalogEntry.totalPages),
                dateAdded: cal.date(byAdding: .day,
                                    value: -(horizonDays + 7), to: today) ?? today,
                genre: catalogEntry.genre,
                series: catalogEntry.series
            )
            book.wordCountEstimate = catalogEntry.totalPages * 250

            book.sessions = sessionsPerBook[index]
            book.isCompleted = completedBooks[index]
            // A completed book stays completed even if it is being reread;
            // the current page reflects the most recent simulated position.
            book.currentPage = positions[index]
            return book
        }
    }

    private nonisolated static func demoChapters(totalPages: Int) -> [Chapter] {
        let chapterCount = max(6, totalPages / 40)
        let span = totalPages / chapterCount
        return (0..<chapterCount).map { i in
            Chapter(title: "Chapter \(i + 1)", index: i,
                    startPage: i * span,
                    endPage: (i == chapterCount - 1)
                        ? totalPages - 1 : (i + 1) * span - 1)
        }
    }
}

extension Book {
    /// Small DEBUG helper used by the demo lab to flag favorites.
    mutating func applyFavorite(_ favorite: Bool) {
        isFavorite = favorite
    }
}

// MARK: - Installation (the ONLY path into DataStore — DEBUG-gated on both ends)

struct DemoInstallSummary {
    let personaName: String
    let bookCount: Int
    let sessionCount: Int
    let totalHours: Double
}

extension DemoProfileCatalog {

    /// P6-HOTFIX split: generation is now a PURE STATIC (no store access,
    /// safe on detached tasks); collection rebuild is a separate main-actor
    /// step. The old monolithic install() did both plus heavy synthesis in one
    /// synchronous main-thread call — the freeze.
    @discardableResult
    static func installCollections(
        for books: [Book],
        personaName: String,
        into store: DataStore
    ) -> DemoInstallSummary {
        let shelf = store.addCollection(name: "\(personaName) Shelf")
        for book in books.prefix(max(1, books.count / 2)) {
            store.setBook(book.id, membershipIn: shelf.id, isMember: true)
        }
        if let favoriteTarget = books.first(where: { !$0.isCompleted }) {
            var fav = favoriteTarget
            fav.applyFavorite(true)
            store.updateBook(fav)
        }

        let sessionTotal = books.reduce(0) { $0 + $1.sessions.count }
        return DemoInstallSummary(
            personaName: personaName,
            bookCount: books.count,
            sessionCount: sessionTotal,
            totalHours: books.reduce(0) { $0 + $1.totalReadingTime } / 3600
        )
    }
}

enum DemoLabError: LocalizedError {
    case unknownProfile(String)
    var errorDescription: String? {
        switch self {
        case let .unknownProfile(id): return "Unknown demo profile id: \(id)"
        }
    }
}
#endif
