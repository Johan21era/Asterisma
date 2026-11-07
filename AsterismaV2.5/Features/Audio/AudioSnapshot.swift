//  AudioSnapshot.swift
//  AsterismaV2.5
//  PURPOSE
//  All model types for the audio intelligence layer.
//  Consumed by AudioMonitorService (collection) and MusicalAnalysisEngine (analysis).
//
//  PLATFORM CONSTRAINT
//  macOS public APIs do not expose cross-process acoustic analysis.
//  MPNowPlayingInfoCenter.default.nowPlayingInfo reflects only the current process's
//  registration. True BPM, spectral energy, and timbre require AVCaptureAudioDataOutput
//  with microphone entitlements — inappropriate for a reading tracker.
//
//  This engine uses:
//    1. NSWorkspace — to detect which audio app is running (AudioSource classification)
//    2. NSAppleScript — to query Music.app and Spotify for track metadata
//       (requires com.apple.security.automation.apple-events entitlement)
//    3. CoreAudio output-device presence — to detect if any audio is playing
//    4. Genre-string heuristics — to infer mood and energy (InferredMood, InferredEnergy)
//
//  All "characteristics" fields are labelled as inferred, never measured.

import Foundation

// MARK: - AudioCategory

/// The classification of audio present at a single observation point.
/// Derived from media type, app identity, and genre-string heuristics.
public enum AudioCategory: String, Codable, CaseIterable, Hashable, Sendable {
    case silence // No audio detected on the default output device
    case music // Music (Music.app, Spotify, or genre-confirmed music)
    case podcast // Podcast app or genre-confirmed podcast content
    case audioBook // Audiobook app or genre-confirmed audiobook
    case spokenWord // Other spoken-word (lectures, radio, interviews)
    case videoAudio // Audio from video playback (QuickTime, VLC, IINA, browser)
    case ambientSoundscape // Ambient / white-noise / nature-sounds apps
    case unknown // Audio detected but source not classifiable
}

// MARK: - AudioSource

/// Which application category is producing the audio.
/// Determined via NSWorkspace.shared.runningApplications.
public enum AudioSource: String, Codable, CaseIterable, Hashable, Sendable {
    case appleMusicApp // com.apple.Music
    case spotifyApp // com.spotify.client
    case podcastsApp // com.apple.podcasts
    case audiobooksApp // com.apple.Audiobooks
    case quickTimePlayer // com.apple.QuickTimePlayerX
    case vlcPlayer // org.videolan.vlc
    case iinaPlayer // com.colliderli.iina
    case safariBrowser // com.apple.Safari
    case chromeBrowser // com.google.Chrome
    case firefoxBrowser // org.mozilla.firefox
    case systemAudio // System alert / UI sounds
    case unknown // No identifiable audio-producing application
}

// MARK: - InferredMood

/// Mood classification derived from the genre metadata string.
/// This is a heuristic mapping, NOT an acoustic measurement.
/// All cases other than .unavailable are approximations based on genre taxonomy.
public enum InferredMood: String, Codable, CaseIterable, Hashable, Sendable {
    case calm // Classical, Ambient, New Age, Acoustic, Folk, Chamber
    case focused // Electronic, Instrumental, Lo-Fi, Minimal, Study, Chillout
    case energetic // Rock, Metal, EDM, Dance, Hip-Hop, Punk, Trap
    case melancholic // Blues, Country, Singer-Songwriter, Emo
    case upbeat // Pop, Reggae, Soul, Funk, Gospel
    case neutral // Genre present but not mappable to a mood cluster
    case unavailable // No genre metadata in the audio source
}

// MARK: - AudioCharacteristics

/// Audio traits inferrable from macOS public APIs without audio capture entitlements.
/// Every field has a documented derivation path. Nothing is computed from audio signal.
public struct AudioCharacteristics: Codable, Hashable, Sendable {
    /// Mood inferred from genre string. .unavailable when genre metadata is absent.
    public let inferredMood: InferredMood

    /// Energy level 0.0–1.0 inferred from genre string. nil when genre is absent.
    /// This is a genre-taxonomy heuristic, not a loudness or RMS measurement.
    public let inferredEnergy: Double?

    public init(inferredMood: InferredMood, inferredEnergy: Double?) {
        self.inferredMood = inferredMood
        self.inferredEnergy = inferredEnergy
    }

    /// Null characteristics produced when no genre metadata is available.
    public static let unavailable = AudioCharacteristics(
        inferredMood: .unavailable,
        inferredEnergy: nil
    )
}

// MARK: - AudioSnapshot

