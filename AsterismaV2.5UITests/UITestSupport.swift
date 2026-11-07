import XCTest

/// Every UI-test launch is isolated from the real sandbox store.
/// DataStore, CoverStore, and SentinelEngine all honor RT_TEST_STORE_DIR.
func makeIsolatedApp() -> XCUIApplication {
    let app = XCUIApplication()
    // The app resolves this inside its own sandbox temp directory.
    app.launchArguments.append("--uitest")
    return app
}
