//  WeatherVisual.swift
//  AsterismaV2.5
//
//  The visual vocabulary the environment background renders. Until this file,
//  weather only nudged atmospheric opacity and star visibility (Part 8's two
//  knobs), so a rainy day looked identical to a clear one. This file classifies
//  the engine's OWN stored `WeatherSnapshot` into a small, testable visual kind,
//  with an intensity and wind value the effect layer can draw.
//
//  Two sources, one shape:
//    • `.from(...)` maps a real snapshot — never a network call, never a write.
//    • `EnvironmentOverrideStore` lets the Debug Environment Studio force a
//      kind/time. Overrides are persisted in UserDefaults so the studio and the
//      app's own engine (a different instance) read the same value.
//
//  Honesty rule: a missing or stale snapshot is `.clear` with `isLive == false`,
//  not an invented storm. The studio label says "Live weather" vs "Forced".

import Foundation

// MARK: - WeatherVisualKind

nonisolated enum WeatherVisualKind: String, CaseIterable, Identifiable, Sendable {
    case clear
    case cloudy
    case fog
    case rain
    case heavyRain
    case snow
    case heavySnow
    case storm
    case wind

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .clear: return "Clear"
        case .cloudy: return "Cloudy"
        case .fog: return "Fog"
        case .rain: return "Rain"
        case .heavyRain: return "Heavy rain"
        case .snow: return "Snow"
        case .heavySnow: return "Heavy snow"
        case .storm: return "Storm"
        case .wind: return "Windy"
        }
    }

    var symbolName: String {
        switch self {
        case .clear: return "sun.max"
        case .cloudy: return "cloud"
        case .fog: return "cloud.fog"
        case .rain: return "cloud.rain"
        case .heavyRain: return "cloud.heavyrain"
        case .snow: return "cloud.snow"
        case .heavySnow: return "cloud.snow.fill"
        case .storm: return "cloud.bolt.rain"
        case .wind: return "wind"
        }
    }

    /// Precipitation-like kinds are drawn above the star layer; the rest are
    /// atmosphere only.
    var isPrecipitation: Bool {
        switch self {
        case .rain, .heavyRain, .snow, .heavySnow, .storm: return true
        case .clear, .cloudy, .fog, .wind: return false
        }
    }
}

// MARK: - WeatherVisual

nonisolated struct WeatherVisual: Equatable, Sendable {
    var kind: WeatherVisualKind
    /// 0 (barely there) ... 1 (fully saturated effect).
    var intensity: Double
    /// 0 (still) ... 1 (driving rain / streaking wind).
    var wind: Double
    /// 0 (clear sky) ... 1 (fully overcast) — also drives the cloud layer.
    var cloud: Double
    /// False when this is a studio override or a neutral fallback.
    var isLive: Bool

    static let clear = WeatherVisual(
        kind: .clear, intensity: 0, wind: 0, cloud: 0, isLive: false)

    init(
        kind: WeatherVisualKind,
        intensity: Double,
        wind: Double,
        cloud: Double,
        isLive: Bool
    ) {
        self.kind = kind
        self.intensity = EnvironmentMath.clampUnit(intensity)
        self.wind = EnvironmentMath.clampUnit(wind)
        self.cloud = EnvironmentMath.clampUnit(cloud)
        self.isLive = isLive
    }

    /// Pure mapping, kept free of WeatherKit so it is trivially testable.
    /// Precedence follows what a reader would call the weather: storm beats
    /// heavy precipitation, which beats light precipitation, which beats fog,
    /// which beats wind, which beats cloud cover.
    static func from(
        condition: WeatherConditionCategory,
        cloudCover: Double,
        precipitationMM: Double,
        snowfallMM: Double,
        windKPH: Double,
        visibilityKM: Double,
        stormIndex: Double
    ) -> WeatherVisual {
        let cloud = EnvironmentMath.clampUnit(cloudCover)
        let wind = EnvironmentMath.clampUnit(windKPH / 65.0)
        let storm = EnvironmentMath.clampUnit(stormIndex)
        let rainPower = EnvironmentMath.clampUnit(precipitationMM / 6.0)
        let snowPower = EnvironmentMath.clampUnit(snowfallMM / 6.0)
        let fogPower = EnvironmentMath.clampUnit((12.0 - visibilityKM) / 12.0)

        switch condition {
        case .storm:
            return WeatherVisual(
                kind: .storm, intensity: max(0.55, max(storm, rainPower)),
                wind: max(0.45, wind), cloud: max(0.7, cloud), isLive: true)
        case .heavyRain:
            return WeatherVisual(
                kind: .heavyRain, intensity: max(0.6, rainPower),
                wind: wind, cloud: max(0.55, cloud), isLive: true)
        case .rain:
            return WeatherVisual(
                kind: .rain, intensity: max(0.25, rainPower),
                wind: wind, cloud: max(0.35, cloud), isLive: true)
        case .heavySnow:
            return WeatherVisual(
                kind: .heavySnow, intensity: max(0.6, snowPower),
                wind: wind, cloud: max(0.55, cloud), isLive: true)
        case .snow:
            return WeatherVisual(
                kind: .snow, intensity: max(0.25, snowPower),
                wind: wind, cloud: max(0.35, cloud), isLive: true)
        case .fog:
            return WeatherVisual(
                kind: .fog, intensity: max(0.35, fogPower),
                wind: wind, cloud: max(0.4, cloud), isLive: true)
        case .wind:
            return WeatherVisual(
                kind: .wind, intensity: max(0.3, wind),
                wind: max(0.5, wind), cloud: cloud, isLive: true)
        case .cloudy, .mixed:
            return WeatherVisual(
                kind: .cloudy, intensity: max(0.2, cloud),
                wind: wind, cloud: max(0.4, cloud), isLive: true)
        case .partlyCloudy:
            return WeatherVisual(
                kind: .cloudy, intensity: max(0.1, cloud * 0.6),
                wind: wind, cloud: cloud, isLive: true)
        case .clear, .unknown:
            // A clear sky with a genuinely high cloud-cover reading is still
            // visually cloudy; below that, stay clear rather than inventing
            // precipitation from a label.
            if cloud >= 0.55 {
                return WeatherVisual(
                    kind: .cloudy, intensity: cloud, wind: wind, cloud: cloud,
                    isLive: true)
            }
            return WeatherVisual(
                kind: .clear, intensity: 0, wind: wind, cloud: cloud,
                isLive: true)
        }
    }

    static func from(_ snapshot: WeatherSnapshot) -> WeatherVisual {
        from(
            condition: snapshot.condition,
            cloudCover: snapshot.cloudCover,
            precipitationMM: snapshot.precipitationMillimeters,
            snowfallMM: snapshot.snowfallMillimeters,
            windKPH: snapshot.windSpeedKPH,
            visibilityKM: snapshot.visibilityKilometers,
            stormIndex: snapshot.stormActivityIndex)
    }

    /// A forced studio value. `isLive` is false so every surface can say so.
    static func forced(_ kind: WeatherVisualKind, intensity: Double) -> WeatherVisual {
        WeatherVisual(
            kind: kind, intensity: intensity, wind: kind == .wind ? 0.8 : 0.35,
            cloud: kind == .clear ? 0 : 0.6, isLive: false)
    }
}

