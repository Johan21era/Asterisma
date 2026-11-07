//  DemoProfileServiceTests.swift
//  AsterismaV2.5Tests
//
//  Pins for the Developer Console's Demo Profile Lab (LT-8 v2).
//
//  What these tests guarantee before Johan ever clicks "Install":
//    • Every persona's generated library passes DataIntegrityValidator with no
//      unrepairable errors — installing can never trip the corruption banner.
//    • Every synthesized session is CLOSED (no phantom-time ghosts in demo data).
//    • Persona SIGNATURES are real: the Winter Romantic genuinely reads mostly
//      romance in winter; the Afternoon Devotee genuinely reads 12–5.
//    • Generation is deterministic per persona id.

import Foundation
import Testing

@testable import AsterismaV2_5

#if DEBUG

@Suite("Demo Profile Lab — persona generation pins")
struct DemoProfileServiceTests {

    private let cal = Calendar(identifier: .gregorian)

    // MARK: - Catalog integrity

    @Test("catalog contains 16 personas with unique ids")
    func catalogShape() {
        #expect(DemoProfileCatalog.all.count == 16)
        #expect(Set(DemoProfileCatalog.all.map(\.id)).count == 16)
        #expect(DemoProfileCatalog.persona(withID: "winter-romantic") != nil)
    }

    // MARK: - Validator cleanliness across EVERY persona

    @Test("every persona generates a validator-clean library", arguments: DemoProfileCatalog.all.map(\.id))
    func everyPersonaIsValidatorClean(id: String) throws {
        let persona = try #require(DemoProfileCatalog.persona(withID: id))
        let books = DemoProfileCatalog.generateBooks(for: persona)

        #expect(!books.isEmpty)

        let (_, report) = DataIntegrityValidator.validate(books)
        #expect(!report.hasUnrepairableErrors,
                "\(id): unrepairable validation issues — install would trip the corruption gate")

