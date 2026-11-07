import CoreLocation
import Foundation
import Testing
@testable import AsterismaV2_5

private func liveWeatherEnabled() -> Bool {
    ProcessInfo.processInfo.environment["RT_OPENMETEO_LIVE"] == "1"
        || ProcessInfo.processInfo.environment["TEST_RUNNER_RT_OPENMETEO_LIVE"] == "1"
}

@Suite(
    "G4 · Open-Meteo live smoke (opt-in)",
    .enabled(if: liveWeatherEnabled())
)
struct OpenMeteoLiveSmokeTests {
    @Test("A real current-conditions request produces a valid snapshot")
    func liveCurrentConditions() async throws {
        let provider = OpenMeteoProvider()
        let location = CLLocation(latitude: 40.7128, longitude: -74.0060)
        let snapshot = try await provider.snapshot(at: Date(), location: location)
        #expect(snapshot.timestamp.timeIntervalSinceNow > -60)
        #expect(snapshot.temperatureCelsius > -80 && snapshot.temperatureCelsius < 70)
        #expect(snapshot.humidity >= 0 && snapshot.humidity <= 1)
        #expect(snapshot.cloudCover >= 0 && snapshot.cloudCover <= 1)
        #expect(snapshot.condition != .unknown)
    }
}