// MARK: - EnvironmentOverrideStore

/// Debug-studio overrides, persisted so the studio's engine and the app's
/// engine agree. Nothing in Release ever writes these keys; a Release launch
/// with stale keys still respects them only until the studio's own
/// `clearAll()` runs, so the studio clears on disappear.
nonisolated struct EnvironmentOverrideStore {
    enum Key {
        static let minute = "environment.studio.minute"
        static let weatherKind = "environment.studio.weatherKind"
        static let weatherIntensity = "environment.studio.weatherIntensity"
    }

    let defaults: UserDefaults

    static let standard = EnvironmentOverrideStore(defaults: .standard)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Nil means "use the real clock".
    var minuteOverride: Int? {
        guard defaults.object(forKey: Key.minute) != nil else { return nil }
        let value = defaults.integer(forKey: Key.minute)
        guard (0..<1440).contains(value) else { return nil }
        return value
    }

    /// Nil means "use the latest captured weather".
    var weatherOverride: WeatherVisual? {
        guard let raw = defaults.string(forKey: Key.weatherKind),
              let kind = WeatherVisualKind(rawValue: raw)
        else { return nil }
        let intensity = defaults.object(forKey: Key.weatherIntensity) == nil
            ? 0.6
            : defaults.double(forKey: Key.weatherIntensity)
        return .forced(kind, intensity: intensity)
    }

    var hasOverrides: Bool { minuteOverride != nil || weatherOverride != nil }

    func setMinuteOverride(_ minute: Int) {
        defaults.set(min(1439, max(0, minute)), forKey: Key.minute)
    }

    func clearMinuteOverride() {
        defaults.removeObject(forKey: Key.minute)
    }

    func setWeatherOverride(_ kind: WeatherVisualKind, intensity: Double) {
        defaults.set(kind.rawValue, forKey: Key.weatherKind)
        defaults.set(EnvironmentMath.clampUnit(intensity), forKey: Key.weatherIntensity)
    }

    func clearWeatherOverride() {
        defaults.removeObject(forKey: Key.weatherKind)
        defaults.removeObject(forKey: Key.weatherIntensity)
    }

    func clearAll() {
        clearMinuteOverride()
        clearWeatherOverride()
    }

    /// The minute the engine should render: the studio override when present,
    /// otherwise the real fractional clock.
    func effectiveMinute(now: Date, calendar: Calendar) -> Double {
        if let minute = minuteOverride { return Double(minute) }
        return AnchorClock.fractionalMinutesSinceMidnight(for: now, calendar: calendar)
    }
}
