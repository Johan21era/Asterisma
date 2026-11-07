//  BehavioralCategory.swift
import AppKit
import Combine
import Foundation
import GRDB
import IOKit
import IOKit.pwr_mgt

// MARK: - Behavioral Category

/// Represents a broad behavioral classification for an application.
///
/// Categories are intentionally broad and non-interpretive.
/// They exist solely to organize raw evidence for future systems.
///
/// This subsystem never assigns significance or behavioral meaning
/// to these categories.
public enum BehavioralCategory: String, Codable, CaseIterable, Hashable, Sendable {
    case gaming = "Gaming"
    case entertainment = "Entertainment"
    case communication = "Communication"
    case browsing = "Browsing"
    case productivity = "Productivity"
    case development = "Development"
    case education = "Education"
    case finance = "Finance"
    case creativeWork = "CreativeWork"
    case utility = "Utility"
    case system = "System"
    case unknown = "Unknown"
}

// MARK: - Behavioral Event Type

/// Defines the type of observed operating-system behavioral event.
///
/// These events are low-level evidence records and intentionally avoid
/// any interpretation or semantic conclusions.
public enum BehavioralEventType: String, Codable, Hashable, Sendable {
    case applicationLaunched
    case applicationTerminated
    case applicationActivated
    case applicationDeactivated

    case sessionStarted
    case sessionEnded

    case inactivityStarted
    case inactivityEnded

    case deviceSleep
    case deviceWake

    case screenLocked
    case screenUnlocked

    case deviceStateTransition
}

// MARK: - Device State Type

/// Represents coarse device state transitions.
///
/// These states exist only to preserve contextual system evidence.
public enum DeviceStateType: String, Codable, Hashable, Sendable {
    case active
    case inactive
    case sleeping
    case awake
    case locked
    case unlocked
}

// MARK: - Application Descriptor

/// Represents normalized application identity information.
///
/// This structure preserves the original application metadata
/// observed from the operating system.
public struct ApplicationDescriptor: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let applicationName: String
    public let bundleIdentifier: String?
    public let processIdentifier: Int32?
    public let category: BehavioralCategory
    public let executableURL: URL?

    public init(
        id: UUID = UUID(),
        applicationName: String,
        bundleIdentifier: String?,
        processIdentifier: Int32?,
        category: BehavioralCategory,
        executableURL: URL?
    ) {
        self.id = id
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.category = category
        self.executableURL = executableURL
    }
}

// MARK: - Behavioral Event

/// Represents a timestamped operating-system behavioral event.
///
/// Events preserve raw evidence and should remain historically accurate.
/// Future systems may reconstruct behavior from these records.
public struct BehavioralEvent: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let eventType: BehavioralEventType
    public let application: ApplicationDescriptor?
    public let metadata: [String: String]
    public let source: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        eventType: BehavioralEventType,
        application: ApplicationDescriptor?,
        metadata: [String: String] = [:],
        source: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.eventType = eventType
        self.application = application
        self.metadata = metadata
        self.source = source
    }
}

// MARK: - Application Usage Session

/// Represents a continuous foreground application usage interval.
///
/// Sessions are reconstructed from activation/deactivation transitions.
/// No interpretation is performed regarding productivity, importance,
/// or behavioral significance.
public struct ApplicationUsageSession: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let application: ApplicationDescriptor
    public let startTime: Date
    public var endTime: Date?
    public var duration: TimeInterval? {
        guard let endTime else { return nil }
        return endTime.timeIntervalSince(startTime)
    }

    public init(
        id: UUID = UUID(),
        application: ApplicationDescriptor,
        startTime: Date,
        endTime: Date? = nil
    ) {
        self.id = id
        self.application = application
        self.startTime = startTime
        self.endTime = endTime
    }
}

// MARK: - Device State Event

/// Represents a timestamped device-level state transition.
///
/// These events preserve operating-system context without attaching
/// behavioral meaning.
public struct DeviceStateEvent: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let state: DeviceStateType
    public let metadata: [String: String]

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        state: DeviceStateType,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.state = state
        self.metadata = metadata
    }
}

// MARK: - Inactivity Record

/// Represents a period of detected user inactivity.
///
/// Inactivity is preserved as first-class evidence and intentionally
/// avoids assumptions regarding user intent or absence reasons.
public struct InactivityRecord: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let startTime: Date
    public var endTime: Date?

    public var duration: TimeInterval? {
        guard let endTime else { return nil }
        return endTime.timeIntervalSince(startTime)
    }

    public init(
        id: UUID = UUID(),
        startTime: Date,
        endTime: Date? = nil
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
    }
}

// MARK: - Timeline Segment

/// Represents a normalized behavioral timeline interval.
///
/// Timeline segments provide future systems with a consistent
/// reconstruction primitive without imposing interpretation.
public struct BehavioralTimelineSegment: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let startTime: Date
    public let endTime: Date
    public let eventType: BehavioralEventType
    public let application: ApplicationDescriptor?

    public init(
        id: UUID = UUID(),
        startTime: Date,
        endTime: Date,
        eventType: BehavioralEventType,
        application: ApplicationDescriptor?
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.eventType = eventType
        self.application = application
    }
}

// MARK: - Observation Window

/// Represents a bounded historical observation interval.
public struct BehavioralObservationWindow: Codable, Hashable, Sendable {
    public let startDate: Date
    public let endDate: Date

    public init(startDate: Date, endDate: Date) {
        self.startDate = startDate
        self.endDate = endDate
    }
}

// MARK: - Application Behavior Profile

/// Aggregates observed application evidence.
///
/// This model is intentionally descriptive rather than analytical.
public struct ApplicationBehaviorProfile: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let application: ApplicationDescriptor
    public let observedEvents: Int
    public let observedSessions: Int
    public let totalObservedDuration: TimeInterval

    public init(
        id: UUID = UUID(),
        application: ApplicationDescriptor,
        observedEvents: Int,
        observedSessions: Int,
        totalObservedDuration: TimeInterval
    ) {
        self.id = id
        self.application = application
        self.observedEvents = observedEvents
        self.observedSessions = observedSessions
        self.totalObservedDuration = totalObservedDuration
    }
}

// MARK: - Behavioral Snapshot

/// Represents a point-in-time evidence snapshot.
public struct BehavioralSnapshot: Codable, Hashable, Sendable {
    public let timestamp: Date
    public let activeApplication: ApplicationDescriptor?
    public let deviceState: DeviceStateType

    public init(
        timestamp: Date = Date(),
        activeApplication: ApplicationDescriptor?,
        deviceState: DeviceStateType
    ) {
        self.timestamp = timestamp
        self.activeApplication = activeApplication
        self.deviceState = deviceState
    }
}

// MARK: - Behavioral Statistics

/// Provides descriptive summaries over stored evidence.
///
/// This structure intentionally avoids scoring, ranking,
/// or interpretation.
public struct BehavioralStatistics: Codable, Hashable, Sendable {
    public let totalEvents: Int
    public let totalSessions: Int
    public let totalInactivityRecords: Int
    public let totalObservedApplicationDuration: TimeInterval

    public init(
        totalEvents: Int,
        totalSessions: Int,
        totalInactivityRecords: Int,
        totalObservedApplicationDuration: TimeInterval
    ) {
        self.totalEvents = totalEvents
        self.totalSessions = totalSessions
        self.totalInactivityRecords = totalInactivityRecords
        self.totalObservedApplicationDuration = totalObservedApplicationDuration
    }
}

// MARK: - Behavioral Query

/// Defines filtering criteria for evidence retrieval.
///
/// Query structures provide future systems with a stable interface
/// without exposing storage implementation details.
public struct BehavioralQuery: Codable, Hashable, Sendable {
    public var dateRange: ClosedRange<Date>?
    public var bundleIdentifier: String?
    public var category: BehavioralCategory?
    public var eventType: BehavioralEventType?
    public var deviceState: DeviceStateType?

    public init(
        dateRange: ClosedRange<Date>? = nil,
        bundleIdentifier: String? = nil,
        category: BehavioralCategory? = nil,
        eventType: BehavioralEventType? = nil,
        deviceState: DeviceStateType? = nil
    ) {
        self.dateRange = dateRange
        self.bundleIdentifier = bundleIdentifier
        self.category = category
        self.eventType = eventType
        self.deviceState = deviceState
    }
}

// MARK: - Behavioral Categorizer

/// Maps known applications into broad behavioral categories.
///
/// Categorization exists solely to organize evidence.
/// Unknown applications remain fully supported.
public enum BehavioralCategorizer {
    private static let categoryMappings: [String: BehavioralCategory] = [
        "com.apple.Safari": .browsing,
        "com.google.Chrome": .browsing,
        "org.mozilla.firefox": .browsing,

        "com.apple.mail": .communication,
        "com.tinyspeck.slackmacgap": .communication,
        "us.zoom.xos": .communication,
        "com.microsoft.teams": .communication,

        "com.apple.dt.Xcode": .development,
        "com.microsoft.VSCode": .development,
        "com.jetbrains.intellij": .development,

        "com.apple.Pages": .productivity,
        "com.microsoft.Word": .productivity,
        "com.apple.Keynote": .productivity,

        "com.apple.Terminal": .utility,
        "com.apple.ActivityMonitor": .utility,

        "com.valvesoftware.steam": .gaming,

        "com.apple.Music": .entertainment,
        "com.spotify.client": .entertainment,

        "com.adobe.Photoshop": .creativeWork,
        "com.figma.Desktop": .creativeWork,

        "com.apple.SystemSettings": .system,
    ]

