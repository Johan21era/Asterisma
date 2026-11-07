import Foundation
import Testing
@testable import AsterismaV2_5

private func weatherLiveEnabled() -> Bool {
    ProcessInfo.processInfo.environment["RT_OPENMETEO_LIVE"] == "1"
        || ProcessInfo.processInfo.environment["TEST_RUNNER_RT_OPENMETEO_LIVE"] == "1"
}

@Suite(
    "G4 · Weather live pipeline (opt-in)",
    .enabled(if: weatherLiveEnabled()),
    .serialized
)
@MainActor
final class WeatherLivePipelineTests {

    @Test("Session end → Open-Meteo snapshot → SQLite → range query")
    func liveSessionSnapshotPersists() async throws {
        let defaults = UserDefaults.standard
        defaults.set(40.7128, forKey: "wks_manual_lat")
        defaults.set(-74.0060, forKey: "wks_manual_lon")
        defer {
            defaults.removeObject(forKey: "wks_manual_lat")
            defaults.removeObject(forKey: "wks_manual_lon")
        }

        let sessionID = UUID()
        let snapshot = try await WeatherKitService.shared
            .snapshotForCurrentConditions(sessionID: sessionID)

        #expect(snapshot.condition != .unknown)
        #expect(snapshot.humidity >= 0 && snapshot.humidity <= 1)

        let stored = try WeatherKitService.shared.snapshots(
            from: snapshot.timestamp.addingTimeInterval(-120),
            to: snapshot.timestamp.addingTimeInterval(120))
        #expect(stored.contains { $0.id == snapshot.id })

        let coverage = try WeatherKitService.shared.coverageRatio(for: [sessionID])
        #expect(coverage == 1.0)
    }
}
