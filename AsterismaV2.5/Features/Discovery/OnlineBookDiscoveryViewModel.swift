//  OnlineBookDiscoveryViewModel.swift
//  Online Book Discovery System
//
//  Swift Concurrency only.
//  No Combine pipelines.
//  Auto-search with 500ms debounce.
//  Network monitoring via NWPathMonitor.
//

import Combine
import Foundation
import Network

@MainActor
final class BookDiscoveryViewModel: ObservableObject {
    @Published var query = "" {
        didSet {
            scheduleSearch()
        }
    }

    @Published var results: [OnlineBook] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var isOffline = false

    private let service: BookDiscoveryService
    private var searchTask: Task<Void, Never>?
    private let monitor: NWPathMonitor
    private let monitorQueue = DispatchQueue(
        label: "BookDiscovery.NetworkMonitor"
    )

    init(
        monitor: NWPathMonitor = NWPathMonitor(),
        service: BookDiscoveryService = BookDiscoveryService()
    ) {
        self.monitor = monitor
        self.service = service
        startNetworkMonitoring()
    }

    deinit {
        searchTask?.cancel()
        monitor.cancel()
    }

    func searchNow() {
        scheduleSearch(immediate: true)
    }
}

// MARK: - Search

private extension BookDiscoveryViewModel {
    func scheduleSearch(
        immediate: Bool = false
    ) {
        searchTask?.cancel()

        let trimmedQuery = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard trimmedQuery.count >= 3 else {
            results = []
            errorMessage = nil
            isLoading = false
            return
        }

        guard !isOffline else {
            cancelSearch()
            results = []
            errorMessage = nil
            isLoading = false
            return
        }

        searchTask = Task { [weak self] in
            guard let self else { return }

            if !immediate {
                do {
                    try await Task.sleep(
                        for: .milliseconds(500)
                    )
                } catch {
                    return
                }
            }

            guard !Task.isCancelled else {
                return
            }

            await self.performSearch(
                query: trimmedQuery
            )
        }
    }

    func performSearch(
        query: String
    ) async {
        guard !Task.isCancelled, !isOffline else {
            return
        }

        isLoading = true
        errorMessage = nil

        let searchResults = await service.searchBooks(
            query: query
        )

        guard !Task.isCancelled, !isOffline else {
            return
        }

        results = searchResults
        isLoading = false
        errorMessage = nil
    }

    func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
    }
}

// MARK: - Network Monitoring

private extension BookDiscoveryViewModel {
    func startNetworkMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }

                let offline = path.status != .satisfied

                self.isOffline = offline

                if offline {
                    // Cancel an in-flight search immediately. Without this,
                    // a search started before the network dropped could keep
                    // a second provider request alive and later overwrite the
                    // offline state with an empty result set.
                    self.cancelSearch()
                    self.results = []
                    self.isLoading = false
                    self.errorMessage = nil

                } else {
                    self.errorMessage = nil

                    let trimmedQuery = self.query
                        .trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )

                    if trimmedQuery.count >= 3 {
                        self.searchNow()
                    }
                }
            }
        }

        monitor.start(
            queue: monitorQueue
        )
    }
}
