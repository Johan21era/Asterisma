//  WeatherKitService2.swift
//  AsterismaV2.5
//  Sole responsibility: produce a valid WeatherSnapshot for any (location, timestamp) pair,
//  persist it durably, and make historical snapshots queryable by the range and granularity
//  that WeatherAnalysisEngine needs.
//
//  Every subsystem in this file answers the four-gate test:
//  1. Which WeatherAnalysisEngine structure consumes its output?
//  2. What data does it provide?
//  3. How does that data reach WeatherAnalysisEngine?
//  4. Why can WeatherAnalysisEngine not function correctly without it?
//
//  Target: macOS 13+ (Ventura and later). No iOS-first assumptions.
//  Persistence: SQLite at ~/Library/Application Support/<BundleID>/weather_snapshots.sqlite3
//
//  REMEDIATION NOTE (RA-002 / Roadmap 1.1, Route B): a former extension block
//  ("WeatherAnalysisEngine Bug Fixes" — avoidedGenres / calculateAggregateConfidenceReal /
//  temporalBounds) claimed to patch three engine defects but had ZERO callers, while its
//  comments implied the fixes were applied. Deleted; the three underlying engine defects
//  are recorded OPEN in CURRENT_AUDIT.md (W-01/W-02/W-03).
//  `coverageRatio(for:)` below is retained: exercised by WeatherTests and the intended
//  data source when W-01 is eventually wired.
//
//  ROADMAP 2.2 (O-8): unguarded urls(for:).first! replaced with a temporary-directory
//  fallback so a misbehaving domain lookup can no longer crash store construction.
//  ROADMAP 3.4 (F-13c): sqlite3_open failures are now logged with the engine's own
//  error message instead of being swallowed — degradation behavior itself is UNCHANGED.

import Combine
import CoreLocation
import Foundation
import SQLite3
import WeatherKit

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - WeatherKitService

@MainActor
public final class WeatherKitService: ObservableObject {
    public static let shared = WeatherKitService()

    private var store: WeatherSnapshotStore
    private let normaliser = WeatherSnapshotNormaliser()
    private let locationProvider: LocationProvider
    private let provider: WeatherProviding

    #if DEBUG
    private(set) var consoleLastAttemptAt: Date?
    private(set) var consoleLastSuccessAt: Date?
    private(set) var consoleSuccessCount: Int = 0
    #endif

    private init() {
        store = WeatherSnapshotStore()
        locationProvider = LocationProvider()
        provider = OpenMeteoProvider()

        #if DEBUG
        DeveloperConsoleRegistry.shared.register(self)
        #endif
    }

    /// Testing reset: close the old weather DB handle and reopen a fresh one
    /// after the app-owned data root has been erased.
    func resetStore() {
        store.close()
        store = WeatherSnapshotStore()
    }

    /// Honest availability surface for the weather panel.
    public var locationAuthorizationStatus: CLAuthorizationStatus {
        locationProvider.authorizationStatus
    }

    // MARK: - Primary Session Attachment

    public func snapshotForCurrentConditions(
        sessionID: UUID
    ) async throws -> WeatherSnapshot {
        #if DEBUG
        consoleLastAttemptAt = Date()
        #endif

        let location = try await locationProvider.currentLocation()

        // G4: Open-Meteo is the default provider. No WeatherKit entitlement
        // is required, and the provider protocol keeps WeatherKit optional.
        let snapshot = try await provider.snapshot(
            at: Date(), location: location)

        try store.save(snapshot, sessionID: sessionID)

        #if DEBUG
        consoleLastSuccessAt = Date()
        consoleSuccessCount += 1
        #endif

        return snapshot
    }

    // MARK: - Historical Backfill

    public func snapshotForHistoricalSession(
        sessionID: UUID,
        at timestamp: Date
    ) async throws -> WeatherSnapshot {
        if let cached = try store.fetch(sessionID: sessionID) {
            return cached
        }

        guard let location = locationProvider.cachedLocation else {
            throw WeatherKitServiceError.locationUnavailable
        }

        let snapshot = try await provider.snapshot(
            at: timestamp, location: location)

        try store.save(snapshot, sessionID: sessionID)

        return snapshot
    }

