import XCTest

final class TwoFAuthUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunch() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["2FAuth Login"].exists)
    }

    func testLogoutImmediatelyShowsLoginWhileWipeInProgress() {
        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_START_UNLOCKED"] = "1"
        app.launchEnvironment["UI_TEST_WIPE_DELAY_MS"] = "2500"
        app.launch()

        XCTAssertTrue(app.navigationBars["Accounts"].waitForExistence(timeout: 2))

        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 2))
        settingsTab.tap()

        let logoutButton = app.buttons["Log Out"]
        XCTAssertTrue(logoutButton.waitForExistence(timeout: 2))
        logoutButton.tap()

        let logoutAlert = app.alerts["Log Out?"]
        XCTAssertTrue(logoutAlert.waitForExistence(timeout: 2))
        logoutAlert.buttons["Log Out"].tap()

        XCTAssertTrue(app.navigationBars["2FAuth Login"].waitForExistence(timeout: 1))
    }
}
