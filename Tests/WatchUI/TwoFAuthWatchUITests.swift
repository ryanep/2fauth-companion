import XCTest

@MainActor
final class TwoFAuthWatchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testWatchAppLaunches() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.otherElements["watch.accounts.screen"].waitForExistence(timeout: 5))
    }

    func testSyncedAccountsAppearOnWatch() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.otherElements["watch.accounts.screen"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["watch.empty"].waitForExistence(timeout: 1))

        let rows = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH %@", "watch.row."))
        XCTAssertEqual(rows.element(boundBy: 0).identifier, "watch.row.amazon")
        XCTAssertEqual(rows.element(boundBy: 11).identifier, "watch.row.stripe")

        let steamCode = app.staticTexts["watch.code.steam"]
        XCTAssertTrue(scrollUntilExists(steamCode, in: app))
        XCTAssertTrue(steamCode.label.range(of: "^[23456789BCDFGHJKMNPQRTVWXY]{5}$", options: .regularExpression) != nil)

        let totpTenCode = app.staticTexts["watch.code.stripe"]
        XCTAssertTrue(scrollUntilExists(totpTenCode, in: app))
        XCTAssertTrue(totpTenCode.label.range(of: "^[0-9]{10}$", options: .regularExpression) != nil)
        XCTAssertTrue(scrollUntilExists(app.staticTexts["watch.countdown.stripe"], in: app))
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