    // MARK: - Forecast Input

    public func snapshotForForecast(
        targetDate: Date
    ) async throws -> WeatherSnapshot {
        let location = try await locationProvider.currentLocation()

        return try await provider.snapshot(
            at: targetDate, location: location)
    }

    // MARK: - Bulk Historical Query

    public func snapshots(
        from startDate: Date,
        to endDate: Date
    ) throws -> [WeatherSnapshot] {
        try store.fetchRange(from: startDate, to: endDate)
    }

    // MARK: - Coverage Audit

    //
    // Returns the fraction of session IDs that have a persisted WeatherSnapshot.
    // Currently exercised by WeatherTests only; this is the intended data source for
    // W-01 (see CURRENT_AUDIT.md) whenever real confidence derivation gets wired into
    // WeatherAnalysisEngine.generateTrendReport / generateBehaviorReport.

    public func coverageRatio(for sessionIDs: [UUID]) throws -> Double {
        let covered = try store.countPresent(sessionIDs: sessionIDs)
        guard !sessionIDs.isEmpty else { return 0 }
        return Double(covered) / Double(sessionIDs.count)
    }
}

public enum WeatherKitServiceError: Error {
    case locationUnavailable
    case noHistoricalDataAvailable(Date)
    case noForecastAvailable(Date)
    case storeWriteFailure(Error)
}

// MARK: - WeatherSnapshotNormaliser

struct WeatherSnapshotNormaliser {
    // MARK: - Current Conditions

    func normalise(
        current: CurrentWeather,
        hourly: Forecast<HourWeather>,
        at timestamp: Date,
        location: CLLocation,
        sessionID _: UUID?
    ) -> WeatherSnapshot {
        let hourEntry = hourly.forecast.first(where: {
            Calendar.current.isDate($0.date, equalTo: timestamp, toGranularity: .hour)
        })

        let precipMM = hourEntry?.precipitationAmount.converted(to: .millimeters).value ?? 0
        let snowMM = hourEntry?.snowfallAmount.converted(to: .millimeters).value ?? 0

        return WeatherSnapshot(
            timestamp: timestamp,
            temperatureCelsius: current.temperature.converted(to: .celsius).value,
            feelsLikeTemperatureCelsius: current.apparentTemperature.converted(to: .celsius).value,
            humidity: current.humidity,
            pressure: current.pressure.converted(to: .hectopascals).value,
            cloudCover: current.cloudCover,
            visibilityKilometers: current.visibility.converted(to: .kilometers).value,
            windSpeedKPH: current.wind.speed.converted(to: .kilometersPerHour).value,
            precipitationMillimeters: precipMM,
            snowfallMillimeters: snowMM,
            stormActivityIndex: computeStormIndex(
                condition: current.condition,
                windKPH: current.wind.speed.converted(to: .kilometersPerHour).value,
                precipMM: precipMM
            ),
            condition: mapCondition(current.condition),
            season: deriveSeason(from: timestamp, latitude: location.coordinate.latitude),
            month: Calendar.current.component(.month, from: timestamp),
            weekday: Calendar.current.component(.weekday, from: timestamp),
            dayPeriod: deriveDayPeriod(from: timestamp)
        )
    }

    // MARK: - Hourly Entry (historical / forecast)

    func normaliseFromHourly(
        hourly: HourWeather,
        at timestamp: Date,
        location: CLLocation,
        sessionID _: UUID?
    ) -> WeatherSnapshot {
        let precipMM = hourly.precipitationAmount.converted(to: .millimeters).value
        let snowMM = hourly.snowfallAmount.converted(to: .millimeters).value

        return WeatherSnapshot(
            timestamp: timestamp,
            temperatureCelsius: hourly.temperature.converted(to: .celsius).value,
            feelsLikeTemperatureCelsius: hourly.apparentTemperature.converted(to: .celsius).value,
            humidity: hourly.humidity,
            pressure: hourly.pressure.converted(to: .hectopascals).value,
            cloudCover: hourly.cloudCover,
            visibilityKilometers: hourly.visibility.converted(to: .kilometers).value,
            windSpeedKPH: hourly.wind.speed.converted(to: .kilometersPerHour).value,
            precipitationMillimeters: precipMM,
            snowfallMillimeters: snowMM,
            stormActivityIndex: computeStormIndex(
                condition: hourly.condition,
                windKPH: hourly.wind.speed.converted(to: .kilometersPerHour).value,
                precipMM: precipMM
            ),
            condition: mapCondition(hourly.condition),
            season: deriveSeason(from: timestamp, latitude: location.coordinate.latitude),
            month: Calendar.current.component(.month, from: timestamp),
            weekday: Calendar.current.component(.weekday, from: timestamp),
            dayPeriod: deriveDayPeriod(from: timestamp)
        )
    }

