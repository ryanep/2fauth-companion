import Foundation
import BackgroundTasks
import SwiftData
import WatchConnectivity
import XCTest

@testable import TwoFAuth

private final class TestWatchSession: WatchSession {
    var delegate: WCSessionDelegate?
    var isPaired = false
    var isWatchAppInstalled = false
    var activationState: WatchSessionActivationState = .notActivated
    var updateError: Error?

    private(set) var updateContextCallCount = 0
    private(set) var lastApplicationContext: [String: Any]?

    func activate() {}

    func updateApplicationContext(_ applicationContext: [String: Any]) throws {
        updateContextCallCount += 1
        lastApplicationContext = applicationContext
        if let updateError {
            throw updateError
        }
    }
}

@MainActor
final class AppModelStateMachineTests: XCTestCase {
    private struct SUT {
        let appModel: AppModel
        let configStore: UserDefaultsAppConfigStore
        let modelContext: ModelContext
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

    func testBootstrapWithoutSessionConfigurationStartsLoggedOut() async throws {
        let setup = try makeSUT(testName: #function)

        await setup.appModel.bootstrap()

        XCTAssertEqual(setup.appModel.sessionState, .loggedOut)
    }

    func testBootstrapWithSessionConfigurationStartsLocked() async throws {
        let setup = try makeSUT(testName: #function)
        setup.configStore.baseURLString = "https://example.com"
        try secretStore.saveAPIKey("api-key")

        await setup.appModel.bootstrap()

        XCTAssertEqual(setup.appModel.sessionState, .locked)
    }

    func testBootstrapWithReloginFlagStartsReloginRequired() async throws {
        let setup = try makeSUT(testName: #function)
        setup.configStore.baseURLString = "https://example.com"
        try secretStore.saveAPIKey("api-key")
        setup.configStore.requiresRelogin = true

        await setup.appModel.bootstrap()

        XCTAssertEqual(setup.appModel.sessionState, .reloginRequired)
    }

    func testUnlockWithoutSessionConfigurationReturnsToLoggedOut() async throws {
        let setup = try makeSUT(testName: #function)
        setup.appModel.sessionState = .locked

        await setup.appModel.unlock()

        XCTAssertEqual(setup.appModel.sessionState, .loggedOut)
    }

    func testUnlockWithSuccessfulBiometricsTransitionsToUnlocked() async throws {
        let setup = try makeSUT(
            testName: #function,
            biometricAuthenticator: MockBiometricAuthenticator(result: .success(true))
        )
        setup.configStore.baseURLString = "https://example.com"
        try secretStore.saveAPIKey("api-key")
        setup.appModel.sessionState = .locked

        await setup.appModel.unlock()

        XCTAssertEqual(setup.appModel.sessionState, .unlocked)
        XCTAssertNil(setup.appModel.syncMessage)
    }

    func testUnlockWithBiometricFailureSetsMessage() async throws {
        let setup = try makeSUT(
            testName: #function,
            biometricAuthenticator: MockBiometricAuthenticator(result: .failure(NSError(domain: "test", code: 1)))
        )
        setup.configStore.baseURLString = "https://example.com"
        try secretStore.saveAPIKey("api-key")
        setup.appModel.sessionState = .locked

        await setup.appModel.unlock()

        XCTAssertEqual(setup.appModel.sessionState, .locked)
        XCTAssertEqual(setup.appModel.syncMessage, String(localized: "sync.error.biometric_failed"))
    }

    func testSyncNowSuccessKeepsUnlockedAndStoresLastSyncDate() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("[]".utf8))
        }

        let setup = try makeSUT(testName: #function)
        setup.configStore.baseURLString = "https://example.com"
        try secretStore.saveAPIKey("api-key")
        setup.appModel.sessionState = .degradedOffline
        setup.appModel.syncMessage = "offline"

        await setup.appModel.syncNow()

        XCTAssertEqual(setup.appModel.sessionState, .unlocked)
        XCTAssertNil(setup.appModel.syncMessage)
        XCTAssertNotNil(setup.appModel.lastSuccessfulSyncAt)
    }

    func testSyncNowTransportErrorTransitionsToDegradedOffline() async throws {
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        let setup = try makeSUT(testName: #function)
        setup.configStore.baseURLString = "https://example.com"
        try secretStore.saveAPIKey("api-key")
        setup.appModel.sessionState = .unlocked

        await setup.appModel.syncNow()

        XCTAssertEqual(setup.appModel.sessionState, .degradedOffline)
        XCTAssertNotNil(setup.appModel.syncMessage)
    }

    func testSyncNowUnauthorizedTriggersReloginWipe() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let setup = try makeSUT(testName: #function)
        setup.configStore.baseURLString = "https://example.com"
        try secretStore.saveAPIKey("api-key")
        setup.appModel.sessionState = .unlocked

        await setup.appModel.syncNow()

        XCTAssertEqual(setup.appModel.sessionState, .reloginRequired)
        XCTAssertEqual(setup.appModel.syncMessage, String(localized: "sync.status.session_expired"))
        XCTAssertTrue(setup.configStore.requiresRelogin)
        XCTAssertNil(secretStore.loadAPIKey())
        XCTAssertNil(secretStore.loadEncryptionKey())
    }

    func testSyncNowUnauthorizedClearsLastSyncAndKeepsConfiguredBaseURL() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let setup = try makeSUT(testName: #function)
        setup.configStore.baseURLString = "https://example.com"
        setup.configStore.lastSuccessfulSyncAt = Date(timeIntervalSince1970: 12345)
        setup.appModel.lastSuccessfulSyncAt = setup.configStore.lastSuccessfulSyncAt
        setup.appModel.baseURLInput = "https://example.com"
        try secretStore.saveAPIKey("api-key")
        setup.appModel.sessionState = .unlocked

        await setup.appModel.syncNow()

        XCTAssertEqual(setup.appModel.sessionState, .reloginRequired)
        XCTAssertNil(setup.appModel.lastSuccessfulSyncAt)
        XCTAssertNil(setup.configStore.lastSuccessfulSyncAt)
        XCTAssertEqual(setup.appModel.baseURLInput, "https://example.com")
        XCTAssertEqual(setup.configStore.baseURLString, "https://example.com")
    }

    func testLogoutResetsSessionAndClearsStoredData() async throws {
        let setup = try makeSUT(testName: #function)
        setup.configStore.baseURLString = "https://example.com"
        try secretStore.saveAPIKey("api-key")
        setup.configStore.requiresRelogin = true
        setup.appModel.sessionState = .unlocked
        setup.appModel.loginError = "error"
        setup.appModel.syncMessage = "sync"

        let account = AccountEntity(
            remoteID: 1,
            service: "GitHub",
            account: "ryan",
            otpType: "totp",
            digits: 6,
            algorithm: "SHA1",
            period: 30,
            encryptedSecret: nil,
            updatedAt: Date()
        )
        setup.modelContext.insert(account)
        try setup.modelContext.save()

        await setup.appModel.logout()

        XCTAssertEqual(setup.appModel.sessionState, .loggedOut)
        XCTAssertNil(setup.appModel.loginError)
        XCTAssertNil(setup.appModel.syncMessage)
        XCTAssertFalse(setup.configStore.requiresRelogin)
        XCTAssertNil(secretStore.loadAPIKey())
        let fetched = try setup.modelContext.fetch(FetchDescriptor<AccountEntity>())
        XCTAssertTrue(fetched.isEmpty)
    }

    func testLogoutPersistsPendingWatchClearWhenWatchDeliveryCannotRun() async throws {
        let configStore = makeTestConfigStore(testName: #function)
        let watchSession = TestWatchSession()
        let watchManager = WatchSyncManager(session: watchSession, configStore: configStore) { _, _ in }
        let setup = try makeSUT(
            testName: #function,
            configStore: configStore,
            clearWatchSnapshot: {
                watchManager.pushEmptySnapshot()
            }
        )
        setup.configStore.baseURLString = "https://example.com"
        try secretStore.saveAPIKey("api-key")
        setup.appModel.sessionState = .unlocked

        await setup.appModel.logout()

        XCTAssertTrue(setup.configStore.hasPendingWatchClear)
        XCTAssertEqual(watchSession.updateContextCallCount, 0)
    }

    private func makeSUT(
        testName: String,
        configStore: UserDefaultsAppConfigStore? = nil,
        clearWatchSnapshot: @escaping () -> Void = {},
        biometricAuthenticator: any BiometricAuthenticator = MockBiometricAuthenticator(result: .success(true))
    ) throws -> SUT {
        let container = try makeInMemoryModelContainer()
        let context = ModelContext(container)
        let configStore = configStore ?? makeTestConfigStore(testName: testName)
        let apiClient = URLSessionAPIClient(session: makeMockedURLSession())
        let cryptoStore = AESGCMCryptoStore(secretStore: secretStore)
        let repository = DefaultAccountRepository(apiClient: apiClient, cryptoStore: cryptoStore)
        let appModel = AppModel(
            modelContext: context,
            configStore: configStore,
            secretStore: secretStore,
            repository: repository,
            scheduleBackgroundRefresh: {},
            pushWatchSnapshot: {},
            clearWatchSnapshot: clearWatchSnapshot,
            biometricAuthenticator: biometricAuthenticator
        )

        return SUT(appModel: appModel, configStore: configStore, modelContext: context)
    }
}

@MainActor
final class BackgroundSyncManagerBehaviorTests: XCTestCase {
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

    func testRunBackgroundSyncCancelledPreflightReturnsFalse() async throws {
        let setup = try makeSUT(testName: #function)
        setup.configStore.baseURLString = "https://example.com"
        try secretStore.saveAPIKey("api-key")

        let result = await setup.manager.runBackgroundSync(isCancelled: { true })

        XCTAssertFalse(result)
    }

    func testRunBackgroundSyncCancelledAfterNetworkReturnsFalse() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("[]".utf8))
        }

        let setup = try makeSUT(testName: #function)
        setup.configStore.baseURLString = "https://example.com"
        try secretStore.saveAPIKey("api-key")

        var checks = 0
        let result = await setup.manager.runBackgroundSync(isCancelled: {
            checks += 1
            return checks >= 2
        })

        XCTAssertFalse(result)
    }

    func testRunBackgroundSyncUnauthorizedTriggersReloginAndWipesKey() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let setup = try makeSUT(testName: #function)
        setup.configStore.baseURLString = "https://example.com"
        try secretStore.saveAPIKey("api-key")

        let result = await setup.manager.runBackgroundSync(isCancelled: { false })

        XCTAssertTrue(result)
        XCTAssertTrue(setup.configStore.requiresRelogin)
        XCTAssertNil(secretStore.loadAPIKey())
    }

    func testRunBackgroundSyncUnauthorizedPersistsPendingWatchClearWhenWatchDeliveryCannotRun() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let configStore = makeTestConfigStore(testName: #function)
        let watchSession = TestWatchSession()
        let watchManager = WatchSyncManager(session: watchSession, configStore: configStore) { _, _ in }
        let setup = try makeSUT(
            testName: #function,
            configStore: configStore,
            clearWatchSnapshot: {
                watchManager.pushEmptySnapshot()
            }
        )
        setup.configStore.baseURLString = "https://example.com"
        try secretStore.saveAPIKey("api-key")

        let result = await setup.manager.runBackgroundSync(isCancelled: { false })

        XCTAssertTrue(result)
        XCTAssertTrue(setup.configStore.hasPendingWatchClear)
        XCTAssertEqual(watchSession.updateContextCallCount, 0)
    }

    func testRunBackgroundSyncTransientReturnsTrue() async throws {
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.timedOut)
        }

        let setup = try makeSUT(testName: #function)
        setup.configStore.baseURLString = "https://example.com"
        try secretStore.saveAPIKey("api-key")

        let result = await setup.manager.runBackgroundSync(isCancelled: { false })

        XCTAssertTrue(result)
        XCTAssertFalse(setup.configStore.requiresRelogin)
        XCTAssertNotNil(secretStore.loadAPIKey())
    }

    func testRunBackgroundSyncSkipsHTTPWhenPolicyIsSecureOnly() async throws {
        let setup = try makeSUT(testName: #function)
        setup.configStore.baseURLString = "http://example.com"
        setup.configStore.transportPolicy = .secureOnly
        try secretStore.saveAPIKey("api-key")

        let result = await setup.manager.runBackgroundSync(isCancelled: { false })

        XCTAssertTrue(result)
        XCTAssertFalse(setup.configStore.requiresRelogin)
        XCTAssertNotNil(secretStore.loadAPIKey())
    }

    func testRunBackgroundSyncAllowsHTTPWhenPolicyAllowsHTTP() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("[]".utf8))
        }

        let setup = try makeSUT(testName: #function)
        setup.configStore.baseURLString = "http://example.com"
        setup.configStore.transportPolicy = .allowHTTP
        try secretStore.saveAPIKey("api-key")

        let result = await setup.manager.runBackgroundSync(isCancelled: { false })

        XCTAssertTrue(result)
        XCTAssertFalse(setup.configStore.requiresRelogin)
        XCTAssertNotNil(secretStore.loadAPIKey())
    }

    func testRunBackgroundSyncSkipsInvalidBaseURL() async throws {
        let setup = try makeSUT(testName: #function)
        setup.configStore.baseURLString = "not-a-url"
        try secretStore.saveAPIKey("api-key")

        let result = await setup.manager.runBackgroundSync(isCancelled: { false })

        XCTAssertTrue(result)
        XCTAssertFalse(setup.configStore.requiresRelogin)
        XCTAssertNotNil(secretStore.loadAPIKey())
    }

    private func makeSUT(
        testName: String,
        configStore: UserDefaultsAppConfigStore? = nil,
        clearWatchSnapshot: @escaping () -> Void = {}
    ) throws -> (manager: BackgroundSyncManager, configStore: UserDefaultsAppConfigStore) {
        let container = try makeInMemoryModelContainer()
        let configStore = configStore ?? makeTestConfigStore(testName: testName)
        let apiClient = URLSessionAPIClient(session: makeMockedURLSession())
        let repository = DefaultAccountRepository(
            apiClient: apiClient,
            cryptoStore: AESGCMCryptoStore(secretStore: secretStore)
        )
        let manager = BackgroundSyncManager(
            modelContainer: container,
            configStore: configStore,
            secretStore: secretStore,
            repository: repository,
            clearWatchSnapshot: clearWatchSnapshot
        )
        return (manager, configStore)
    }
}

@MainActor
final class BackgroundSyncManagerDiagnosticsTests: XCTestCase {
    private struct ReportEvent: Equatable {
        let event: String
        let metadata: [String: String]
    }

    private final class MockBackgroundTaskScheduler: BackgroundTaskScheduling {
        var registerResult = true
        var submitError: Error?

        func register(
            forTaskWithIdentifier identifier: String,
            using queue: DispatchQueue?,
            launchHandler: @escaping (BGTask) -> Void
        ) -> Bool {
            registerResult
        }

        func submit(_ taskRequest: BGTaskRequest) throws {
            if let submitError {
                throw submitError
            }
        }
    }

    nonisolated(unsafe) private let secretStore = KeychainSecretStore()

    override func setUp() {
        super.setUp()
        _ = secretStore.deleteAPIKey()
        _ = secretStore.deleteEncryptionKey()
    }

    override func tearDown() {
        _ = secretStore.deleteAPIKey()
        _ = secretStore.deleteEncryptionKey()
        super.tearDown()
    }

    func testRegisterReportsFailureWhenSchedulerRejectsIdentifier() async throws {
        let scheduler = MockBackgroundTaskScheduler()
        scheduler.registerResult = false
        var reported: [ReportEvent] = []
        let manager = try makeSUT(scheduler: scheduler) { event, metadata in
            reported.append(ReportEvent(event: event, metadata: metadata))
        }

        manager.register()

        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(
            reported.first,
            ReportEvent(
                event: "background.register_failed",
                metadata: ["taskIdentifier": BackgroundSyncManager.taskIdentifier]
            )
        )
    }

    func testScheduleReportsSubmitFailureWithIdentifierAndError() async throws {
        let scheduler = MockBackgroundTaskScheduler()
        scheduler.submitError = NSError(domain: "test", code: 99, userInfo: [NSLocalizedDescriptionKey: "submit failed"])
        var reported: [ReportEvent] = []
        let manager = try makeSUT(scheduler: scheduler) { event, metadata in
            reported.append(ReportEvent(event: event, metadata: metadata))
        }

        manager.scheduleAppRefresh()

        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(reported.first?.event, "background.schedule_submit_failed")
        XCTAssertEqual(reported.first?.metadata["taskIdentifier"], BackgroundSyncManager.taskIdentifier)
        XCTAssertEqual(reported.first?.metadata["error"], "submit failed")
    }

    private func makeSUT(
        scheduler: any BackgroundTaskScheduling,
        report: @escaping (String, [String: String]) -> Void
    ) throws -> BackgroundSyncManager {
        let container = try makeInMemoryModelContainer()
        let configStore = makeTestConfigStore(testName: #function)
        let apiClient = URLSessionAPIClient(session: makeMockedURLSession())
        let repository = DefaultAccountRepository(
            apiClient: apiClient,
            cryptoStore: AESGCMCryptoStore(secretStore: secretStore)
        )
        return BackgroundSyncManager(
            modelContainer: container,
            configStore: configStore,
            secretStore: secretStore,
            repository: repository,
            taskScheduler: scheduler,
            report: report
        )
    }
}

@MainActor
final class WatchSyncManagerTests: XCTestCase {
    private struct ReportEvent: Equatable {
        let event: String
        let metadata: [String: String]
    }

    func testPushEmptySnapshotSkipsWhenSessionNotPaired() {
        let session = TestWatchSession()
        session.isPaired = false
        session.isWatchAppInstalled = true
        session.activationState = .activated
        var reported: [ReportEvent] = []
        let manager = WatchSyncManager(session: session) { event, metadata in
            reported.append(ReportEvent(event: event, metadata: metadata))
        }

        manager.pushEmptySnapshot()

        XCTAssertEqual(session.updateContextCallCount, 0)
        XCTAssertEqual(reported.last?.event, "watch.sync_skipped_not_paired")
    }

    func testPushEmptySnapshotSkipsWhenSessionNotActivated() {
        let session = TestWatchSession()
        session.isPaired = true
        session.isWatchAppInstalled = true
        session.activationState = .inactive
        var reported: [ReportEvent] = []
        let manager = WatchSyncManager(session: session) { event, metadata in
            reported.append(ReportEvent(event: event, metadata: metadata))
        }

        manager.pushEmptySnapshot()

        XCTAssertEqual(session.updateContextCallCount, 0)
        XCTAssertEqual(reported.last?.event, "watch.sync_skipped_not_activated")
        XCTAssertEqual(reported.last?.metadata["state"], "inactive")
    }

    func testPushEmptySnapshotReportsWhenUpdateContextThrows() {
        let session = TestWatchSession()
        session.isPaired = true
        session.isWatchAppInstalled = true
        session.activationState = .activated
        session.updateError = NSError(domain: "test", code: 9, userInfo: [NSLocalizedDescriptionKey: "boom"])
        var reported: [ReportEvent] = []
        let manager = WatchSyncManager(session: session) { event, metadata in
            reported.append(ReportEvent(event: event, metadata: metadata))
        }

        manager.pushEmptySnapshot()

        XCTAssertEqual(session.updateContextCallCount, 1)
        XCTAssertEqual(reported.last?.event, "watch.sync_update_context_failed")
        XCTAssertEqual(reported.last?.metadata["error"], "boom")
    }

    func testPushEmptySnapshotPersistsPendingClearWhenDeliveryFails() {
        let session = TestWatchSession()
        session.isPaired = true
        session.isWatchAppInstalled = true
        session.activationState = .activated
        session.updateError = NSError(domain: "test", code: 9, userInfo: [NSLocalizedDescriptionKey: "boom"])
        let configStore = makeTestConfigStore(testName: #function)
        let manager = WatchSyncManager(session: session, configStore: configStore) { _, _ in }

        manager.pushEmptySnapshot()

        XCTAssertTrue(configStore.hasPendingWatchClear)
    }

    func testPushEmptySnapshotUpdatesContextWhenSessionReady() {
        let session = TestWatchSession()
        session.isPaired = true
        session.isWatchAppInstalled = true
        session.activationState = .activated
        var reported: [ReportEvent] = []
        let manager = WatchSyncManager(session: session) { event, metadata in
            reported.append(ReportEvent(event: event, metadata: metadata))
        }

        manager.pushEmptySnapshot()

        XCTAssertEqual(session.updateContextCallCount, 1)
        XCTAssertEqual(reported.last?.event, "watch.sync_updated_context")
        XCTAssertEqual(reported.last?.metadata["accountCount"], "0")
    }

    func testPushEmptySnapshotRetriesAfterSessionActivationCompletes() {
        let session = TestWatchSession()
        session.isPaired = true
        session.isWatchAppInstalled = true
        session.activationState = .notActivated
        var reported: [ReportEvent] = []
        let manager = WatchSyncManager(session: session) { event, metadata in
            reported.append(ReportEvent(event: event, metadata: metadata))
        }

        manager.pushEmptySnapshot()

        XCTAssertEqual(session.updateContextCallCount, 0)
        XCTAssertEqual(reported.last?.event, "watch.sync_skipped_not_activated")

        session.activationState = .activated
        manager.session(WCSession.default, activationDidCompleteWith: .activated, error: nil)

        XCTAssertEqual(session.updateContextCallCount, 1)
        XCTAssertEqual(reported.last?.event, "watch.sync_updated_context")
        XCTAssertEqual(reported.last?.metadata["accountCount"], "0")
    }

    func testPushEmptySnapshotRetriesWhenWatchStateChangesToPaired() {
        let session = TestWatchSession()
        session.isPaired = false
        session.isWatchAppInstalled = true
        session.activationState = .activated
        var reported: [ReportEvent] = []
        let manager = WatchSyncManager(session: session) { event, metadata in
            reported.append(ReportEvent(event: event, metadata: metadata))
        }

        manager.pushEmptySnapshot()

        XCTAssertEqual(session.updateContextCallCount, 0)
        XCTAssertEqual(reported.last?.event, "watch.sync_skipped_not_paired")

        session.isPaired = true
        manager.sessionWatchStateDidChange(WCSession.default)

        XCTAssertEqual(session.updateContextCallCount, 1)
        XCTAssertEqual(reported.last?.event, "watch.sync_updated_context")
        XCTAssertEqual(reported.last?.metadata["accountCount"], "0")
    }

    func testResumePendingSyncIfNeededRetriesPersistedWatchClearAndClearsFlagOnSuccess() {
        let session = TestWatchSession()
        session.isPaired = true
        session.isWatchAppInstalled = true
        session.activationState = .activated
        let configStore = makeTestConfigStore(testName: #function)
        configStore.hasPendingWatchClear = true
        let manager = WatchSyncManager(session: session, configStore: configStore) { _, _ in }

        manager.resumePendingSyncIfNeeded()

        XCTAssertEqual(session.updateContextCallCount, 1)
        XCTAssertFalse(configStore.hasPendingWatchClear)

        let snapshotData = try? XCTUnwrap(session.lastApplicationContext?["snapshot"] as? Data)
        let payload = try? snapshotData.map { try WatchSnapshotPayload.decodeSupported(from: $0) }
        XCTAssertEqual(payload?.accounts.count, 0)
    }

    func testResumePendingSyncIfNeededPrefersNewerPendingSnapshotOverStalePersistedClear() throws {
        let session = TestWatchSession()
        session.isPaired = false
        session.isWatchAppInstalled = true
        session.activationState = .activated
        let configStore = makeTestConfigStore(testName: #function)
        configStore.hasPendingWatchClear = true
        let manager = WatchSyncManager(session: session, configStore: configStore) { _, _ in }
        let container = try makeInMemoryModelContainer()
        let secretStore = KeychainSecretStore()
        let cryptoStore = AESGCMCryptoStore(secretStore: secretStore)
        let repository = DefaultAccountRepository(
            apiClient: URLSessionAPIClient(session: makeMockedURLSession()),
            cryptoStore: cryptoStore
        )
        let context = container.mainContext

        let encryptedSecret = try cryptoStore.encrypt("JBSWY3DPEHPK3PXP")
        context.insert(
            AccountEntity(
                remoteID: 1,
                service: "GitHub",
                account: "ryan",
                otpType: "totp",
                digits: 6,
                algorithm: "SHA1",
                period: 30,
                encryptedSecret: encryptedSecret,
                updatedAt: .init()
            )
        )
        try context.save()

        manager.pushLatestSnapshot(from: context, repository: repository)
        session.isPaired = true

        manager.resumePendingSyncIfNeeded()

        XCTAssertEqual(session.updateContextCallCount, 1)
        let snapshotData = try XCTUnwrap(session.lastApplicationContext?["snapshot"] as? Data)
        let payload = try WatchSnapshotPayload.decodeSupported(from: snapshotData)
        XCTAssertEqual(payload.accounts.count, 1)
        XCTAssertEqual(payload.accounts.map(\.account), ["ryan"])
        XCTAssertFalse(configStore.hasPendingWatchClear)
    }

    func testPushLatestSnapshotClearsStalePendingWatchClearAfterSuccessfulDelivery() throws {
        let session = TestWatchSession()
        session.isPaired = true
        session.isWatchAppInstalled = true
        session.activationState = .activated
        let configStore = makeTestConfigStore(testName: #function)
        configStore.hasPendingWatchClear = true
        let manager = WatchSyncManager(session: session, configStore: configStore) { _, _ in }
        let container = try makeInMemoryModelContainer()
        let secretStore = KeychainSecretStore()
        let cryptoStore = AESGCMCryptoStore(secretStore: secretStore)
        let repository = DefaultAccountRepository(
            apiClient: URLSessionAPIClient(session: makeMockedURLSession()),
            cryptoStore: cryptoStore
        )
        let context = container.mainContext

        let encryptedSecret = try cryptoStore.encrypt("JBSWY3DPEHPK3PXP")
        context.insert(
            AccountEntity(
                remoteID: 1,
                service: "GitHub",
                account: "ryan",
                otpType: "totp",
                digits: 6,
                algorithm: "SHA1",
                period: 30,
                encryptedSecret: encryptedSecret,
                updatedAt: .init()
            )
        )
        try context.save()

        manager.pushLatestSnapshot(from: context, repository: repository)
        manager.resumePendingSyncIfNeeded()

        XCTAssertEqual(session.updateContextCallCount, 1)
        XCTAssertFalse(configStore.hasPendingWatchClear)

        let snapshotData = try XCTUnwrap(session.lastApplicationContext?["snapshot"] as? Data)
        let payload = try WatchSnapshotPayload.decodeSupported(from: snapshotData)
        XCTAssertEqual(payload.accounts.count, 1)
        XCTAssertEqual(payload.accounts.map(\.account), ["ryan"])
    }

    func testPushLatestSnapshotPreservesAlgorithmForNonDefaultTOTPAccount() throws {
        let session = TestWatchSession()
        session.isPaired = true
        session.isWatchAppInstalled = true
        session.activationState = .activated
        let manager = WatchSyncManager(session: session) { _, _ in }
        let container = try makeInMemoryModelContainer()
        let secretStore = KeychainSecretStore()
        let cryptoStore = AESGCMCryptoStore(secretStore: secretStore)
        let repository = DefaultAccountRepository(
            apiClient: URLSessionAPIClient(session: makeMockedURLSession()),
            cryptoStore: cryptoStore
        )
        let context = container.mainContext

        let encryptedSecret = try cryptoStore.encrypt("JBSWY3DPEHPK3PXP")
        context.insert(
            AccountEntity(
                remoteID: 1,
                service: "TOTP",
                account: "totp-user",
                otpType: "totp",
                digits: 8,
                algorithm: "SHA512",
                period: 30,
                encryptedSecret: encryptedSecret,
                updatedAt: .init()
            )
        )
        try context.save()

        manager.pushLatestSnapshot(from: context, repository: repository)

        let snapshotData = try XCTUnwrap(session.lastApplicationContext?["snapshot"] as? Data)
        let object = try JSONSerialization.jsonObject(with: snapshotData)
        guard let dictionary = object as? [String: Any],
            let accounts = dictionary["accounts"] as? [[String: Any]],
            let firstAccount = accounts.first
        else {
            return XCTFail("Expected dictionary JSON with accounts")
        }

        XCTAssertEqual(firstAccount["algorithm"] as? String, "SHA512")
    }

    func testPushLatestSnapshotExcludesHOTPAccounts() throws {
        let session = TestWatchSession()
        session.isPaired = true
        session.isWatchAppInstalled = true
        session.activationState = .activated
        let manager = WatchSyncManager(session: session) { _, _ in }
        let container = try makeInMemoryModelContainer()
        let secretStore = KeychainSecretStore()
        let cryptoStore = AESGCMCryptoStore(secretStore: secretStore)
        let repository = DefaultAccountRepository(
            apiClient: URLSessionAPIClient(session: makeMockedURLSession()),
            cryptoStore: cryptoStore
        )
        let context = container.mainContext

        let encryptedSecret = try cryptoStore.encrypt("JBSWY3DPEHPK3PXP")
        context.insert(
            AccountEntity(
                remoteID: 1,
                service: "TOTP",
                account: "totp-user",
                otpType: "totp",
                digits: 6,
                algorithm: "SHA1",
                period: 30,
                encryptedSecret: encryptedSecret,
                updatedAt: .init()
            )
        )
        context.insert(
            AccountEntity(
                remoteID: 2,
                service: "HOTP",
                account: "hotp-user",
                otpType: "hotp",
                digits: 6,
                algorithm: "SHA1",
                period: 30,
                encryptedSecret: encryptedSecret,
                updatedAt: .init()
            )
        )
        try context.save()

        manager.pushLatestSnapshot(from: context, repository: repository)

        let snapshotData = try XCTUnwrap(session.lastApplicationContext?["snapshot"] as? Data)
        let payload = try WatchSnapshotPayload.decodeSupported(from: snapshotData)
        XCTAssertEqual(payload.accounts.map(\.otpType), ["totp"])
        XCTAssertEqual(payload.accounts.map(\.account), ["totp-user"])
    }

    func testPushLatestSnapshotSortsAccountsUsingDisplayOrder() throws {
        let session = TestWatchSession()
        session.isPaired = true
        session.isWatchAppInstalled = true
        session.activationState = .activated
        let manager = WatchSyncManager(session: session) { _, _ in }
        let container = try makeInMemoryModelContainer()
        let secretStore = KeychainSecretStore()
        let cryptoStore = AESGCMCryptoStore(secretStore: secretStore)
        let repository = DefaultAccountRepository(
            apiClient: URLSessionAPIClient(session: makeMockedURLSession()),
            cryptoStore: cryptoStore
        )
        let context = container.mainContext

        let encryptedSecret = try cryptoStore.encrypt("JBSWY3DPEHPK3PXP")
        context.insert(
            AccountEntity(
                remoteID: 1,
                service: "Zulu",
                account: "bravo@example.com",
                otpType: "totp",
                digits: 6,
                algorithm: "SHA1",
                period: 30,
                encryptedSecret: encryptedSecret,
                updatedAt: .init()
            )
        )
        context.insert(
            AccountEntity(
                remoteID: 2,
                service: "Alpha",
                account: "charlie@example.com",
                otpType: "totp",
                digits: 6,
                algorithm: "SHA1",
                period: 30,
                encryptedSecret: encryptedSecret,
                updatedAt: .init()
            )
        )
        context.insert(
            AccountEntity(
                remoteID: 3,
                service: "Alpha",
                account: "able@example.com",
                otpType: "totp",
                digits: 6,
                algorithm: "SHA1",
                period: 30,
                encryptedSecret: encryptedSecret,
                updatedAt: .init()
            )
        )
        try context.save()

        manager.pushLatestSnapshot(from: context, repository: repository)

        let snapshotData = try XCTUnwrap(session.lastApplicationContext?["snapshot"] as? Data)
        let payload = try WatchSnapshotPayload.decodeSupported(from: snapshotData)

        XCTAssertEqual(payload.accounts.map(\.service), ["Alpha", "Alpha", "Zulu"])
        XCTAssertEqual(payload.accounts.map(\.account), ["able@example.com", "charlie@example.com", "bravo@example.com"])
    }
}

private struct MockBiometricAuthenticator: BiometricAuthenticator {
    let result: Result<Bool, Error>

    @MainActor
    func authenticate(reason: String) async throws -> Bool {
        try result.get()
    }
}