/// An atomic observation of the audio environment captured during an active reading session.
/// Recorded every 60 seconds by AudioMonitorService.
/// Analogous to WeatherSnapshot in the environmental intelligence subsystem.
public struct AudioSnapshot: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date

    // MARK: Playback State

    /// True if any audio was actively playing at capture time.
    public let isPlaying: Bool
    /// 0.0 = paused or stopped; 1.0 = normal playback speed.
    public let playbackRate: Double
    /// Elapsed seconds in the current track (AppleScript: Music.app only). nil if unavailable.
    public let elapsedPlaybackTime: TimeInterval?
    /// Total track duration in seconds (AppleScript: Music.app only). nil if unavailable.
    public let trackDuration: TimeInterval?

    // MARK: Source

    public let audioSource: AudioSource
    /// Human-readable application name, if identifiable via NSWorkspace.
    public let applicationDisplayName: String?

    // MARK: Track Metadata

    // Available only from Music.app and Spotify via AppleScript.
    // nil for all other audio sources (browsers, video players, etc.).
    public let trackTitle: String?
    public let artistName: String?
    public let albumTitle: String?
    /// Raw genre string as reported by the audio source (e.g. "Alternative & Punk").
    public let genreString: String?
    /// Current playlist name. Available from Music.app via AppleScript only.
    public let playlistName: String?

    // MARK: Classification

    public let category: AudioCategory
    public let characteristics: AudioCharacteristics

    // MARK: Temporal Context

    public let hourOfDay: Int // 0–23
    public let dayOfWeek: Int // 1 (Sunday) – 7 (Saturday)
    public let month: Int // 1–12
    /// Reuses SeasonalPeriod from WeatherAnalysisEngine (same module).
    public let season: SeasonalPeriod

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        isPlaying: Bool,
        playbackRate: Double,
        elapsedPlaybackTime: TimeInterval?,
        trackDuration: TimeInterval?,
        audioSource: AudioSource,
        applicationDisplayName: String?,
        trackTitle: String?,
        artistName: String?,
        albumTitle: String?,
        genreString: String?,
        playlistName: String?,
        category: AudioCategory,
        characteristics: AudioCharacteristics,
        hourOfDay: Int,
        dayOfWeek: Int,
        month: Int,
        season: SeasonalPeriod
    ) {
        self.id = id
        self.timestamp = timestamp
        self.isPlaying = isPlaying
        self.playbackRate = playbackRate
        self.elapsedPlaybackTime = elapsedPlaybackTime
        self.trackDuration = trackDuration
        self.audioSource = audioSource
        self.applicationDisplayName = applicationDisplayName
        self.trackTitle = trackTitle
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.genreString = genreString
        self.playlistName = playlistName
        self.category = category
        self.characteristics = characteristics
        self.hourOfDay = hourOfDay
        self.dayOfWeek = dayOfWeek
        self.month = month
        self.season = season
    }
}

// MARK: - AudioContextProfile

