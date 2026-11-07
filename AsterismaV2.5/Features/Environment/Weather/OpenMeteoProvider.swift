//  OpenMeteoProvider.swift
//  Bedrock G4 — the entitlement-free weather source.
//
//  Open-Meteo needs no Apple Developer entitlement and returns current,
//  hourly, and archive data. The provider stays behind a protocol so WeatherKit
//  can return later without touching call sites.

import CoreLocation
import Foundation

protocol WeatherProviding: Sendable {
    func snapshot(at timestamp: Date, location: CLLocation) async throws -> WeatherSnapshot
}

enum OpenMeteoError: Error, LocalizedError {
    case badStatus(Int)
    case malformedResponse
    case noHistoricalData(Date)

    var errorDescription: String? {
        switch self {
        case let .badStatus(code): return "Open-Meteo returned HTTP \(code)."
        case .malformedResponse: return "Open-Meteo returned an unexpected response."
        case let .noHistoricalData(date): return "No Open-Meteo history for \(date)."
        }
    }
}

/// Default network provider. `fetch` is injectable for deterministic tests.
nonisolated struct OpenMeteoProvider: WeatherProviding {
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let fetch: Fetch
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
        self.fetch = { request in
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw OpenMeteoError.malformedResponse
            }
            return (data, http)
        }
    }

    init(fetch: @escaping Fetch) {
        self.session = .shared
        self.fetch = fetch
    }

    func snapshot(at timestamp: Date, location: CLLocation) async throws -> WeatherSnapshot {
        // Sessions are captured at close time. If the timestamp is more than a
        // few hours old, ask the archive endpoint; otherwise use current.
        if timestamp < Date().addingTimeInterval(-6 * 3600) {
            return try await archiveSnapshot(at: timestamp, location: location)
        }
        return try await currentSnapshot(at: timestamp, location: location)
    }

    // MARK: - Current

    private func currentSnapshot(at timestamp: Date, location: CLLocation) async throws -> WeatherSnapshot {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(location.coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(location.coordinate.longitude)),
            URLQueryItem(name: "current", value: [
                "temperature_2m", "relative_humidity_2m", "apparent_temperature",
                "precipitation", "rain", "snowfall", "cloud_cover", "pressure_msl",
                "wind_speed_10m", "visibility", "weather_code",
            ].joined(separator: ",")),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        let data = try await get(components.url!)
        let decoded = try JSONDecoder().decode(CurrentResponse.self, from: data)
        guard let current = decoded.current else { throw OpenMeteoError.malformedResponse }
        return snapshot(
            timestamp: timestamp,
            location: location,
            temperature: current.temperature2m,
            feelsLike: current.apparentTemperature,
            humidity: current.relativeHumidity2m,
            pressure: current.pressureMsl,
            cloudCover: current.cloudCover,
            visibilityMeters: current.visibility,
            windKPH: current.windSpeed10m,
            precipitationMM: current.precipitation,
            snowfallCM: current.snowfall,
            weatherCode: current.weatherCode)
    }

    // MARK: - Archive (historical backfill)

    private func archiveSnapshot(at timestamp: Date, location: CLLocation) async throws -> WeatherSnapshot {
        let day = Self.dayFormatter.string(from: timestamp)
        var components = URLComponents(string: "https://archive-api.open-meteo.com/v1/archive")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(location.coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(location.coordinate.longitude)),
            URLQueryItem(name: "start_date", value: day),
            URLQueryItem(name: "end_date", value: day),
            URLQueryItem(name: "hourly", value: [
                "temperature_2m", "relative_humidity_2m", "apparent_temperature",
                "precipitation", "snowfall", "cloud_cover", "pressure_msl",
                "wind_speed_10m", "visibility", "weather_code",
            ].joined(separator: ",")),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        let data = try await get(components.url!)
        let decoded = try JSONDecoder().decode(ArchiveResponse.self, from: data)
        guard let hourly = decoded.hourly else { throw OpenMeteoError.malformedResponse }
        let hour = Calendar.current.component(.hour, from: timestamp)
        guard hour >= 0, hour < hourly.time.count,
              let temperature = hourly.temperature2m?[safe: hour],
              let feelsLike = hourly.apparentTemperature?[safe: hour],
              let humidity = hourly.relativeHumidity2m?[safe: hour],
              let pressure = hourly.pressureMsl?[safe: hour],
              let cloud = hourly.cloudCover?[safe: hour],
              let visibility = hourly.visibility?[safe: hour],
              let wind = hourly.windSpeed10m?[safe: hour],
              let precipitation = hourly.precipitation?[safe: hour],
              let code = hourly.weatherCode?[safe: hour]
        else { throw OpenMeteoError.noHistoricalData(timestamp) }

        return snapshot(
            timestamp: timestamp,
            location: location,
            temperature: temperature,
            feelsLike: feelsLike,
            humidity: humidity,
            pressure: pressure,
            cloudCover: cloud,
            visibilityMeters: visibility,
            windKPH: wind,
            precipitationMM: precipitation,
            snowfallCM: hourly.snowfall?[safe: hour] ?? 0,
            weatherCode: code)
    }

    // MARK: - Mapping

    private func snapshot(
        timestamp: Date,
        location: CLLocation,
        temperature: Double,
        feelsLike: Double,
        humidity: Double,
        pressure: Double,
        cloudCover: Double,
        visibilityMeters: Double,
        windKPH: Double,
        precipitationMM: Double,
        snowfallCM: Double,
        weatherCode: Int
    ) -> WeatherSnapshot {
        let condition = Self.condition(for: weatherCode)
        let storm = (condition == .storm ? 0.5 : 0)
            + min(max(windKPH / 120.0, 0), 1) * 0.3
            + min(max(precipitationMM / 50.0, 0), 1) * 0.2
        let normaliser = WeatherSnapshotNormaliser()
        return WeatherSnapshot(
            timestamp: timestamp,
            temperatureCelsius: temperature,
            feelsLikeTemperatureCelsius: feelsLike,
            humidity: humidity / 100.0,
            pressure: pressure,
            cloudCover: cloudCover / 100.0,
            visibilityKilometers: visibilityMeters / 1000.0,
            windSpeedKPH: windKPH,
            precipitationMillimeters: precipitationMM,
            snowfallMillimeters: snowfallCM * 10.0,
            stormActivityIndex: min(max(storm, 0), 1),
            condition: condition,
            season: normaliser.deriveSeason(
                from: timestamp, latitude: location.coordinate.latitude),
            month: Calendar.current.component(.month, from: timestamp),
            weekday: Calendar.current.component(.weekday, from: timestamp),
            dayPeriod: normaliser.deriveDayPeriod(from: timestamp))
    }

    static func condition(for code: Int) -> WeatherConditionCategory {
        switch code {
        case 0: return .clear
        case 1, 2: return .partlyCloudy
        case 3: return .cloudy
        case 45, 48: return .fog
        case 51, 53, 55, 56, 57: return .rain
        case 61, 63, 80, 81: return .rain
        case 65, 66, 67, 82: return .heavyRain
        case 71, 73, 75, 77, 85: return .snow
        case 86: return .heavySnow
        case 95, 96, 99: return .storm
        default: return .unknown
        }
    }

    /// Bounded even though this is enrichment: an offline session close must
    /// not leave a background weather request waiting on the default timeout.
    static let requestTimeout: TimeInterval = 10

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.requestTimeout
        let (data, response) = try await fetch(request)
        guard 200 ..< 300 ~= response.statusCode else {
            throw OpenMeteoError.badStatus(response.statusCode)
        }
        return data
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

