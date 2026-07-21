import XCTest

@testable import TwoFAuth

final class TwoFAuthTests: XCTestCase {
    @MainActor
    func testWatchAccountStoreClearsInvalidPersistedMetadataOnLoad() {
        let defaults = makeWatchDefaults(testName: #function)
        let secretStore = makeWatchSecretStore(testName: #function)
        defaults.set(Data("not-json".utf8), forKey: "watch.account.metadata")
        defaults.set(42.0, forKey: "watch.snapshot.generatedAt")
        XCTAssertTrue(secretStore.saveSecret("SECRET", id: 1))

        let store = WatchAccountStore(defaults: defaults, secretStore: secretStore)

        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertNil(store.generatedAt)
        XCTAssertNil(defaults.object(forKey: "watch.account.metadata"))
        XCTAssertNil(defaults.object(forKey: "watch.snapshot.generatedAt"))
        XCTAssertNil(secretStore.loadSecret(id: 1))
    }

    @MainActor
    func testWatchAccountStoreClearsPersistedStateForUnsupportedIncomingSnapshot() throws {
        let defaults = makeWatchDefaults(testName: #function)
        let secretStore = makeWatchSecretStore(testName: #function)
        seedWatchState(defaults: defaults, secretStore: secretStore, generatedAt: 42)
        let store = WatchAccountStore(defaults: defaults, secretStore: secretStore)

        XCTAssertEqual(store.accounts.map(\.account), ["user@example.com"])
        XCTAssertNotNil(store.generatedAt)
        XCTAssertEqual(secretStore.loadSecret(id: 1), "SECRET")

        let json = """
        {
          "schemaVersion": 2,
          "generatedAt": 1,
          "accounts": []
        }
        """

        store.handleApplicationContext(["snapshot": Data(json.utf8)])

        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertNil(store.generatedAt)
        XCTAssertNil(defaults.object(forKey: "watch.account.metadata"))
        XCTAssertNil(defaults.object(forKey: "watch.snapshot.generatedAt"))
        XCTAssertNil(secretStore.loadSecret(id: 1))
    }

    func testTOTPVector() {
        let secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
        let date = Date(timeIntervalSince1970: 59)

        let otp = TOTPGenerator.generate(secret: secret, digits: .eight, period: 30, at: date)

        XCTAssertEqual(otp, "94287082")
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

    func testPendingWatchClearPersistsAcrossStoreInstances() {
        let store = makeConfigStore(testName: #function)

        XCTAssertFalse(store.hasPendingWatchClear)

        store.hasPendingWatchClear = true

        let reloadedStore = makeConfigStore(testName: #function, reset: false)
        XCTAssertTrue(reloadedStore.hasPendingWatchClear)
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

    func testWatchSnapshotDecodeDefaultsMissingSchemaVersionToOne() throws {
        let json = """
        {
          "generatedAt": 1,
          "accounts": []
        }
        """

        let payload = try WatchSnapshotPayload.decodeSupported(
            from: Data(json.utf8),
            supportedSchemaVersion: 1
        )

        XCTAssertEqual(payload.schemaVersion, 1)
    }

    func testWatchSnapshotDecodeRejectsUnsupportedSchemaVersion() {
        let json = """
        {
          "schemaVersion": 2,
          "generatedAt": 1,
          "accounts": []
        }
        """

        XCTAssertThrowsError(
            try WatchSnapshotPayload.decodeSupported(
                from: Data(json.utf8),
                supportedSchemaVersion: 1
            )
        ) { error in
            guard case WatchSnapshotDecodeError.unsupportedSchemaVersion(let version) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(version, 2)
        }
    }

    func testWatchSnapshotDecodeSupportsISO8601GeneratedAt() throws {
        let json = """
        {
          "schemaVersion": 1,
          "generatedAt": "2026-04-11T21:00:00Z",
          "accounts": []
        }
        """

        let payload = try WatchSnapshotPayload.decodeSupported(
            from: Data(json.utf8),
            supportedSchemaVersion: 1
        )

        XCTAssertEqual(payload.schemaVersion, 1)
    }

    func testWatchSnapshotEncodeUsesNumericGeneratedAt() throws {
        let payload = WatchSnapshotPayload(
            generatedAt: Date(timeIntervalSince1970: 42),
            accounts: []
        )

        let data = try WatchSnapshotPayload.encodeForSync(payload)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            return XCTFail("Expected dictionary JSON")
        }

        XCTAssertEqual(dictionary["generatedAt"] as? Double, 42)
    }

    func testWatchSnapshotEncodePreservesAccountAlgorithm() throws {
        let payload = WatchSnapshotPayload(
            generatedAt: Date(timeIntervalSince1970: 42),
            accounts: [
                WatchAccountPayload(
                    id: 1,
                    service: "Example",
                    account: "user@example.com",
                    otpType: "totp",
                    digits: 8,
                    algorithm: "SHA512",
                    period: 30,
                    secret: "SECRET"
                )
            ]
        )

        let data = try WatchSnapshotPayload.encodeForSync(payload)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any],
            let accounts = dictionary["accounts"] as? [[String: Any]],
            let firstAccount = accounts.first
        else {
            return XCTFail("Expected dictionary JSON with accounts")
        }

        XCTAssertEqual(firstAccount["algorithm"] as? String, "SHA512")
    }

    func testWatchE2EScriptLaunchesWatchAppBeforeSyncPrep() throws {
        let testsDirectoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let repositoryRootURL = testsDirectoryURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = repositoryRootURL
            .appendingPathComponent("Scripts")
            .appendingPathComponent("e2e")
            .appendingPathComponent("watch-e2e-live.sh")

        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let buildStep = "xcodebuild build -project \"2FAuth.xcodeproj\" -scheme \"2FAuthWatch\" -destination \"platform=watchOS Simulator,id=${WATCH_SIM_ID}\" -derivedDataPath \"$WATCH_BUILD_DIR\""
        let installStep = "xcrun simctl install \"$WATCH_SIM_ID\" \"$WATCH_APP_PATH\""
        let launchStep = "xcrun simctl launch \"$WATCH_SIM_ID\" \"com.ryanep.2fauth.watchkitapp\" >/dev/null"
        let launchFallback = "xcrun simctl launch \"$WATCH_SIM_ID\" \"com.ryanep.2fauth.watchkitapp\" >/dev/null 2>&1 || true"
        let syncPrepStep = "-only-testing:2FAuthUITests/TwoFAuthUITests/testLiveLoginPublishesWatchSyncMarker"
        let watchAssertionStep = "xcodebuild test -project \"2FAuth.xcodeproj\" -scheme \"2FAuthWatch\" -destination \"platform=watchOS Simulator,id=${WATCH_SIM_ID}\""

        guard let buildRange = script.range(of: buildStep) else {
            return XCTFail("Expected watch build step in watch-e2e-live.sh")
        }
        guard let installRange = script.range(of: installStep) else {
            return XCTFail("Expected watch install step in watch-e2e-live.sh")
        }
        guard let launchRange = script.range(of: launchStep) else {
            return XCTFail("Expected watch launch step in watch-e2e-live.sh")
        }
        guard let syncPrepRange = script.range(of: syncPrepStep) else {
            return XCTFail("Expected sync prep step in watch-e2e-live.sh")
        }
        guard let watchAssertionRange = script.range(of: watchAssertionStep) else {
            return XCTFail("Expected final watch assertion step in watch-e2e-live.sh")
        }
        XCTAssertNil(script.range(of: launchFallback))

        XCTAssertLessThan(buildRange.lowerBound, installRange.lowerBound)
        XCTAssertLessThan(installRange.lowerBound, launchRange.lowerBound)
        XCTAssertLessThan(launchRange.lowerBound, syncPrepRange.lowerBound)
        XCTAssertLessThan(syncPrepRange.lowerBound, watchAssertionRange.lowerBound)
    }

    func testE2ESeedAccountsUseUniqueMatchingSecrets() throws {
        let testsDirectoryURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repositoryRootURL = testsDirectoryURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = repositoryRootURL
            .appendingPathComponent("Scripts/e2e/local-2fauth-reset.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        let fieldPattern = try NSRegularExpression(pattern: #"'secret' => '([A-Z2-7]+)',"#)
        let uriPattern = try NSRegularExpression(pattern: #"legacy_uri'.*secret=([A-Z2-7]+)(?:&|')"#)
        let range = NSRange(script.startIndex..., in: script)

        let malformedField = "'secret' => 'JBSWY3DPEHPK3PXP'INVALID,"
        let malformedURI = "'legacy_uri' => 'otpauth://totp/Example:user?secret=JBSWY3DPEHPK3PXP!&issuer=Example',"
        XCTAssertEqual(
            fieldPattern.numberOfMatches(
                in: malformedField,
                range: NSRange(malformedField.startIndex..., in: malformedField)
            ),
            0
        )
        XCTAssertEqual(
            uriPattern.numberOfMatches(
                in: malformedURI,
                range: NSRange(malformedURI.startIndex..., in: malformedURI)
            ),
            0
        )

        func captures(for pattern: NSRegularExpression) -> [String] {
            pattern.matches(in: script, range: range).compactMap { match in
                guard let captureRange = Range(match.range(at: 1), in: script) else { return nil }
                return String(script[captureRange])
            }
        }

        let fieldSecrets = captures(for: fieldPattern)
        let uriSecrets = captures(for: uriPattern)

        XCTAssertEqual(fieldSecrets.count, 12)
        XCTAssertEqual(uriSecrets.count, 12)
        XCTAssertEqual(Set(fieldSecrets).count, 12)
        XCTAssertEqual(uriSecrets, fieldSecrets)
    }

    private func makeConfigStore(testName: String, reset: Bool = true) -> UserDefaultsAppConfigStore {
        let suiteName = "TwoFAuthTests.\(testName)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Could not create UserDefaults test suite")
        }
        if reset {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return UserDefaultsAppConfigStore(defaults: defaults)
    }

    private func makeWatchDefaults(testName: String) -> UserDefaults {
        let suiteName = "TwoFAuthTests.Watch.\(testName)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Could not create Watch UserDefaults test suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeWatchSecretStore(testName: String) -> WatchSecretStore {
        WatchSecretStore(service: "com.ryanep.2fauth.watch.secretstore.tests.\(testName)") { _, _, _ in }
    }

    private func seedWatchState(defaults: UserDefaults, secretStore: WatchSecretStore, generatedAt: TimeInterval) {
        let metadataJSON = """
        [
          {
            "id": 1,
            "service": "Example",
            "account": "user@example.com",
            "otpType": "totp",
            "digits": 6,
            "algorithm": "SHA1",
            "period": 30
          }
        ]
        """
        defaults.set(Data(metadataJSON.utf8), forKey: "watch.account.metadata")
        defaults.set(generatedAt, forKey: "watch.snapshot.generatedAt")
        XCTAssertTrue(secretStore.saveSecret("SECRET", id: 1))
    }
}