    public static func category(
        for bundleIdentifier: String?,
        applicationName _: String
    ) -> BehavioralCategory {
        guard let bundleIdentifier else {
            return .unknown
        }

        return categoryMappings[bundleIdentifier] ?? .unknown
    }
}

// MARK: - Behavior Context Access Kit

/// Central behavioral evidence acquisition subsystem.
///
/// This framework continuously observes operating-system behavioral
/// activity and preserves normalized evidence records.
///
/// Responsibilities:
/// - Observe application lifecycle events
/// - Track foreground application sessions
/// - Record inactivity intervals
/// - Monitor device state transitions
/// - Preserve timestamped behavioral evidence
/// - Provide query access to evidence history
///
/// Explicitly excluded responsibilities:
/// - Analytics
/// - Recommendations
/// - Predictions
/// - Behavioral interpretation
/// - Trend analysis
/// - Significance scoring
///
/// The subsystem records what occurred.
/// It does not determine what those events mean.
@MainActor
public final class BehaviorContextAccessKit: ObservableObject {
    // MARK: Published Evidence

    @Published public private(set) var events: [BehavioralEvent] = []
    @Published public private(set) var applicationSessions: [ApplicationUsageSession] = []
    @Published public private(set) var inactivityRecords: [InactivityRecord] = []
    @Published public private(set) var deviceStateEvents: [DeviceStateEvent] = []

    // MARK: Internal State

    private var cancellables = Set<AnyCancellable>()

    /// AUDIT §4.1: tokens for the two block-based DistributedNotificationCenter
    /// registrations in observeScreenLockEvents(). removeObserver(self) is a
    /// silent no-op for block-based registrations; only captured tokens work.
    private var screenLockObserver: NSObjectProtocol?
    private var screenUnlockObserver: NSObjectProtocol?

    private var currentForegroundApplication: ApplicationDescriptor?
    private var currentSession: ApplicationUsageSession?
    private var currentInactivityRecord: InactivityRecord?

    private var inactivityTimer: Timer?
    private let inactivityThreshold: TimeInterval = 300

    private var systemPowerObserver: NSObjectProtocol?

    /// MEMORY-FIX (Phase 4, BEHAVIOR_MEMORY_FIX_PLAN.txt Section 4 Step 2):
    /// Caps applied to events/applicationSessions/inactivityRecords/deviceStateEvents
    /// below. Uses BehavioralRetentionPolicy's existing defaults (250k/100k/50k/50k) —
    /// unchanged from what was already coded, just actually enforced now.
    private let retentionPolicy = BehavioralRetentionPolicy()

    // MARK: Persistence

    /// G6: behavioral evidence survives relaunch. Kept local, capped by the
    /// existing retention policy. This is deliberately a small JSON archive;
    /// the unified SQLite behavior tables can replace it later without changing
    /// the observation API.
    private let archiveURL: URL?
    private let database: LibraryDatabase?

    struct BehaviorEvidenceArchive: Codable {
        var version: Int = 1
        var savedAt: Date = Date()
        var events: [BehavioralEvent]
        var applicationSessions: [ApplicationUsageSession]
        var inactivityRecords: [InactivityRecord]
        var deviceStateEvents: [DeviceStateEvent]
    }

    // MARK: Initialization

    init(archiveURL: URL? = nil, database: LibraryDatabase? = nil) {
        self.archiveURL = archiveURL ?? Self.defaultArchiveURL()
        self.database = database
        loadEvidence()
    }

    private static func defaultArchiveURL() -> URL? {
        let dir: URL
        if let testRoot = RuntimeEnvironment.isolatedStoreDirectory {
            dir = testRoot
        } else {
            guard let root = AppIdentity.dataRootURL() else { return nil }
            dir = root
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("behavior-evidence.json")
    }

    private var hasEvidence: Bool {
        !events.isEmpty || !applicationSessions.isEmpty ||
            !inactivityRecords.isEmpty || !deviceStateEvents.isEmpty
    }

    private func apply(_ archive: BehaviorEvidenceArchive) {
        events = archive.events
        applicationSessions = archive.applicationSessions
        inactivityRecords = archive.inactivityRecords
        deviceStateEvents = archive.deviceStateEvents
        BehavioralRetentionController.apply(policy: retentionPolicy, to: &events)
        BehavioralRetentionController.apply(policy: retentionPolicy, to: &applicationSessions)
        BehavioralRetentionController.apply(policy: retentionPolicy, to: &inactivityRecords)
        BehavioralRetentionController.apply(policy: retentionPolicy, to: &deviceStateEvents)
    }

    /// G6/E8: SQLite is the live store; the JSON archive is the import seed and
    /// a compatibility mirror for older builds and Sentinel's file probe.
    private func loadEvidence() {
        if let database {
            do {
                let stored = try database.loadBehaviorEvidence()
                if stored.events.isEmpty, stored.applicationSessions.isEmpty,
                   stored.inactivityRecords.isEmpty, stored.deviceStateEvents.isEmpty {
                    loadArchive()
                    if hasEvidence { saveArchive() }
                } else {
                    apply(BehaviorEvidenceArchive(
                        events: stored.events,
                        applicationSessions: stored.applicationSessions,
                        inactivityRecords: stored.inactivityRecords,
                        deviceStateEvents: stored.deviceStateEvents))
                }
                return
            } catch {
                print("[BehaviorContextAccessKit] SQLite evidence load failed: \(error)")
            }
        }
        loadArchive()
    }

    private func loadArchive() {
        guard let archiveURL,
              let data = try? Data(contentsOf: archiveURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let archive = try? decoder.decode(
            BehaviorEvidenceArchive.self, from: data) else { return }
        apply(archive)
    }

    /// Flush evidence. Called on monitor stop (app background/quit).
    public func saveArchive() {
        let archive = BehaviorEvidenceArchive(
            events: events,
            applicationSessions: applicationSessions,
            inactivityRecords: inactivityRecords,
            deviceStateEvents: deviceStateEvents)

        if let database {
            do {
                try database.replaceBehaviorEvidence(
                    events: events,
                    applicationSessions: applicationSessions,
                    inactivityRecords: inactivityRecords,
                    deviceStateEvents: deviceStateEvents)
            } catch {
                print("[BehaviorContextAccessKit] SQLite evidence save failed: \(error)")
            }
        }

        // Keep the JSON mirror current. It is no longer read when SQLite has
        // rows; it remains the fallback for older builds and Sentinel.
        guard let archiveURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            try encoder.encode(archive).write(to: archiveURL, options: .atomic)
        } catch {
            print("[BehaviorContextAccessKit] evidence archive save failed: \(error)")
        }
    }

    /// CONTRACT (bug-fix session): callers MUST call stopMonitoring() before
    /// releasing this object. Both real paths do — AsterismaApp on
    /// scenePhase .background, and ObserverLifecycleTests explicitly.
    ///
    /// This deinit deliberately does NOTHING: an earlier version spawned
    /// `Task { @MainActor in stopMonitoring() }`, which implicitly captured
    /// `self` mid-deallocation. Retiring an object from inside its own deinit
    /// is undefined behavior — the task hopped to main and called methods on
    /// freed memory, aborting the process (swift_deallocClassInstance /
    /// EXC_BREAKPOINT-family SIGABRT). Production masked it because this
    /// object lives for the app's lifetime; tests were the first to release.
    deinit {}

    // MARK: Monitoring Lifecycle

    /// AUDIT F-07 (Phase 1): re-entry gate. The app calls startMonitoring() from
    /// BOTH the root .task pipeline binding AND the initial scenePhase → .active
    /// change; without this guard the four Combine registration paths appended a
    /// second sink set at launch (only the screen-lock pair had its own §4.1
    /// idempotence guard), duplicating every application activate/deactivate/
    /// sleep/wake evidence record for process lifetime.
    private var isMonitoring = false

    /// Starts all behavioral observation systems.
    ///
    /// Redundant calls without an intervening stop are no-ops.
    public func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        observeApplicationLifecycle()
        observeWorkspaceActivity()
        observeScreenLockEvents()
        observeSystemPowerEvents()
        startInactivityMonitoring()
    }

    /// Stops all active observers and monitoring systems.
    public func stopMonitoring() {
        isMonitoring = false
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)

        // AUDIT §4.1: block-based registrations require token-based removal;
        // removeObserver(self) above never touches them.
        if let lockToken = screenLockObserver {
            DistributedNotificationCenter.default().removeObserver(lockToken)
            screenLockObserver = nil
        }
        if let unlockToken = screenUnlockObserver {
            DistributedNotificationCenter.default().removeObserver(unlockToken)
            screenUnlockObserver = nil
        }

        inactivityTimer?.invalidate()
        inactivityTimer = nil

        cancellables.removeAll()

