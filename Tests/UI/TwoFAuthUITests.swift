import XCTest

final class TwoFAuthUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunch() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["login.submit"].waitForExistence(timeout: 2))
    }

    func testLogoutImmediatelyShowsLoginWhileWipeInProgress() {
        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_START_UNLOCKED"] = "1"
        app.launchEnvironment["UI_TEST_WIPE_DELAY_MS"] = "2500"
        app.launch()

        let settingsTab = app.buttons["tab.settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 8))
        settingsTab.tap()

        let logoutButton = app.buttons["settings.logout"]
        XCTAssertTrue(logoutButton.waitForExistence(timeout: 2))
        logoutButton.tap()

        let confirmLogoutButton = app.buttons["settings.logout.confirm"]
        XCTAssertTrue(confirmLogoutButton.waitForExistence(timeout: 2))
        confirmLogoutButton.tap()

        XCTAssertTrue(app.buttons["login.submit"].waitForExistence(timeout: 1))
    }
}
