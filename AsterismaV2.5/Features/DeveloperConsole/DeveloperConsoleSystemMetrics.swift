//  DeveloperConsoleSystemMetrics.swift
//  AsterismaV2.5
//
//  DEVELOPER CONSOLE — Phase 2 (Dashboard)
//
//  App-level facts that are NOT per-subsystem — they describe the process
//  and its data files as a whole, which is what the Dashboard's header strip
//  needs (Build Configuration, Version, Launch Time, Memory Usage, Storage
//  Usage). Every value here is either read directly from the system/bundle,
//  or is a plain arithmetic total (bytes on disk, seconds of CPU time) — not
//  a synthesized score, so none of this needs to go through the Derived
//  Metrics Protocol.
//
//  HONEST NOTE ON SCOPE: the Developer Console contract's Phase 2 checklist
//  names several subsystems by generic role names ("Pattern Engine",
//  "Timeline Engine", "Reading Session Detector") that do not correspond to
//  any type actually found in this codebase during this session's
//  inspection. Rather than invent types to match those names — which the
//  contract's own Anti-Hallucination clause forbids — the Dashboard is built
//  to show whatever is REALLY registered (see DeveloperConsoleRegistry) plus
//  these genuinely real, verifiable app-level facts. See
//  developer-console-component-registry.md for the full list of what this
//  session did and did not find a real match for.
//

#if DEBUG

import Foundation
import Darwin

// MARK: - DeveloperConsoleSystemMetrics

enum DeveloperConsoleSystemMetrics {
    // MARK: Version

    /// e.g. "1.0 (build 3)" — read directly from the bundle, never hand-typed.
    static var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let shortVersion = info?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(shortVersion) (build \(build))"
    }

    /// Always "Debug" while this file is compiled in at all — the entire
    /// Developer Console module is wrapped in #if DEBUG, so if this code is
    /// running, the active configuration is, by construction, Debug. This is
    /// a true fact stated directly, not a placeholder.
    static let buildConfiguration = "Debug"

    // MARK: Launch time

    /// Set once, the first time anything touches DeveloperConsoleRegistry.
    /// In practice that happens within DataStore's own init() — the very
    /// first object AsterismaApp.init() creates — so this is accurate
    /// to within milliseconds of true process launch, not exact-to-the-tick.
    /// Documented here precisely rather than described as more exact than it is.
    static let approximateLaunchTime = Date()

    static var uptimeDescription: String {
        let seconds = Date().timeIntervalSince(approximateLaunchTime)
        if seconds < 60 { return "\(Int(seconds))s" }
        let minutes = Int(seconds) / 60
        let remainderSeconds = Int(seconds) % 60
        return "\(minutes)m \(remainderSeconds)s"
    }

    // MARK: Memory

    /// Resident memory (bytes) for the current process, via the standard
    /// Mach task_info call. Returns nil if the call fails for any reason —
    /// the Dashboard must show "Unavailable" in that case, never a fake number.
    static func residentMemoryBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
        )
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    reboundPointer,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.resident_size
    }

    static var memoryUsageDescription: String {
        guard let bytes = residentMemoryBytes() else { return "Unavailable" }
        return byteCountDescription(bytes)
    }

    // MARK: CPU

    /// Total CPU time (user + system) consumed by this process since launch,
    /// in seconds. Deliberately reported as a cumulative total, not a
    /// percentage — an instantaneous CPU % needs two samples and a time
    /// delta, which is a derived metric with its own formula and belongs to
    /// Phase 9 (Performance Center) if/when that's built, not invented here.
    static func totalCPUTimeSeconds() -> Double? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
        )
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    reboundPointer,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1_000_000
        let system = Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1_000_000
        return user + system
    }

    static var cpuTimeDescription: String {
        guard let seconds = totalCPUTimeSeconds() else { return "Unavailable" }
        return String(format: "%.1fs (user+system) since launch", seconds)
    }

    // MARK: Storage

    /// Real on-disk size of this app's own data files (library.json,
    /// library-state.json, and the audio-profiles directory), read from
    /// the Application Support directory DataStore itself writes to — the
    /// exact same path DataStore already computes, not a guessed path.
    static func appDataStorageBytes() -> UInt64? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = AppIdentity.dataRootURL()
            ?? appSupport.appendingPathComponent("Asterisma", isDirectory: true)
        guard fm.fileExists(atPath: dir.path) else { return 0 }

        var total: UInt64 = 0
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += UInt64(size)
            }
        }
        return total
    }

    static var storageUsageDescription: String {
        guard let bytes = appDataStorageBytes() else { return "Unavailable" }
        return byteCountDescription(bytes)
    }

    // MARK: Formatting

    private static func byteCountDescription(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}

#endif
