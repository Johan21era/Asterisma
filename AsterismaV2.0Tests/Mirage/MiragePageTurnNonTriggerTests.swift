import Foundation
import Testing
@testable import AsterismaV2_0

// ADR-7 (countersigned 2026-10-18) — S10-ES-4 pin 1: reading progress events
// must never trigger Mirage work. This suite pins the structural shape that
// guarantees it: the status controller's engine runner fires ONLY from an
// explicit refresh gesture — initialization computes the local map status
// synchronously and makes zero runner calls, and no positional mutation or
// repeated read of the book snapshot exists that could invoke it.
//
// Companion census gate (M-026, machine-readable): the whole
// Features/Reader directory carries NO Mirage symbol outside the two explicit
// sheet mounts in EPUBReaderScreen (analysis and graph) — page-turn code paths
// cannot reach Mirage by construction.
//
// NOTE: the real production runner spawns processes; unit tests only ever
// exercise the injected-runner paths (fake-transport doctrine, M-024).

@Suite("Mirage Page-Turn Non-Trigger (PR-6)", .serialized)
@MainActor
struct MiragePageTurnNonTriggerTests {
    /// Counting runner: records invocation count and returns a fixed status.
    private final class CountingRunner: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private let result: MirageAnalysisStatus

        init(result: MirageAnalysisStatus) { self.result = result }

        var callCount: Int {
            lock.lock(); defer { lock.unlock() }
            return calls
        }

        func call(
            _ source: MirageImportSource,
            checkCancelled: @escaping () async -> Bool
        ) async -> MirageAnalysisStatus {
            lock.lock(); calls += 1; lock.unlock()
            return result
        }
    }

    private func makeController(
        book: Book,
        runner: CountingRunner
    ) -> MirageStatusController {
        MirageStatusController(
            book: book,
            localStatus: MirageAnalysisStatus(linkState: .notImported, channel: .localMap),
            runner: { source, checkCancelled in
                await runner.call(source, checkCancelled: checkCancelled)
            })
    }

    private func makeBook() -> Book {
        Book(title: "Non-Trigger Fixture",
             author: "Fixture Author",
             fileURL: FileManager.default.temporaryDirectory
                 .appendingPathComponent("non-trigger-fixture.epub"),
             fileType: .epub,
             totalPages: 240,
             currentPage: 77)
    }

    @Test func initializationRunsNoEngineWork() {
        let runner = CountingRunner(result: MirageAnalysisStatus(
            linkState: .notImported, channel: .engineVerified))
        let controller = makeController(book: makeBook(), runner: runner)
        #expect(!controller.checking)
        #expect(controller.engineStatus == nil)
        #expect(runner.callCount == 0,
                "sheet open / controller init must never touch the engine (auto-run ban)")
    }

    @Test func positionalChangesAndReadsStayRunnerFree() {
        let runner = CountingRunner(result: MirageAnalysisStatus(
            linkState: .notImported, channel: .engineVerified))
        let controller = makeController(book: makeBook(), runner: runner)
        // The book snapshot is immutable-in-place: page positions exist only as
        // values RT's own recorder writes. No event aperture on the controller
        // observes them; reading them can't run the runner.
        let page = controller.book.currentPage
        #expect(page == 77)
        let progressed = Book(
            title: "Non-Trigger Fixture (after turn)",
            author: "Fixture Author",
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("non-trigger-fixture-2.epub"),
            fileType: .epub,
            totalPages: 240,
            currentPage: 78)
        #expect(progressed.currentPage == 78)
        #expect(runner.callCount == 0)
    }

    @Test func explicitRefreshIsTheOnlyRunnerAperture() async {
        let runner = CountingRunner(result: MirageAnalysisStatus(
            linkState: .linked(
                entry: MirageIdentityMapEntry.fromReceipt(
                    rtBookID: UUID(), mirageBookID: "book_0123456789abcdef",
                    mirageEditionID: "edition_0123456789abcdef",
                    fingerprint: String(repeating: "01", count: 32),
                    resumeHint: nil,
                    createdAt: MirageIdentityMapTime.canonical(Date())),
                counts: MirageInventoryEntry(
                    bookID: "book_0123456789abcdef", title: nil,
                    editionID: "edition_0123456789abcdef",
                    units: 5, claims: 2, maxCursor: 4, firstEntityID: nil, createdAt: nil)),
            channel: .engineVerified))
        let controller = makeController(book: makeBook(), runner: runner)

        await controller.refreshEngineStatus()
        #expect(runner.callCount == 1, "one gesture ⇒ one runner run")
        guard case .linked(_, let counts) = controller.engineStatus?.linkState else {
            Issue.record("expected linked engine status"); return
        }
        #expect(counts?.units == 5)
        // A repeat gesture runs once more — never a burst, never an auto retry.
        await controller.refreshEngineStatus()
        #expect(runner.callCount == 2)
    }

    @Test func cancelBeforeDispatchYieldsTheHonestNothingRanState() async {
        let runner = CountingRunner(result: MirageAnalysisStatus(
            linkState: .checkCancelled, channel: .engineVerified))
        let controller = makeController(book: makeBook(), runner: runner)
        controller.cancelRequested()
        await controller.refreshEngineStatus()
        #expect(runner.callCount == 1) // the runner RAN but saw the cancel flag
        #expect(controller.engineStatus?.linkState == .checkCancelled)
        #expect(MirageStatusCopy.headline(
            MirageAnalysisStatus(linkState: .checkCancelled, channel: .engineVerified))
            == "The status check was canceled — nothing was run")
    }
}
