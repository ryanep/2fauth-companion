import XCTest

@testable import TwoFAuth

final class TwoFAuthTests: XCTestCase {
    func testTOTPVector() {
        let secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
        let date = Date(timeIntervalSince1970: 59)

        let otp = TOTPGenerator.generate(secret: secret, digits: .eight, period: 30, at: date)

        XCTAssertEqual(otp, "94287082")
    }

    func testHOTPVector() {
        let secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"

        let otp0 = HOTPGenerator.generate(secret: secret, digits: .six, counter: 0)
        let otp1 = HOTPGenerator.generate(secret: secret, digits: .six, counter: 1)

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

    func testDisplayVersionReturnsVersionAndBuildWhenBothValuesPresent() {
        let value = AppVersionFormatter.displayVersion(
            shortVersion: "1.2.3",
            buildVersion: "45"
        )

        XCTAssertEqual(value, "1.2.3 (45)")
    }

    func testDisplayVersionReturnsVersionAndBuildWhenBuildPresent() {
        let value = AppVersionFormatter.displayVersion(
            shortVersion: "1.2.3",
            buildVersion: "1.2.3"
        )

        XCTAssertEqual(value, "1.2.3 (1.2.3)")
    }

    func testDisplayVersionReturnsUnknownWhenVersionMissing() {
        let value = AppVersionFormatter.displayVersion(
            shortVersion: nil,
            buildVersion: "45"
        )

        XCTAssertEqual(value, String(localized: "settings.app_version.unknown"))
    }

    func testInfoPlistUsesBuildSettingsForVersionValues() throws {
        let testsDirectoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let repositoryRootURL = testsDirectoryURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let infoPlistURL = repositoryRootURL
            .appendingPathComponent("Resources")
            .appendingPathComponent("Info.plist")

        let data = try Data(contentsOf: infoPlistURL)
        let plistObject = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dictionary = plistObject as? [String: Any] else {
            return XCTFail("Info.plist did not decode as dictionary")
        }

        XCTAssertEqual(dictionary["CFBundleShortVersionString"] as? String, "$(MARKETING_VERSION)")
        XCTAssertEqual(dictionary["CFBundleVersion"] as? String, "$(CURRENT_PROJECT_VERSION)")
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
