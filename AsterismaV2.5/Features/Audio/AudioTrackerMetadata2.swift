//  AudioTrackerMetadata2.swift
//  PURPOSE
//  The macOS audio-environment monitoring service.
//  Analogous to WeatherKitService in the environmental intelligence subsystem.
//
//  WHAT THIS FILE DOES
//  Polls the audio environment every 60 seconds during an active reading session,
//  accumulates AudioSnapshot observations, and builds an AudioContextProfile when
//  the session ends.  The profile is handed to DataStore.attachAudioContext().
//
//  MACROS PLATFORM APPROACH
//  macOS offers no public cross-process API for reading Now Playing metadata
//  (MPNowPlayingInfoCenter.default.nowPlayingInfo is per-process only).
//  This service uses three complementary mechanisms:
//
//    1. NSWorkspace.shared.runningApplications
//       Identifies which known audio application is active → AudioSource, AudioCategory.
//       Thread: Main (NSWorkspace must be accessed on main thread).
//
//    2. NSAppleScript
//       Queries Music.app and Spotify for track-level metadata when those apps
//       are the detected source.
//       REQUIRED ENTITLEMENT in AsterismaV2.5.entitlements:
//         <key>com.apple.security.automation.apple-events</key>
//         <true/>
//       And the corresponding NSAppleEventsUsageDescription key in Info.plist.
//       Thread: Main (NSAppleScript -executeAndReturnError: is synchronous;
//               ≈100–300 ms per call, once per 60-second poll — acceptable).
//
//    3. CoreAudio (kAudioDevicePropertyDeviceIsRunningSomewhere)
//       Reports whether any process is currently using the default output device.
//       Used to detect audio that isn't from a recognized application.
//       Thread: thread-safe (CoreAudio property access).
//
//  TARGET: macOS 13+ (Ventura and later)

import AppKit
import Combine
import CoreAudio
import Foundation

// MARK: - AudioTrackMetadata (Internal)

/// Intermediate carrier returned by AppleScript query helpers.
private struct AudioTrackMetadata {
    let title: String
    let artist: String
    let album: String
    let genre: String
    let playlist: String
    let duration: TimeInterval // total track duration in seconds
    let position: TimeInterval // current playback position in seconds
}

// MARK: - AudioProfileStore

/// Persists AudioContextProfile objects as a JSON array.
/// Stored at: ~/Library/Application Support/Asterisma/audio-profiles.json
/// One flat array; profiles are keyed by sessionID for fast lookup.
public final class AudioProfileStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// In-memory cache; invalidated on save and reloaded lazily on next read.
    private var cache: [AudioContextProfile]?

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("audio-profiles.json")
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder.dateDecodingStrategy = .iso8601
    }

    /// Saves a profile, replacing any existing profile for the same sessionID.
    /// Call from @MainActor only (DataStore is @MainActor).
    public func save(profile: AudioContextProfile) {
        var all = fetchAll()
        all.removeAll { $0.sessionID == profile.sessionID }
        all.append(profile)
        persist(all)
        cache = all
    }

    /// Returns the profile for the given session, or nil if not yet saved.
    public func fetch(sessionID: UUID) -> AudioContextProfile? {
        fetchAll().first { $0.sessionID == sessionID }
    }

    /// Returns all stored profiles. Cached after the first disk read.
    public func fetchAll() -> [AudioContextProfile] {
        if let hit = cache {
            return hit
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cache = []
            return []
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let loaded = try decoder.decode([AudioContextProfile].self, from: data)
            cache = loaded
            return loaded
        } catch {
            print("[AudioProfileStore] Load error at \(fileURL.path): \(error)")
            cache = []
            return []
        }
    }

    private func persist(_ profiles: [AudioContextProfile]) {
        do {
            let data = try encoder.encode(profiles)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[AudioProfileStore] Save error at \(fileURL.path): \(error)")
        }
    }

    /// Full erase: drops the in-memory cache and the on-disk profile file.
    func removeAll() {
        cache = []
        try? FileManager.default.removeItem(at: fileURL)
    }
}

