//  SolarDaylight.swift
//  AsterismaV2.5
//
//  Environment Engine — seasonal daylight model.
//
//  The palette track was authored against a fixed equinox-ish day: sunrise at
//  05:45, solar noon at 12:00, sunset at 19:45. That is why the background
//  stayed on the same clock all year even when the real day was eight hours
//  long. This file computes the actual solar day for the user's cached
//  coordinate and maps it onto the SAME palette track:
//
//      sunrise  -> 06:00 (minute 360, Morning start)
//      solar noon -> 12:00 (minute 720, Midday)
//      sunset   -> 19:45 (minute 1185, Night)
//
//  Outside daylight the wall-clock minute is returned unchanged, so the flat
//  Night palette still holds overnight. If no coordinate is available the
//  fixed track is returned verbatim — the existing behaviour is the fallback,
//  not a regression.
//
//  The NOAA solar-position equations are used in their compact form. They are
//  accurate to a few minutes at mid-latitudes, which is far finer than the
//  10 s palette cadence and the soft palette transitions need.
//
//  This type is pure: no Date(), no CoreLocation, no view state. EnvironmentEngine
//  supplies the reference date, calendar and optional coordinate.

import Foundation

/// A plain coordinate so the solar model does not depend on CoreLocation.
nonisolated struct SolarCoordinate: Sendable, Equatable {
    var latitude: Double
    var longitude: Double
}

