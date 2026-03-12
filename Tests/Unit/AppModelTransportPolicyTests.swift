import Foundation
import SwiftData
import XCTest

@testable import TwoFAuth

@MainActor
final class AppModelTransportPolicyTests: XCTestCase {
    private struct SUT {
        let appModel: AppModel
        let configStore: UserDefaultsAppConfigStore
    }

    nonisolated(unsafe) private let secretStore = KeychainSecretStore()

    override func setUp() {
        super.setUp()
        _ = secretStore.deleteAPIKey()
        _ = secretStore.deleteEncryptionKey()
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        _ = secretStore.deleteAPIKey()
        _ = secretStore.deleteEncryptionKey()
        super.tearDown()
    }

    func testBootstrapWithHTTPConfigurationStartsLockedWhenPolicyAllowsHTTP() async throws {
        let setup = try makeSUT(testName: #function)
        setup.configStore.baseURLString = "http://example.com"
        setup.configStore.transportPolicy = .allowHTTP
        try secretStore.saveAPIKey("api-key")

        await setup.appModel.bootstrap()

        XCTAssertEqual(setup.appModel.sessionState, .locked)
    }

    func testBootstrapWithHTTPConfigurationStartsLoggedOutWhenPolicyIsSecureOnly() async throws {
        let setup = try makeSUT(testName: #function)
        setup.configStore.baseURLString = "http://example.com"
        setup.configStore.transportPolicy = .secureOnly
        try secretStore.saveAPIKey("api-key")

        await setup.appModel.bootstrap()

        XCTAssertEqual(setup.appModel.sessionState, .loggedOut)
    }

    func testSyncNowWithHTTPAndSecureOnlyPolicyLogsOut() async throws {
        let setup = try makeSUT(testName: #function)
        setup.configStore.baseURLString = "http://example.com"
        setup.configStore.transportPolicy = .secureOnly
        try secretStore.saveAPIKey("api-key")
        setup.appModel.sessionState = .unlocked

        await setup.appModel.syncNow()

        XCTAssertEqual(setup.appModel.sessionState, .loggedOut)
    }

    func testSyncNowWithHTTPAndAllowHTTPPolicyUsesURLAndTransitionsOfflineOnTransportError() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.scheme, "http")
            throw URLError(.notConnectedToInternet)
        }

        let setup = try makeSUT(testName: #function)
        setup.configStore.baseURLString = "http://example.com"
        setup.configStore.transportPolicy = .allowHTTP
        try secretStore.saveAPIKey("api-key")
        setup.appModel.sessionState = .unlocked

        await setup.appModel.syncNow()

        XCTAssertEqual(setup.appModel.sessionState, .degradedOffline)
    }

    func testAttemptLoginWithHTTPBaseURLRejectedWhenPolicyIsSecureOnly() async throws {
        let setup = try makeSUT(testName: #function)
        setup.configStore.transportPolicy = .secureOnly
        setup.appModel.baseURLInput = "http://example.com"

        await setup.appModel.attemptLogin(apiKey: "api-key")

        XCTAssertEqual(setup.appModel.loginError, String(localized: "login.error.invalid_base_url"))
    }

    func testDefaultTransportPolicyAllowsHTTP() {
        let configStore = makeTestConfigStore(testName: #function)

        XCTAssertEqual(configStore.transportPolicy, .allowHTTP)
    }

    private func makeSUT(testName: String) throws -> SUT {
        let container = try makeInMemoryModelContainer()
        let context = ModelContext(container)
        let configStore = makeTestConfigStore(testName: testName)
        let apiClient = URLSessionAPIClient(session: makeMockedURLSession())
        let cryptoStore = AESGCMCryptoStore(secretStore: secretStore)
        let repository = DefaultAccountRepository(apiClient: apiClient, cryptoStore: cryptoStore)
        let appModel = AppModel(
            modelContext: context,
            configStore: configStore,
            secretStore: secretStore,
            repository: repository,
            scheduleBackgroundRefresh: {},
            biometricAuthenticator: FixedBiometricAuthenticator()
        )

        return SUT(appModel: appModel, configStore: configStore)
    }
}

private struct FixedBiometricAuthenticator: BiometricAuthenticator {
    @MainActor
    func authenticate(reason: String) async throws -> Bool {
        true
    }
}
