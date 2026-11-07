import CryptoKit
import Foundation
import XCTest

@testable import AsterismaV2_5

final class FreshStressBundleTests: XCTestCase {
    func testFreshDemoRounds() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "FreshDemoRounds", withExtension: "json"))
        let rounds = try JSONDecoder().decode([Int].self, from: Data(contentsOf: url))
        struct Result: Encodable {
            let id: String
            let round: Int
            let actual_seconds: Double
            let baseline: Double
            let legacy: Double
            let prior_seconds: Double?
            let recent_seconds: Double?
            let candidate_seconds: Double
            let target_samples: Int
            let input: AdversarialEvaluationTests.Input
            let futureDurations: [Double]
        }
        var results: [Result] = []
        let runner = AdversarialEvaluationTests()
        for round in rounds {
            for persona in DemoProfileCatalog.all {
                let books = DemoProfileCatalog.generateBooks(
                    for: persona, referenceDate: Date(timeIntervalSince1970: 1_790_000_000),
                    simulationSeed: "fresh-stress-\(round)"
                )
                let targetIndex = try XCTUnwrap(books.indices.first { index in
                    books[index].sessions.flatMap(\.pageTimes).filter { $0.endTime != nil && $0.duration > 0 }.count >= 55
                })
                func opaque(_ text: String) -> String {
                    SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
                }
                let targetID = opaque("\(round):\(persona.id):\(targetIndex)")
                let timings = books[targetIndex].sessions.flatMap(\.pageTimes)
                    .filter { $0.endTime != nil && $0.duration > 0 }.sorted { $0.startTime < $1.startTime }
                let future = Array(timings.suffix(40))
                let cutoff = future[0].startTime
                var history: [(Date, AdversarialEvaluationTests.Segment)] = []
                for (index, book) in books.enumerated() {
                    let id = opaque("\(round):\(persona.id):\(index)")
                    for session in book.sessions {
                        let past = session.pageTimes.filter { $0.endTime.map { $0 <= cutoff } ?? false }
                            .filter { $0.duration > 0 }
                        if !past.isEmpty {
                            history.append((past[0].startTime, .init(book: id, pages: past.map(\.pageNumber),
                                                                    durations: past.map(\.duration))))
                        }
                    }
                }
                history.sort { $0.0 < $1.0 }
                let id = opaque("fresh-demo:\(round):\(persona.id)")
                let input = AdversarialEvaluationTests.Input(id: id, target: targetID, remainingPages: 40,
                                                           history: history.map(\.1))
                let prediction = try runner.predict(input)
                results.append(Result(id: id, round: round,
                    actual_seconds: future.reduce(0) { $0 + $1.duration }, baseline: prediction.baseline,
                    legacy: prediction.legacy, prior_seconds: prediction.prior_seconds,
                    recent_seconds: prediction.recent_seconds,
                    candidate_seconds: prediction.candidate_seconds,
                    target_samples: prediction.target_samples, input: input,
                    futureDurations: future.map(\.duration)))
            }
            print("FRESH_DEMO round=\(round) count=\(DemoProfileCatalog.all.count)")
        }
        XCTAssertEqual(results.count, rounds.count * DemoProfileCatalog.all.count)
        let attachment = XCTAttachment(data: try JSONEncoder().encode(results), uniformTypeIdentifier: "public.json")
        attachment.name = "fresh-demo-predictions"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The committed fixture is a 200-case representative sample. The full
    /// 37 MB generated batch is archived outside the repository (2026-11-07)
    /// because it is build evidence, not source; the reduced sample keeps the
    /// decode/uniqueness/prediction assertions running in every checkout.
    func testBundledBatch() throws {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: "FreshStressInput", withExtension: "json"))
        let inputs = try JSONDecoder().decode([AdversarialEvaluationTests.Input].self,
                                              from: Data(contentsOf: url))
        XCTAssertFalse(inputs.isEmpty)
        XCTAssertEqual(Set(inputs.map(\.id)).count, inputs.count)
        let runner = AdversarialEvaluationTests()
        let results = try inputs.map { try runner.predict($0) }
        let attachment = XCTAttachment(data: try JSONEncoder().encode(results),
                                       uniformTypeIdentifier: "public.json")
        attachment.name = "fresh-stress-predictions"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("FRESH_STRESS cases=\(results.count)")
    }
}