        if let systemPowerObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(systemPowerObserver)
        }

        saveArchive()
    }

    // MARK: Application Monitoring

    /// Observes application launch and termination events.
    ///
    /// These are preserved as immutable historical evidence.
    private func observeApplicationLifecycle() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        workspaceCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .sink { [weak self] notification in
                self?.handleApplicationNotification(
                    notification,
                    eventType: .applicationLaunched
                )
            }
            .store(in: &cancellables)

        workspaceCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .sink { [weak self] notification in
                self?.handleApplicationNotification(
                    notification,
                    eventType: .applicationTerminated
                )
            }
            .store(in: &cancellables)
    }

    /// Observes foreground application activation transitions.
    ///
    /// These transitions are used to reconstruct application usage sessions.
    private func observeWorkspaceActivity() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        workspaceCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] notification in
                self?.handleApplicationActivation(notification)
            }
            .store(in: &cancellables)

        workspaceCenter.publisher(for: NSWorkspace.didDeactivateApplicationNotification)
            .sink { [weak self] notification in
                self?.handleApplicationNotification(
                    notification,
                    eventType: .applicationDeactivated
                )
            }
            .store(in: &cancellables)
    }

    // MARK: Device State Monitoring

    /// Observes lock and unlock transitions using distributed notifications.
    ///
    /// These notifications are best-effort and may vary across macOS versions.
    private func observeScreenLockEvents() {
        // AUDIT §4.1: idempotent — startMonitoring() runs on every .active
        // transition, so re-entry here must never stack duplicate observers.
        guard screenLockObserver == nil, screenUnlockObserver == nil else { return }

        let center = DistributedNotificationCenter.default()

        screenLockObserver = center.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.recordDeviceState(.locked)
            self?.recordEvent(
                type: .screenLocked,
                source: "DistributedNotificationCenter"
            )
        }

        screenUnlockObserver = center.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.recordDeviceState(.unlocked)
            self?.recordEvent(
                type: .screenUnlocked,
                source: "DistributedNotificationCenter"
            )
        }
    }

    /// Observes system sleep and wake transitions.
    private func observeSystemPowerEvents() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        workspaceCenter.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in
                self?.recordDeviceState(.sleeping)
                self?.recordEvent(
                    type: .deviceSleep,
                    source: "NSWorkspace"
                )
            }
            .store(in: &cancellables)

        workspaceCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in
                self?.recordDeviceState(.awake)
                self?.recordEvent(
                    type: .deviceWake,
                    source: "NSWorkspace"
                )
            }
            .store(in: &cancellables)
    }

    // MARK: Inactivity Monitoring

    /// Starts periodic inactivity evaluation.
    ///
    /// Inactivity evidence is preserved independently of application activity.
    private func startInactivityMonitoring() {
        inactivityTimer?.invalidate()

        inactivityTimer = Timer.scheduledTimer(
            withTimeInterval: 30,
            repeats: true
        ) { [weak self] _ in
            self?.evaluateInactivity()
        }
    }

    /// Evaluates current user idle duration using supported macOS APIs.
    private func evaluateInactivity() {
        let idleTime = systemIdleTime()

        if idleTime >= inactivityThreshold {
            if currentInactivityRecord == nil {
                let record = InactivityRecord(
                    startTime: Date().addingTimeInterval(-idleTime)
                )

                currentInactivityRecord = record
                inactivityRecords.append(record)

                // MEMORY-FIX (Phase 4, Step 5): safe to trim here — the record
                // just appended is always the most recent, so it's never the
                // one a count-based .suffix() trim would drop, and the later
                // close-out below looks it up by id, not by stored index.
                BehavioralRetentionController.apply(policy: retentionPolicy, to: &inactivityRecords)

                recordEvent(
                    type: .inactivityStarted,
                    source: "IOKit",
                    metadata: [
                        "idleDuration": "\(idleTime)",
                    ]
                )

                recordDeviceState(.inactive)
            }

        } else {
            if var record = currentInactivityRecord {
                record.endTime = Date()

                if let index = inactivityRecords.firstIndex(where: { $0.id == record.id }) {
                    inactivityRecords[index] = record
                }

                currentInactivityRecord = nil

                recordEvent(
                    type: .inactivityEnded,
                    source: "IOKit"
                )

                recordDeviceState(.active)
            }
        }
    }

    /// Retrieves current system idle duration.
    ///
    /// Returns:
    /// Estimated idle duration in seconds.
    private func systemIdleTime() -> TimeInterval {
        guard let dict = IOServiceMatching("IOHIDSystem") else {
            return 0
        }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, dict)
        guard service != 0 else {
            return 0
        }

        defer {
            IOObjectRelease(service)
        }

        var propertiesRef: Unmanaged<CFMutableDictionary>?
        let kernResult = IORegistryEntryCreateCFProperties(
            service,
            &propertiesRef,
            kCFAllocatorDefault,
            0
        )

        guard
            kernResult == KERN_SUCCESS,
            let properties = propertiesRef?.takeRetainedValue() as? [String: Any],
            let idleTime = properties["HIDIdleTime"] as? UInt64
        else {
            return 0
        }

        return TimeInterval(idleTime) / 1_000_000_000
    }

    // MARK: Event Handling

    private func handleApplicationNotification(
        _ notification: Notification,
        eventType: BehavioralEventType
    ) {
        guard
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication
        else {
            return
        }

        let descriptor = applicationDescriptor(from: app)

        recordEvent(
            type: eventType,
            application: descriptor,
            source: "NSWorkspace"
        )
    }

    private func handleApplicationActivation(_ notification: Notification) {
        guard
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
            as? NSRunningApplication
        else {
            return
        }

        let descriptor = applicationDescriptor(from: app)

        endCurrentSessionIfNeeded()

        currentForegroundApplication = descriptor

        let session = ApplicationUsageSession(
            application: descriptor,
            startTime: Date()
        )

        currentSession = session
        applicationSessions.append(session)

        // MEMORY-FIX (Phase 4, Step 4): safe to trim here — the just-appended
        // session is always the most recent, and both endCurrentSessionIfNeeded()
        // above and the close-out logic elsewhere look sessions up by id, not
        // by stored index, so a count-based trim can't invalidate them.
        BehavioralRetentionController.apply(policy: retentionPolicy, to: &applicationSessions)

        recordEvent(
            type: .applicationActivated,
            application: descriptor,
            source: "NSWorkspace"
        )

        recordEvent(
            type: .sessionStarted,
            application: descriptor,
            source: "BehaviorContextAccessKit"
        )
    }

    private func endCurrentSessionIfNeeded() {
        guard var session = currentSession else {
            return
        }

        session.endTime = Date()

        if let index = applicationSessions.firstIndex(where: { $0.id == session.id }) {
            applicationSessions[index] = session
        }

        recordEvent(
            type: .sessionEnded,
            application: session.application,
            source: "BehaviorContextAccessKit",
            metadata: [
                "duration": "\(session.duration ?? 0)",
            ]
        )

        currentSession = nil
    }

    // MARK: Event Recording

    /// Records a normalized behavioral event.
    ///
    /// Original source information is preserved.
    private func recordEvent(
        type: BehavioralEventType,
        application: ApplicationDescriptor? = nil,
        source: String,
        metadata: [String: String] = [:]
    ) {
        let event = BehavioralEvent(
            eventType: type,
            application: application,
            metadata: metadata,
            source: source
        )

        events.append(event)

        // MEMORY-FIX (Phase 4, Step 3): recordEvent() is the single choke point
        // every event-producing code path in this class funnels through, so
        // capping here covers all of them.
        BehavioralRetentionController.apply(policy: retentionPolicy, to: &events)
    }

    /// Records a device state transition.
    private func recordDeviceState(
        _ state: DeviceStateType,
        metadata: [String: String] = [:]
    ) {
        let event = DeviceStateEvent(
            state: state,
            metadata: metadata
        )

        deviceStateEvents.append(event)

        // MEMORY-FIX (Phase 4, Step 6):
        BehavioralRetentionController.apply(policy: retentionPolicy, to: &deviceStateEvents)

        recordEvent(
            type: .deviceStateTransition,
            source: "BehaviorContextAccessKit",
            metadata: [
                "state": state.rawValue,
            ]
        )
    }

    // MARK: Application Descriptor Construction

    /// Normalizes NSRunningApplication into stable evidence structures.
    private func applicationDescriptor(
        from application: NSRunningApplication
    ) -> ApplicationDescriptor {
        let name = application.localizedName ?? "Unknown"

        let category = BehavioralCategorizer.category(
            for: application.bundleIdentifier,
            applicationName: name
        )

        return ApplicationDescriptor(
            applicationName: name,
            bundleIdentifier: application.bundleIdentifier,
            processIdentifier: application.processIdentifier,
            category: category,
            executableURL: application.executableURL
        )
    }

    // MARK: Query Interface

    /// Retrieves events matching query criteria.
    public func queryEvents(
        using query: BehavioralQuery
    ) -> [BehavioralEvent] {
        events.filter { event in
            if let range = query.dateRange,
               !range.contains(event.timestamp)
            {
                return false
            }

            if let bundleIdentifier = query.bundleIdentifier,
               event.application?.bundleIdentifier != bundleIdentifier
            {
                return false
            }

            if let category = query.category,
               event.application?.category != category
            {
                return false
            }

            if let eventType = query.eventType,
               event.eventType != eventType
            {
                return false
            }

            return true
        }
    }

    /// Retrieves sessions within a date range.
    public func sessions(
        in range: ClosedRange<Date>? = nil
    ) -> [ApplicationUsageSession] {
        applicationSessions.filter { session in
            guard let range else {
                return true
            }

            return range.contains(session.startTime)
        }
    }

    /// Retrieves inactivity records within a date range.
    public func inactivity(
        in range: ClosedRange<Date>? = nil
    ) -> [InactivityRecord] {
        inactivityRecords.filter { record in
            guard let range else {
                return true
            }

            return range.contains(record.startTime)
        }
    }

    /// Retrieves device state events matching a state.
    public func deviceEvents(
        state: DeviceStateType? = nil
    ) -> [DeviceStateEvent] {
        deviceStateEvents.filter { event in
            guard let state else {
                return true
            }

            return event.state == state
        }
    }

    // MARK: Statistics

    /// Produces descriptive summaries over collected evidence.
    ///
    /// No interpretation or ranking is performed.
    public func statistics() -> BehavioralStatistics {
        let totalDuration = applicationSessions.reduce(0) { partialResult, session in
            partialResult + (session.duration ?? 0)
        }

        return BehavioralStatistics(
            totalEvents: events.count,
            totalSessions: applicationSessions.count,
            totalInactivityRecords: inactivityRecords.count,
            totalObservedApplicationDuration: totalDuration
        )
    }

    // MARK: Snapshot

    /// Produces a point-in-time behavioral snapshot.
    public func currentSnapshot() -> BehavioralSnapshot {
        let latestState =
            deviceStateEvents.last?.state ?? .active

        return BehavioralSnapshot(
            activeApplication: currentForegroundApplication,
            deviceState: latestState
        )
    }
}

