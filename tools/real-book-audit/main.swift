//  main.swift — real-book audit driver
//
//  Links the app's own content and estimation code (no reimplementation) and
//  runs it over a manifest produced by scripts/real-book-inventory.py:
//
//      [{"title": "...", "words": 120248, "sample": "first pages of prose"}]
//
//  For each book it reports the difficulty profile, the canonical page count,
//  and the estimated remaining hours for three reader paces. The paces are
//  expressed in seconds per canonical page (250 words): 60 = 250 wpm,
//  90 = 167 wpm, 120 = 125 wpm (the app's documented default).
//
//  Read-only: no file is written and no library is touched. This is not a test
//  suite; it produces the numbers a human then grades.

import Foundation

struct AuditInput: Decodable {
    let title: String
    let words: Int
    let sample: String
}

func makeBook(title: String, pages: Int, secondsPerPage: Double) -> Book {
    var book = Book(
        id: UUID(),
        title: title,
        author: "audit",
        fileURL: URL(fileURLWithPath: "/audit/\(UUID().uuidString).epub"),
        fileType: .epub,
        totalPages: pages,
        chapters: [],
        dateAdded: Date(timeIntervalSince1970: 1_700_000_000),
        genre: .unknown
    )
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    var elapsed: Double = 0
    let timings = (0..<30).map { index -> PageTiming in
        let t0 = start.addingTimeInterval(elapsed)
        elapsed += secondsPerPage
        return PageTiming(pageNumber: index, startTime: t0,
                          endTime: t0.addingTimeInterval(secondsPerPage))
    }
    book.sessions = [ReadingSession(
        bookID: book.id,
        startTime: start,
        endTime: start.addingTimeInterval(elapsed),
        startPage: 0,
        endPage: 30,
        pageTimes: timings
    )]
    // A third of the way in, so remaining time is a non-zero projection.
    book.currentPage = max(0, pages / 3)
    return book
}

@main
struct RealBookAudit {
    /// The cache and analytics types are main-actor isolated in the app; the
    /// driver runs on the main actor for the same reason the app does.
    @MainActor
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            FileHandle.standardError.write(Data("usage: real-book-audit <manifest.json>\n".utf8))
            exit(2)
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
        let inputs = try JSONDecoder().decode([AuditInput].self, from: data)

        var rows: [[String: Any]] = []
        for input in inputs {
            let profile = DifficultyAnalyzer.analyze(text: input.sample)
            let pageEstimate = PageEstimationModel.estimatePages(
                wordCount: input.words
            )
            var row: [String: Any] = [
                "title": input.title,
                "words": input.words,
                "sampleWords": input.sample.split { $0.isWhitespace }.count,
                "gradeLevel": (profile.gradeLevel * 1000).rounded() / 1000,
                "difficultyMultiplier": (profile.difficultyMultiplier * 1000).rounded() / 1000,
                "difficultyLabel": profile.difficultyLabel,
                "pages": pageEstimate.pages,
                "pageConfidence": pageEstimate.confidence
            ]
            for pace in [60.0, 90.0, 120.0] {
                let book = makeBook(title: input.title, pages: pageEstimate.pages,
                                    secondsPerPage: pace)
                let result = EstimationEngine.estimate(for: book, allBooks: [book])
                row["hoursAt\(Int(pace))s"] = (result.remainingHours * 100).rounded() / 100
                row["statusAt\(Int(pace))s"] = result.provenance.status.rawValue
            }
            rows.append(row)
        }

        let output = try JSONSerialization.data(
            withJSONObject: rows,
            options: [.prettyPrinted, .sortedKeys]
        )
        FileHandle.standardOutput.write(output)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