        for book in books {
            for session in book.sessions {
                #expect(session.endTime != nil,
                        "\(id)/\(book.title): open session would create phantom time")
            }
            #expect(book.currentPage < max(1, book.totalPages),
                    "\(id)/\(book.title): currentPage out of range")
        }
    }

    // MARK: - Persona signatures

    @Test("Winter Romantic: majority of reading happens in winter months, dominated by romance")
    func winterRomanticSignature() throws {
        let persona = try #require(DemoProfileCatalog.persona(withID: "winter-romantic"))
        let books = DemoProfileCatalog.generateBooks(for: persona)
        let sessions = books.flatMap(\.sessions)

        let winterMonths: Set<Int> = [12, 1, 2]
        let winterSeconds = sessions.filter { winterMonths.contains(cal.component(.month, from: $0.startTime)) }
            .reduce(0.0) { $0 + $1.duration }
        let totalSeconds = sessions.reduce(0.0) { $0 + $1.duration }
        #expect(winterSeconds / totalSeconds > 0.45,
                "winter share too low — seasonality engine drifted")

        let romance = books.filter { $0.genre == .romance }
            .reduce(0.0) { $0 + $1.totalReadingTime }
        #expect(romance / totalSeconds >= 0.52, "romance must clearly dominate this persona")
    }

    @Test("Afternoon Devotee: ≥70% of sessions start between 12:00 and 16:59")
    func afternoonDevoteeSignature() throws {
        let persona = try #require(DemoProfileCatalog.persona(withID: "afternoon-devotee"))
        let sessions = DemoProfileCatalog.generateBooks(for: persona).flatMap(\.sessions)

        let afternoon = sessions.filter {
            (12..<17).contains(cal.component(.hour, from: $0.startTime))
        }
        #expect(Double(afternoon.count) / Double(sessions.count) > 0.7)
    }

    // MARK: - E1 completion invariants

    @Test("no session claims pages outside its book", arguments: DemoProfileCatalog.all.map(\.id))
    func pagesStayInsideBook(id: String) throws {
        let persona = try #require(DemoProfileCatalog.persona(withID: id))
        for book in DemoProfileCatalog.generateBooks(for: persona) {
            for session in book.sessions {
                #expect(session.startPage >= 0 && session.endPage < book.totalPages,
                        "\(id)/\(book.title): session \(session.startPage)…\(session.endPage) outside the book")
                #expect(session.endPage >= session.startPage,
                        "\(id)/\(book.title): session ended before its starting page")
                #expect(!session.pageTimes.isEmpty)
                #expect(session.pageTimes.first?.pageNumber == session.startPage)
                #expect(session.pageTimes.last?.pageNumber == session.endPage)
                for timing in session.pageTimes {
                    #expect((0..<book.totalPages).contains(timing.pageNumber))
                    #expect(timing.endTime != nil && timing.duration > 0)
                    #expect(timing.startTime >= session.startTime && timing.endTime! <= session.endTime!)
                }
                for (left, right) in zip(session.pageTimes, session.pageTimes.dropFirst()) {
                    #expect(left.endTime == right.startTime)
                    #expect(abs(left.pageNumber - right.pageNumber) == 1)
                }
            }
        }
    }

    @Test("a book at its last page reports completed", arguments: DemoProfileCatalog.all.map(\.id))
    func lastPageImpliesCompleted(id: String) throws {
        let persona = try #require(DemoProfileCatalog.persona(withID: id))
        for book in DemoProfileCatalog.generateBooks(for: persona) {
            guard book.currentPage >= book.totalPages - 1 else { continue }
            #expect(book.isCompleted,
                    "\(id)/\(book.title): 100% progress with isCompleted == false")
        }
    }

    @Test("sessions do not overlap or extend beyond the reference day", arguments: DemoProfileCatalog.all.map(\.id))
    func chronologicalSessions(id: String) throws {
        let persona = try #require(DemoProfileCatalog.persona(withID: id))
        let reference = Date(timeIntervalSince1970: 1_790_000_000)
        let sessions = DemoProfileCatalog.generateBooks(for: persona, referenceDate: reference)
            .flatMap(\.sessions).sorted { $0.startTime < $1.startTime }
        for session in sessions {
            #expect(session.endTime! <= cal.startOfDay(for: reference))
        }
        for (left, right) in zip(sessions, sessions.dropFirst()) {
            #expect(left.endTime! <= right.startTime)
        }
    }

    @Test("simulation contains interruptions, revisits, and jumps between sessions")
    func behaviorVariety() throws {
        let persona = try #require(DemoProfileCatalog.persona(withID: "winter-romantic"))
        let books = DemoProfileCatalog.generateBooks(for: persona, referenceDate: Date(timeIntervalSince1970: 1_790_000_000))
        let sessions = books.flatMap(\.sessions)
        #expect(sessions.contains { $0.duration < persona.sessionMinutes.lowerBound * 60 })
        #expect(sessions.contains { session in
            zip(session.pageTimes, session.pageTimes.dropFirst()).contains { $1.pageNumber < $0.pageNumber }
        })
        #expect(books.contains { book in
            zip(book.sessions, book.sessions.dropFirst()).contains { $1.startPage > $0.endPage }
        })
        #expect(sessions.contains { $0.startPage == $0.endPage })
    }

    @Test("abandoner starts books but never finishes them")
    func abandonmentSignature() throws {
        let persona = try #require(DemoProfileCatalog.persona(withID: "serial-abandoner"))
        let books = DemoProfileCatalog.generateBooks(for: persona, referenceDate: Date(timeIntervalSince1970: 1_790_000_000))
        #expect(books.allSatisfy { !$0.sessions.isEmpty && !$0.isCompleted && $0.currentPage < $0.totalPages - 1 })
    }

    @Test("comeback has a quiet period and resumes reading")
    func comebackSignature() throws {
        let persona = try #require(DemoProfileCatalog.persona(withID: "comeback-story"))
        let reference = Date(timeIntervalSince1970: 1_790_000_000)
        let today = cal.startOfDay(for: reference)
        let start = try #require(cal.date(byAdding: .day, value: -180, to: today))
        let end = try #require(cal.date(byAdding: .day, value: -60, to: today))
        let sessions = DemoProfileCatalog.generateBooks(for: persona, referenceDate: reference).flatMap(\.sessions)
        #expect(!sessions.contains { $0.startTime >= start && $0.startTime < end })
        #expect(sessions.contains { $0.startTime < start })
        #expect(sessions.contains { $0.startTime >= end })
    }

    // MARK: - Determinism

    @Test("an explicit simulation seed is reproducible and changes generated history")
    func explicitSeed() throws {
        let persona = try #require(DemoProfileCatalog.persona(withID: "goal-crusher"))
        let reference = Date(timeIntervalSince1970: 1_760_000_000)
        func sessionStarts(_ seed: String) -> [Date] {
            DemoProfileCatalog.generateBooks(for: persona, referenceDate: reference, simulationSeed: seed)
                .flatMap(\.sessions).map(\.startTime).sorted()
        }
        let first = sessionStarts("fresh-a")
        #expect(!first.isEmpty)
        #expect(first == sessionStarts("fresh-a"))
        #expect(first != sessionStarts("fresh-b"))
    }

    @Test("generation is deterministic per persona id")
    func deterministicOutput() throws {
        let persona = try #require(DemoProfileCatalog.persona(withID: "goal-crusher"))

        let a = DemoProfileCatalog.generateBooks(for: persona,
                                                 referenceDate: Date(timeIntervalSince1970: 1_760_000_000))
        let b = DemoProfileCatalog.generateBooks(for: persona,
                                                 referenceDate: Date(timeIntervalSince1970: 1_760_000_000))

        #expect(a.map(\.title) == b.map(\.title))
        #expect(a.flatMap(\.sessions).count == b.flatMap(\.sessions).count)
        #expect(a.flatMap(\.sessions).first?.startTime
              == b.flatMap(\.sessions).first?.startTime)
    }
}
#endif