// MARK: - Utility Extension

private extension Equatable {
    func takeIf(_ predicate: (Self) -> Bool) -> Self? {
        predicate(self) ? self : nil
    }
}

// MARK: - Persistence Architecture

/// Defines persistence behavior for behavioral evidence.
///
/// The subsystem intentionally separates evidence acquisition
/// from persistence implementation details.
///
/// DataStore.swift or future archival systems can conform
/// to this protocol without coupling storage concerns into
/// monitoring logic.
public protocol BehavioralEvidencePersistence: Sendable {
    func persist(events: [BehavioralEvent]) async throws

    func persist(
        sessions: [ApplicationUsageSession]
    ) async throws

    func persist(
        inactivityRecords: [InactivityRecord]
    ) async throws

    func persist(
        deviceStateEvents: [DeviceStateEvent]
    ) async throws

    func restoreEvents() async throws -> [BehavioralEvent]

    func restoreSessions() async throws -> [ApplicationUsageSession]

    func restoreInactivityRecords() async throws -> [InactivityRecord]

    func restoreDeviceStateEvents() async throws -> [DeviceStateEvent]
}

// MARK: - Behavioral Retention Policy

/// Defines local evidence retention behavior.
///
/// Retention policies are operational controls only.
/// They do not imply behavioral importance.
public struct BehavioralRetentionPolicy:
    Codable,
    Hashable,
    Sendable
{
    public let maximumEventCount: Int
    public let maximumSessionCount: Int
    public let maximumInactivityRecords: Int
    public let maximumDeviceStateEvents: Int
    public let maximumAge: TimeInterval?

    public init(
        maximumEventCount: Int = 250_000,
        maximumSessionCount: Int = 100_000,
        maximumInactivityRecords: Int = 50000,
        maximumDeviceStateEvents: Int = 50000,
        maximumAge: TimeInterval? = nil
    ) {
        self.maximumEventCount = maximumEventCount
        self.maximumSessionCount = maximumSessionCount
        self.maximumInactivityRecords = maximumInactivityRecords
        self.maximumDeviceStateEvents = maximumDeviceStateEvents
        self.maximumAge = maximumAge
    }
}

// MARK: - Timeline Integrity Report

/// Describes timeline validation results.
///
/// Validation exists to preserve historical consistency
/// and chronological correctness.
public struct BehavioralIntegrityReport:
    Codable,
    Hashable,
    Sendable
{
    public let duplicateEventCount: Int
    public let unorderedEventCount: Int
    public let invalidSessionCount: Int
    public let overlappingSessionCount: Int
    public let generatedAt: Date

    public var isValid: Bool {
        duplicateEventCount == 0 &&
            unorderedEventCount == 0 &&
            invalidSessionCount == 0 &&
            overlappingSessionCount == 0
    }

    public init(
        duplicateEventCount: Int,
        unorderedEventCount: Int,
        invalidSessionCount: Int,
        overlappingSessionCount: Int,
        generatedAt: Date = Date()
    ) {
        self.duplicateEventCount = duplicateEventCount
        self.unorderedEventCount = unorderedEventCount
        self.invalidSessionCount = invalidSessionCount
        self.overlappingSessionCount = overlappingSessionCount
        self.generatedAt = generatedAt
    }
}

// MARK: - Evidence Source

/// Describes the origin of acquired behavioral evidence.
public struct BehavioralEvidenceSource:
    Codable,
    Identifiable,
    Hashable,
    Sendable
{
    public let id: UUID
    public let sourceName: String
    public let sourceVersion: String
    public let acquisitionMethod: String

    public init(
        id: UUID = UUID(),
        sourceName: String,
        sourceVersion: String,
        acquisitionMethod: String
    ) {
        self.id = id
        self.sourceName = sourceName
        self.sourceVersion = sourceVersion
        self.acquisitionMethod = acquisitionMethod
    }
}

// MARK: - Event Batch

/// Represents an append-only event ingestion batch.
///
/// Batching improves persistence efficiency while preserving
/// original event ordering.
public struct BehavioralEventBatch:
    Codable,
    Identifiable,
    Hashable,
    Sendable
{
    public let id: UUID
    public let createdAt: Date
    public let events: [BehavioralEvent]

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        events: [BehavioralEvent]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.events = events
    }
}

// MARK: - Historical Replay

/// Provides deterministic historical evidence replay.
///
/// Replay functionality allows future engines to reconstruct
/// behavioral chronology without mutating original evidence.
public struct BehavioralReplayFrame:
    Codable,
    Identifiable,
    Hashable,
    Sendable
{
    public let id: UUID
    public let timestamp: Date
    public let event: BehavioralEvent

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        event: BehavioralEvent
    ) {
        self.id = id
        self.timestamp = timestamp
        self.event = event
    }
}

// MARK: - Extended Query Support

/// Defines temporal sorting behavior for evidence retrieval.
public enum BehavioralSortOrder:
    String,
    Codable,
    Hashable,
    Sendable
{
    case ascending
    case descending
}

/// Extended query descriptor for scalable evidence retrieval.
public struct BehavioralAdvancedQuery:
    Codable,
    Hashable,
    Sendable
{
    public var dateRange: ClosedRange<Date>?
    public var categories: Set<BehavioralCategory>
    public var eventTypes: Set<BehavioralEventType>
    public var bundleIdentifiers: Set<String>
    public var limit: Int?
    public var offset: Int
    public var sortOrder: BehavioralSortOrder

    public init(
        dateRange: ClosedRange<Date>? = nil,
        categories: Set<BehavioralCategory> = [],
        eventTypes: Set<BehavioralEventType> = [],
        bundleIdentifiers: Set<String> = [],
        limit: Int? = nil,
        offset: Int = 0,
        sortOrder: BehavioralSortOrder = .ascending
    ) {
        self.dateRange = dateRange
        self.categories = categories
        self.eventTypes = eventTypes
        self.bundleIdentifiers = bundleIdentifiers
        self.limit = limit
        self.offset = offset
        self.sortOrder = sortOrder
    }
}

// MARK: - Session Reconstruction Engine

/// Responsible for reconstructing coherent usage sessions
/// from raw application activation evidence.
///
/// This engine remains intentionally non-analytical.
/// It performs chronological normalization only.
public enum ApplicationSessionReconstructor {
    public static func reconstruct(
        from events: [BehavioralEvent]
    ) -> [ApplicationUsageSession] {
        let sortedEvents = events.sorted {
            $0.timestamp < $1.timestamp
        }

        var sessions: [ApplicationUsageSession] = []

        var activeSession:
            (
                application: ApplicationDescriptor,
                start: Date
            )?

        for event in sortedEvents {
            switch event.eventType {
            case .applicationActivated:
                if let activeSession {
                    let session = ApplicationUsageSession(
                        application: activeSession.application,
                        startTime: activeSession.start,
                        endTime: event.timestamp
                    )

                    sessions.append(session)
                }

                if let application = event.application {
                    activeSession = (
                        application: application,
                        start: event.timestamp
                    )
                }

            case .applicationDeactivated,
                 .applicationTerminated:
                if let ending = activeSession,
                   let application = event.application,
                   ending.application.bundleIdentifier ==
                   application.bundleIdentifier
                {
                    let session = ApplicationUsageSession(
                        application: ending.application,
                        startTime: ending.start,
                        endTime: event.timestamp
                    )

                    sessions.append(session)

                    clear(&activeSession)
                }

            default:
                break
            }
        }

        return sessions
    }

    private static func clear<T>(_ value: inout T?) {
        value = nil
    }
}

// MARK: - Behavioral Timeline Builder

/// Constructs normalized timeline intervals from raw evidence.
///
/// Timeline normalization helps future systems consume
/// chronologically coherent evidence streams.
public enum BehavioralTimelineBuilder {
    public static func buildSegments(
        from sessions: [ApplicationUsageSession]
    ) -> [BehavioralTimelineSegment] {
        sessions.compactMap { session in
            guard let endTime = session.endTime else {
                return nil
            }

            return BehavioralTimelineSegment(
                startTime: session.startTime,
                endTime: endTime,
                eventType: .sessionStarted,
                application: session.application
            )
        }
    }
}

// MARK: - Behavioral History Index

