import Combine
import Foundation

nonisolated enum MirageGraphError: Error, Equatable, Sendable {
    case engineUnsupported
    case editionUnavailable(String)
    case malformedBoundaries(String)
    case malformedProjection(String)
    case firstChapter
    case transport(String)
    case cancelled

    var userMessage: String {
        switch self {
        case .engineUnsupported:
            return "This Mirage engine build doesn't expose chapter boundaries yet. "
                + "The graph stays closed and nothing was read from the ledger."
        case .editionUnavailable(let reason):
            return "Mirage couldn't open this edition. \(reason)"
        case .malformedBoundaries(let reason):
            return "Mirage's chapter boundaries did not match the pinned shape. \(reason)"
        case .malformedProjection(let reason):
            return "Mirage's graph projection did not match the pinned shape. \(reason)"
        case .firstChapter:
            return "The graph starts after Chapter 1. This book has no earlier chapter boundary yet."
        case .transport(let reason):
            return "Mirage's engine could not be reached. \(reason)"
        case .cancelled:
            return "The graph request was canceled."
        }
    }
}

nonisolated struct MirageGraphEnginePayload: Sendable {
    let boundaries: MirageChapterMap
    let cursor: MirageChapterBoundaryCursor
    let snapshot: MirageGraphSnapshot
}

@MainActor
protocol MirageGraphLoading: AnyObject {
    func load(editionID: String, chapterIndex: Int) async throws -> MirageGraphEnginePayload
}

/// Production loader: one warm-session lease, two read-only wire calls:
/// `edition_chapters` then the projection at the boundary-derived cursor.
/// If the engine predates the amendment, the first call is refused with a
/// validation error and the UI reports the capability gap honestly.
@MainActor
final class MirageLiveGraphLoader: MirageGraphLoading {
    func load(editionID: String, chapterIndex: Int) async throws -> MirageGraphEnginePayload {
        do {
            return try await MirageEngineService.shared.withEngine { client, _ in
                let boundaryOutcome = try await client.perform(
                    .editionChapters,
                    payload: .payload(["edition_id": .string(editionID)]))

                let boundaries: MirageChapterMap
                switch boundaryOutcome {
                case .success(let result):
                    guard let decoded = MirageChapterMap.decode(result) else {
                        throw MirageGraphError.malformedBoundaries(
                            "result lacked the pinned chapter range shape")
                    }
                    boundaries = decoded
                case .engineError(let error):
                    if error.code == "validation_error",
                       (error.status == 404
                        || error.message.localizedCaseInsensitiveContains("unknown command")) {
                        throw MirageGraphError.engineUnsupported
                    }
                    throw MirageGraphError.editionUnavailable(error.message)
                }

                guard boundaries.editionID == editionID else {
                    throw MirageGraphError.malformedBoundaries(
                        "engine returned boundaries for a different edition")
                }
                guard let cursor = boundaries.safeCursor(forRTChapterIndex: chapterIndex) else {
                    throw MirageGraphError.firstChapter
                }

                let request = MirageDetailRequest(
                    action: .projection,
                    editionID: editionID,
                    cursor: .chapterBoundary(cursor))
                let line = try MirageDetailQuery.preflight(
                    request, mappedEditionID: editionID)

                let projectionOutcome: MirageClient.Outcome
                do {
                    projectionOutcome = try await client.perform(
                        line.action, payload: line.payload)
                } catch let error as MirageGraphError {
                    throw error
                } catch {
                    throw MirageGraphError.transport(String(describing: error))
                }

                switch projectionOutcome {
                case .success(let result):
                    guard let snapshot = MirageGraphSnapshot.decode(
                        result,
                        editionID: editionID,
                        cursorUnit: cursor.cursorUnit)
                    else {
                        throw MirageGraphError.malformedProjection(
                            "result lacked the pinned node/edge shape")
                    }
                    return MirageGraphEnginePayload(
                        boundaries: boundaries,
                        cursor: cursor,
                        snapshot: snapshot)
                case .engineError(let error):
                    throw MirageGraphError.editionUnavailable(error.message)
                }
            }
        } catch let error as MirageGraphError {
            throw error
        } catch let error as MirageEngineServiceError {
            throw MirageGraphError.transport(error.plainReason)
        } catch {
            throw MirageGraphError.transport(String(describing: error))
        }
    }
}

