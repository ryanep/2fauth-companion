import XCTest

@testable import TwoFAuth

final class TwoFAuthTests: XCTestCase {
    func testTOTPVector() {
        let secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
        let date = Date(timeIntervalSince1970: 59)

        let otp = TOTPGenerator.generate(secret: secret, digits: 8, period: 30, at: date)

        XCTAssertEqual(otp, "94287082")
    }

    func testHOTPVector() {
        let secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"

        let otp0 = HOTPGenerator.generate(secret: secret, digits: 6, counter: 0)
        let otp1 = HOTPGenerator.generate(secret: secret, digits: 6, counter: 1)

        XCTAssertEqual(otp0, "755224")
        XCTAssertEqual(otp1, "287082")
    }

    func testSteamGuardFormat() {
        let secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
        let code = SteamGuardGenerator.generate(secret: secret, counter: 1)

        XCTAssertNotNil(code)
        XCTAssertEqual(code?.count, 5)
        let allowed = CharacterSet(charactersIn: "23456789BCDFGHJKMNPQRTVWXY")
        XCTAssertTrue(code?.unicodeScalars.allSatisfy(allowed.contains) == true)
    }

    func testAutoLockTimeoutDefaultsToImmediate() {
        let store = makeConfigStore(testName: #function)

        XCTAssertEqual(store.autoLockTimeoutSeconds, UserDefaultsAppConfigStore.defaultAutoLockTimeoutSeconds)
    }

    func testAutoLockTimeoutAcceptsPresetValues() {
        let store = makeConfigStore(testName: #function)

        for value in UserDefaultsAppConfigStore.autoLockTimeoutOptionsSeconds {
            store.autoLockTimeoutSeconds = value
            XCTAssertEqual(store.autoLockTimeoutSeconds, value)
        }
    }

    func testAutoLockTimeoutRejectsUnsupportedValues() {
        let store = makeConfigStore(testName: #function)

        store.autoLockTimeoutSeconds = 45
        XCTAssertEqual(store.autoLockTimeoutSeconds, UserDefaultsAppConfigStore.defaultAutoLockTimeoutSeconds)

        store.autoLockTimeoutSeconds = -10
        XCTAssertEqual(store.autoLockTimeoutSeconds, UserDefaultsAppConfigStore.defaultAutoLockTimeoutSeconds)
    }

    private func makeConfigStore(testName: String) -> UserDefaultsAppConfigStore {
        let suiteName = "TwoFAuthTests.\(testName)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Could not create UserDefaults test suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return UserDefaultsAppConfigStore(defaults: defaults)
    }
}