/// Provides lightweight in-memory indexing for efficient retrieval.
///
/// This index intentionally avoids interpretation logic.
public final class BehavioralHistoryIndex:
    @unchecked Sendable
{
    private var bundleIndex:
        [String: [UUID]] = [:]

    private var categoryIndex:
        [BehavioralCategory: [UUID]] = [:]

    private var eventTypeIndex:
        [BehavioralEventType: [UUID]] = [:]

    public init() {}

    public func index(event: BehavioralEvent) {
        if let bundleIdentifier =
            event.application?.bundleIdentifier
        {
            bundleIndex[bundleIdentifier, default: []]
                .append(event.id)
        }

        if let category =
            event.application?.category
        {
            categoryIndex[category, default: []]
                .append(event.id)
        }

        eventTypeIndex[event.eventType, default: []]
            .append(event.id)
    }

    public func identifiers(
        for bundleIdentifier: String
    ) -> [UUID] {
        bundleIndex[bundleIdentifier] ?? []
    }

    public func identifiers(
        for category: BehavioralCategory
    ) -> [UUID] {
        categoryIndex[category] ?? []
    }

    public func identifiers(
        for eventType: BehavioralEventType
    ) -> [UUID] {
        eventTypeIndex[eventType] ?? []
    }

    public func clear() {
        bundleIndex.removeAll()
        categoryIndex.removeAll()
        eventTypeIndex.removeAll()
    }
}

// MARK: - Idle Activity Debouncer

/// Prevents rapid oscillation between active and inactive states.
///
/// Debouncing exists purely for chronological stability.
public final class InactivityDebouncer {
    private var lastTransitionDate: Date?
    private let minimumTransitionInterval: TimeInterval

    public init(
        minimumTransitionInterval: TimeInterval = 15
    ) {
        self.minimumTransitionInterval =
            minimumTransitionInterval
    }

    public func shouldAcceptTransition() -> Bool {
        let now = Date()

        defer {
            lastTransitionDate = now
        }

        guard let lastTransitionDate else {
            return true
        }

        return now.timeIntervalSince(lastTransitionDate)
            >= minimumTransitionInterval
    }
}

// MARK: - Behavioral Event Store Actor

/// Actor-isolated append-only evidence storage.
///
/// This actor protects chronological consistency while allowing
/// concurrent ingestion.
public actor BehavioralEventStore {
    private(set) var events: [BehavioralEvent] = []

    private(set) var sessions:
        [ApplicationUsageSession] = []

    private(set) var inactivityRecords:
        [InactivityRecord] = []

    private(set) var deviceStateEvents:
        [DeviceStateEvent] = []

    public init() {}

    public func append(
        _ event: BehavioralEvent
    ) {
        events.append(event)
    }

    public func append(
        _ session: ApplicationUsageSession
    ) {
        sessions.append(session)
    }

    public func append(
        _ record: InactivityRecord
    ) {
        inactivityRecords.append(record)
    }

    public func append(
        _ event: DeviceStateEvent
    ) {
        deviceStateEvents.append(event)
    }

    public func allEvents() -> [BehavioralEvent] {
        events
    }

    public func allSessions() -> [ApplicationUsageSession] {
        sessions
    }

    public func allInactivityRecords()
        -> [InactivityRecord]
    {
        inactivityRecords
    }

    public func allDeviceStateEvents()
        -> [DeviceStateEvent]
    {
        deviceStateEvents
    }

    public func clear() {
        events.removeAll()
        sessions.removeAll()
        inactivityRecords.removeAll()
        deviceStateEvents.removeAll()
    }
}

// MARK: - Timeline Integrity Validator

/// Validates historical consistency across evidence streams.
///
/// Validation protects chronology correctness only.
public enum BehavioralTimelineValidator {
    public static func validate(
        events: [BehavioralEvent],
        sessions: [ApplicationUsageSession]
    ) -> BehavioralIntegrityReport {
        let sortedEvents =
            events.sorted {
                $0.timestamp < $1.timestamp
            }

        var unorderedEvents = 0

        for index in 1 ..< sortedEvents.count {
            let previous =
                sortedEvents[index - 1]

            let current =
                sortedEvents[index]

            if current.timestamp <
                previous.timestamp
            {
                unorderedEvents += 1
            }
        }

        let duplicateCount =
            Set(events.map(\.id)).count != events.count
                ? events.count - Set(events.map(\.id)).count
                : 0

        let invalidSessions =
            sessions.filter {
                guard let endTime = $0.endTime else {
                    return false
                }

                return endTime < $0.startTime
            }.count

        let overlappingSessions =
            overlappingSessionCount(sessions)

        return BehavioralIntegrityReport(
            duplicateEventCount: duplicateCount,
            unorderedEventCount: unorderedEvents,
            invalidSessionCount: invalidSessions,
            overlappingSessionCount: overlappingSessions
        )
    }

    private static func overlappingSessionCount(
        _ sessions: [ApplicationUsageSession]
    ) -> Int {
        let sorted =
            sessions.sorted {
                $0.startTime < $1.startTime
            }

        var count = 0

        for index in 1 ..< sorted.count {
            let previous = sorted[index - 1]
            let current = sorted[index]

            guard
                let previousEnd = previous.endTime
            else {
                continue
            }

            if current.startTime < previousEnd {
                count += 1
            }
        }

        return count
    }
}

// MARK: - Historical Export

/// Export container for archival or replay workflows.
///
/// The export remains fully neutral and descriptive.
public struct BehavioralArchive:
    Codable,
    Hashable,
    Sendable
{
    public let exportedAt: Date
    public let events: [BehavioralEvent]
    public let sessions: [ApplicationUsageSession]
    public let inactivityRecords: [InactivityRecord]
    public let deviceStateEvents: [DeviceStateEvent]

    public init(
        exportedAt: Date = Date(),
        events: [BehavioralEvent],
        sessions: [ApplicationUsageSession],
        inactivityRecords: [InactivityRecord],
        deviceStateEvents: [DeviceStateEvent]
    ) {
        self.exportedAt = exportedAt
        self.events = events
        self.sessions = sessions
        self.inactivityRecords = inactivityRecords
        self.deviceStateEvents = deviceStateEvents
    }
}

// MARK: - Storage Partition

/// Represents a bounded local evidence partition.
///
/// Partitioning improves long-term memory behavior while
/// preserving chronological integrity.
public struct BehavioralStoragePartition:
    Codable,
    Identifiable,
    Hashable,
    Sendable
{
    public let id: UUID
    public let createdAt: Date
    public let observationWindow:
        BehavioralObservationWindow

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        observationWindow: BehavioralObservationWindow
    ) {
        self.id = id
        self.createdAt = createdAt
        self.observationWindow = observationWindow
    }
}

// MARK: - Advanced Behavioral Categorization

/// Provides runtime-extensible application categorization.
///
/// Categorization remains organizational only and intentionally
/// avoids behavioral interpretation.
public final class BehavioralCategoryRegistry:
    ObservableObject,
    @unchecked Sendable
{
    @Published
    public private(set) var mappings:
        [String: BehavioralCategory]

    public init(
        mappings: [String: BehavioralCategory] = [:]
    ) {
        self.mappings = mappings
    }

    public func register(
        bundleIdentifier: String,
        category: BehavioralCategory
    ) {
        mappings[bundleIdentifier] = category
    }

    public func unregister(
        bundleIdentifier: String
    ) {
        mappings.removeValue(
            forKey: bundleIdentifier
        )
    }

    public func category(
        for bundleIdentifier: String?
    ) -> BehavioralCategory {
        guard let bundleIdentifier else {
            return .unknown
        }

        return mappings[bundleIdentifier]
            ?? .unknown
    }

    public func allMappings()
        -> [String: BehavioralCategory]
    {
        mappings
    }
}

// MARK: - Behavioral Evidence Buffer

/// Buffered append-only evidence ingestion queue.
///
/// Buffering reduces persistence pressure while preserving
/// exact acquisition order.
public actor BehavioralEvidenceBuffer {
    private var eventBuffer:
        [BehavioralEvent] = []

    private var sessionBuffer:
        [ApplicationUsageSession] = []

    private var inactivityBuffer:
        [InactivityRecord] = []

    private var deviceStateBuffer:
        [DeviceStateEvent] = []

    public init() {}

    public func append(
        _ event: BehavioralEvent
    ) {
        eventBuffer.append(event)
    }

    public func append(
        _ session: ApplicationUsageSession
    ) {
        sessionBuffer.append(session)
    }

    public func append(
        _ record: InactivityRecord
    ) {
        inactivityBuffer.append(record)
    }

    public func append(
        _ event: DeviceStateEvent
    ) {
        deviceStateBuffer.append(event)
    }

    public func drainEvents()
        -> [BehavioralEvent]
    {
        defer {
            eventBuffer.removeAll()
        }

        return eventBuffer
    }

    public func drainSessions()
        -> [ApplicationUsageSession]
    {
        defer {
            sessionBuffer.removeAll()
        }

        return sessionBuffer
    }

    public func drainInactivityRecords()
        -> [InactivityRecord]
    {
        defer {
            inactivityBuffer.removeAll()
        }

        return inactivityBuffer
    }

    public func drainDeviceStateEvents()
        -> [DeviceStateEvent]
    {
        defer {
            deviceStateBuffer.removeAll()
        }

        return deviceStateBuffer
    }
}

// MARK: - Event Sequence Generator

/// Provides monotonic sequence identifiers for acquired evidence.
///
/// Sequence numbers help preserve deterministic chronology
/// during replay and persistence operations.
public actor BehavioralSequenceGenerator {
    private var currentValue: UInt64 = 0

    public init() {}

    public func next() -> UInt64 {
        currentValue += 1
        return currentValue
    }
}

// MARK: - Sequenced Event

/// Represents an event with deterministic ingestion ordering.
public struct SequencedBehavioralEvent:
    Codable,
    Identifiable,
    Hashable,
    Sendable
{
    public let id: UUID
    public let sequenceNumber: UInt64
    public let event: BehavioralEvent

    public init(
        id: UUID = UUID(),
        sequenceNumber: UInt64,
        event: BehavioralEvent
    ) {
        self.id = id
        self.sequenceNumber = sequenceNumber
        self.event = event
    }
}

