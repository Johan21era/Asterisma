import Foundation
import Testing
@testable import AsterismaV2_5

// PR-5 mount-contract pins (fake/free — no sidecar, no file system dragon):
// The app glue's ONLY RT borrow is the read-only Book referent; engine
// discovery is gated; outcome copy never claims an undo that didn't happen.

@Suite("Mirage App Import Mount (PR-5)", .serialized)
@MainActor
struct MirageAppImportMountTests {
    @Test func engineDiscoveryIgnoresGarbageDirectory() {
        // Garbage value must NOT be discovered even if the variable is present;
        // robust against the opt-in test harness itself setting the variable.
        setenv("MIRAGE_REAL_ENGINE_DIR", "/nonexistent-mirage-checkout-\(UUID().uuidString)", 1)
        defer { unsetenv("MIRAGE_REAL_ENGINE_DIR") }
        #expect(MirageAppImportMount.engineCheckoutDirectory() == nil)
    }

    @Test func importSourceBorrowsOnlyTheReferent() {
        var book = Book(title: " Mirage Mount Fixture", author: "fixture",
                        fileURL: URL(fileURLWithPath: "/tmp/mirage-mount-fixture.epub"),
                        fileType: .epub, totalPages: 1, currentPage: 1)
        book.bookmarkData = nil // the resolver falls back to the raw fileURL

        let source = MirageAppImportMount.importSource(for: book)
        #expect(source.rtBookID == book.id)
        #expect(source.fileTypeIsEpub == true)
        #expect(source.resolveURL() == book.fileURL) // referent passes through

        // PDF books are typed out at the source level — no engine routing.
        var half = book
        half.fileType = .pdf
        #expect(MirageAppImportMount.importSource(for: half).fileTypeIsEpub == false)
    }

    @Test func outcomeCopyNeverClaimsAnUndo() {
        // The owner-approved honesty rule: cancel-with-engine-commit says the
        // stored analysis STAYS; cancel-before-dispatch says nothing was run.
        let stored = MirageOutcomeCopy.detail(.cancelled(engineCommitted: true))
        #expect(stored.contains("already stored"))
        #expect(!stored.lowercased().contains("removed"))
        #expect(!stored.lowercased().contains("undone"))

        let clean = MirageOutcomeCopy.detail(.cancelled(engineCommitted: false))
        #expect(clean.contains("Nothing was run"))
    }
}
