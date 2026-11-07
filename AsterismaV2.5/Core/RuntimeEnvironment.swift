import Foundation

/// Process-scoped runtime paths. Production uses Application Support.
/// Unit-test hosts and UI tests get an isolated temp store automatically, so
/// a green census can never mutate the user's real library.
enum RuntimeEnvironment {
    static var isRunningTests: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    /// Explicit override wins; `--uitest` uses the app's own sandbox temp;
    /// otherwise a test host gets its own process-scoped directory.
    /// `nil` in production.
    static var isolatedStoreDirectory: URL? {
        let env = ProcessInfo.processInfo.environment
        if let explicit = env["RT_TEST_STORE_DIR"], !explicit.isEmpty {
            return URL(fileURLWithPath: explicit, isDirectory: true)
        }
        let temp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        if ProcessInfo.processInfo.arguments.contains("--uitest") {
            return temp.appendingPathComponent(
                "Asterisma-UITests-\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true)
        }
        guard isRunningTests else { return nil }
        return temp.appendingPathComponent(
            "Asterisma-Tests-\(ProcessInfo.processInfo.processIdentifier)",
            isDirectory: true)
    }

    static func ensureDirectory(_ url: URL) {
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
    }
}