// MARK: - Display State Tracking

/// Represents display power transitions.
///
/// Display transitions are preserved as neutral device evidence.
public enum DisplayStateType:
    String,
    Codable,
    Hashable,
    Sendable
{
    case displayAwake
    case displaySleeping
}

// MARK: - Display State Event

/// Timestamped display state evidence.
public struct DisplayStateEvent:
    Codable,
    Identifiable,
    Hashable,
    Sendable
{
    public let id: UUID
    public let timestamp: Date
    public let state: DisplayStateType

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        state: DisplayStateType
    ) {
        self.id = id
        self.timestamp = timestamp
        self.state = state
    }
}

// MARK: - Power Source Type

/// Represents current device power source state.
public enum DevicePowerSource:
    String,
    Codable,
    Hashable,
    Sendable
{
    case battery
    case charging
    case acPower
    case unknown
}

// MARK: - Power Source Event

/// Preserves power-source transition evidence.
public struct PowerSourceEvent:
    Codable,
    Identifiable,
    Hashable,
    Sendable
{
    public let id: UUID
    public let timestamp: Date
    public let source: DevicePowerSource

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        source: DevicePowerSource
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
    }
}

// MARK: - Thermal State Event

/// Preserves device thermal-state transitions.
///
/// These records are contextual environmental evidence only.
public struct ThermalStateEvent:
    Identifiable,
    Hashable,
    Sendable
{
    public let id: UUID
    public let timestamp: Date
    public let thermalState: ProcessInfo.ThermalState

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        thermalState: ProcessInfo.ThermalState
    ) {
        self.id = id
        self.timestamp = timestamp
        self.thermalState = thermalState
    }
}

extension ThermalStateEvent: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, timestamp, thermalState
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        let rawValue = try container.decode(Int.self, forKey: .thermalState)
        guard let state = ProcessInfo.ThermalState(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                forKey: .thermalState, in: container,
                debugDescription: "Invalid ProcessInfo.ThermalState rawValue: \(rawValue)")
        }
        thermalState = state
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(thermalState.rawValue, forKey: .thermalState)
    }
}

// MARK: - Connectivity State

/// Represents network reachability context.
///
/// Connectivity evidence remains purely descriptive.
public enum ConnectivityState:
    String,
    Codable,
    Hashable,
    Sendable
{
    case connected
    case disconnected
}

// MARK: - Connectivity Event

/// Timestamped network reachability evidence.
public struct ConnectivityEvent:
    Codable,
    Identifiable,
    Hashable,
    Sendable
{
    public let id: UUID
    public let timestamp: Date
    public let state: ConnectivityState

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        state: ConnectivityState
    ) {
        self.id = id
        self.timestamp = timestamp
        self.state = state
    }
}

// MARK: - Behavioral Event Journal

/// Append-only chronological evidence journal.
///
/// Journals preserve immutable acquisition history.
public actor BehavioralEventJournal {
    private var journal:
        [SequencedBehavioralEvent] = []

    public init() {}

    public func append(
        _ event: SequencedBehavioralEvent
    ) {
        journal.append(event)
    }

    public func all()
        -> [SequencedBehavioralEvent]
    {
        journal
    }

    public func events(
        in range: ClosedRange<Date>
    ) -> [SequencedBehavioralEvent] {
        journal.filter {
            range.contains(
                $0.event.timestamp
            )
        }
    }

    public func latest()
        -> SequencedBehavioralEvent?
    {
        journal.last
    }

    public func clear() {
        journal.removeAll()
    }
}

// MARK: - Session Conflict Resolver

/// Resolves overlapping or malformed session intervals.
///
/// Conflict resolution exists only to preserve
/// chronological consistency.
public enum SessionConflictResolver {
    public static func resolve(
        sessions: [ApplicationUsageSession]
    ) -> [ApplicationUsageSession] {
        let sorted =
            sessions.sorted {
                $0.startTime < $1.startTime
            }

        guard !sorted.isEmpty else {
            return []
        }

        var resolved:
            [ApplicationUsageSession] = []

        for session in sorted {
            guard let previous =
                resolved.last
            else {
                resolved.append(session)
                continue
            }

            guard let previousEnd =
                previous.endTime
            else {
                resolved.append(session)
                continue
            }

            if session.startTime < previousEnd {
                var adjusted =
                    session

                adjusted.endTime =
                    max(
                        previousEnd,
                        session.endTime ?? previousEnd
                    )

                resolved.append(adjusted)

            } else {
                resolved.append(session)
            }
        }

        return resolved
    }
}

// MARK: - Behavioral Snapshot Stream

/// Provides async behavioral snapshot streaming.
///
/// Streams expose evidence updates without exposing
/// internal storage implementation.
public actor BehavioralSnapshotStream {
    private var continuations:
        [UUID: AsyncStream<BehavioralSnapshot>.Continuation]
        = [:]

    public init() {}

    public func stream()
        -> AsyncStream<BehavioralSnapshot>
    {
        let id = UUID()

        return AsyncStream {

            continuation in
            continuations[id] =
                continuation

            continuation.onTermination = {
                [weak self] _ in
                Task {
                    await self?.removeContinuation(
                        id: id
                    )
                }
            }
        }
    }

    public func publish(
        _ snapshot: BehavioralSnapshot
    ) {
        for value in continuations.values {
            value.yield(snapshot)
        }
    }

    private func removeContinuation(
        id: UUID
    ) {
        continuations.removeValue(
            forKey: id
        )
    }
}

// MARK: - Evidence Replay Controller

/// Replays historical evidence chronologically.
///
/// Replay functionality remains deterministic and
/// non-analytical.
public actor BehavioralReplayController {
    public init() {}

    public func replay(
        events: [BehavioralEvent]
    ) -> AsyncStream<BehavioralReplayFrame> {
        let sorted =
            events.sorted {
                $0.timestamp < $1.timestamp
            }

        return AsyncStream {

            continuation in
            Task {

                for event in sorted {
                    let frame =
                        BehavioralReplayFrame(
                            timestamp: event.timestamp,
                            event: event
                        )

                    continuation.yield(frame)
                }

                continuation.finish()
            }
        }
    }
}

// MARK: - Evidence Window Cache

/// Provides bounded in-memory observation caching.
///
/// Window caches improve query efficiency without
/// changing evidence semantics.
public final class BehavioralWindowCache:
    @unchecked Sendable
{
    private let maximumWindows: Int

    private var windows:
        [BehavioralObservationWindow:
            [BehavioralEvent]] = [:]

    public init(
        maximumWindows: Int = 128
    ) {
        self.maximumWindows =
            maximumWindows
    }

    public func store(
        events: [BehavioralEvent],
        for window: BehavioralObservationWindow
    ) {
        if windows.count >= maximumWindows {
            if let oldest =
                windows.keys.sorted(
                    by: {
                        $0.startDate <
                            $1.startDate
                    }
                ).first
            {
                windows.removeValue(
                    forKey: oldest
                )
            }
        }

        windows[window] = events
    }

    public func events(
        for window: BehavioralObservationWindow
    ) -> [BehavioralEvent]? {
        windows[window]
    }

    public func clear() {
        windows.removeAll()
    }
}

// MARK: - Activity Resumption Event

/// Represents the transition from inactivity back
/// to observable user activity.
public struct ActivityResumptionEvent:
    Codable,
    Identifiable,
    Hashable,
    Sendable
{
    public let id: UUID
    public let resumedAt: Date
    public let precedingIdleDuration:
        TimeInterval

    public init(
        id: UUID = UUID(),
        resumedAt: Date = Date(),
        precedingIdleDuration: TimeInterval
    ) {
        self.id = id
        self.resumedAt = resumedAt
        self.precedingIdleDuration =
            precedingIdleDuration
    }
}

// MARK: - Workspace Context Event

/// Represents desktop/workspace transitions.
///
/// Workspace changes are preserved as neutral
/// environmental evidence.
public struct WorkspaceContextEvent:
    Codable,
    Identifiable,
    Hashable,
    Sendable
{
    public let id: UUID
    public let timestamp: Date
    public let workspaceIdentifier: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        workspaceIdentifier: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.workspaceIdentifier =
            workspaceIdentifier
    }
}

// MARK: - Behavioral Export Encoder

/// Encodes archival evidence payloads.
///
/// Export encoding preserves exact evidence fidelity.
public enum BehavioralExportEncoder {
    public static func encode(
        archive: BehavioralArchive
    ) throws -> Data {
        let encoder = JSONEncoder()

        encoder.dateEncodingStrategy =
            .iso8601

        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
        ]

        return try encoder.encode(
            archive
        )
    }

    public static func decode(
        data: Data
    ) throws -> BehavioralArchive {
        let decoder = JSONDecoder()

        decoder.dateDecodingStrategy =
            .iso8601

        return try decoder.decode(
            BehavioralArchive.self,
            from: data
        )
    }
}

// MARK: - Evidence Retention Controller

/// Applies local retention policies.
///
/// Retention operations exist only to control
/// local storage growth.
public enum BehavioralRetentionController {
    public static func apply(
        policy: BehavioralRetentionPolicy,
        to events: inout [BehavioralEvent]
    ) {
        if events.count >
            policy.maximumEventCount
        {
            events = Array(
                events.suffix(
                    policy.maximumEventCount
                )
            )
        }

        guard let maximumAge =
            policy.maximumAge
        else {
            return
        }

        let cutoff =
            Date().addingTimeInterval(
                -maximumAge
            )

        events.removeAll {
            $0.timestamp < cutoff
        }
    }