    // MARK: - stormActivityIndex

    func computeStormIndex(
        condition: WeatherCondition,
        windKPH: Double,
        precipMM: Double
    ) -> Double {
        let stormConditions: Set<WeatherCondition> = [
            .thunderstorms, .tropicalStorm, .hurricane,
            .heavyRain, .strongStorms, .freezingRain, .sleet,
        ]

        let conditionScore: Double = stormConditions.contains(condition) ? 0.5 : 0.0
        let windScore = min(windKPH / 120.0, 1.0) * 0.3 // 120 kph ceiling
        let precipScore = min(precipMM / 50.0, 1.0) * 0.2 // 50 mm/h ceiling

        return conditionScore + windScore + precipScore
    }

    // MARK: - Season

    nonisolated func deriveSeason(from date: Date, latitude: Double) -> SeasonalPeriod {
        let month = Calendar.current.component(.month, from: date)
        let isNorthern = latitude >= 0

        switch month {
        case 3, 4, 5: return isNorthern ? .spring : .autumn
        case 6, 7, 8: return isNorthern ? .summer : .winter
        case 9, 10, 11: return isNorthern ? .autumn : .spring
        default: return isNorthern ? .winter : .summer
        }
    }

    // MARK: - DayPeriod

    nonisolated func deriveDayPeriod(from date: Date) -> DayPeriod {
        let hour = Calendar.current.component(.hour, from: date)

        switch hour {
        case 5 ..< 7: return .dawn
        case 7 ..< 12: return .morning
        case 12 ..< 17: return .afternoon
        case 17 ..< 21: return .evening
        default: return .night
        }
    }

    // MARK: - WeatherCondition → WeatherConditionCategory

    func mapCondition(_ condition: WeatherCondition) -> WeatherConditionCategory {
        switch condition {
        case .clear, .mostlyClear:
            return .clear
        case .partlyCloudy:
            return .partlyCloudy
        case .mostlyCloudy, .cloudy:
            return .cloudy
        case .foggy, .haze, .smoky, .blowingDust:
            return .fog
        case .drizzle, .rain:
            return .rain
        case .heavyRain, .freezingRain:
            return .heavyRain
        case .flurries, .snow, .sleet:
            return .snow
        case .heavySnow, .blizzard:
            return .heavySnow
        case .thunderstorms, .strongStorms, .tropicalStorm, .hurricane:
            return .storm
        case .windy, .blowingSnow:
            return .wind
        case .wintryMix:
            return .mixed
        default:
            return .unknown
        }
    }
}

// MARK: - WeatherSnapshotStore

final class WeatherSnapshotStore {
    private let dbURL: URL
    private var db: OpaquePointer?

    init(directory: URL? = nil) {
        if let dir = directory {
            dbURL = dir.appendingPathComponent("weather_snapshots.sqlite3")
        } else if let testRoot = RuntimeEnvironment.isolatedStoreDirectory {
            RuntimeEnvironment.ensureDirectory(testRoot)
            dbURL = testRoot.appendingPathComponent("weather_snapshots.sqlite3")
        } else if let root = AppIdentity.dataRootURL() {
            AppIdentity.migrateLegacyWeatherStoreIfNeeded(to: root)
            dbURL = root.appendingPathComponent("weather_snapshots.sqlite3")
        } else {
            // ROADMAP 2.2 (O-8): was `.first!`. A guarded fallback keeps the app
            // alive (and diagnosable via the log line) if Application Support is
            // unavailable; snapshots land somewhere ephemeral instead of crashing.
            let appSupportCandidates = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )
            let baseDir = appSupportCandidates.first ?? FileManager.default.temporaryDirectory
            if appSupportCandidates.isEmpty {
                print("[WeatherSnapshotStore] Application Support unavailable — " +
                    "falling back to \(baseDir.path)")
            }

            let appDir = baseDir.appendingPathComponent(
                Bundle.main.bundleIdentifier ?? "Asterisma",
                isDirectory: true
            )

            try? FileManager.default.createDirectory(
                at: appDir,
                withIntermediateDirectories: true
            )

            dbURL = appDir.appendingPathComponent("weather_snapshots.sqlite3")
        }

