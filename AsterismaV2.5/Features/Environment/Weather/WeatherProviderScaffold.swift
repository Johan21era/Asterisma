//  WeatherProviderScaffold.swift
//  AsterismaV2.5
//
//  Modular weather-provider seam. Open-Meteo is the active, entitlement-free
//  source. WeatherKit is represented here as an honest, unconfigured provider:
//  it throws `notConfigured` and never returns invented conditions.
//
//  When the project is linked against an entitled Apple Developer account, the
//  only required change is inside WeatherKitProvider.snapshot(at:location:):
//  fetch `CurrentWeather` and map it through the existing
//  WeatherSnapshotNormaliser. No call site, engine, view, or state type needs
//  to change.

import CoreLocation
import Foundation

nonisolated enum WeatherProviderKind: String, CaseIterable, Sendable {
    case openMeteo
    case weatherKit

    var displayName: String {
        switch self {
        case .openMeteo: return "Open-Meteo"
        case .weatherKit: return "WeatherKit"
        }
    }

    /// WeatherKit requires an Apple Developer entitlement and a configured
    /// WeatherKit capability. The scaffold is integration-ready but not live.
    var isConfigured: Bool {
        switch self {
        case .openMeteo: return true
        case .weatherKit: return false
        }
    }
}

enum WeatherProviderError: Error, LocalizedError, Equatable {
    case notConfigured(WeatherProviderKind)

    var errorDescription: String? {
        switch self {
        case let .notConfigured(kind):
            return "\(kind.displayName) is not configured. The provider scaffold is present, but no live data is available."
        }
    }
}

/// Scaffold only. This deliberately does not fabricate a `WeatherSnapshot`.
nonisolated struct WeatherKitProvider: WeatherProviding {
    func snapshot(
        at timestamp: Date,
        location: CLLocation
    ) async throws -> WeatherSnapshot {
        throw WeatherProviderError.notConfigured(.weatherKit)
    }
}

nonisolated enum WeatherProviderFactory {
    static func make(kind: WeatherProviderKind) -> WeatherProviding {
        switch kind {
        case .openMeteo:
            return OpenMeteoProvider()
        case .weatherKit:
            return WeatherKitProvider()
        }
    }
}