// MARK: - AudioMonitorService

/// Captures the audio environment during active reading sessions.
///
/// Usage:
///   SessionCoordinator creates one instance and calls:
///     startMonitoring(sessionID:)   — when a session begins
///     finalizeContext(sessionID:sessionDuration:) — when the session ends
///
@MainActor
public final class AudioMonitorService: ObservableObject {
    // MARK: - Published

    @Published public private(set) var isMonitoring: Bool = false

    // MARK: - Private State

    private var pollingTimer: Timer?
    private var currentSessionID: UUID?
    private var accumulatedSnapshots: [AudioSnapshot] = []
    private var lastTrackTitle: String?
    private var lastCategory: AudioCategory = .silence

    /// Snapshot cap: 120 entries = 2 hours at one-per-minute. Prevents unbounded growth.
    private let maxSnapshots: Int = 120
    private let pollingInterval: TimeInterval = 60.0

    // MARK: - Public API

    /// Starts monitoring the audio environment for the given reading session.
    /// Takes an immediate baseline snapshot so even short sessions have data.
    public func startMonitoring(sessionID: UUID) {
        stopCurrentMonitor()

        currentSessionID = sessionID
        accumulatedSnapshots = []
        lastTrackTitle = nil
        lastCategory = .silence
        isMonitoring = true

        // Baseline snapshot immediately (t = 0).
        if let snapshot = captureAudioSnapshot() {
            accumulatedSnapshots.append(snapshot)
            lastTrackTitle = snapshot.trackTitle
            lastCategory = snapshot.category
        }

        pollingTimer = Timer.scheduledTimer(
            withTimeInterval: pollingInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollAudioEnvironment()
            }
        }