    public static func apply(
        policy: BehavioralRetentionPolicy,
        to sessions:
        inout [ApplicationUsageSession]
    ) {
        if sessions.count >
            policy.maximumSessionCount
        {
            sessions = Array(
                sessions.suffix(
                    policy.maximumSessionCount
                )
            )
        }
    }

    // MEMORY-FIX (Phase 4, Step 1): the two overloads below were missing even
    // though BehavioralRetentionPolicy already declared limits for both
    // (maximumInactivityRecords, maximumDeviceStateEvents) — mirrors the
    // count-based trim pattern used by the two overloads above. No age-based
    // cutoff is added here, matching how the sessions overload above also
    // only does a count-based trim (see BEHAVIOR_MEMORY_FIX_PLAN.txt, open
    // decision 2, for adding age-based eviction to these later if wanted).

    public static func apply(
        policy: BehavioralRetentionPolicy,
        to records: inout [InactivityRecord]
    ) {
        if records.count >
            policy.maximumInactivityRecords
        {
            records = Array(
                records.suffix(
                    policy.maximumInactivityRecords
                )
            )
        }
    }

    public static func apply(
        policy: BehavioralRetentionPolicy,
        to deviceEvents: inout [DeviceStateEvent]
    ) {
        if deviceEvents.count >
            policy.maximumDeviceStateEvents
        {
            deviceEvents = Array(
                deviceEvents.suffix(
                    policy.maximumDeviceStateEvents
                )
            )
        }
    }
}

// MARK: - Observer Health Monitoring

/// Represents the operational health state of an observer.
///
/// Observer health exists solely to maintain continuity
/// of behavioral evidence acquisition.
public enum BehavioralObserverHealth:
    String,
    Codable,
    Hashable,
    Sendable
{
    case active
    case inactive
    case degraded
    case failed
}

// MARK: - Observer Status Record

/// Timestamped observer operational state record.
public struct BehavioralObserverStatus:
    Codable,
    Identifiable,
    Hashable,
    Sendable
{
    public let id: UUID
    public let observerName: String
    public let health: BehavioralObserverHealth
    public let timestamp: Date
    public let metadata: [String: String]

    public init(
        id: UUID = UUID(),
        observerName: String,
        health: BehavioralObserverHealth,
        timestamp: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.observerName = observerName
        self.health = health
        self.timestamp = timestamp
        self.metadata = metadata
    }
}

// MARK: - Observer Diagnostics Center

/// Tracks operational observer diagnostics.
///
/// Diagnostics are infrastructural only and never
/// influence behavioral interpretation.
public final class BehavioralObserverDiagnostics:
    ObservableObject,
    @unchecked Sendable
{
    @Published
    public private(set) var statuses:
        [BehavioralObserverStatus] = []

    public init() {}

    public func record(
        observerName: String,
        health: BehavioralObserverHealth,
        metadata: [String: String] = [:]
    ) {
        let status =
            BehavioralObserverStatus(
                observerName: observerName,
                health: health,
                metadata: metadata
            )

        statuses.append(status)
    }

    public func latestStatus(
        for observerName: String
    ) -> BehavioralObserverStatus? {
        statuses
            .reversed()
            .first {
                $0.observerName == observerName
            }
    }
}

// MARK: - Behavioral Clock

/// Injectable chronological source.
///
/// Clock injection enables deterministic replay,
/// testing, and timeline validation.
public protocol BehavioralClock:
    Sendable
{
    func now() -> Date
}

// MARK: - System Clock

/// Production system clock implementation.
public struct SystemBehavioralClock:
    BehavioralClock
{
    public init() {}

    public func now() -> Date {
        Date()
    }
}

// MARK: - Mock Clock

/// Deterministic testing clock.
public actor MockBehavioralClock:
    BehavioralClock
{
    private var currentDate: Date

    public init(
        initialDate: Date
    ) {
        currentDate =
            initialDate
    }

    public func now() -> Date {
        currentDate
    }

    public func advance(
        by interval: TimeInterval
    ) {
        currentDate =
            currentDate.addingTimeInterval(
                interval
            )
    }

    public func set(
        _ date: Date
    ) {
        currentDate = date
    }
}

// MARK: - Behavioral Event Deduplicator

/// Removes exact duplicate evidence records.
///
/// Deduplication preserves historical integrity while
/// avoiding duplicate ingestion artifacts.
public enum BehavioralEventDeduplicator {
    public static func deduplicate(
        events: [BehavioralEvent]
    ) -> [BehavioralEvent] {
        var seen:
            Set<BehavioralEvent> = []

        return events.filter {
            if seen.contains($0) {
                return false
            }

            seen.insert($0)
            return true
        }
    }
}

// MARK: - Event Ordering Normalizer

/// Restores strict chronological ordering.
///
/// Ordering normalization exists solely for
/// deterministic historical reconstruction.
public enum BehavioralOrderingNormalizer {
    public static func normalize(
        events: [BehavioralEvent]
    ) -> [BehavioralEvent] {
        events.sorted {
            if $0.timestamp ==
                $1.timestamp
            {
                return $0.id.uuidString <
                    $1.id.uuidString
            }

            return $0.timestamp <
                $1.timestamp
        }
    }
}

// MARK: - Event Partition Builder

/// Creates bounded chronological evidence partitions.
///
/// Partitioning improves long-term memory safety
/// and retrieval efficiency.
public enum BehavioralPartitionBuilder {
    public static func buildDailyPartitions(
        events: [BehavioralEvent]
    ) -> [BehavioralStoragePartition] {
        let calendar =
            Calendar.current

        let grouped =
            Dictionary(
                grouping: events
            ) {
                calendar.startOfDay(
                    for: $0.timestamp
                )
            }

        return grouped.compactMap {

            day,
            _ in
            guard
                let end =
                calendar.date(
                    byAdding: .day,
                    value: 1,
                    to: day
                )
            else {
                return nil
            }

            return BehavioralStoragePartition(
                observationWindow:
                BehavioralObservationWindow(
                    startDate: day,
                    endDate: end
                )
            )
        }
    }
}

// MARK: - Historical Evidence Cursor

/// Provides incremental chronological traversal.
///
/// Cursors support large historical evidence sets
/// without loading everything simultaneously.
public struct BehavioralEvidenceCursor:
    Codable,
    Hashable,
    Sendable
{
    public let position: Int
    public let batchSize: Int

    public init(
        position: Int = 0,
        batchSize: Int = 1000
    ) {
        self.position = position
        self.batchSize = batchSize
    }

    public func advanced()
        -> BehavioralEvidenceCursor
    {
        BehavioralEvidenceCursor(
            position: position + batchSize,
            batchSize: batchSize
        )
    }
}

// MARK: - Paginated Evidence Response

/// Represents a bounded historical retrieval result.
public struct BehavioralEvidencePage<T: Codable & Hashable & Sendable>:
    Codable,
    Hashable,
    Sendable
{
    public let items: [T]
    public let cursor:
        BehavioralEvidenceCursor
    public let hasMore: Bool

    public init(
        items: [T],
        cursor: BehavioralEvidenceCursor,
        hasMore: Bool
    ) {
        self.items = items
        self.cursor = cursor
        self.hasMore = hasMore
    }
}

// MARK: - Evidence Pagination Engine

/// Provides paginated retrieval over large evidence sets.
///
/// Pagination exists strictly for operational efficiency.
public enum BehavioralPaginationEngine {
    public static func page<T: Codable & Hashable & Sendable>(
        items: [T],
        cursor: BehavioralEvidenceCursor
    ) -> BehavioralEvidencePage<T> {
        let start =
            cursor.position

        let end =
            min(
                items.count,
                start + cursor.batchSize
            )

        guard start < end else {
            return BehavioralEvidencePage(
                items: [],
                cursor: cursor,
                hasMore: false
            )
        }

        let slice =
            Array(
                items[start ..< end]
            )

        return BehavioralEvidencePage(
            items: slice,
            cursor: cursor.advanced(),
            hasMore: end < items.count
        )
    }
}

// MARK: - Behavioral Replay Speed

/// Defines deterministic replay timing modes.
public enum BehavioralReplaySpeed:
    String,
    Codable,
    Hashable,
    Sendable
{
    case immediate
    case realtime
    case accelerated
}

// MARK: - Timed Replay Controller

/// Replays evidence with temporal pacing.
///
/// Replay pacing exists for chronological simulation only.
public actor TimedBehavioralReplayController {
    public init() {}

    public func replay(
        events: [BehavioralEvent],
        speed: BehavioralReplaySpeed
    ) -> AsyncStream<BehavioralReplayFrame> {
        let ordered =
            BehavioralOrderingNormalizer
                .normalize(
                    events: events
                )

        return AsyncStream {

            continuation in
            Task {

                for index in
                    ordered.indices
                {
                    let event =
                        ordered[index]

                    let frame =
                        BehavioralReplayFrame(
                            timestamp: event.timestamp,
                            event: event
                        )

                    continuation.yield(
                        frame
                    )

                    guard
                        speed != .immediate
                    else {
                        continue
                    }

                    if index < ordered.count - 1 {
                        let next =
                            ordered[index + 1]

                        let interval =
                            next.timestamp
                                .timeIntervalSince(
                                    event.timestamp
                                )

                        switch speed {
                        case .realtime:
                            try? await Task.sleep(
                                nanoseconds:
                                UInt64(
                                    max(
                                        interval,
                                        0
                                    ) * 1_000_000_000
                                )
                            )

                        case .accelerated:
                            try? await Task.sleep(
                                nanoseconds:
                                UInt64(
                                    max(
                                        interval / 10,
                                        0
                                    ) * 1_000_000_000
                                )
                            )

                        case .immediate:
                            break
                        }
                    }
                }

                continuation.finish()
            }
        }
    }
}