        openDatabase()
        createSchemaIfNeeded()
    }

    deinit {
        close()
    }

    func close() {
        guard let db else { return }
        sqlite3_close(db)
        self.db = nil
    }

    // MARK: - Write

    func save(_ snapshot: WeatherSnapshot, sessionID: UUID?) throws {
        // BUG FIX (found by WeatherTests on its first-ever run): the table's
        // PRIMARY KEY is each snapshot's own UUID, so INSERT OR REPLACE could
        // never dedupe a retry saved under the same session_id — a crash-
        // recovery double-save silently stranded the stale row forever, while
        // fetch(sessionID:) LIMIT 1 and countPresent both assume exactly one
        // row per session. Replacement is now an explicit DELETE + INSERT
        // wrapped in a transaction, so no failure path can leave the session
        // with zero rows or two.
        var inTransaction = false
        func rollbackIfOpen() {
            if inTransaction {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                inTransaction = false
            }
        }

        if sessionID != nil {
            guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
                throw StoreError.writeFailed
            }
            inTransaction = true
        }
        defer { rollbackIfOpen() }

        if let sid = sessionID {
            var delStmt: OpaquePointer?
            let deleteSQL = "DELETE FROM weather_snapshots WHERE session_id = ?"
            guard sqlite3_prepare_v2(db, deleteSQL, -1, &delStmt, nil) == SQLITE_OK else {
                throw StoreError.prepareFailed
            }
            defer { sqlite3_finalize(delStmt) }
            sqlite3_bind_text(delStmt, 1, sid.uuidString, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(delStmt) == SQLITE_DONE else {
                throw StoreError.writeFailed
            }
        }

        let sql = """
            INSERT OR REPLACE INTO weather_snapshots (
                id, timestamp, session_id,
                temperature_celsius, feels_like_celsius,
                humidity, pressure, cloud_cover,
                visibility_km, wind_speed_kph,
                precipitation_mm, snowfall_mm,
                storm_activity_index, condition, season,
                month, weekday, day_period, created_at
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, snapshot.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, snapshot.timestamp.timeIntervalSince1970)

        if let sid = sessionID {
            sqlite3_bind_text(stmt, 3, sid.uuidString, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 3)
        }

        sqlite3_bind_double(stmt, 4, snapshot.temperatureCelsius)
        sqlite3_bind_double(stmt, 5, snapshot.feelsLikeTemperatureCelsius)
        sqlite3_bind_double(stmt, 6, snapshot.humidity)
        sqlite3_bind_double(stmt, 7, snapshot.pressure)
        sqlite3_bind_double(stmt, 8, snapshot.cloudCover)
        sqlite3_bind_double(stmt, 9, snapshot.visibilityKilometers)
        sqlite3_bind_double(stmt, 10, snapshot.windSpeedKPH)
        sqlite3_bind_double(stmt, 11, snapshot.precipitationMillimeters)
        sqlite3_bind_double(stmt, 12, snapshot.snowfallMillimeters)
        sqlite3_bind_double(stmt, 13, snapshot.stormActivityIndex)
        sqlite3_bind_text(stmt, 14, snapshot.condition.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 15, snapshot.season.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 16, Int32(snapshot.month))
        sqlite3_bind_int(stmt, 17, Int32(snapshot.weekday))
        sqlite3_bind_text(stmt, 18, snapshot.dayPeriod.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 19, Date().timeIntervalSince1970)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.writeFailed
        }

        if inTransaction {
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw StoreError.writeFailed
            }
            inTransaction = false
        }
    }

    // MARK: - Read

    func fetch(sessionID: UUID) throws -> WeatherSnapshot? {
        let sql = "SELECT * FROM weather_snapshots WHERE session_id = ? LIMIT 1"
        return try executeQuery(sql: sql, bindings: [sessionID.uuidString]).first
    }

    func fetchRange(from start: Date, to end: Date) throws -> [WeatherSnapshot] {
        let sql = """
            SELECT * FROM weather_snapshots
            WHERE timestamp >= ? AND timestamp <= ?
            ORDER BY timestamp ASC
        """
        return try executeQuery(
            sql: sql,
            bindings: [start.timeIntervalSince1970, end.timeIntervalSince1970]
        )
    }

    func countPresent(sessionIDs: [UUID]) throws -> Int {
        guard !sessionIDs.isEmpty else { return 0 }

        let placeholders = sessionIDs.map { _ in "?" }.joined(separator: ",")
        let sql = "SELECT COUNT(*) FROM weather_snapshots WHERE session_id IN (\(placeholders))"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }

        for (i, id) in sessionIDs.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), id.uuidString, -1, SQLITE_TRANSIENT)
        }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    // MARK: - Private

    private func openDatabase() {
        // ROADMAP 3.4 (F-13c): the open RESULT was previously ignored entirely —
        // when opening failed, every later operation failed with a generic
        // StoreError and diagnosis was impossible. Degradation semantics are
        // intentionally UNCHANGED (operations still fail closed); we now say why
        // in the log using SQLite's own message.
        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            print("[WeatherSnapshotStore] FAILED to open database at \(dbURL.path): \(message). " +
                "Weather persistence will be degraded until the next launch.")
        }
    }

    private func createSchemaIfNeeded() {
        let sql = """
            CREATE TABLE IF NOT EXISTS weather_snapshots (
                id                    TEXT PRIMARY KEY,
                timestamp             REAL NOT NULL,
                session_id            TEXT,
                temperature_celsius   REAL NOT NULL,
                feels_like_celsius    REAL NOT NULL,
                humidity              REAL NOT NULL,
                pressure              REAL NOT NULL,
                cloud_cover           REAL NOT NULL,
                visibility_km         REAL NOT NULL,
                wind_speed_kph        REAL NOT NULL,
                precipitation_mm      REAL NOT NULL,
                snowfall_mm           REAL NOT NULL,
                storm_activity_index  REAL NOT NULL,
                condition             TEXT NOT NULL,
                season                TEXT NOT NULL,
                month                 INTEGER NOT NULL,
                weekday               INTEGER NOT NULL,
                day_period            TEXT NOT NULL,
                created_at            REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_ws_timestamp  ON weather_snapshots(timestamp);
            CREATE INDEX IF NOT EXISTS idx_ws_session_id ON weather_snapshots(session_id);
            CREATE INDEX IF NOT EXISTS idx_ws_season     ON weather_snapshots(season);
            CREATE INDEX IF NOT EXISTS idx_ws_condition  ON weather_snapshots(condition);
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func executeQuery(sql: String, bindings: [Any]) throws -> [WeatherSnapshot] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepareFailed
        }
        defer { sqlite3_finalize(stmt) }

        for (i, binding) in bindings.enumerated() {
            let idx = Int32(i + 1)
            switch binding {
            case let s as String: sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case let d as Double: sqlite3_bind_double(stmt, idx, d)
            default: break
            }
        }

        var results: [WeatherSnapshot] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let snapshot = rowToSnapshot(stmt) {
                results.append(snapshot)
            }
        }
        return results
    }

    private func rowToSnapshot(_ stmt: OpaquePointer?) -> WeatherSnapshot? {
        guard let stmt = stmt else { return nil }

        guard
            let idStr = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
            let id = UUID(uuidString: idStr),
            let condStr = sqlite3_column_text(stmt, 13).map({ String(cString: $0) }),
            let condition = WeatherConditionCategory(rawValue: condStr),
            let seasStr = sqlite3_column_text(stmt, 14).map({ String(cString: $0) }),
            let season = SeasonalPeriod(rawValue: seasStr),
            let dpStr = sqlite3_column_text(stmt, 17).map({ String(cString: $0) }),
            let dayPeriod = DayPeriod(rawValue: dpStr)
        else { return nil }

        return WeatherSnapshot(
            id: id,
            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
            temperatureCelsius: sqlite3_column_double(stmt, 3),
            feelsLikeTemperatureCelsius: sqlite3_column_double(stmt, 4),
            humidity: sqlite3_column_double(stmt, 5),
            pressure: sqlite3_column_double(stmt, 6),
            cloudCover: sqlite3_column_double(stmt, 7),
            visibilityKilometers: sqlite3_column_double(stmt, 8),
            windSpeedKPH: sqlite3_column_double(stmt, 9),
            precipitationMillimeters: sqlite3_column_double(stmt, 10),
            snowfallMillimeters: sqlite3_column_double(stmt, 11),
            stormActivityIndex: sqlite3_column_double(stmt, 12),
            condition: condition,
            season: season,
            month: Int(sqlite3_column_int(stmt, 15)),
            weekday: Int(sqlite3_column_int(stmt, 16)),
            dayPeriod: dayPeriod
        )
    }

    enum StoreError: Error {
        case prepareFailed
        case writeFailed
    }
}