/// The complete audio environment picture for a single reading session.
/// Created by AudioMonitorService when a session ends.
/// Every session receives a profile — even sessions in complete silence.
public struct AudioContextProfile: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let createdAt: Date

    // MARK: Presence

    /// True if any audio was playing at any point during the session.
    public let wasAudioPresent: Bool
    /// The audio category with the most time-weighted presence.
    public let primaryCategory: AudioCategory
    /// Fraction of session time [0–1] each category was active.
    public let categoryDistribution: [AudioCategory: Double]

    // MARK: Duration

    /// Total seconds audio was present (all categories except silence).
    public let totalAudioDuration: TimeInterval
    /// Total seconds the session was silent.
    public let silenceDuration: TimeInterval
    /// Total session duration in seconds (passed in from SessionCoordinator.elapsedTime).
    public let sessionDuration: TimeInterval

    // MARK: Change Frequency

    /// Number of distinct track titles observed (proxy for playlist size / listening variety).
    public let trackTransitionCount: Int
    /// Number of times the primary audio category changed during the session.
    public let categoryTransitionCount: Int

    // MARK: Listening Conditions (sampled throughout session)

    /// One snapshot per 60-second poll interval, capped at 120 snapshots (2 hours).
    public let snapshots: [AudioSnapshot]

    // MARK: Metadata Fingerprints (deduplicated sets)

    public let tracksHeard: [String]
    public let artistsHeard: [String]
    public let albumsHeard: [String]
    public let genresHeard: [String]
    public let playlistsHeard: [String] // Music.app only

    // MARK: Computed

    /// Fraction of session time during which audio was present. 0–1.
    public var listeningIntensity: Double {
        guard sessionDuration > 0 else { return 0 }
        return min(1.0, totalAudioDuration / sessionDuration)
    }

    /// The dominant mood across all playing snapshots, derived from genre inference.
    public var dominantMood: InferredMood {
        let moods = snapshots.filter(\.isPlaying).map(\.characteristics.inferredMood)
        guard !moods.isEmpty else { return .unavailable }
        return Dictionary(grouping: moods, by: { $0 })
            .max(by: { $0.value.count < $1.value.count })?.key ?? .unavailable
    }

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        createdAt: Date = Date(),
        wasAudioPresent: Bool,
        primaryCategory: AudioCategory,
        categoryDistribution: [AudioCategory: Double],
        totalAudioDuration: TimeInterval,
        silenceDuration: TimeInterval,
        sessionDuration: TimeInterval,
        trackTransitionCount: Int,
        categoryTransitionCount: Int,
        snapshots: [AudioSnapshot],
        tracksHeard: [String],
        artistsHeard: [String],
        albumsHeard: [String],
        genresHeard: [String],
        playlistsHeard: [String]
    ) {
        self.id = id
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.wasAudioPresent = wasAudioPresent
        self.primaryCategory = primaryCategory
        self.categoryDistribution = categoryDistribution
        self.totalAudioDuration = totalAudioDuration
        self.silenceDuration = silenceDuration
        self.sessionDuration = sessionDuration
        self.trackTransitionCount = trackTransitionCount
        self.categoryTransitionCount = categoryTransitionCount
        self.snapshots = snapshots
        self.tracksHeard = tracksHeard
        self.artistsHeard = artistsHeard
        self.albumsHeard = albumsHeard
        self.genresHeard = genresHeard
        self.playlistsHeard = playlistsHeard
    }
}

// MARK: - AudioSessionRecord

/// The unit of analysis for MusicalAnalysisEngine.
/// Pairs one completed reading session with its audio context and reading performance metrics.
/// Mirrors WeatherAnalysisEngine.EnvironmentalSessionRecord in structure and purpose.
public struct AudioSessionRecord: Codable, Identifiable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let bookID: UUID
    /// Session start time; used for temporal analysis (hour of day, day of week, season).
    public let timestamp: Date

    // MARK: Audio Input

    public let audioContext: AudioContextProfile

    // MARK: Reading Performance

    // These fields are supplied by the caller (DataStore / MusicalAnalysisEngine.buildSessionRecords).
    // MusicalAnalysisEngine does NOT compute reading metrics — it consumes them.

    public let readingDurationMinutes: Double
    public let pagesRead: Double
    public let chaptersCompleted: Double
    public let booksCompleted: Double // 0.0 or 1.0
    public let readingSpeed: Double // average seconds per page
    public let consistencyScore: Double // 0–1 pace consistency (low variance = 1.0)
    public let readingFrequencyScore: Double // sessions per week in surrounding 7-day window, normalized 0–1
    public let engagementScore: Double // 0–1 derived from session length and depth
    public let sessionQualityScore: Double // 0–1 composite quality
    public let momentumScore: Double // 0–1 reading streak momentum at session time
    public let completionProbability: Double // book.progressFraction at session end
    public let abandonmentProbability: Double // 1 - completionProbability
    public let difficultyScore: Double // ReadingDifficultyProfile.difficultyMultiplier
    public let complexityScore: Double // normalized 0–1
    public let bookLength: Double // book.totalPages
    public let genre: String? // ReadingGenre.rawValue
    public let annotationCount: Int // notes created during this session
    public let reread: Bool

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        bookID: UUID,
        timestamp: Date,
        audioContext: AudioContextProfile,
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
        annotationCount: Int,
        reread: Bool
    ) {
        self.id = id
        self.sessionID = sessionID
        self.bookID = bookID
        self.timestamp = timestamp
        self.audioContext = audioContext
        self.readingDurationMinutes = readingDurationMinutes
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
        self.annotationCount = annotationCount
        self.reread = reread
    }
}

// MARK: - AudioCategory Helpers

public extension AudioCategory {
    /// Human-readable display name.
    var displayName: String {
        switch self {
        case .silence: return "Silence"
        case .music: return "Music"
        case .podcast: return "Podcasts"
        case .audioBook: return "Audiobook"
        case .spokenWord: return "Spoken Word"
        case .videoAudio: return "Video Audio"
        case .ambientSoundscape: return "Ambient Sounds"
        case .unknown: return "Background Audio"
        }
    }
}
