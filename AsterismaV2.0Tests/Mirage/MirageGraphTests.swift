import CoreGraphics
import Foundation
import Testing
@testable import AsterismaV2_0

// ADR-7 amendment 1 graph tests. The engine is faked; this suite proves the
// cache-first controller, the boundary anchor, the strict decoders, and the
// deterministic layout. It does not claim a real engine graph was rendered.

@Suite("Mirage Graph (ADR-7 amendment 1)", .serialized)
@MainActor
struct MirageGraphTests {
    @MainActor
    private final class CountingLoader: MirageGraphLoading {
        var calls = 0
        var payload: MirageGraphEnginePayload?
        var failure: MirageGraphError?

        func load(
            editionID: String, chapterIndex: Int
        ) async throws -> MirageGraphEnginePayload {
            calls += 1
            if let failure { throw failure }
            guard let payload else {
                throw MirageGraphError.transport("fixture loader has no payload")
            }
            return payload
        }
    }

    private func makeBook() -> Book {
        Book(title: "Graph Fixture",
             author: "Fixture Author",
             fileURL: FileManager.default.temporaryDirectory
                 .appendingPathComponent("graph-fixture.epub"),
             fileType: .epub,
             totalPages: 240,
             currentPage: 77)
    }

    private func makeSnapshot(
        edition: String = "edition_abc",
        cursor: Int = 11,
        nodeCount: Int = 3
    ) -> MirageGraphSnapshot {
        let statuses = ["explicit_fact", "rumor", "allegation"]
        let nodes = (0..<nodeCount).map { index in
            MirageGraphNode(
                id: "n\(index)",
                entityID: "e\(index)",
                label: "Entity \(index)",
                nodeType: "character",
                epistemicStatus: statuses[index % statuses.count],
                confidence: 0.9,
                sourcePosition: index)
        }
        let edges: [MirageGraphEdge]
        if nodeCount >= 2 {
            edges = [MirageGraphEdge(
                id: "edge1",
                sourceEntityID: "e0",
                targetEntityID: "e1",
                predicate: "knows",
                epistemicStatus: "explicit_fact",
                confidence: 0.8,
                sourcePosition: 1)]
        } else {
            edges = []
        }
        return MirageGraphSnapshot(
            schema: MirageGraphSnapshot.schemaIdentifier,
            editionID: edition,
            cursorUnit: cursor,
            mode: "read_so_far",
            ledgerVersion: 1,
            projectionHash: "hash",
            nodes: nodes,
            edges: edges,
            fetchedAt: Date(timeIntervalSince1970: 0))
    }

    private func makeEntry(
        edition: String = "edition_abc",
        chapter: Int = 1,
        cursor: Int = 11
    ) -> MirageGraphCacheEntry {
        MirageGraphCacheEntry(
            schema: MirageGraphCacheEntry.schemaIdentifier,
            editionID: edition,
            rtChapterIndex: chapter,
            cursorUnit: cursor,
            snapshot: makeSnapshot(edition: edition, cursor: cursor),
            cachedAt: Date(timeIntervalSince1970: 0))
    }

    private func makeCache() -> (MirageGraphCache, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return (MirageGraphCache(directory: directory), directory)
    }

    private func chapterMapWire() -> MirageJSONValue {
        MirageJSONValue.object([
            "edition_id": .string("edition_abc"),
            "chapters": .array([
                .object([
                    "chapter_index": .int(1),
                    "first_unit_index": .int(0),
                    "last_unit_index": .int(11),
                    "unit_count": .int(12),
                ]),
                .object([
                    "chapter_index": .int(2),
                    "first_unit_index": .int(12),
                    "last_unit_index": .int(23),
                    "unit_count": .int(12),
                ]),
            ]),
        ])
    }

    private func projectionWire() -> MirageJSONValue {
        MirageJSONValue.object([
            "nodes": .array([
                .object([
                    "node_id": .string("node_1"),
                    "entity_id": .string("entity_1"),
                    "label": .string("Mirage"),
                    "node_type": .string("character"),
                    "epistemic_status": .string("explicit_fact"),
                    "confidence": .double(0.85),
                    "source_position": .int(3),
                ]),
            ]),
            "edges": .array([
                .object([
                    "edge_id": .string("edge_1"),
                    "source_entity_id": .string("entity_1"),
                    "target_entity_id": .string("entity_2"),
                    "predicate": .string("knows"),
                    "epistemic_status": .string("inference"),
                    "confidence": .double(0.7),
                    "source_position": .int(3),
                ]),
            ]),
            "metadata": .object([
                "mode": .string("read_so_far"),
                "ledger_version": .int(7),
                "projection_hash": .string("hash"),
            ]),
        ])
    }