// MARK: - LocationProvider

@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    /// AUDIT F-05 (Phase 1): was a single optional continuation — an overlapping
    /// request overwrote it and the first caller's task hung forever. All pending
    /// requests are now queued and resumed exactly once together.
    private var pendingContinuations: [CheckedContinuation<CLLocation, Error>] = []

    /// Cached from last successful fetch — used when app is not foreground.
    private(set) var cachedLocation: CLLocation? {
        didSet {
            if let loc = cachedLocation {
                UserDefaults.standard.set(loc.coordinate.latitude, forKey: "wks_lat")
                UserDefaults.standard.set(loc.coordinate.longitude, forKey: "wks_lon")
            }
        }
    }

    /// User-configured manual location override (macOS Preferences affordance).
    var manualLocation: CLLocation? {
        get {
            let lat = UserDefaults.standard.double(forKey: "wks_manual_lat")
            let lon = UserDefaults.standard.double(forKey: "wks_manual_lon")
            guard lat != 0 || lon != 0 else { return nil }
            return CLLocation(latitude: lat, longitude: lon)
        }
        set {
            UserDefaults.standard.set(newValue?.coordinate.latitude, forKey: "wks_manual_lat")
            UserDefaults.standard.set(newValue?.coordinate.longitude, forKey: "wks_manual_lon")
        }
    }

    override init() {
        super.init()
        manager.delegate = self
        restorePersistedLocation()
    }

    var authorizationStatus: CLAuthorizationStatus {
        manager.authorizationStatus
    }

    func currentLocation() async throws -> CLLocation {
        if let manual = manualLocation {
            return manual
        }

        switch manager.authorizationStatus {
        case .authorized:
            return try await fetchOneTimeLocation()
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            if let cached = cachedLocation { return cached }
            // G4: never invent a city while the user is deciding.
            throw LocationError.permissionPending
        case .denied, .restricted:
            if let cached = cachedLocation {
                return cached
            }
            throw LocationError.permissionDenied
        default:
            if let cached = cachedLocation { return cached }
            throw LocationError.permissionDenied
        }
    }

    private func fetchOneTimeLocation() async throws -> CLLocation {
        // HOTFIX (stall report): if CLLocationManager never delivers a callback
        // (radio off, driver hiccup), the queued continuation previously hung
        // FOREVER, wedging every awaiting task behind it. A 30 s watchdog now
        // fails the queue instead of hanging it. F-05's exactly-once drain is
        // preserved: resumePending clears the queue before resuming.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CLLocation, Error>) in
            pendingContinuations.append(continuation)
            manager.requestLocation()

            Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard let self, !self.pendingContinuations.isEmpty else { return }
                self.resumePending(throwing: LocationError.timeout)
            }
        }
    }

    /// Resumes every queued continuation exactly once. Called from the delegate
    /// hop on the main actor; draining before resuming prevents re-entrancy.
    private func resumePending(returning location: CLLocation? = nil, throwing error: Error? = nil) {
        let queued = pendingContinuations
        pendingContinuations.removeAll()
        for continuation in queued {
            if let error {
                continuation.resume(throwing: error)
            } else if let location {
                continuation.resume(returning: location)
            } else {
                continuation.resume(throwing: LocationError.permissionDenied)
            }
        }
    }

    private func restorePersistedLocation() {
        let lat = UserDefaults.standard.double(forKey: "wks_lat")
        let lon = UserDefaults.standard.double(forKey: "wks_lon")
        guard lat != 0 || lon != 0 else { return }
        cachedLocation = CLLocation(latitude: lat, longitude: lon)
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(
        _: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        Task { @MainActor in
            if let location = locations.last {
                self.cachedLocation = location
                self.resumePending(returning: location)
            }
        }
    }

    nonisolated func locationManager(
        _: CLLocationManager,
        didFailWithError error: Error
    ) {
        Task { @MainActor in
            self.resumePending(throwing: error)
        }
    }

    enum LocationError: Error {
        case permissionPending
        case permissionDenied
        case timeout
    }
}

