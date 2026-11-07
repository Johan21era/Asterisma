import Foundation

/// Single source of truth for the product's user-visible name and data root.
///
/// Bundle identifier note (MVP): the sandbox container is keyed by bundle ID.
/// Renaming it now would orphan the user's existing library. The display and
/// product name are AsterismaV2.5; the bundle ID remains the stable MVP id
/// until a dedicated container-migration release.
enum AppIdentity {
    static let displayName = "AsterismaV2.5"
    static let productName = "AsterismaV2.5"
    static let dataDirectoryName = "Asterisma"
    static let legacyDataDirectoryName = "ReadTracker"
    /// Stable MVP sandbox identity. Not user-visible.
    static let bundleIdentifier = "johan.Reading-Tracker"

    /// The app-support root for all Asterisma data. In test processes this is
    /// the process-scoped temp store. On first real launch it moves the legacy
    /// `ReadTracker` directory to `Asterisma` in place.
    static func dataRootURL() -> URL? {
        if let testRoot = RuntimeEnvironment.isolatedStoreDirectory {
            RuntimeEnvironment.ensureDirectory(testRoot)
            return testRoot
        }

        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }

        let newRoot = base.appendingPathComponent(dataDirectoryName, isDirectory: true)
        let legacyRoot = base.appendingPathComponent(legacyDataDirectoryName, isDirectory: true)
        let fm = FileManager.default

        if !fm.fileExists(atPath: newRoot.path),
           fm.fileExists(atPath: legacyRoot.path) {
            do {
                try fm.moveItem(at: legacyRoot, to: newRoot)
                print("[AppIdentity] Migrated data root ReadTracker → Asterisma.")
            } catch {
                // Move can fail across volume/ACL boundaries; a copy is safer
                // than starting empty. The legacy directory is left untouched.
                if (try? fm.copyItem(at: legacyRoot, to: newRoot)) != nil {
                    print("[AppIdentity] Copied data root ReadTracker → Asterisma.")
                } else {
                    print("[AppIdentity] Data-root migration failed: \(error)")
                }
            }
        }

        try? fm.createDirectory(at: newRoot, withIntermediateDirectories: true)
        return newRoot
    }

    /// Legacy weather DB lived under the bundle-id folder. Move it into the
    /// unified Asterisma root on first launch if the new path is empty.
    static func migrateLegacyWeatherStoreIfNeeded(to root: URL) {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return }
        let newURL = root.appendingPathComponent("weather_snapshots.sqlite3")
        let legacyURL = base.appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("weather_snapshots.sqlite3")
        let fm = FileManager.default
        guard !fm.fileExists(atPath: newURL.path),
              fm.fileExists(atPath: legacyURL.path) else { return }
        do {
            try fm.moveItem(at: legacyURL, to: newURL)
        } catch {
            try? fm.copyItem(at: legacyURL, to: newURL)
        }
    }
}
