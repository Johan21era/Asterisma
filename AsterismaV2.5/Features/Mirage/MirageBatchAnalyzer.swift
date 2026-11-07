import Combine
import Foundation

// ADR-13 (2026-10-29): library-scale analysis without a second execution path.
//
// The batch runner is deliberately a sequencer, not an engine. Every job calls
// MirageEngineService.analyze, so the warm session, the request gate, the
// identity-map commit rules, and the typed outcome copy all remain the proven
// one-book path. This file only decides WHICH book runs next and how progress is
// reported.
//
// Explicit gesture only: `prepare` never starts work, and `run` is called from
// the Settings button (or a test). Cancel is cooperative at the flow's own
// checkpoints — it never claims to undo an engine commit.

@MainActor
final class MirageBatchAnalyzer: ObservableObject {
    typealias Analyze = @MainActor (
        MirageImportSource, @escaping () async -> Bool
    ) async -> MirageImportOutcome

    struct Job: Identifiable {
        enum State: Equatable {
            case pending
            case running
            case linked(reused: Bool)
            case failed(String)
            case cancelled

            var isFinished: Bool {
                switch self {
                case .pending, .running: return false
                case .linked, .failed, .cancelled: return true
                }
            }

            var isFailure: Bool {
                if case .failed = self { return true }
                return false
            }
        }

        let id: UUID
        let title: String
        let source: MirageImportSource
        var state: State = .pending
        var attempts = 0

        init(id: UUID, title: String, source: MirageImportSource) {
            self.id = id
            self.title = title
            self.source = source
        }

        init(book: Book) {
            id = book.id
            title = book.title
            source = MirageAppImportMount.importSource(for: book)
        }
    }

    @Published private(set) var jobs: [Job] = []
    @Published private(set) var isRunning = false
    @Published private(set) var cancelRequested = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var finishedAt: Date?

    private let analyze: Analyze

    init(analyze: @escaping Analyze = { source, checkCancelled in
        await MirageEngineService.shared.analyze(
            source: source, checkCancelled: checkCancelled)
    }) {
        self.analyze = analyze
    }

    // MARK: - Planning

    /// Builds the queue from the live library. EPUB books and comic
    /// containers (CBZ archives and image folders) are eligible; PDFs are not.
    /// Already-linked books are skipped by default so the button does exactly
    /// what its label says.
    func prepare(
        books: [Book],
        linkedBookIDs: Set<UUID> = [],
        skipLinked: Bool = true
    ) {
        guard !isRunning else { return }
        jobs = books
            .filter { $0.fileType == .epub || $0.fileType.isComic }
            .filter { !skipLinked || !linkedBookIDs.contains($0.id) }
            .map(Job.init(book:))
        resetRunState()
    }

    /// Test/injection seam: the caller supplies the exact jobs.
    func prepare(jobs: [Job]) {
        guard !isRunning else { return }
        self.jobs = jobs
        resetRunState()
    }

    // MARK: - Execution

    func run() async {
        guard !isRunning else { return }
        guard jobs.contains(where: { $0.state == .pending }) else { return }

        isRunning = true
        cancelRequested = false
        startedAt = Date()
        finishedAt = nil

        for index in jobs.indices {
            if cancelRequested { break }
            guard jobs[index].state == .pending else { continue }

            jobs[index].state = .running
            jobs[index].attempts += 1
            let source = jobs[index].source
            let outcome = await analyze(source) { [weak self] in
                await MainActor.run { self?.cancelRequested ?? true }
            }

            guard index < jobs.count, jobs[index].source.rtBookID == source.rtBookID else {
                continue
            }
            switch outcome {
            case .linked(_, let reused):
                jobs[index].state = .linked(reused: reused)
            case .cancelled:
                jobs[index].state = .cancelled
            default:
                jobs[index].state = .failed(MirageOutcomeCopy.headline(outcome))
            }
        }

        if cancelRequested {
            for index in jobs.indices where jobs[index].state == .pending {
                jobs[index].state = .cancelled
            }
        }
        isRunning = false
        cancelRequested = false
        finishedAt = Date()
    }

    /// Cooperative cancel: pending jobs become visibly cancelled now; the
    /// running book reaches the flow's next checkpoint. Nothing is undone.
    func cancel() {
        guard isRunning else { return }
        cancelRequested = true
        for index in jobs.indices where jobs[index].state == .pending {
            jobs[index].state = .cancelled
        }
    }

    /// Re-queues only the failed jobs and runs them again. Successful and
    /// cancelled rows are left untouched.
    func retryFailed() async {
        guard !isRunning else { return }
        for index in jobs.indices where jobs[index].state.isFailure {
            jobs[index].state = .pending
        }
        await run()
    }

    func reset() {
        guard !isRunning else { return }
        jobs = []
        resetRunState()
    }

    // MARK: - Progress

    var completedCount: Int { jobs.filter(\.state.isFinished).count }
    var linkedCount: Int {
        jobs.filter { if case .linked = $0.state { return true }; return false }.count
    }
    var failedCount: Int { jobs.filter(\.state.isFailure).count }
    var cancelledCount: Int {
        jobs.filter { if case .cancelled = $0.state { return true }; return false }.count
    }
    var totalCount: Int { jobs.count }
    var fractionComplete: Double {
        guard !jobs.isEmpty else { return 0 }
        return Double(completedCount) / Double(jobs.count)
    }

    var summaryLine: String {
        guard !jobs.isEmpty else { return "No books are waiting for analysis." }
        var parts: [String] = []
        if linkedCount > 0 { parts.append("\(linkedCount) analyzed") }
        if failedCount > 0 { parts.append("\(failedCount) failed") }
        if cancelledCount > 0 { parts.append("\(cancelledCount) cancelled") }
        let remaining = jobs.count - completedCount
        if remaining > 0 { parts.append("\(remaining) remaining") }
        return parts.isEmpty ? "Ready." : parts.joined(separator: " · ")
    }

    private func resetRunState() {
        isRunning = false
        cancelRequested = false
        startedAt = nil
        finishedAt = nil
    }
}
