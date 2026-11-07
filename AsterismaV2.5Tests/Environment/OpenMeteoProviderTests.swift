//  OpenMeteoProviderTests.swift
//  Bedrock G4 pins: provider mapping, request shape, archive path, failures.

import CoreLocation
import Foundation
import Testing
@testable import AsterismaV2_5

@Suite("G4 · Open-Meteo provider", .serialized)
struct OpenMeteoProviderTests {

    private let location = CLLocation(latitude: 40.7128, longitude: -74.0060)

    private func response(_ code: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.open-meteo.com")!,
            statusCode: code,
            httpVersion: nil,
            headerFields: nil)!
    }

    private let currentJSON = """
    {
      "current": {
        "time": "2026-10-24T12:00",
        "temperature_2m": 18.5,
        "relative_humidity_2m": 55,
        "apparent_temperature": 17.8,
        "precipitation": 0.4,
        "snowfall": 2.0,
        "cloud_cover": 40,
        "pressure_msl": 1012.3,
        "wind_speed_10m": 14.2,
        "visibility": 10000,
        "weather_code": 61
      }
    }
    """

    @Test("Current conditions map into WeatherSnapshot units and category")
    func currentMapping() async throws {
        let provider = OpenMeteoProvider { request in
            #expect(request.url?.absoluteString.contains("latitude=40.7128") == true)
            #expect(request.url?.absoluteString.contains("current=") == true)
            #expect(request.timeoutInterval == OpenMeteoProvider.requestTimeout)
            #expect(OpenMeteoProvider.requestTimeout <= 10)
            return (Data(currentJSON.utf8), response(200))
        }
        let snapshot = try await provider.snapshot(at: Date(), location: location)

        #expect(snapshot.temperatureCelsius == 18.5)
        #expect(snapshot.feelsLikeTemperatureCelsius == 17.8)
        #expect(snapshot.humidity == 0.55)
        #expect(snapshot.cloudCover == 0.40)
        #expect(snapshot.visibilityKilometers == 10)
        #expect(snapshot.windSpeedKPH == 14.2)
        #expect(snapshot.precipitationMillimeters == 0.4)
        #expect(snapshot.snowfallMillimeters == 20) // cm → mm
        #expect(snapshot.condition == .rain)
        #expect(snapshot.month == Calendar.current.component(.month, from: Date()))
    }

    @Test("HTTP failures are typed, not silent")
    func badStatus() async {
        let provider = OpenMeteoProvider { _ in
            (Data(), self.response(503))
        }
        await #expect(throws: OpenMeteoError.self) {
            _ = try await provider.snapshot(at: Date(), location: self.location)
        }
    }

    @Test("Malformed payloads fail closed")
    func malformedPayload() async {
        let provider = OpenMeteoProvider { _ in
            (Data("{}".utf8), self.response(200))
        }
        await #expect(throws: OpenMeteoError.self) {
            _ = try await provider.snapshot(at: Date(), location: self.location)
        }
    }

    @Test("Offline failures are typed, not served as fabricated weather")
    func offlineFailure() async {
        let provider = OpenMeteoProvider { _ in
            throw URLError(.notConnectedToInternet)
        }
        await #expect(throws: URLError.self) {
            _ = try await provider.snapshot(at: Date(), location: self.location)
        }
    }

    @Test("WMO weather codes map to the app's categories")
    func weatherCodeMapping() {
        #expect(OpenMeteoProvider.condition(for: 0) == .clear)
        #expect(OpenMeteoProvider.condition(for: 2) == .partlyCloudy)
        #expect(OpenMeteoProvider.condition(for: 3) == .cloudy)
        #expect(OpenMeteoProvider.condition(for: 45) == .fog)
        #expect(OpenMeteoProvider.condition(for: 61) == .rain)
        #expect(OpenMeteoProvider.condition(for: 65) == .heavyRain)
        #expect(OpenMeteoProvider.condition(for: 75) == .snow)
        #expect(OpenMeteoProvider.condition(for: 95) == .storm)
    }

    @Test("Older timestamps use the archive endpoint and pick the right hour")
    func archiveMapping() async throws {
        let archiveJSON = """
        {
          "hourly": {
            "time": ["2026-10-24T00:00","2026-10-24T01:00","2026-10-24T02:00","2026-10-24T03:00","2026-10-24T04:00","2026-10-24T05:00","2026-10-24T06:00","2026-10-24T07:00","2026-10-24T08:00","2026-10-24T09:00","2026-10-24T10:00","2026-10-24T11:00","2026-10-24T12:00","2026-10-24T13:00","2026-10-24T14:00","2026-10-24T15:00","2026-10-24T16:00","2026-10-24T17:00","2026-10-24T18:00","2026-10-24T19:00","2026-10-24T20:00","2026-10-24T21:00","2026-10-24T22:00","2026-10-24T23:00"],
            "temperature_2m": [10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33],
            "relative_humidity_2m": [50,50,50,50,50,50,50,50,50,50,50,50,55,50,50,50,50,50,50,50,50,50,50,50],
            "apparent_temperature": [9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32],
            "precipitation": [0,0,0,0,0,0,0,0,0,0,0,0,0.4,0,0,0,0,0,0,0,0,0,0,0],
            "snowfall": [0,0,0,0,0,0,0,0,0,0,0,0,2,0,0,0,0,0,0,0,0,0,0,0],
            "cloud_cover": [0,0,0,0,0,0,0,0,0,0,0,0,40,0,0,0,0,0,0,0,0,0,0,0],
            "pressure_msl": [1012,1012,1012,1012,1012,1012,1012,1012,1012,1012,1012,1012,1012,1012,1012,1012,1012,1012,1012,1012,1012,1012,1012,1012],
            "wind_speed_10m": [14,14,14,14,14,14,14,14,14,14,14,14,14.2,14,14,14,14,14,14,14,14,14,14,14],
            "visibility": [10000,10000,10000,10000,10000,10000,10000,10000,10000,10000,10000,10000,10000,10000,10000,10000,10000,10000,10000,10000,10000,10000,10000,10000],
            "weather_code": [0,0,0,0,0,0,0,0,0,0,0,0,61,0,0,0,0,0,0,0,0,0,0,0]
          }
        }
        """
        let day = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let oldTimestamp = day.addingTimeInterval(-24 * 3600)
        let provider = OpenMeteoProvider { request in
            #expect(request.url?.absoluteString.contains("archive-api.open-meteo.com") == true)
            #expect(request.url?.absoluteString.contains("start_date=") == true)
            return (Data(archiveJSON.utf8), self.response(200))
        }
        let snapshot = try await provider.snapshot(at: oldTimestamp, location: location)
        #expect(snapshot.temperatureCelsius == 22)
        #expect(snapshot.humidity == 0.55)
        #expect(snapshot.condition == .rain)
        #expect(snapshot.snowfallMillimeters == 20)
    }
}