// MARK: - EnvironmentalSessionAssembler

public struct EnvironmentalSessionAssembler {
    private let weatherService: WeatherKitService

    public init(weatherService: WeatherKitService? = nil) {
        if let ws = weatherService {
            self.weatherService = ws
        } else {
            // Resolve the shared instance on the main actor to satisfy isolation rules in Swift 6
            self.weatherService = Self.resolveShared()
        }
    }

    @MainActor
    private static func resolveShared() -> WeatherKitService {
        WeatherKitService.shared
    }

    // MARK: - Assemble at Session End

    public func assembleAtSessionEnd(
        sessionID: UUID,
        bookID: UUID,
        readingDurationMinutes: Double,
        pagesRead: Double,
        chaptersCompleted: Double,
        booksCompleted: Double,
        readingSpeed: Double,
        consistencyScore: Double,
        readingFrequencyScore: Double,
        engagementScore: Double,
        sessionQualityScore: Double,
        momentumScore: Double,
        completionProbability: Double,
        abandonmentProbability: Double,
        difficultyScore: Double,
        complexityScore: Double,
        bookLength: Double,
        genre: String?,
        seriesIdentifier: String?,
        reread: Bool
    ) async throws -> WeatherAnalysisEngine.EnvironmentalSessionRecord {
        let snapshot = try await weatherService.snapshotForCurrentConditions(
            sessionID: sessionID
        )

        return WeatherAnalysisEngine.EnvironmentalSessionRecord(
            sessionID: sessionID,
            bookID: bookID,
            timestamp: snapshot.timestamp,
            weather: snapshot,
            readingDurationMinutes: readingDurationMinutes,
            pagesRead: pagesRead,
            chaptersCompleted: chaptersCompleted,
            booksCompleted: booksCompleted,
            readingSpeed: readingSpeed,
            consistencyScore: consistencyScore,
            readingFrequencyScore: readingFrequencyScore,
            engagementScore: engagementScore,
            sessionQualityScore: sessionQualityScore,
            momentumScore: momentumScore,
            completionProbability: completionProbability,
            abandonmentProbability: abandonmentProbability,
            difficultyScore: difficultyScore,
            complexityScore: complexityScore,
            bookLength: bookLength,
            genre: genre,
            seriesIdentifier: seriesIdentifier,
            reread: reread
        )
    }