@MainActor
final class MirageGraphController: ObservableObject {
    enum Source: Equatable, Sendable {
        case cache
        case engine
    }

    struct Ready: Equatable, Sendable {
        let entry: MirageGraphCacheEntry
        let source: Source
        let milliseconds: Int
    }

    enum State: Equatable {
        case idle
        case loading
        case ready(Ready)
        case firstChapter
        case engineUnsupported
        case unavailable(String)
        case failed(String)
    }

    let book: Book
    let chapterIndex: Int
    let chapterTitle: String

    @Published private(set) var state: State = .idle
    @Published private(set) var lastLoadMilliseconds: Int?

    private let cache: MirageGraphCache
    private let loader: any MirageGraphLoading
    private let editionResolver: (UUID) -> String?
    private let isEnabled: () -> Bool
    private var isLoading = false

    init(
        book: Book,
        chapterIndex: Int,
        chapterTitle: String,
        cache: MirageGraphCache? = nil,
        loader: (any MirageGraphLoading)? = nil,
        editionResolver: ((UUID) -> String?)? = nil,
        isEnabled: @escaping () -> Bool = { MirageSettings.isEnabled }
    ) {
        self.book = book
        self.chapterIndex = chapterIndex
        self.chapterTitle = chapterTitle
        self.cache = cache ?? MirageGraphCache.shared
        self.loader = loader ?? MirageLiveGraphLoader()
        self.editionResolver = editionResolver ?? Self.activeEditionID
        self.isEnabled = isEnabled
    }

    /// Explicit graph gesture only. Initialization is inert so reader page
    /// turns can never reach the engine.
    func load(force: Bool = false) async {
        guard !isLoading else { return }
        guard isEnabled() else {
            state = .unavailable("Mirage is turned off in Settings ▸ Mirage.")
            return
        }
        guard chapterIndex > 0 else {
            state = .firstChapter
            return
        }
        guard let editionID = editionResolver(book.id), !editionID.isEmpty else {
            state = .unavailable("Analyze this book with Mirage first.")
            return
        }

        if !force, let entry = cache.entry(
            editionID: editionID, chapterIndex: chapterIndex) {
            state = .ready(Ready(entry: entry, source: .cache, milliseconds: 0))
            return
        }

        isLoading = true
        state = .loading
        defer { isLoading = false }
        let started = Date()
        do {
            let payload = try await loader.load(
                editionID: editionID, chapterIndex: chapterIndex)
            let entry = MirageGraphCacheEntry(
                schema: MirageGraphCacheEntry.schemaIdentifier,
                editionID: editionID,
                rtChapterIndex: chapterIndex,
                cursorUnit: payload.cursor.cursorUnit,
                snapshot: payload.snapshot,
                cachedAt: Date())
            cache.store(entry)
            let milliseconds = max(
                0, Int(Date().timeIntervalSince(started) * 1000))
            lastLoadMilliseconds = milliseconds
            state = .ready(Ready(
                entry: entry, source: .engine, milliseconds: milliseconds))
        } catch let error as MirageGraphError {
            state = failedState(for: error)
        } catch {
            state = .failed("The graph could not be prepared. \(error.localizedDescription)")
        }
    }

    private func failedState(for error: MirageGraphError) -> State {
        switch error {
        case .engineUnsupported: return .engineUnsupported
        case .firstChapter: return .firstChapter
        case .cancelled: return .failed("The graph request was canceled.")
        default: return .failed(error.userMessage)
        }
    }

    nonisolated private static func activeEditionID(for bookID: UUID) -> String? {
        let store = MirageIdentityMapStore(
            fileURL: MirageSupportPaths.mirageDirectory()
                .appendingPathComponent("identity-map.json"))
        switch store.load() {
        case .loaded(let map):
            return map.activeEntry(for: bookID)?.mirageEditionID
        case .unreadable:
            return nil
        }
    }
}
