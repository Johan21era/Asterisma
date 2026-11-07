//  G6ContextPinsTests.swift
//  Bedrock G6: V3 report generation from history.

import Foundation
import Testing
@testable import AsterismaV2_5

@Suite("G6 · Behavior Context V3", .serialized)
@MainActor
final class G6ContextPinsTests {

    @Test("History analysis produces a stored V3 report with real session contexts")
    func v3ReportFromHistory() {
        var book = Book(
            title: "Context History",
            author: "A",
            fileURL: URL(fileURLWithPath: "/tmp/context.pdf"),
            fileType: .pdf,
            totalPages: 400)
        book.sessions = (0..<10).map { index in
            let end = Date().addingTimeInterval(TimeInterval(-index * 86_400))
            let start = end.addingTimeInterval(-1800)
            return ReadingSession(
                bookID: book.id,
                startTime: start,
                endTime: end,
                startPage: index * 10,
                endPage: index * 10 + 5,
                pageTimes: [
                    PageTiming(
                        pageNumber: index * 10,
                        startTime: start,
                        endTime: start.addingTimeInterval(300)),
                ])
        }

        let kit = BehaviorContextAccessKit()
        let engine = BehaviorContextEngine()
        let input = IntegrationInputBuilder.build(from: [book], kit: kit)
        let report = engine.analyzeWithIntelligence(input: input)

        #expect(report.contextResult.contexts.count == 10)
        #expect(engine.intelligenceReport != nil)
        #expect(report.significanceResult.evidenceChains.count == 10)
        // Evidence is absent in this fixture, so no narrative may invent one.
        #expect(report.narrativeResult.citedNarratives.allSatisfy { $0.sessionIDs.count <= 10 })
    }
}