    // MARK: - Retroactive Assembly

    public func assembleRetroactively(
        sessionID: UUID,
        bookID: UUID,
        timestamp: Date,
        readingMetrics: ReadingSessionMetrics
    ) async throws -> WeatherAnalysisEngine.EnvironmentalSessionRecord {
        let snapshot = try await weatherService.snapshotForHistoricalSession(
            sessionID: sessionID,
            at: timestamp
        )

        return WeatherAnalysisEngine.EnvironmentalSessionRecord(
            sessionID: sessionID,
            bookID: bookID,
            timestamp: timestamp,
            weather: snapshot,
            readingDurationMinutes: readingMetrics.durationMinutes,
            pagesRead: readingMetrics.pagesRead,
            chaptersCompleted: readingMetrics.chaptersCompleted,
            booksCompleted: readingMetrics.booksCompleted,
            readingSpeed: readingMetrics.readingSpeed,
            consistencyScore: readingMetrics.consistencyScore,
            readingFrequencyScore: readingMetrics.readingFrequencyScore,
            engagementScore: readingMetrics.engagementScore,
            sessionQualityScore: readingMetrics.sessionQualityScore,
            momentumScore: readingMetrics.momentumScore,
            completionProbability: readingMetrics.completionProbability,
            abandonmentProbability: readingMetrics.abandonmentProbability,
            difficultyScore: readingMetrics.difficultyScore,
            complexityScore: readingMetrics.complexityScore,
            bookLength: readingMetrics.bookLength,
            genre: readingMetrics.genre,
            seriesIdentifier: readingMetrics.seriesIdentifier,
            reread: readingMetrics.reread
        )
    }
}

