import CryptoKit
import Foundation
import XCTest

@testable import AsterismaV2_5

#if DEBUG
final class FinalStressDemoSnapshotTests: XCTestCase {
    private func opaque(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    func testCaptureDemoPersonas() throws {
        struct Segment: Encodable {
            let book: String
            let pages: [Int]
            let durations: [Double]
        }
        struct Input: Encodable {
            let id: String
            let target: String
            let remainingPages: Int
            let history: [Segment]
        }
        struct Truth: Encodable {
            let id: String
            let active_seconds: Double
            let target_kind: String
            let future_visits: Int
        }
        struct Capture: Encodable {
            let inputs: [Input]
            let truth: [Truth]
            let excluded: [String]
        }
        let reference = Date(timeIntervalSince1970: 1_790_000_000)
        var inputs: [Input] = []
        var truths: [Truth] = []
        var excluded: [String] = []
        for persona in DemoProfileCatalog.all {
            let id = opaque("demo:" + persona.id)
            let books = DemoProfileCatalog.generateBooks(for: persona, referenceDate: reference)
            guard let targetIndex = books.indices.first(where: { index in
                books[index].sessions.flatMap(\.pageTimes).filter { $0.endTime != nil && $0.duration > 0 }.count >= 55
            }) else {
                excluded.append(id)
                continue
            }
            let target = books[targetIndex]
            let targetID = opaque(persona.id + ":book:" + String(targetIndex))
            let timings = target.sessions.flatMap(\.pageTimes)
                .filter { $0.endTime != nil && $0.duration > 0 }
                .sorted { $0.startTime < $1.startTime }
            let future = Array(timings.suffix(40))
            let cutoff = future[0].startTime
            var history: [(Date, Segment)] = []
            for (index, book) in books.enumerated() {
                let bookID = opaque(persona.id + ":book:" + String(index))
                for session in book.sessions {
                    let past = session.pageTimes.filter {
                        guard let end = $0.endTime else { return false }
                        return end <= cutoff && $0.duration > 0
                    }
                    if !past.isEmpty {
                        history.append((past[0].startTime, Segment(book: bookID,
                            pages: past.map(\.pageNumber), durations: past.map(\.duration))))
                    }
                }
            }
            history.sort { $0.0 < $1.0 }
            inputs.append(Input(id: id, target: targetID, remainingPages: 40,
                                history: history.map(\.1)))
            truths.append(Truth(id: id, active_seconds: future.reduce(0) { $0 + $1.duration },
                                target_kind: "generated elapsed time, not measured active time",
                                future_visits: future.count))
        }
        XCTAssertEqual(inputs.count + excluded.count, DemoProfileCatalog.all.count)
        XCTAssertFalse(inputs.isEmpty)
        let data = try JSONEncoder().encode(Capture(inputs: inputs, truth: truths, excluded: excluded))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "final-stress-demo-snapshots"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("FINAL_DEMO captured=\(inputs.count) excluded=\(excluded.count)")
    }
}
#endif
