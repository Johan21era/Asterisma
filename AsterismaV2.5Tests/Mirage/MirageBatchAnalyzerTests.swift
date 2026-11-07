import Foundation
import Testing
@testable import AsterismaV2_5

// ADR-13 pins: the batch runner is a sequencer over the one-book flow. It runs
// jobs in order, never overlaps them, cancels cooperatively, and retries only
// failed rows — successes are not re-analyzed by accident.

@Suite("Mirage Batch Analyzer (ADR-13)", .serialized)
@MainActor
struct MirageBatchAnalyzerTests {
    private func source(_ id: UUID) -> MirageImportSource {
        MirageImportSource(rtBookID: id, fileTypeIsEpub: true) { nil }
    }

    private func linkedEntry(_ id: UUID) -> MirageIdentityMapEntry {
        .fromReceipt(
            rtBookID: id,
            mirageBookID: "book_\(id.uuidString.prefix(8))",
            mirageEditionID: "edition_\(id.uuidString.prefix(8))",
            fingerprint: String(repeating: "cd", count: 32),
            resumeHint: nil,
            createdAt: Date(timeIntervalSince1970: 1_770_000_000))
    }

    private func makeJobs(_ ids: [UUID]) -> [MirageBatchAnalyzer.Job] {
        ids.map { MirageBatchAnalyzer.Job(
            id: $0, title: "Book \($0.uuidString.prefix(4))", source: source($0)) }
    }

    @Test func runsEveryPendingJobInOrderAndNeverOverlaps() async {
        let ids = [UUID(), UUID(), UUID()]
        var order: [UUID] = []
        var active = 0
        var peak = 0

        let analyzer = MirageBatchAnalyzer { source, _ in
            order.append(source.rtBookID)
            active += 1
            peak = max(peak, active)
            try? await Task.sleep(nanoseconds: 10_000_000)
            active -= 1
            return .linked(entry: self.linkedEntry(source.rtBookID), reused: false)
        }
        analyzer.prepare(jobs: makeJobs(ids))
        await analyzer.run()

        #expect(order == ids)
        #expect(peak == 1)
        #expect(analyzer.linkedCount == 3)
        #expect(analyzer.completedCount == 3)
        #expect(analyzer.failedCount == 0)
        #expect(!analyzer.isRunning)
        #expect(analyzer.finishedAt != nil)
    }

    @Test func cancelStopsTheNextJobAndMarksPendingAsCancelled() async throws {
        let ids = [UUID(), UUID(), UUID()]
        var analyzed: [UUID] = []

        let analyzer = MirageBatchAnalyzer { source, checkCancelled in
            analyzed.append(source.rtBookID)
            if source.rtBookID == ids[0] {
                while await checkCancelled() == false {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                return .cancelled(engineCommitted: false)
            }
            return .linked(entry: self.linkedEntry(source.rtBookID), reused: false)
        }
        analyzer.prepare(jobs: makeJobs(ids))
        let run = Task { @MainActor in await analyzer.run() }

        try await Task.sleep(nanoseconds: 50_000_000)
        analyzer.cancel()
        await run.value

        #expect(analyzed == [ids[0]], "cancel must stop before the next book")
        #expect(analyzer.cancelledCount == 3)
        #expect(analyzer.linkedCount == 0)
        #expect(!analyzer.isRunning)
    }

    @Test func retryFailedRequeuesOnlyFailures() async {
        let successID = UUID()
        let failingID = UUID()
        var attempts: [UUID: Int] = [:]

        let analyzer = MirageBatchAnalyzer { source, _ in
            attempts[source.rtBookID, default: 0] += 1
            if source.rtBookID == failingID && attempts[source.rtBookID] == 1 {
                return .invalidReceipt(reason: "transient fixture fault")
            }
            return .linked(entry: self.linkedEntry(source.rtBookID), reused: false)
        }
        analyzer.prepare(jobs: makeJobs([successID, failingID]))
        await analyzer.run()

        #expect(analyzer.linkedCount == 1)
        #expect(analyzer.failedCount == 1)
        #expect(attempts[successID] == 1)
        #expect(attempts[failingID] == 1)

        await analyzer.retryFailed()

        #expect(analyzer.linkedCount == 2)
        #expect(analyzer.failedCount == 0)
        #expect(attempts[successID] == 1, "a success is never re-analyzed by retry")
        #expect(attempts[failingID] == 2)
    }

    @Test func prepareIncludesComicsAndSkipsUnsupportedAndAlreadyLinkedBooks() {
        let linked = Book(
            title: "Linked EPUB", author: "Fixture",
            fileURL: URL(fileURLWithPath: "/tmp/linked.epub"),
            fileType: .epub, totalPages: 10, currentPage: 1)
        let unlinked = Book(
            title: "Unlinked EPUB", author: "Fixture",
            fileURL: URL(fileURLWithPath: "/tmp/unlinked.epub"),
            fileType: .epub, totalPages: 10, currentPage: 1)
        let pdf = Book(
            title: "PDF", author: "Fixture",
            fileURL: URL(fileURLWithPath: "/tmp/book.pdf"),
            fileType: .pdf, totalPages: 10, currentPage: 1)
        let comic = Book(
            title: "Manga Volume 1", author: "Fixture",
            fileURL: URL(fileURLWithPath: "/tmp/manga.cbz"),
            fileType: .cbz, totalPages: 180, currentPage: 0)

        let analyzer = MirageBatchAnalyzer { source, _ in
            .linked(entry: self.linkedEntry(source.rtBookID), reused: false)
        }
        analyzer.prepare(
            books: [linked, unlinked, pdf, comic],
            linkedBookIDs: [linked.id],
            skipLinked: true)

        #expect(analyzer.jobs.map(\.id) == [unlinked.id, comic.id])
        #expect(analyzer.jobs.last?.title == "Manga Volume 1")
        #expect(analyzer.jobs.last?.source.kind == .comic)
    }
}