        print("[AudioMonitorService] Monitoring started — session \(sessionID.uuidString.prefix(8))")
    }

    /// Stops monitoring without producing a profile. Used for emergency cleanup only.
    public func stopMonitoring() {
        stopCurrentMonitor()
        print("[AudioMonitorService] Monitoring stopped (no profile produced).")
    }

    /// Stops monitoring and returns the complete AudioContextProfile for the session.
    /// Always returns a non-nil profile — even silence-only sessions get a profile.
    ///
    /// - Parameters:
    ///   - sessionID:        The session being ended (must match the monitored session).
    ///   - sessionDuration:  Total session duration in seconds (from SessionCoordinator.elapsedTime).
    @discardableResult
    public func finalizeContext(
        sessionID: UUID,
        sessionDuration: TimeInterval
    ) -> AudioContextProfile {
        // Final snapshot at session end.
        if let last = captureAudioSnapshot() {
            // Avoid duplicate if polled within the last few seconds.
            let gap = last.timestamp.timeIntervalSince(accumulatedSnapshots.last?.timestamp ?? .distantPast)
            if gap > 10 {
                accumulatedSnapshots.append(last)
            }
        }

        let profile = buildContextProfile(
            sessionID: sessionID,
            sessionDuration: max(1, sessionDuration)
        )

        stopCurrentMonitor()

        print("[AudioMonitorService] Finalized — session \(sessionID.uuidString.prefix(8)) " +
            "primary=\(profile.primaryCategory.rawValue) " +
            "intensity=\(String(format: "%.0f%%", profile.listeningIntensity * 100)) " +
            "snapshots=\(profile.snapshots.count)")

        return profile
    }

    // MARK: - Polling

    private func pollAudioEnvironment() {
        guard isMonitoring else { return }
        guard let snapshot = captureAudioSnapshot() else { return }

        accumulatedSnapshots.append(snapshot)
        if accumulatedSnapshots.count > maxSnapshots {
            accumulatedSnapshots = Array(accumulatedSnapshots.suffix(maxSnapshots))
        }

        lastTrackTitle = snapshot.trackTitle
        lastCategory = snapshot.category
    }

    // MARK: - Snapshot Capture

    private func captureAudioSnapshot() -> AudioSnapshot? {
        let now = Date()
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        let weekday = calendar.component(.weekday, from: now)
        let month = calendar.component(.month, from: now)
        let season = deriveSeason(month: month)

        let detection = detectAudioEnvironment()
        let isActive = detection.isPlaying || (!detection.isPlaying && isAudioOutputActive())
        let category = isActive ? detection.category : .silence
        let chars = inferCharacteristics(genreString: detection.metadata?.genre)

        return AudioSnapshot(
            timestamp: now,
            isPlaying: isActive,
            playbackRate: detection.isPlaying ? 1.0 : 0.0,
            elapsedPlaybackTime: detection.metadata?.position,
            trackDuration: detection.metadata?.duration,
            audioSource: detection.source,
            applicationDisplayName: detection.applicationName,
            trackTitle: detection.metadata?.title,
            artistName: detection.metadata?.artist,
            albumTitle: detection.metadata?.album,
            genreString: detection.metadata?.genre,
            playlistName: detection.metadata?.playlist,
            category: category,
            characteristics: chars,
            hourOfDay: hour,
            dayOfWeek: weekday,
            month: month,
            season: season
        )
    }

    // MARK: - Audio Environment Detection

    private struct DetectionResult {
        let source: AudioSource
        let applicationName: String?
        let isPlaying: Bool
        let category: AudioCategory
        let metadata: AudioTrackMetadata?
    }

    private func detectAudioEnvironment() -> DetectionResult {
        let running = NSWorkspace.shared.runningApplications

        // Priority 1: Music.app — richest metadata via AppleScript.
        if running.contains(where: { $0.bundleIdentifier == "com.apple.Music" }) {
            if let meta = fetchMusicAppMetadata(), !meta.title.isEmpty {
                return DetectionResult(
                    source: .appleMusicApp,
                    applicationName: "Music",
                    isPlaying: true,
                    category: classifyCategory(source: .appleMusicApp, genre: meta.genre),
                    metadata: meta
                )
            }
            // Music.app is open but paused/stopped — continue checking others.
        }

        // Priority 2: Spotify — track metadata via AppleScript (no genre from Spotify's dictionary).
        if running.contains(where: { $0.bundleIdentifier == "com.spotify.client" }) {
            if let meta = fetchSpotifyMetadata(), !meta.title.isEmpty {
                return DetectionResult(
                    source: .spotifyApp,
                    applicationName: "Spotify",
                    isPlaying: true,
                    category: classifyCategory(source: .spotifyApp, genre: meta.genre),
                    metadata: meta
                )
            }
        }

        // Priority 3: Other known audio apps — category only, no metadata.
        let sourceResult = identifyAudioSource(from: running)
        let hasAudio = isAudioOutputActive()

        return DetectionResult(
            source: sourceResult.source,
            applicationName: sourceResult.name,
            isPlaying: hasAudio,
            category: hasAudio ? defaultCategory(for: sourceResult.source) : .silence,
            metadata: nil
        )
    }

    private func identifyAudioSource(
        from apps: [NSRunningApplication]
    ) -> (source: AudioSource, name: String?) {
        // Ordered by specificity — most specific audio apps checked first.
        let candidates: [(bundleID: String, source: AudioSource, name: String)] = [
            ("com.apple.podcasts", .podcastsApp, "Podcasts"),
            ("com.apple.Audiobooks", .audiobooksApp, "Books"),
            ("com.apple.QuickTimePlayerX", .quickTimePlayer, "QuickTime Player"),
            ("org.videolan.vlc", .vlcPlayer, "VLC"),
            ("com.colliderli.iina", .iinaPlayer, "IINA"),
            ("com.apple.Safari", .safariBrowser, "Safari"),
            ("com.google.Chrome", .chromeBrowser, "Chrome"),
            ("org.mozilla.firefox", .firefoxBrowser, "Firefox"),
        ]
        for c in candidates where apps.contains(where: { $0.bundleIdentifier == c.bundleID }) {
            return (c.source, c.name)
        }
        return (.unknown, nil)
    }

    private func defaultCategory(for source: AudioSource) -> AudioCategory {
        switch source {
        case .appleMusicApp, .spotifyApp:
            return .music
        case .podcastsApp:
            return .podcast
        case .audiobooksApp:
            return .audioBook
        case .quickTimePlayer, .vlcPlayer, .iinaPlayer:
            return .videoAudio
        case .safariBrowser, .chromeBrowser, .firefoxBrowser:
            return .unknown // Could be music, video, or podcast — can't tell without metadata
        case .systemAudio, .unknown:
            return .unknown
        }
    }

    private func classifyCategory(source: AudioSource, genre: String) -> AudioCategory {
        let lower = genre.lowercased()
        if lower.contains("podcast") {
            return .podcast
        }
        if lower.contains("audiobook") || lower.contains("audio book") {
            return .audioBook
        }
        if lower.contains("spoken") || lower.contains("lecture") {
            return .spokenWord
        }
        if lower.contains("ambient") || lower.contains("nature") ||
            lower.contains("soundscape") || lower.contains("white noise")
        {
            return .ambientSoundscape
        }
        // Music.app / Spotify with non-overriding genre → music.
        if source == .appleMusicApp || source == .spotifyApp {
            return .music
        }
        return defaultCategory(for: source)
    }

    // MARK: - AppleScript Metadata Queries

    /// Queries Music.app for the currently playing track via AppleScript.
    /// Returns nil when Music.app is paused, stopped, or when a query error occurs.
    ///
    /// REQUIRES entitlement: com.apple.security.automation.apple-events
    private func fetchMusicAppMetadata() -> AudioTrackMetadata? {
        let source = """
        tell application "Music"
            if player state is playing then
                set t  to name of current track as string
                set ar to artist of current track as string
                set al to album of current track as string
                set g  to genre of current track as string
                set dur to duration of current track as real
                set pos to player position as real
                set pl to name of current playlist as string
                return {t, ar, al, g, pos, dur, pl}
            else
                return {}
            end if
        end tell
        """
        return runAppleScript(source) { desc in
            guard desc.numberOfItems >= 6 else { return nil }
            let title = desc.atIndex(1)?.stringValue ?? ""
            let artist = desc.atIndex(2)?.stringValue ?? ""
            let album = desc.atIndex(3)?.stringValue ?? ""
            let genre = desc.atIndex(4)?.stringValue ?? ""
            let position = desc.atIndex(5)?.doubleValue ?? 0
            let duration = desc.atIndex(6)?.doubleValue ?? 0
            let playlist = desc.atIndex(7)?.stringValue ?? ""
            guard !title.isEmpty else { return nil }
            return AudioTrackMetadata(
                title: title, artist: artist, album: album,
                genre: genre, playlist: playlist,
                duration: duration, position: position
            )
        }
    }

    /// Queries Spotify for the currently playing track via AppleScript.
    /// Note: Spotify's AppleScript dictionary does not expose genre or playlist name.
    ///
    /// REQUIRES entitlement: com.apple.security.automation.apple-events
    private func fetchSpotifyMetadata() -> AudioTrackMetadata? {
        let source = """
        tell application "Spotify"
            if player state is playing then
                set t  to name of current track as string
                set ar to artist of current track as string
                set al to album of current track as string
                set dur to (duration of current track / 1000) as real
                set pos to player position as real
                return {t, ar, al, pos, dur}
            else
                return {}
            end if
        end tell
        """
        return runAppleScript(source) { desc in
            guard desc.numberOfItems >= 4 else { return nil }
            let title = desc.atIndex(1)?.stringValue ?? ""
            let artist = desc.atIndex(2)?.stringValue ?? ""
            let album = desc.atIndex(3)?.stringValue ?? ""
            let position = desc.atIndex(4)?.doubleValue ?? 0
            let duration = desc.atIndex(5)?.doubleValue ?? 0
            guard !title.isEmpty else { return nil }
            // Spotify's AppleScript dictionary doesn't expose genre or playlist name.
            return AudioTrackMetadata(
                title: title, artist: artist, album: album,
                genre: "", playlist: "",
                duration: duration, position: position
            )
        }
    }

    /// Executes an AppleScript string synchronously and passes the result to a parser.
    /// Returns nil on compilation or execution error.
    private func runAppleScript<T>(
        _ source: String,
        parser: (NSAppleEventDescriptor) -> T?
    ) -> T? {
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let _ = errorInfo {
            return nil
        }
        return parser(descriptor)
    }

    // MARK: - CoreAudio Output Presence Detection

    /// Returns true if any process is currently sending audio to the default output device.
    /// This is a presence check only — it does not identify what is playing.
    private func isAudioOutputActive() -> Bool {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let deviceStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard deviceStatus == noErr, deviceID != kAudioObjectUnknown else { return false }

        var isRunning: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let runStatus = AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &size, &isRunning
        )
        return runStatus == noErr && isRunning != 0
    }

    // MARK: - Inference Helpers

    private func inferCharacteristics(genreString: String?) -> AudioCharacteristics {
        guard let genre = genreString, !genre.isEmpty else { return .unavailable }
        let lower = genre.lowercased()
        let mood = inferMood(lower)
        let energy = inferEnergy(lower)
        return AudioCharacteristics(inferredMood: mood, inferredEnergy: energy)
    }

    private func inferMood(_ lower: String) -> InferredMood {
        if lower.contains("classical") || lower.contains("ambient") ||
            lower.contains("new age") || lower.contains("acoustic") ||
            lower.contains("folk") || lower.contains("chamber")
        {
            return .calm
        }

        if lower.contains("electronic") || lower.contains("instrumental") ||
            lower.contains("lo-fi") || lower.contains("lo fi") ||
            lower.contains("minimal") || lower.contains("chillout") ||
            lower.contains("study") || lower.contains("focus")
        {
            return .focused
        }

        if lower.contains("rock") || lower.contains("metal") ||
            lower.contains("edm") || lower.contains("dance") ||
            lower.contains("hip-hop") || lower.contains("hip hop") ||
            lower.contains("punk") || lower.contains("trap")
        {
            return .energetic
        }

        if lower.contains("blues") ||
            lower.contains("country") ||
            lower.contains("singer-songwriter") ||
            lower.contains("emo")
        {
            return .melancholic
        }

        if lower.contains("pop") || lower.contains("reggae") ||
            lower.contains("soul") || lower.contains("funk") ||
            lower.contains("gospel") || lower.contains("r&b")
        {
            return .upbeat
        }

        return .neutral
    }

    private func inferEnergy(_ lower: String) -> Double {
        // Heuristic energy buckets. Not an acoustic measurement.
        if lower.contains("metal") || lower.contains("edm") ||
            lower.contains("trap") || lower.contains("punk")
        {
            return 0.90
        }
        if lower.contains("rock") || lower.contains("dance") ||
            lower.contains("hip-hop") || lower.contains("hip hop")
        {
            return 0.75
        }
        if lower.contains("pop") || lower.contains("reggae") ||
            lower.contains("soul") || lower.contains("funk")
        {
            return 0.60
        }
        if lower.contains("electronic") || lower.contains("lo-fi") ||
            lower.contains("lo fi") || lower.contains("instrumental")
        {
            return 0.40
        }
        if lower.contains("acoustic") || lower.contains("folk") ||
            lower.contains("blues") || lower.contains("country")
        {
            return 0.30
        }
        if lower.contains("classical") || lower.contains("ambient") ||
            lower.contains("new age") || lower.contains("chamber")
        {
            return 0.20
        }
        return 0.50 // default
    }

    private func deriveSeason(month: Int) -> SeasonalPeriod {
        switch month {
        case 3, 4, 5: return .spring
        case 6, 7, 8: return .summer
        case 9, 10, 11: return .autumn
        default: return .winter
        }
    }

    // MARK: - Profile Assembly

    private func buildContextProfile(
        sessionID: UUID,
        sessionDuration: TimeInterval
    ) -> AudioContextProfile {
        let snaps = accumulatedSnapshots

        // Edge case: session ended before a single poll fired.
        guard !snaps.isEmpty else {
            return AudioContextProfile(
                sessionID: sessionID,
                wasAudioPresent: false,
                primaryCategory: .silence,
                categoryDistribution: [.silence: 1.0],
                totalAudioDuration: 0,
                silenceDuration: sessionDuration,
                sessionDuration: sessionDuration,
                trackTransitionCount: 0,
                categoryTransitionCount: 0,
                snapshots: [],
                tracksHeard: [],
                artistsHeard: [],
                albumsHeard: [],
                genresHeard: [],
                playlistsHeard: []
            )
        }

        // Assign equal time slices to each snapshot (approximation).
        let segmentSeconds = sessionDuration / Double(snaps.count)
        var categorySeconds: [AudioCategory: Double] = [:]
        for snap in snaps {
            let cat = snap.isPlaying ? snap.category : .silence
            categorySeconds[cat, default: 0] += segmentSeconds
        }

        let totalAudio = categorySeconds.filter { $0.key != .silence }.values.reduce(0, +)
        let silence = sessionDuration - totalAudio
        let total = max(1, sessionDuration)
        let distribution = categorySeconds.mapValues { $0 / total }
        let primary = categorySeconds.max(by: { $0.value < $1.value })?.key ?? .silence

        // Track transitions: consecutive distinct track title changes.
        var trackTransitions = 0
        var prevTitle: String? = nil
        for snap in snaps where snap.isPlaying {
            if let t = snap.trackTitle, !t.isEmpty {
                if prevTitle != nil && t != prevTitle {
                    trackTransitions += 1
                }
                prevTitle = t
            }
        }

        // Category transitions: consecutive category changes.
        var catTransitions = 0
        var prevCat: AudioCategory? = nil
        for snap in snaps {
            let cat = snap.isPlaying ? snap.category : .silence
            if let pc = prevCat, cat != pc {
                catTransitions += 1
            }
            prevCat = cat
        }

        let tracks = Array(Set(snaps.compactMap(\.trackTitle).filter { !$0.isEmpty }))
        let artists = Array(Set(snaps.compactMap(\.artistName).filter { !$0.isEmpty }))
        let albums = Array(Set(snaps.compactMap(\.albumTitle).filter { !$0.isEmpty }))
        let genres = Array(Set(snaps.compactMap(\.genreString).filter { !$0.isEmpty }))
        let playlists = Array(Set(snaps.compactMap(\.playlistName).filter { !$0.isEmpty }))

        return AudioContextProfile(
            sessionID: sessionID,
            wasAudioPresent: totalAudio > 0,
            primaryCategory: primary,
            categoryDistribution: distribution,
            totalAudioDuration: max(0, totalAudio),
            silenceDuration: max(0, silence),
            sessionDuration: sessionDuration,
            trackTransitionCount: trackTransitions,
            categoryTransitionCount: catTransitions,
            snapshots: snaps,
            tracksHeard: tracks,
            artistsHeard: artists,
            albumsHeard: albums,
            genresHeard: genres,
            playlistsHeard: playlists
        )
    }

    // MARK: - Cleanup

    private func stopCurrentMonitor() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        currentSessionID = nil
        isMonitoring = false
    }
}
