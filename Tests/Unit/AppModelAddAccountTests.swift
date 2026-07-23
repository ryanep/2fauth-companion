import Foundation
import SwiftData
import XCTest

@testable import TwoFAuth

private actor AsyncGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class AddAccountTestRepository: AccountRepository {
    var syncHandler: () async -> SyncResult = { .success }
    var previewHandler: () throws -> APIAccount = {
        fatalError("Unexpected preview")
    }
    var createHandler: () async throws -> Void = {}
    private(set) var syncCallCount = 0
    private(set) var syncSawCancellation = false
    private(set) var wipeCallCount = 0

    func ensureEncryptionKey() throws {}
    func decryptSecret(_ encryptedSecret: Data) throws -> String { "" }

    func syncAccounts(
        context: ModelContext,
        baseURL: URL,
        apiKey: String,
        includeSecrets: Bool
    ) async -> SyncResult {
        syncCallCount += 1
        syncSawCancellation = syncSawCancellation || Task.isCancelled
        return await syncHandler()
    }

    func previewAccount(baseURL: URL, apiKey: String, uri: String, customOTP: String?) async throws -> APIAccount {
        try previewHandler()
    }

    func createAccount(
        context: ModelContext,
        baseURL: URL,
        apiKey: String,
        requestBody: AccountCreationRequest
    ) async throws {
        try await createHandler()
    }

    func wipeCachedData(context: ModelContext) throws {
        wipeCallCount += 1
    }
}

@MainActor
final class AppModelAddAccountTests: XCTestCase {
    private struct SUT {
        let appModel: AppModel
        let repository: AddAccountTestRepository
        let configStore: UserDefaultsAppConfigStore
        let secretStore: KeychainSecretStore
    }

    override func tearDown() {
        let secretStore = KeychainSecretStore()
        _ = secretStore.deleteAPIKey()
        _ = secretStore.deleteEncryptionKey()
        super.tearDown()
    }

    func testSyncNowSerializesRepositoryRequests() async throws {
        let setup = try makeSUT(testName: #function)
        let firstGate = AsyncGate()
        let secondGate = AsyncGate()
        setup.repository.syncHandler = {
            if setup.repository.syncCallCount == 1 {
                await firstGate.wait()
            } else {
                await secondGate.wait()
            }
            return .success
        }

        let firstSync = Task { await setup.appModel.syncNow() }
        try await waitUntil { setup.repository.syncCallCount == 1 }
        let secondSync = Task { await setup.appModel.syncNow() }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(setup.repository.syncCallCount, 1)

        await firstGate.open()
        _ = await firstSync.value
        try await waitUntil { setup.repository.syncCallCount == 2 }
        await secondGate.open()
        _ = await secondSync.value
    }

    func testCreateForbiddenPreservesAuthenticatedSessionAndCache() async throws {
        let setup = try makeSUT(testName: #function)
        setup.appModel.sessionState = .unlocked
        setup.repository.createHandler = { throw APIError.forbidden }

        do {
            try await setup.appModel.addAccount(preview: validPreview(), service: "Example", account: "person@example.com")
            XCTFail("Expected permission failure")
        } catch let error as AddAccountError {
            XCTAssertNotEqual(error, .authenticationRequired)
        }

        XCTAssertEqual(setup.appModel.sessionState, .unlocked)
        XCTAssertEqual(setup.secretStore.loadAPIKey(), "api-key")
        XCTAssertEqual(setup.repository.wipeCallCount, 0)
    }

    func testPreviewRejectsMissingSecretFromServer() async throws {
        let setup = try makeSUT(testName: #function)
        setup.repository.previewHandler = {
            try self.apiAccount(secret: nil, digits: 6, algorithm: "SHA1", period: 30)
        }

        do {
            _ = try await setup.appModel.previewAccount(uri: validURI)
            XCTFail("Expected invalid response")
        } catch let error as AddAccountError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testPreviewRejectsUnsupportedServerParameters() async throws {
        let setup = try makeSUT(testName: #function)
        setup.repository.previewHandler = {
            try self.apiAccount(secret: "JBSWY3DPEHPK3PXP", digits: 11, algorithm: "SHA3", period: 0)
        }

        do {
            _ = try await setup.appModel.previewAccount(uri: validURI)
            XCTFail("Expected invalid response")
        } catch let error as AddAccountError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    func testCancelledCreationReconcilesWithoutInheritedCancellation() async throws {
        let setup = try makeSUT(testName: #function)
        setup.repository.createHandler = {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            throw CancellationError()
        }

        let creation = Task {
            try await setup.appModel.addAccount(
                preview: validPreview(),
                service: "Example",
                account: "person@example.com"
            )
        }

        do {
            try await creation.value
            XCTFail("Expected uncertain creation outcome")
        } catch let error as AddAccountError {
            XCTAssertEqual(error, .creationOutcomeUnknown)
        }

        XCTAssertEqual(setup.repository.syncCallCount, 1)
        XCTAssertFalse(setup.repository.syncSawCancellation)
    }

    private var validURI: String {
        "otpauth://totp/Example:person@example.com?secret=JBSWY3DPEHPK3PXP&issuer=Example"
    }

    private func validPreview() -> AddAccountPreview {
        AddAccountPreview(
            service: "Example",
            account: "person@example.com",
            icon: nil,
            otpType: "totp",
            digits: 6,
            period: 30,
            algorithm: "SHA1",
            secret: "JBSWY3DPEHPK3PXP"
        )
    }

    private func apiAccount(secret: String?, digits: Int, algorithm: String, period: Int) throws -> APIAccount {
        let secretJSON = secret.map { "\"\($0)\"" } ?? "null"
        let json = """
            {
              "id": 1,
              "service": "Example",
              "account": "person@example.com",
              "otp_type": "totp",
              "secret": \(secretJSON),
              "digits": \(digits),
              "algorithm": "\(algorithm)",
              "period": \(period)
            }
            """
        return try JSONDecoder().decode(APIAccount.self, from: Data(json.utf8))
    }

    private func makeSUT(testName: String) throws -> SUT {
        let container = try makeInMemoryModelContainer()
        let configStore = makeTestConfigStore(testName: testName)
        configStore.baseURLString = "https://example.com"
        let secretStore = KeychainSecretStore()
        try secretStore.saveAPIKey("api-key")
        let repository = AddAccountTestRepository()
        let appModel = AppModel(
            modelContext: ModelContext(container),
            configStore: configStore,
            secretStore: secretStore,
            repository: repository,
            scheduleBackgroundRefresh: {},
            pushWatchSnapshot: {},
            clearWatchSnapshot: {}
        )
        return SUT(appModel: appModel, repository: repository, configStore: configStore, secretStore: secretStore)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition(), clock.now < deadline {
            await Task.yield()
        }
        XCTAssertTrue(condition())
    }
}