    // MARK: - Boundaries

    @Test func chapterMapAnchorsAtThePreviousChapterLastUnit() throws {
        let map = try #require(MirageChapterMap.decode(chapterMapWire()))
        #expect(map.editionID == "edition_abc")
        #expect(map.chapters.count == 2)
        #expect(map.safeCursor(forRTChapterIndex: 0) == nil)

        let first = try #require(map.safeCursor(forRTChapterIndex: 1))
        #expect(first.previousChapterIndex == 1)
        #expect(first.cursorUnit == 11)
        #expect(first.previousChapterUnitCount == 12)

        let second = try #require(map.safeCursor(forRTChapterIndex: 2))
        #expect(second.previousChapterIndex == 2)
        #expect(second.cursorUnit == 23)
        #expect(map.safeCursor(forRTChapterIndex: 3) == nil)
    }

    @Test func chapterMapRefusesOverlapsAndImpossibleRanges() {
        let overlap = MirageJSONValue.object([
            "edition_id": .string("edition_abc"),
            "chapters": .array([
                .object([
                    "chapter_index": .int(1),
                    "first_unit_index": .int(0),
                    "last_unit_index": .int(11),
                    "unit_count": .int(12),
                ]),
                .object([
                    "chapter_index": .int(2),
                    "first_unit_index": .int(11),
                    "last_unit_index": .int(20),
                    "unit_count": .int(10),
                ]),
            ]),
        ])
        #expect(MirageChapterMap.decode(overlap) == nil)

        let inconsistentCount = MirageJSONValue.object([
            "edition_id": .string("edition_abc"),
            "chapters": .array([
                .object([
                    "chapter_index": .int(1),
                    "first_unit_index": .int(0),
                    "last_unit_index": .int(11),
                    "unit_count": .int(11),
                ]),
            ]),
        ])
        #expect(MirageChapterMap.decode(inconsistentCount) == nil)
    }

    // MARK: - Projection decoding