// MARK: - Event Compression Descriptor

/// Describes non-destructive evidence compression.
///
/// Compression descriptors preserve historical
/// chronology while reducing storage redundancy.
public struct BehavioralCompressionDescriptor:
    Codable,
    Hashable,
    Sendable
{
    public let originalCount: Int
    public let compressedCount: Int
    public let generatedAt: Date

    public init(
        originalCount: Int,
        compressedCount: Int,
        generatedAt: Date = Date()
    ) {
        self.originalCount =
            originalCount

        self.compressedCount =
            compressedCount

        self.generatedAt =
            generatedAt
    }
}

// MARK: - Session Gap Descriptor

/// Represents a chronological discontinuity
/// between observed sessions.
public struct BehavioralSessionGap:
    Codable,
    Identifiable,
    Hashable,
    Sendable
{
    public let id: UUID
    public let start: Date
    public let end: Date

    public var duration:
        TimeInterval
    {
        end.timeIntervalSince(start)
    }

    public init(
        id: UUID = UUID(),
        start: Date,
        end: Date
    ) {
        self.id = id
        self.start = start
        self.end = end
    }
}

// MARK: - Session Gap Analyzer

/// Detects discontinuities in chronological activity.
///
/// Gap analysis remains purely descriptive.
public enum BehavioralSessionGapAnalyzer {
    public static func gaps(
        in sessions:
        [ApplicationUsageSession]
    ) -> [BehavioralSessionGap] {
        let sorted =
            sessions.sorted {
                $0.startTime <
                    $1.startTime
            }

        guard sorted.count > 1 else {
            return []
        }

        var gaps:
            [BehavioralSessionGap] = []

        for index in
            1 ..< sorted.count
        {
            let previous =
                sorted[index - 1]

            let current =
                sorted[index]

            guard
                let previousEnd =
                previous.endTime
            else {
                continue
            }

            if current.startTime >
                previousEnd
            {
                let gap =
                    BehavioralSessionGap(
                        start: previousEnd,
                        end: current.startTime
                    )

                gaps.append(gap)
            }
        }

        return gaps
    }
}

// MARK: - Event Correlation Group

/// Represents temporally adjacent evidence.
///
/// Correlation groups preserve chronology only and
/// intentionally avoid causal interpretation.
public struct BehavioralCorrelationGroup:
    Codable,
    Identifiable,
    Hashable,
    Sendable
{
    public let id: UUID
    public let startTime: Date
    public let endTime: Date
    public let events:
        [BehavioralEvent]

    public init(
        id: UUID = UUID(),
        startTime: Date,
        endTime: Date,
        events: [BehavioralEvent]
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.events = events
    }
}

// MARK: - Temporal Grouping Engine

/// Groups chronologically adjacent evidence.
///
/// Grouping is organizational only.
public enum BehavioralTemporalGroupingEngine {
    public static func group(
        events: [BehavioralEvent],
        maximumGap: TimeInterval
    ) -> [BehavioralCorrelationGroup] {
        let ordered =
            BehavioralOrderingNormalizer
                .normalize(
                    events: events
                )

        guard !ordered.isEmpty else {
            return []
        }

        var groups:
            [BehavioralCorrelationGroup]
            = []

        var current:
            [BehavioralEvent]
            = [ordered[0]]

        for index in
            1 ..< ordered.count
        {
            let previous =
                ordered[index - 1]

            let next =
                ordered[index]

            let delta =
                next.timestamp
                    .timeIntervalSince(
                        previous.timestamp
                    )

            if delta <= maximumGap {
                current.append(next)

            } else {
                if let first =
                    current.first,
                    let last =
                    current.last
                {
                    groups.append(
                        BehavioralCorrelationGroup(
                            startTime:
                            first.timestamp,
                            endTime:
                            last.timestamp,
                            events: current
                        )
                    )
                }

                current = [next]
            }
        }

        if let first =
            current.first,
            let last =
            current.last
        {
            groups.append(
                BehavioralCorrelationGroup(
                    startTime:
                    first.timestamp,
                    endTime:
                    last.timestamp,
                    events: current
                )
            )
        }

        return groups
    }
}

// MARK: - Behavioral Metrics Descriptor

/// Descriptive evidence metrics.
///
/// Metrics remain observational only.
public struct BehavioralMetricsDescriptor:
    Codable,
    Hashable,
    Sendable
{
    public let eventCount: Int
    public let sessionCount: Int
    public let inactivityCount: Int
    public let uniqueApplications: Int
    public let generatedAt: Date

    public init(
        eventCount: Int,
        sessionCount: Int,
        inactivityCount: Int,
        uniqueApplications: Int,
        generatedAt: Date = Date()
    ) {
        self.eventCount = eventCount
        self.sessionCount = sessionCount
        self.inactivityCount = inactivityCount
        self.uniqueApplications = uniqueApplications
        self.generatedAt = generatedAt
    }
}

// MARK: - Metrics Generator

/// Produces descriptive system metrics.
///
/// Metrics intentionally avoid ranking,
/// scoring, or behavioral interpretation.
public enum BehavioralMetricsGenerator {
    public static func generate(
        events: [BehavioralEvent],
        sessions:
        [ApplicationUsageSession],
        inactivity:
        [InactivityRecord]
    ) -> BehavioralMetricsDescriptor {
        let applications =
            Set(
                sessions.map {
                    $0.application.bundleIdentifier
                        ?? $0.application.applicationName
                }
            )

        return BehavioralMetricsDescriptor(
            eventCount: events.count,
            sessionCount: sessions.count,
            inactivityCount:
            inactivity.count,
            uniqueApplications:
            applications.count
        )
    }
}

// MARK: - SQLite behavior evidence

extension LibraryDatabase {
    func loadBehaviorEvidence() throws -> (
        events: [BehavioralEvent],
        applicationSessions: [ApplicationUsageSession],
        inactivityRecords: [InactivityRecord],
        deviceStateEvents: [DeviceStateEvent]
    ) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try pool.read { db in
            let events = try String.fetchAll(
                db, sql: "SELECT payload_json FROM behavior_events ORDER BY timestamp"
            ).map { try decoder.decode(BehavioralEvent.self, from: Data($0.utf8)) }
            let sessions = try String.fetchAll(
                db, sql: "SELECT payload_json FROM application_sessions ORDER BY start_time"
            ).map { try decoder.decode(ApplicationUsageSession.self, from: Data($0.utf8)) }
            let inactivity = try String.fetchAll(
                db, sql: "SELECT payload_json FROM inactivity_records ORDER BY start_time"
            ).map { try decoder.decode(InactivityRecord.self, from: Data($0.utf8)) }
            let device = try String.fetchAll(
                db, sql: "SELECT payload_json FROM device_state_events ORDER BY timestamp"
            ).map { try decoder.decode(DeviceStateEvent.self, from: Data($0.utf8)) }
            return (events, sessions, inactivity, device)
        }
    }

    func replaceBehaviorEvidence(
        events: [BehavioralEvent],
        applicationSessions: [ApplicationUsageSession],
        inactivityRecords: [InactivityRecord],
        deviceStateEvents: [DeviceStateEvent]
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try pool.write { db in
            try db.execute(sql: "DELETE FROM behavior_events")
            try db.execute(sql: "DELETE FROM application_sessions")
            try db.execute(sql: "DELETE FROM inactivity_records")
            try db.execute(sql: "DELETE FROM device_state_events")

            for event in events {
                let payload = try encoder.encode(event)
                try db.execute(
                    sql: "INSERT INTO behavior_events (id, timestamp, type, payload_json) VALUES (?, ?, ?, ?)",
                    arguments: [
                        event.id.uuidString,
                        event.timestamp.timeIntervalSince1970,
                        event.eventType.rawValue,
                        String(decoding: payload, as: UTF8.self),
                    ])
            }
            for session in applicationSessions {
                let payload = try encoder.encode(session)
                try db.execute(
                    sql: "INSERT INTO application_sessions (id, start_time, end_time, payload_json) VALUES (?, ?, ?, ?)",
                    arguments: [
                        session.id.uuidString,
                        session.startTime.timeIntervalSince1970,
                        session.endTime?.timeIntervalSince1970,
                        String(decoding: payload, as: UTF8.self),
                    ])
            }
            for record in inactivityRecords {
                let payload = try encoder.encode(record)
                try db.execute(
                    sql: "INSERT INTO inactivity_records (id, start_time, end_time, payload_json) VALUES (?, ?, ?, ?)",
                    arguments: [
                        record.id.uuidString,
                        record.startTime.timeIntervalSince1970,
                        record.endTime?.timeIntervalSince1970,
                        String(decoding: payload, as: UTF8.self),
                    ])
            }
            for event in deviceStateEvents {
                let payload = try encoder.encode(event)
                try db.execute(
                    sql: "INSERT INTO device_state_events (id, timestamp, payload_json) VALUES (?, ?, ?)",
                    arguments: [
                        event.id.uuidString,
                        event.timestamp.timeIntervalSince1970,
                        String(decoding: payload, as: UTF8.self),
                    ])
            }
        }
    }

    func behaviorEvidenceCounts() throws -> (
        events: Int, sessions: Int, inactivity: Int, device: Int
    ) {
        try pool.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM behavior_events") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM application_sessions") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inactivity_records") ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM device_state_events") ?? 0
            )
        }
    }
}