// MARK: - ReadingSessionMetrics

public struct ReadingSessionMetrics {
    public let durationMinutes: Double
    public let pagesRead: Double
    public let chaptersCompleted: Double
    public let booksCompleted: Double
    public let readingSpeed: Double
    public let consistencyScore: Double
    public let readingFrequencyScore: Double
    public let engagementScore: Double
    public let sessionQualityScore: Double
    public let momentumScore: Double
    public let completionProbability: Double
    public let abandonmentProbability: Double
    public let difficultyScore: Double
    public let complexityScore: Double
    public let bookLength: Double
    public let genre: String?
    public let seriesIdentifier: String?
    public let reread: Bool

    public init(
        durationMinutes: Double,
        pagesRead: Double,
        chaptersCompleted: Double,
        booksCompleted: Double,
        readingSpeed: Double,
        consistencyScore: Double,
        readingFrequencyScore: Double,
        engagementScore: Double,
        sessionQualityScore: Double,
        momentumScore: Double,
        completionProbability: Double,
        abandonmentProbability: Double,
        difficultyScore: Double,
        complexityScore: Double,
        bookLength: Double,
        genre: String?,
        seriesIdentifier: String?,
        reread: Bool
    ) {
        self.durationMinutes = durationMinutes
        self.pagesRead = pagesRead
        self.chaptersCompleted = chaptersCompleted
        self.booksCompleted = booksCompleted
        self.readingSpeed = readingSpeed
        self.consistencyScore = consistencyScore
        self.readingFrequencyScore = readingFrequencyScore
        self.engagementScore = engagementScore
        self.sessionQualityScore = sessionQualityScore
        self.momentumScore = momentumScore
        self.completionProbability = completionProbability
        self.abandonmentProbability = abandonmentProbability
        self.difficultyScore = difficultyScore
        self.complexityScore = complexityScore
        self.bookLength = bookLength
        self.genre = genre
        self.seriesIdentifier = seriesIdentifier
        self.reread = reread
    }
}

// MARK: - Unit-test pointer
//
// WeatherSnapshotNormaliser / WeatherSnapshotStore / engine-integration suites live in
// `AsterismaV2.5Tests/WeatherTests.swift` and execute under `xcodebuild test`.

// MARK: - Developer Console

#if DEBUG
extension WeatherKitService: DeveloperConsoleObservable {
    static var consoleIdentity: ConsoleSubsystemIdentity {
        ConsoleSubsystemIdentity(
            id: "weather-kit-service",
            displayName: "WeatherKit Service",
            category: .service,
            purpose: "Fetches and persists weather snapshots (via Apple WeatherKit + a local SQLite store) so reading sessions can be correlated with weather conditions."
        )
    }

    var consoleSnapshot: ConsoleSubsystemSnapshot {
        ConsoleSubsystemSnapshot(
            identity: Self.consoleIdentity,
            status: consoleLastAttemptAt == nil ? .idle : .healthy,
            currentActivity: consoleLastAttemptAt == nil
                ? "Not called yet this session"
                : "\(consoleSuccessCount) successful fetch(es) this session",
            lastUpdated: consoleLastSuccessAt ?? consoleLastAttemptAt,
            metrics: [
                "Attempts this session": consoleLastAttemptAt == nil ? "0" : "≥1",
                "Successes this session": "\(consoleSuccessCount)",
            ]
        )
    }
}
#endif
