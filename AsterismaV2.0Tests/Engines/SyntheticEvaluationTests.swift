import Foundation
import XCTest

@testable import AsterismaV2_0

/// An optional project-local request file explicitly selects a batch directory.
/// Normal census runs a small adapter check without creating artifacts.
final class SyntheticEvaluationTests: XCTestCase {
    struct History: Decodable {
        let book: String
        let durations: [Double]
    }
    struct Case: Decodable {
        let id: String
        let target: String
        let remainingPages: Int
        let history: [History]
    }
    struct Prediction: Encodable {
        let id: String
        let seconds: Double
        let status: String
    }

    private func predict(_ input: Case) throws -> Prediction {
        guard input.remainingPages > 0 else { throw Failure.invalidInput }
        let currentPage = input.history.filter { $0.book == input.target }
            .reduce(0) { $0 + $1.durations.count }
        var books: [String: Book] = [:]
        func makeBook(_ name: String, pages: Int) -> Book {
            Book(id: UUID(), title: name, author: "Synthetic",
                 fileURL: URL(fileURLWithPath: "/synthetic/\(name).epub"),
                 fileType: .epub, totalPages: pages, chapters: [],
                 dateAdded: Date(timeIntervalSince1970: 1_700_000_000), genre: .fiction)
        }
        var target = makeBook(input.target, pages: currentPage + input.remainingPages + 1)
        target.currentPage = currentPage
        books[input.target] = target
        for (index, segment) in input.history.enumerated() {
            guard !segment.durations.isEmpty,
                  segment.durations.allSatisfy({ $0.isFinite && $0 > 0 }) else { throw Failure.invalidInput }
            var book = books[segment.book] ?? makeBook(segment.book, pages: 200)
            let start = Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 86_400)
            var cursor = start
            var timings: [PageTiming] = []
            for (page, duration) in segment.durations.enumerated() {
                let end = cursor.addingTimeInterval(duration)
                timings.append(PageTiming(pageNumber: page, startTime: cursor, endTime: end))
                cursor = end
            }
            book.sessions.append(ReadingSession(bookID: book.id, startTime: start,
                                                endTime: cursor, startPage: 0,
                                                endPage: segment.durations.count, pageTimes: timings))
            books[segment.book] = book
        }
        target = try XCTUnwrap(books[input.target])
        let allBooks = books.keys.sorted().compactMap { books[$0] }
        let result = EstimationEngine.estimate(for: target, allBooks: allBooks)
        return Prediction(id: input.id, seconds: result.remainingSeconds,
                          status: result.provenance.status.rawValue)
    }

    enum Failure: Error { case invalidInput }

    func testActualEstimatorAdapter() throws {
        let empty = try predict(Case(id: "empty", target: "target", remainingPages: 40, history: []))
        XCTAssertEqual(empty.seconds, 4800, accuracy: 0.001)
        XCTAssertEqual(empty.status, "globalDefault")
        let personal = try predict(Case(id: "personal", target: "target", remainingPages: 40,
                                        history: [History(book: "target", durations: Array(repeating: 60, count: 12))]))
        XCTAssertEqual(personal.seconds, 2400, accuracy: 0.001)
        XCTAssertEqual(personal.status, "personalized")
        let cross = try predict(Case(id: "cross", target: "target", remainingPages: 40,
                                     history: [History(book: "prior", durations: Array(repeating: 80, count: 12))]))
        XCTAssertEqual(cross.seconds, 3200, accuracy: 0.001)
        XCTAssertEqual(cross.status, "crossBookBaseline")
    }

    func testOptionalBatch() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let request = root.appendingPathComponent(".synthetic-eval-request")
        guard FileManager.default.fileExists(atPath: request.path) else { return }
        let directory = try String(contentsOf: request, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directory.isEmpty, !directory.hasPrefix("/"),
              !directory.split(separator: "/").contains("..") else { throw Failure.invalidInput }
        let dir = root.appendingPathComponent(directory, isDirectory: true)
        let input = try JSONDecoder().decode([Case].self, from: Data(contentsOf: dir.appendingPathComponent("app-input.json")))
        XCTAssertFalse(input.isEmpty)
        XCTAssertEqual(Set(input.map(\.id)).count, input.count)
        let results = try input.map(predict)
        let attachment = XCTAttachment(data: try JSONEncoder().encode(results),
                                       uniformTypeIdentifier: "public.json")
        attachment.name = "synthetic-swift-predictions"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("SYNTHETIC_EVAL cases=\(results.count) attachment=synthetic-swift-predictions")
    }
}