    @Test func projectionDecodesVerbatimAndSorted() throws {
        let snapshot = try #require(MirageGraphSnapshot.decode(
            projectionWire(),
            editionID: "edition_abc",
            cursorUnit: 11,
            now: Date(timeIntervalSince1970: 0)))
        #expect(snapshot.nodes.count == 1)
        #expect(snapshot.nodes[0].id == "node_1")
        #expect(snapshot.nodes[0].label == "Mirage")
        #expect(snapshot.edges.count == 1)
        #expect(snapshot.edges[0].predicate == "knows")
        #expect(snapshot.ledgerVersion == 7)
        #expect(snapshot.projectionHash == "hash")
        #expect(snapshot.cursorUnit == 11)
    }

    @Test func projectionRefusesMissingPinnedFields() {
        let malformed = MirageJSONValue.object([
            "nodes": .array([
                .object([
                    "node_id": .string("node_1"),
                    "entity_id": .string("entity_1"),
                    "label": .string("Mirage"),
                    "node_type": .string("character"),
                    "epistemic_status": .string("explicit_fact"),
                    "confidence": .double(0.8),
                    // source_position deliberately missing
                ]),
            ]),
            "edges": .array([]),
        ])
        #expect(MirageGraphSnapshot.decode(
            malformed, editionID: "edition_abc", cursorUnit: 11) == nil)
    }

    // MARK: - Cache

    @Test func controllerInitializationIsInert() {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let loader = CountingLoader()
        let controller = MirageGraphController(
            book: makeBook(),
            chapterIndex: 2,
            chapterTitle: "Two",
            cache: cache,
            loader: loader,
            editionResolver: { _ in "edition_abc" },
            isEnabled: { true })
        #expect(controller.state == .idle)
        #expect(loader.calls == 0)
    }

    @Test func cacheRoundTripsAndClearsOneEdition() throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entry = makeEntry()
        cache.store(entry)
        #expect(cache.count == 1)
        #expect(cache.entry(editionID: "edition_abc", chapterIndex: 1) == entry)

        let reloaded = MirageGraphCache(directory: directory)
        #expect(reloaded.entry(editionID: "edition_abc", chapterIndex: 1) == entry)

        cache.clear(editionID: "edition_abc")
        #expect(cache.entry(editionID: "edition_abc", chapterIndex: 1) == nil)
        #expect(MirageGraphCache(directory: directory)
            .entry(editionID: "edition_abc", chapterIndex: 1) == nil)
    }

    // MARK: - Controller

    @Test func cacheHitReturnsInsideTwoSecondsWithoutEngineCall() async throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        cache.store(makeEntry())
        let loader = CountingLoader()
        let controller = MirageGraphController(
            book: makeBook(),
            chapterIndex: 1,
            chapterTitle: "One",
            cache: cache,
            loader: loader,
            editionResolver: { _ in "edition_abc" },
            isEnabled: { true })

        let started = Date()
        await controller.load()
        #expect(Date().timeIntervalSince(started) < 2)
        #expect(loader.calls == 0)
        guard case .ready(let ready) = controller.state else {
            Issue.record("expected a cached ready state")
            return
        }
        #expect(ready.source == .cache)
        #expect(ready.entry.editionID == "edition_abc")
    }

    @Test func firstChapterIsInertAndMakesNoEngineCall() async {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let loader = CountingLoader()
        let controller = MirageGraphController(
            book: makeBook(),
            chapterIndex: 0,
            chapterTitle: "One",
            cache: cache,
            loader: loader,
            editionResolver: { _ in "edition_abc" },
            isEnabled: { true })
        await controller.load()
        #expect(controller.state == .firstChapter)
        #expect(loader.calls == 0)
    }

    @Test func engineFetchStoresSnapshotAndSecondSummonUsesCache() async throws {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let map = try #require(MirageChapterMap.decode(chapterMapWire()))
        let cursor = try #require(map.safeCursor(forRTChapterIndex: 1))
        let loader = CountingLoader()
        loader.payload = MirageGraphEnginePayload(
            boundaries: map,
            cursor: cursor,
            snapshot: makeSnapshot(cursor: cursor.cursorUnit))
        let controller = MirageGraphController(
            book: makeBook(),
            chapterIndex: 1,
            chapterTitle: "One",
            cache: cache,
            loader: loader,
            editionResolver: { _ in "edition_abc" },
            isEnabled: { true })

        await controller.load()
        #expect(loader.calls == 1)
        guard case .ready(let ready) = controller.state else {
            Issue.record("expected an engine ready state")
            return
        }
        #expect(ready.source == .engine)
        #expect(cache.entry(editionID: "edition_abc", chapterIndex: 1) != nil)

        let secondLoader = CountingLoader()
        let second = MirageGraphController(
            book: makeBook(),
            chapterIndex: 1,
            chapterTitle: "One",
            cache: cache,
            loader: secondLoader,
            editionResolver: { _ in "edition_abc" },
            isEnabled: { true })
        await second.load()
        #expect(secondLoader.calls == 0)
        guard case .ready(let secondReady) = second.state else {
            Issue.record("expected a cached second ready state")
            return
        }
        #expect(secondReady.source == .cache)
    }

    @Test func engineUnsupportedIsReportedTyped() async {
        let (cache, directory) = makeCache()
        defer { try? FileManager.default.removeItem(at: directory) }
        let loader = CountingLoader()
        loader.failure = .engineUnsupported
        let controller = MirageGraphController(
            book: makeBook(),
            chapterIndex: 1,
            chapterTitle: "One",
            cache: cache,
            loader: loader,
            editionResolver: { _ in "edition_abc" },
            isEnabled: { true })
        await controller.load()
        #expect(controller.state == .engineUnsupported)
    }

    // MARK: - Layout

    @Test func layoutIsDeterministicAndBounded() {
        let snapshot = makeSnapshot(nodeCount: 3)
        let size = CGSize(width: 400, height: 300)
        let layout = MirageGraphLayoutEngine.layout(
            snapshot: snapshot, size: size, maxNodes: 2)
        #expect(layout.visibleNodeIDs.count == 2)
        #expect(layout.hiddenNodeCount == 1)
        #expect(layout.positions.count == 2)
        #expect(layout.entityPositions.count == 2)
        for point in layout.positions.values {
            #expect(point.x >= 0 && point.x <= size.width)
            #expect(point.y >= 0 && point.y <= size.height)
        }
        #expect(layout == MirageGraphLayoutEngine.layout(
            snapshot: snapshot, size: size, maxNodes: 2))
    }
}
