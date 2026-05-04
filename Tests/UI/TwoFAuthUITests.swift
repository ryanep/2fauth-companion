import XCTest

#if canImport(UIKit)
    import UIKit
#endif

@MainActor
final class TwoFAuthUITests: XCTestCase {
    private struct LiveConfig: Decodable {
        let baseURL: String
        let apiToken: String
    }

    private var liveConfig: LiveConfig {
        let sourceURL = URL(fileURLWithPath: #filePath)
        let configURL = sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent("Generated/live-config.json")

        guard let data = try? Data(contentsOf: configURL) else {
            XCTFail("Missing live UI test config at \(configURL.path). Run via make -f makefile ui-test-live ...")
            return LiveConfig(baseURL: "", apiToken: "")
        }

        do {
            return try JSONDecoder().decode(LiveConfig.self, from: data)
        } catch {
            XCTFail("Invalid live UI test config at \(configURL.path): \(error.localizedDescription)")
            return LiveConfig(baseURL: "", apiToken: "")
        }
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunch() {
        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_FORCE_LOGGED_OUT"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["login.submit"].waitForExistence(timeout: 2))
    }

    func testLaunchOnIPad() throws {
        try requireIPadDestination()

        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_FORCE_LOGGED_OUT"] = "1"
        app.launch()

        XCTAssertTrue(app.buttons["login.submit"].waitForExistence(timeout: 2))
    }

    func testLoginScreenShowsNativeFormControlsOnIPad() throws {
        try requireIPadDestination()

        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_FORCE_LOGGED_OUT"] = "1"
        app.launch()

        XCTAssertTrue(element(in: app, identifier: "login.screen").waitForExistence(timeout: 2))
        XCTAssertTrue(app.textFields["login.baseURL"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.secureTextFields["login.apiKey"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["login.submit"].waitForExistence(timeout: 2))
    }

    func testLiveBackendShowsSeededAccountsAndCodes() {
        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_FORCE_LOGGED_OUT"] = "1"
        app.launchEnvironment["UI_TEST_BASE_URL"] = liveConfig.baseURL
        app.launchEnvironment["UI_TEST_API_TOKEN"] = liveConfig.apiToken
        app.launch()

        login(app: app, timeout: 20)

        XCTAssertTrue(app.staticTexts["Amazon"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Google"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Microsoft"].waitForExistence(timeout: 5))
        XCTAssertTrue(scrollUntilExists(app.staticTexts["PlayStation"], in: app))
        XCTAssertTrue(scrollUntilExists(app.staticTexts["Steam"], in: app))
        XCTAssertTrue(scrollUntilExists(app.staticTexts["Stripe"], in: app))

        XCTAssertTrue(staticTextMatching(in: app, pattern: "^[0-9]{6}$").waitForExistence(timeout: 5))
        XCTAssertTrue(staticTextMatching(in: app, pattern: "^[0-9]{7}$").waitForExistence(timeout: 5))
        XCTAssertTrue(staticTextMatching(in: app, pattern: "^[0-9]{8}$").waitForExistence(timeout: 5))
        XCTAssertTrue(scrollUntilExists(staticTextMatching(in: app, pattern: "^[23456789BCDFGHJKMNPQRTVWXY]{5}$"), in: app))

        let nineDigitCode = element(in: app, identifier: "account.code.service.playstation")
        XCTAssertTrue(scrollUntilExists(nineDigitCode, in: app))
        XCTAssertTrue(nineDigitCode.label.range(of: "^[0-9]{9}$", options: .regularExpression) != nil)

        let tenDigitCode = element(in: app, identifier: "account.code.service.stripe")
        XCTAssertTrue(scrollUntilExists(tenDigitCode, in: app))
        XCTAssertTrue(tenDigitCode.label.range(of: "^[0-9]{10}$", options: .regularExpression) != nil)
    }

    func testLiveBackendUsesGridOnIPad() throws {
        try requireIPadDestination()

        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_FORCE_LOGGED_OUT"] = "1"
        app.launchEnvironment["UI_TEST_BASE_URL"] = liveConfig.baseURL
        app.launchEnvironment["UI_TEST_API_TOKEN"] = liveConfig.apiToken
        app.launch()

        login(app: app, timeout: 20)

        XCTAssertTrue(element(in: app, identifier: "accounts.grid").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Amazon"].waitForExistence(timeout: 5))

        let sixDigitCode = element(in: app, identifier: "account.code.service.amazon")
        XCTAssertTrue(sixDigitCode.waitForExistence(timeout: 5))
        XCTAssertTrue(sixDigitCode.label.range(of: "^[0-9]{6}$", options: .regularExpression) != nil)
        XCTAssertEqual(sixDigitCode.value as? String, "ready")

        sixDigitCode.tap()

        XCTAssertTrue(waitUntil(timeout: 5) {
            sixDigitCode.value as? String == "copied"
        })
        XCTAssertEqual(sixDigitCode.value as? String, "copied")
    }

    func testLiveBackendFallsBackToListOnNarrowIPadWidth() throws {
        try requireIPadDestination()

        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_FORCE_LOGGED_OUT"] = "1"
        app.launchEnvironment["UI_TEST_BASE_URL"] = liveConfig.baseURL
        app.launchEnvironment["UI_TEST_API_TOKEN"] = liveConfig.apiToken
        app.launchEnvironment["UI_TEST_FORCE_ACCOUNTS_COMPACT_LAYOUT"] = "1"
        app.launch()

        login(app: app, timeout: 20)

        XCTAssertTrue(element(in: app, identifier: "accounts.list").waitForExistence(timeout: 5))
        XCTAssertFalse(element(in: app, identifier: "accounts.grid").exists)
        XCTAssertTrue(app.staticTexts["Amazon"].waitForExistence(timeout: 5))
    }

    func testLiveBackendReturnsToGridAfterSettingsRoundTripOnIPad() throws {
        try requireIPadDestination()

        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_FORCE_LOGGED_OUT"] = "1"
        app.launchEnvironment["UI_TEST_BASE_URL"] = liveConfig.baseURL
        app.launchEnvironment["UI_TEST_API_TOKEN"] = liveConfig.apiToken
        app.launch()

        login(app: app, timeout: 20)

        let initialGrid = element(in: app, identifier: "accounts.grid")
        XCTAssertTrue(initialGrid.waitForExistence(timeout: 5))

        let settingsTab = element(in: app, identifier: "tab.settings")
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()

        XCTAssertTrue(element(in: app, identifier: "settings.screen").waitForExistence(timeout: 5))

        let accountsTab = element(in: app, identifier: "tab.accounts")
        XCTAssertTrue(accountsTab.waitForExistence(timeout: 5))
        accountsTab.tap()

        let returnedGrid = element(in: app, identifier: "accounts.grid")
        XCTAssertTrue(returnedGrid.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Amazon"].waitForExistence(timeout: 5))
    }

    func testLiveBackendUsesGridOnIPadLandscape() throws {
        try requireIPadDestination()

        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_FORCE_LOGGED_OUT"] = "1"
        app.launchEnvironment["UI_TEST_BASE_URL"] = liveConfig.baseURL
        app.launchEnvironment["UI_TEST_API_TOKEN"] = liveConfig.apiToken
        app.launch()

        login(app: app, timeout: 20)
        rotateToLandscape()
        defer { rotateToPortrait() }
        assertAppReachedLandscape(in: app, timeout: 5)

        let grid = element(in: app, identifier: "accounts.grid")
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Amazon"].waitForExistence(timeout: 5))

        let sixDigitCode = element(in: app, identifier: "account.code.service.amazon")
        XCTAssertTrue(sixDigitCode.waitForExistence(timeout: 5))
        XCTAssertTrue(sixDigitCode.label.range(of: "^[0-9]{6}$", options: .regularExpression) != nil)
        XCTAssertEqual(sixDigitCode.value as? String, "ready")

        sixDigitCode.tap()

        XCTAssertTrue(waitUntil(timeout: 5) {
            sixDigitCode.value as? String == "copied"
        })
        XCTAssertEqual(sixDigitCode.value as? String, "copied")
    }

    func testLiveBackendSearchesOnIPadLandscape() throws {
        try requireIPadDestination()

        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_FORCE_LOGGED_OUT"] = "1"
        app.launchEnvironment["UI_TEST_BASE_URL"] = liveConfig.baseURL
        app.launchEnvironment["UI_TEST_API_TOKEN"] = liveConfig.apiToken
        app.launch()

        login(app: app, timeout: 20)
        rotateToLandscape()
        defer { rotateToPortrait() }
        assertAppReachedLandscape(in: app, timeout: 5)

        let grid = element(in: app, identifier: "accounts.grid")
        XCTAssertTrue(grid.waitForExistence(timeout: 5))

        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText("Steam")

        XCTAssertTrue(app.staticTexts["Steam"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Amazon"].exists)
    }

    func testLiveLoginPublishesWatchSyncMarker() {
        let app = XCUIApplication()
        let markerPath = ProcessInfo.processInfo.environment["UI_TEST_WATCH_SYNC_MARKER_PATH"]
            ?? NSTemporaryDirectory().appending("watch-sync-marker-ui-tests.json")
        try? FileManager.default.removeItem(atPath: markerPath)

        app.launchEnvironment["UI_TEST_FORCE_LOGGED_OUT"] = "1"
        app.launchEnvironment["UI_TEST_BASE_URL"] = liveConfig.baseURL
        app.launchEnvironment["UI_TEST_API_TOKEN"] = liveConfig.apiToken
        app.launchEnvironment["UI_TEST_ASSUME_WATCH_APP_INSTALLED"] = "1"
        app.launchEnvironment["UI_TEST_WATCH_SYNC_MARKER_PATH"] = markerPath
        app.launch()

        login(app: app, timeout: 20)
        XCTAssertTrue(waitForWatchSyncMarker(at: markerPath, timeout: 12), markerFailureMessage(at: markerPath))
    }

    func testSettingsScreenShowsLiveAccountMetadata() {
        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_FORCE_LOGGED_OUT"] = "1"
        app.launchEnvironment["UI_TEST_BASE_URL"] = liveConfig.baseURL
        app.launchEnvironment["UI_TEST_API_TOKEN"] = liveConfig.apiToken
        app.launch()

        login(app: app)

        let settingsTab = element(in: app, identifier: "tab.settings")
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()

        let appVersion = element(in: app, identifier: "settings.app_version")
        XCTAssertTrue(appVersion.waitForExistence(timeout: 5))

        let serverURL = element(in: app, identifier: "settings.server_url")
        XCTAssertTrue(serverURL.waitForExistence(timeout: 5))
        XCTAssertEqual(serverURL.label, liveConfig.baseURL)

        let lastSync = element(in: app, identifier: "settings.last_sync")
        XCTAssertTrue(lastSync.waitForExistence(timeout: 5))
        XCTAssertFalse(lastSync.label.isEmpty)

        XCTAssertTrue(element(in: app, identifier: "settings.auto_lock").waitForExistence(timeout: 5))
    }

    func testSettingsScreenShowsNativeFormControlsOnIPad() throws {
        try requireIPadDestination()

        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_FORCE_LOGGED_OUT"] = "1"
        app.launchEnvironment["UI_TEST_BASE_URL"] = liveConfig.baseURL
        app.launchEnvironment["UI_TEST_API_TOKEN"] = liveConfig.apiToken
        app.launch()

        login(app: app)

        let settingsTab = element(in: app, identifier: "tab.settings")
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()

        XCTAssertTrue(element(in: app, identifier: "settings.screen").waitForExistence(timeout: 5))
        XCTAssertTrue(element(in: app, identifier: "settings.app_version").waitForExistence(timeout: 5))
        XCTAssertTrue(element(in: app, identifier: "settings.server_url").waitForExistence(timeout: 5))
        XCTAssertTrue(element(in: app, identifier: "settings.last_sync").waitForExistence(timeout: 5))
        XCTAssertTrue(element(in: app, identifier: "settings.auto_lock").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.logout"].waitForExistence(timeout: 5))
    }

    func testLogoutFromSettingsReturnsToLogin() {
        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_FORCE_LOGGED_OUT"] = "1"
        app.launchEnvironment["UI_TEST_BASE_URL"] = liveConfig.baseURL
        app.launchEnvironment["UI_TEST_API_TOKEN"] = liveConfig.apiToken
        app.launchEnvironment["UI_TEST_WIPE_DELAY_MS"] = "2500"
        app.launch()

        login(app: app)

        let settingsTab = app.tabBars.buttons["tab.settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        settingsTab.tap()

        let logoutButton = app.buttons["settings.logout"]
        XCTAssertTrue(logoutButton.waitForExistence(timeout: 5))
        logoutButton.tap()

        let confirmLogoutButton = app.buttons.matching(identifier: "settings.logout.confirm").firstMatch
        XCTAssertTrue(confirmLogoutButton.waitForExistence(timeout: 5))
        confirmLogoutButton.tap()

        XCTAssertTrue(app.buttons["login.submit"].waitForExistence(timeout: 5))
    }

    func testRelaunchAfterLiveLoginRestoresAuthenticatedSession() {
        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_FORCE_LOGGED_OUT"] = "1"
        app.launchEnvironment["UI_TEST_BASE_URL"] = liveConfig.baseURL
        app.launchEnvironment["UI_TEST_API_TOKEN"] = liveConfig.apiToken
        app.launch()

        login(app: app)
        app.terminate()

        app.launchEnvironment["UI_TEST_FORCE_LOGGED_OUT"] = "0"
        app.launch()

        let restoredAuthenticatedUI = app.buttons["lock.unlock"].waitForExistence(timeout: 5)
            || app.tabBars.buttons["tab.settings"].waitForExistence(timeout: 5)
        XCTAssertTrue(restoredAuthenticatedUI)
        XCTAssertFalse(app.buttons["login.submit"].exists)
    }

    func testReloginRequiredLaunchShowsLoginScreen() {
        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_START_RELOGIN_REQUIRED"] = "1"
        app.launchEnvironment["UI_TEST_BASE_URL"] = liveConfig.baseURL
        app.launch()

        XCTAssertTrue(app.buttons["login.submit"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["lock.unlock"].exists)
    }

    private func login(app: XCUIApplication, timeout: TimeInterval = 8) {
        let submitButton = app.buttons["login.submit"]
        XCTAssertTrue(submitButton.waitForExistence(timeout: 8))
        
        submitButton.tap()

        let reachedMainUI = element(in: app, identifier: "accounts.screen").waitForExistence(timeout: timeout)
            || element(in: app, identifier: "settings.screen").exists
            || app.tabBars.firstMatch.waitForExistence(timeout: 2)
        XCTAssertTrue(reachedMainUI)
    }

    private func requireIPadDestination() throws {
        #if canImport(UIKit)
            guard UIDevice.current.userInterfaceIdiom == .pad else {
                throw XCTSkip("iPad-only UI regression test")
            }
        #else
            throw XCTSkip("iPad-only UI regression test")
        #endif
    }

    private func assertAppReachedLandscape(in app: XCUIApplication, timeout: TimeInterval) {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: timeout))
        XCTAssertTrue(waitUntil(timeout: timeout) {
            let frame = window.frame
            return frame.width > frame.height
        }, "Expected app window to be wider than tall after rotating to landscape")
    }

    private func rotateToLandscape() {
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    private func rotateToPortrait() {
        XCUIDevice.shared.orientation = .portrait
    }

    private func waitForWatchSyncMarker(at path: String, timeout: TimeInterval) -> Bool {
        waitUntil(timeout: timeout) {
            markerEvent(at: path) == "watch.sync_updated_context"
        }
    }

    private func markerFailureMessage(at path: String) -> String {
        guard let payload = markerPayload(at: path), !payload.isEmpty else {
            return "Expected watch sync marker at \(path)"
        }

        return "Unexpected watch sync marker: \(payload)"
    }

    private func markerEvent(at path: String) -> String? {
        markerPayload(at: path)?["event"]
    }

    private func markerPayload(at path: String) -> [String: String]? {
        guard let data = FileManager.default.contents(atPath: path),
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else {
            return nil
        }

        return payload
    }

    private func staticTextMatching(in app: XCUIApplication, pattern: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", pattern)).firstMatch
    }

    private func replaceSecureText(in element: XCUIElement, with text: String) {
        element.tap()
        let deleteText = String(repeating: XCUIKeyboardKey.delete.rawValue, count: 64)
        element.typeText(deleteText)
        element.typeText(text)
    }

    private func element(in app: XCUIApplication, identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func allStaticTextMatches(in app: XCUIApplication, pattern: String) -> Set<String> {
        Set(
            app.staticTexts.allElementsBoundByIndex.compactMap { element in
                let label = element.label
                return label.range(of: pattern, options: .regularExpression) != nil ? label : nil
            }
        )
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    private func scrollUntilExists(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 6) -> Bool {
        if element.waitForExistence(timeout: 2) {
            return true
        }

        for _ in 0..<maxSwipes {
            app.swipeUp()
            if element.waitForExistence(timeout: 1) {
                return true
            }
        }

        return element.exists
    }
}