nonisolated struct SolarDaylight: Sendable, Equatable {

    /// Local-clock minutes (0...1440) for sunrise and sunset. Normalized into
    /// a single day; polar day/night use the synthetic values documented below.
    var sunriseMinute: Double
    var sunsetMinute: Double
    var solarNoonMinute: Double

    /// Length of the solar day in minutes. 0 during polar night, 1440 during
    /// polar day.
    var daylightDurationMinutes: Double

    /// Solar elevation at the reference instant, in degrees. Negative below
    /// the horizon.
    var solarElevationDegrees: Double

    /// 0 at night, 1 in full daylight, smoothstepped through twilight.
    var daylightFactor: Double

    /// 1 near sunrise/sunset, 0 away from the horizon. Drives the warm horizon
    /// glow without hard-coding a clock range.
    var goldenHourFactor: Double

    var isDaylight: Bool

    /// 0 at sunrise, 1 at sunset. 0.5 when there is no daylight (polar night).
    var solarProgress: Double

    /// 0 at sunset, 1 at sunrise. 0 while the sun is up.
    var nightProgress: Double

    /// Unit-point position of the moving celestial glow. The glow traverses
    /// the sky across the day and back across the night.
    var glowX: Double
    var glowY: Double

    /// False for the fixed equinox track. The UI uses this to say "fixed
    /// daylight track" instead of claiming a real sunrise.
    var hasLocation: Bool

    /// The original palette track, used when no coordinate has been cached.
    static let fixed = SolarDaylight(
        sunriseMinute: 345,
        sunsetMinute: 1185,
        solarNoonMinute: 720,
        daylightDurationMinutes: 840,
        solarElevationDegrees: 0,
        daylightFactor: 0.5,
        goldenHourFactor: 0,
        isDaylight: false,
        solarProgress: 0.5,
        nightProgress: 0.5,
        glowX: 0.5,
        glowY: 0.35,
        hasLocation: false)

    /// Computes the solar day for `date`. Returns `.fixed` when `coordinate`
    /// is nil so every caller has one well-defined fallback.
    static func calculate(
        for date: Date,
        calendar: Calendar = .current,
        coordinate: SolarCoordinate?
    ) -> SolarDaylight {
        guard let coordinate else { return .fixed }

        let latitude = coordinate.latitude
        let longitude = coordinate.longitude
        let latitudeRadians = latitude * .pi / 180.0

        let dayOfYear = Double(calendar.ordinality(of: .day, in: .year, for: date) ?? 1)
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        let clockMinute = Double(components.hour ?? 0) * 60.0
            + Double(components.minute ?? 0)
            + Double(components.second ?? 0) / 60.0

        // Fractional year, in radians, at the reference instant.
        let gamma = 2.0 * Double.pi / 365.0
            * (dayOfYear - 1.0 + (clockMinute / 60.0 - 12.0) / 24.0)

        // Equation of time, minutes.
        let equationOfTime = 229.18 * (
            0.000075
            + 0.001868 * cos(gamma)
            - 0.032077 * sin(gamma)
            - 0.014615 * cos(2.0 * gamma)
            - 0.040849 * sin(2.0 * gamma))

        // Solar declination, radians.
        let declination = 0.006918
            - 0.399912 * cos(gamma)
            + 0.070257 * sin(gamma)
            - 0.006758 * cos(2.0 * gamma)
            + 0.000907 * sin(2.0 * gamma)
            - 0.002697 * cos(3.0 * gamma)
            + 0.00148 * sin(3.0 * gamma)

        // Hour angle at sunrise/sunset, in degrees. The 90.833° zenith
        // includes standard atmospheric refraction and the solar radius.
        let zenithRadians = 90.833 * Double.pi / 180.0
        let cosHourAngle = cos(zenithRadians) / (cos(latitudeRadians) * cos(declination))
            - tan(latitudeRadians) * tan(declination)

        let timezoneMinutes = Double(calendar.timeZone.secondsFromGMT(for: date)) / 60.0
        let solarNoon = 720.0 - 4.0 * longitude - equationOfTime + timezoneMinutes

        let daylightDuration: Double
        let sunrise: Double
        let sunset: Double
        if cosHourAngle <= -1.0 {
            // Polar day: the sun never sets.
            daylightDuration = 1440.0
            sunrise = 0.0
            sunset = 1440.0
        } else if cosHourAngle >= 1.0 {
            // Polar night: the sun never rises.
            daylightDuration = 0.0
            sunrise = 720.0
            sunset = 720.0
        } else {
            let hourAngleDegrees = acos(cosHourAngle) * 180.0 / Double.pi
            daylightDuration = 8.0 * hourAngleDegrees
            sunrise = solarNoon - 4.0 * hourAngleDegrees
            sunset = solarNoon + 4.0 * hourAngleDegrees
        }

        let normalizedSunrise = wrapMinutes(sunrise)
        let normalizedSunset = wrapMinutes(sunset)
        let normalizedNoon = wrapMinutes(solarNoon)

        // Solar elevation at the reference instant.
        let trueSolarTime = clockMinute + equationOfTime + 4.0 * longitude - timezoneMinutes
        let hourAngle = (trueSolarTime / 4.0 - 180.0) * Double.pi / 180.0
        let cosZenith = sin(latitudeRadians) * sin(declination)
            + cos(latitudeRadians) * cos(declination) * cos(hourAngle)
        let elevation = 90.0 - acos(min(1.0, max(-1.0, cosZenith))) * 180.0 / Double.pi

        // Twilight is a gradual band, not a switch at the horizon.
        let dayFactor = smoothstep((elevation + 6.0) / 12.0)
        let golden = max(0.0, min(1.0, 1.0 - abs(elevation - 5.0) / 15.0))
            * max(0.0, min(1.0, (elevation + 10.0) / 20.0))
        let daylight = elevation > -0.833

        let progress: Double
        if daylightDuration > 0.0, normalizedSunset > normalizedSunrise, daylight {
            progress = min(1.0, max(0.0,
                (clockMinute - normalizedSunrise)
                    / (normalizedSunset - normalizedSunrise)))
        } else if daylightDuration > 0.0, normalizedSunset > normalizedSunrise {
            progress = clockMinute >= normalizedSunset ? 1.0 : 0.0
        } else {
            progress = 0.5
        }

        let nightDuration = max(1.0, 1440.0 - daylightDuration)
        let night: Double
        if daylight {
            night = 0.0
        } else if clockMinute >= normalizedSunset {
            night = min(1.0, max(0.0,
                (clockMinute - normalizedSunset) / nightDuration))
        } else {
            night = min(1.0, max(0.0,
                (clockMinute + 1440.0 - normalizedSunset) / nightDuration))
        }

        let arcProgress = daylight ? progress : night
        let glowX = 0.12 + 0.76 * arcProgress
        let glowY = 0.18 + 0.34 * (1.0 - sin(Double.pi * arcProgress))

        return SolarDaylight(
            sunriseMinute: normalizedSunrise,
            sunsetMinute: normalizedSunset,
            solarNoonMinute: normalizedNoon,
            daylightDurationMinutes: daylightDuration,
            solarElevationDegrees: elevation,
            daylightFactor: dayFactor,
            goldenHourFactor: golden,
            isDaylight: daylight,
            solarProgress: progress,
            nightProgress: night,
            glowX: glowX,
            glowY: glowY,
            hasLocation: true)
    }

    /// Maps a wall-clock minute onto the palette's fixed day track. Daylight
    /// is stretched or compressed so sunrise lands on 06:00, solar noon on
    /// 12:00, and sunset on 19:45. Night is left on the wall clock; the track
    /// is flat Night there anyway.
    func paletteMinute(for clockMinute: Double) -> Double {
        guard hasLocation, daylightDurationMinutes > 0.0 else { return clockMinute }
        guard sunsetMinute > sunriseMinute else { return clockMinute }
        guard clockMinute >= sunriseMinute, clockMinute <= sunsetMinute else {
            return clockMinute
        }

        if clockMinute <= solarNoonMinute, solarNoonMinute > sunriseMinute {
            return 360.0
                + (clockMinute - sunriseMinute) / (solarNoonMinute - sunriseMinute)
                * (720.0 - 360.0)
        }
        if clockMinute > solarNoonMinute, sunsetMinute > solarNoonMinute {
            return 720.0
                + (clockMinute - solarNoonMinute) / (sunsetMinute - solarNoonMinute)
                * (1185.0 - 720.0)
        }
        return clockMinute
    }

    private static func smoothstep(_ raw: Double) -> Double {
        let t = min(1.0, max(0.0, raw))
        return t * t * (3.0 - 2.0 * t)
    }

    private static func wrapMinutes(_ value: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: 1440.0)
        return remainder < 0.0 ? remainder + 1440.0 : remainder
    }
}
