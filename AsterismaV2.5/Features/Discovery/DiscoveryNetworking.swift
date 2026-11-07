//  DiscoveryNetworking.swift
//  AsterismaV2.5
//
//  Bounded networking for the two online discovery providers.
//
//  Discovery is the only part of the app that cannot work without a network.
//  It must still fail quickly and quietly when the machine is offline: a
//  search is an optional browse surface, never a gate in front of the local
//  library. The default URLSession request timeout (60 s) made an offline
//  search look like a frozen sheet, and two providers queried one after the
//  other could double that wait.
//
//  This session is ephemeral, never waits for connectivity, and caps both a
//  single request and the whole resource load. The providers are injectable
//  so tests can prove the failure path without touching the real network.

import Foundation

nonisolated enum DiscoveryNetworking {
    /// Maximum time a single provider request may take.
    static let requestTimeout: TimeInterval = 10

    /// Hard ceiling for one request including connection setup.
    static let resourceTimeout: TimeInterval = 15

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()
}
