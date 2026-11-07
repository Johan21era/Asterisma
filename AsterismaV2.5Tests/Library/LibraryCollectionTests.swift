//  LibraryCollectionTests.swift
//  AsterismaV2.5Tests
//
//  Phase 2 regression battery — Progressive Filtering model layer.
//
//  Pins DataStore's collection CRUD (the creation half LibraryFilterSidebarView
//  deliberately lacks) and, critically, the REFERENTIAL INTEGRITY contract on
//  removal: deleting a collection must strip its id from every book, so
//  Book.collectionIDs never carries dangling references and downstream
//  LibraryFilterState.apply(to:) can never match a ghost collection.

import Foundation
import Testing

@testable import AsterismaV2_5

@Suite("Library Collections — Phase 2 model layer")
@MainActor
struct LibraryCollectionTests {

    private func makeStore() -> DataStore {
        // ISOLATION MATTERS: stateURL is derived from fileURL's PARENT directory.
        // Dropping the .json straight into the shared temp root made every store
        // load/write one shared library-state.json — tests leaked collections into
        // each other (and across runs). Each store gets its own directory.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return DataStore(fileURL: dir.appendingPathComponent("library.json"))
    }

    private func makeBook(title: String) -> Book {
        Book(title: title, author: "A",
             fileURL: URL(fileURLWithPath: "/tmp/\(title).pdf"), fileType: .pdf)
    }

    @Test("addCollection persists and normalizes names")
    func addPersistsAndNormalizes() {
        let store = makeStore()
        let c1 = store.addCollection(name: "  Beach Reads  ")
        #expect(store.libraryState.collections.count == 1)
        #expect(c1.name == "Beach Reads")

        _ = store.addCollection(name: "   ")
        #expect(store.libraryState.collections.count == 2)
        #expect(store.libraryState.collections.last?.name == "Untitled Collection")
    }

    @Test("renameCollection updates in place; unknown ids and blank names are no-ops")
    func renameGuards() {
        let store = makeStore()
        let c = store.addCollection(name: "Before")
        store.renameCollection(id: c.id, to: "After")
        #expect(store.libraryState.collections[0].name == "After")

        store.renameCollection(id: UUID(), to: "Ghost")          // unknown id — no-op
        store.renameCollection(id: c.id, to: "   ")               // blank — no-op
        #expect(store.libraryState.collections[0].name == "After")
        #expect(store.libraryState.collections.count == 1)
    }

    @Test("membership toggles are exact and idempotent")
    func membershipToggle() {
        let store = makeStore()
        let book = makeBook(title: "Moby Dick")
        store.addBook(book)
        let c = store.addCollection(name: "Whales")

        store.setBook(book.id, membershipIn: c.id, isMember: true)
        #expect(store.book(id: book.id)?.collectionIDs == [c.id])

        store.setBook(book.id, membershipIn: c.id, isMember: true)   // idempotent
        #expect(store.book(id: book.id)?.collectionIDs.count == 1)

        store.setBook(book.id, membershipIn: c.id, isMember: false)
        #expect(store.book(id: book.id)?.collectionIDs.isEmpty == true)

        store.setBook(book.id, membershipIn: c.id, isMember: false)  // idempotent
        store.setBook(UUID(), membershipIn: c.id, isMember: true)    // unknown book — no-op
        #expect(true)
    }

    @Test("THE integrity pin: removing a collection strips every book's dangling id")
    func removalStripsDanglingReferences() {
        let store = makeStore()
        let a = makeBook(title: "A"); let b = makeBook(title: "B")
        store.addBook(a); store.addBook(b)

        let doomed = store.addCollection(name: "Doomed")
        let survivor = store.addCollection(name: "Survivor")

        store.setBook(a.id, membershipIn: doomed.id, isMember: true)
        store.setBook(a.id, membershipIn: survivor.id, isMember: true)
        store.setBook(b.id, membershipIn: doomed.id, isMember: true)

        store.removeCollection(id: doomed.id)

        #expect(store.libraryState.collections.map(\.name) == ["Survivor"])
        #expect(store.book(id: a.id)?.collectionIDs == [survivor.id])
        #expect(store.book(id: b.id)?.collectionIDs.isEmpty == true)

        // Downstream consequence: the filter can never resurrect the ghost.
        var filter = LibraryFilterState.none
        filter.selectedCollectionID = doomed.id
        #expect(filter.apply(to: store.books).isEmpty)
        filter.selectedCollectionID = survivor.id
        #expect(filter.apply(to: store.books).map(\.title) == ["A"])
    }

    @Test("removing an unknown collection is a no-op")
    func removeUnknownIsNoop() {
        let store = makeStore()
        _ = store.addCollection(name: "Keep")
        store.removeCollection(id: UUID())
        #expect(store.libraryState.collections.count == 1)
    }
}
