import XCTest

@MainActor
final class TwoFAuthUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunch() {
        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_FORCE_LOGGED_OUT"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["login.submit"].waitForExistence(timeout: 2))
    }

    func testLogoutImmediatelyShowsLoginWhileWipeInProgress() throws {
        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_FORCE_LOGGED_OUT"] = "1"
        app.launchEnvironment["UI_TEST_LOGIN_FIXTURE"] = "1"
        app.launchEnvironment["UI_TEST_WIPE_DELAY_MS"] = "2500"
        app.launch()

        login(app: app, baseURL: "https://example.com", apiKey: "ui-test-key")

        if !app.buttons["settings.logout"].exists {
            if app.buttons["tab.settings"].waitForExistence(timeout: 2) {
                app.buttons["tab.settings"].tap()
            } else {
                let tabBar = app.tabBars.firstMatch
                XCTAssertTrue(tabBar.waitForExistence(timeout: 3))
                let settingsTab = tabBar.buttons.element(boundBy: 1)
                XCTAssertTrue(settingsTab.waitForExistence(timeout: 2))
                settingsTab.tap()
            }
        }

        let logoutButton = app.buttons["settings.logout"]
        XCTAssertTrue(logoutButton.waitForExistence(timeout: 2))
        logoutButton.tap()

        let logoutAlert = app.alerts.firstMatch
        XCTAssertTrue(logoutAlert.waitForExistence(timeout: 2))
        let confirmLogoutButton = logoutAlert.buttons.matching(identifier: "settings.logout.confirm").firstMatch
        XCTAssertTrue(confirmLogoutButton.waitForExistence(timeout: 2))
        confirmLogoutButton.tap()

        XCTAssertTrue(app.buttons["login.submit"].waitForExistence(timeout: 3))
    }

    func testAllCodeVariantsGenerateExpectedFormats() {
        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_FORCE_LOGGED_OUT"] = "1"
        app.launchEnvironment["UI_TEST_LOGIN_FIXTURE"] = "all-variants"
        app.launch()

        login(app: app, baseURL: "https://example.com", apiKey: "ui-test-key")

        XCTAssertTrue(app.staticTexts["TOTP 6 SHA1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["TOTP 7 SHA256"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["TOTP 8 SHA512"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["TOTP 9 MD5"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["TOTP 10 SHA1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Steam Fixture"].waitForExistence(timeout: 5))

        XCTAssertTrue(waitUntil(timeout: 5) {
            !allStaticTextMatches(in: app, pattern: "^[0-9]{6}$").isEmpty
        })
        XCTAssertTrue(waitUntil(timeout: 5) {
            !allStaticTextMatches(in: app, pattern: "^[0-9]{7}$").isEmpty
        })
        XCTAssertTrue(waitUntil(timeout: 5) {
            !allStaticTextMatches(in: app, pattern: "^[0-9]{8}$").isEmpty
        })
        XCTAssertTrue(waitUntil(timeout: 5) {
            !allStaticTextMatches(in: app, pattern: "^[0-9]{9}$").isEmpty
        })
        XCTAssertTrue(waitUntil(timeout: 5) {
            !allStaticTextMatches(in: app, pattern: "^[0-9]{10}$").isEmpty
        })
        XCTAssertTrue(waitUntil(timeout: 5) {
            !allStaticTextMatches(in: app, pattern: "^[23456789BCDFGHJKMNPQRTVWXY]{5}$").isEmpty
        })
    }

    private func login(app: XCUIApplication, baseURL: String, apiKey: String) {
        let submitButton = app.buttons["login.submit"]
        XCTAssertTrue(submitButton.waitForExistence(timeout: 8))

        let baseURLField = app.textFields["login.baseURL"]
        XCTAssertTrue(baseURLField.waitForExistence(timeout: 2))
        replaceText(in: baseURLField, with: baseURL)

        let apiKeyField = app.secureTextFields["login.apiKey"]
        XCTAssertTrue(apiKeyField.waitForExistence(timeout: 2))
        replaceSecureText(in: apiKeyField, with: apiKey)

        submitButton.tap()

        let reachedMainUI = app.otherElements["accounts.screen"].waitForExistence(timeout: 8)
            || app.otherElements["settings.screen"].exists
            || app.tabBars.firstMatch.waitForExistence(timeout: 2)
        XCTAssertTrue(reachedMainUI)
    }

    private func replaceText(in element: XCUIElement, with text: String) {
        element.tap()
        if let currentValue = element.value as? String, !currentValue.isEmpty {
            let deleteText = String(repeating: XCUIKeyboardKey.delete.rawValue, count: currentValue.count)
            element.typeText(deleteText)
        }
        element.typeText(text)
    }

    private func replaceSecureText(in element: XCUIElement, with text: String) {
        element.tap()
        let deleteText = String(repeating: XCUIKeyboardKey.delete.rawValue, count: 64)
        element.typeText(deleteText)
        element.typeText(text)
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
}