// MARK: - Wire models

private struct CurrentResponse: Decodable {
    let current: Current?

    struct Current: Decodable {
        let temperature2m: Double
        let relativeHumidity2m: Double
        let apparentTemperature: Double
        let precipitation: Double
        let snowfall: Double
        let cloudCover: Double
        let pressureMsl: Double
        let windSpeed10m: Double
        let visibility: Double
        let weatherCode: Int

        enum CodingKeys: String, CodingKey {
            case temperature2m = "temperature_2m"
            case relativeHumidity2m = "relative_humidity_2m"
            case apparentTemperature = "apparent_temperature"
            case precipitation, snowfall
            case cloudCover = "cloud_cover"
            case pressureMsl = "pressure_msl"
            case windSpeed10m = "wind_speed_10m"
            case visibility
            case weatherCode = "weather_code"
        }
    }
}

private struct ArchiveResponse: Decodable {
    let hourly: Hourly?

    struct Hourly: Decodable {
        let time: [String]
        let temperature2m: [Double]?
        let relativeHumidity2m: [Double]?
        let apparentTemperature: [Double]?
        let precipitation: [Double]?
        let snowfall: [Double]?
        let cloudCover: [Double]?
        let pressureMsl: [Double]?
        let windSpeed10m: [Double]?
        let visibility: [Double]?
        let weatherCode: [Int]?

        enum CodingKeys: String, CodingKey {
            case time
            case temperature2m = "temperature_2m"
            case relativeHumidity2m = "relative_humidity_2m"
            case apparentTemperature = "apparent_temperature"
            case precipitation, snowfall
            case cloudCover = "cloud_cover"
            case pressureMsl = "pressure_msl"
            case windSpeed10m = "wind_speed_10m"
            case visibility
            case weatherCode = "weather_code"
        }
    }
}

private extension Array {
    nonisolated subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
