import Foundation
import SwiftData
import XCTest

#if canImport(UIKit)
    import UIKit
#endif

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
    var previewHandler: () async throws -> APIAccount = {
        fatalError("Unexpected preview")
    }
    var createHandler: () async throws -> Void = {}
    var createdAccount: AccountEntity?
    private(set) var syncCallCount = 0
    private(set) var syncSawCancellation = false
    private(set) var wipeCallCount = 0

    func ensureEncryptionKey() throws {}
    func decryptSecret(_ encryptedSecret: Data) throws -> String { "" }

    func syncAccounts(
        context: ModelContext,
        baseURL: URL,
        apiKey: String,
        includeSecrets: Bool,
        isCurrentSession: @escaping () -> Bool
    ) async -> SyncResult {
        syncCallCount += 1
        syncSawCancellation = syncSawCancellation || Task.isCancelled
        return await syncHandler()
    }

    func previewAccount(baseURL: URL, apiKey: String, uri: String, customOTP: String?) async throws -> APIAccount {
        try await previewHandler()
    }

    func createAccount(
        context: ModelContext,
        baseURL: URL,
        apiKey: String,
        requestBody: AccountCreationRequest,
        isCurrentSession: @escaping () -> Bool
    ) async throws {
        try await createHandler()
        guard isCurrentSession() else {
            throw AccountRepositoryError.staleSession
        }
        if let createdAccount {
            context.insert(createdAccount)
            try context.save()
        }
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
        let modelContext: ModelContext
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
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

    func testStaleSyncNowResetsSyncingState() async throws {
        let setup = try makeSUT(testName: #function)
        let started = AsyncGate()
        let release = AsyncGate()
        setup.repository.syncHandler = {
            await started.open()
            await release.wait()
            return .success
        }

        let sync = Task { await setup.appModel.syncNow() }
        await started.wait()
        XCTAssertTrue(setup.appModel.isSyncing)
        setup.configStore.sessionRevision += 1
        await release.open()
        _ = await sync.value

        XCTAssertFalse(setup.appModel.isSyncing)
    }

    func testStaleLoginAttemptResetsSyncingState() async throws {
        let setup = try makeSUT(testName: #function)
        let started = AsyncGate()
        let release = AsyncGate()
        setup.repository.syncHandler = {
            await started.open()
            await release.wait()
            return .success
        }

        let login = Task { await setup.appModel.attemptLogin(apiKey: "replacement-key") }
        await started.wait()
        XCTAssertTrue(setup.appModel.isSyncing)
        setup.configStore.sessionRevision += 1
        await release.open()
        await login.value

        XCTAssertFalse(setup.appModel.isSyncing)
    }

    func testSuccessfulLoginAdvancesSessionRevisionOnce() async throws {
        let setup = try makeSUT(testName: #function)
        setup.configStore.sessionRevision = 41

        await setup.appModel.attemptLogin(apiKey: "replacement-key")

        XCTAssertEqual(setup.configStore.sessionRevision, 42)
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

    func testStalePreviewSuccessDoesNotReturnAfterReplacementSession() async throws {
        let setup = try makeSUT(testName: #function)
        let started = AsyncGate()
        let release = AsyncGate()
        setup.repository.previewHandler = {
            await started.open()
            await release.wait()
            return try self.apiAccount(
                secret: "JBSWY3DPEHPK3PXP",
                digits: 6,
                algorithm: "SHA1",
                period: 30
            )
        }

        let preview = Task { try await setup.appModel.previewAccount(uri: validURI) }
        await started.wait()
        try replaceSession(in: setup)
        await release.open()

        do {
            _ = try await preview.value
            XCTFail("Expected stale preview cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }
        XCTAssertEqual(setup.secretStore.loadAPIKey(), "replacement-key")
        XCTAssertEqual(setup.repository.wipeCallCount, 0)
    }

    func testStaleCreateSuccessDoesNotPersistAfterReplacementSession() async throws {
        let setup = try makeSUT(testName: #function)
        let started = AsyncGate()
        let release = AsyncGate()
        setup.repository.createdAccount = AccountEntity(
            remoteID: 10,
            service: "Old session",
            account: "old@example.com",
            otpType: "totp",
            digits: 6,
            algorithm: "SHA1",
            period: 30,
            encryptedSecret: nil,
            updatedAt: Date()
        )
        setup.repository.createHandler = {
            await started.open()
            await release.wait()
        }

        let creation = Task {
            try await setup.appModel.addAccount(
                preview: validPreview(),
                service: "Example",
                account: "person@example.com"
            )
        }
        await started.wait()
        try replaceSession(in: setup)
        await release.open()

        do {
            try await creation.value
            XCTFail("Expected stale creation cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }
        let accounts = try setup.modelContext.fetch(FetchDescriptor<AccountEntity>())
        XCTAssertTrue(accounts.isEmpty)
        XCTAssertEqual(setup.repository.syncCallCount, 0)
    }

    func testStaleCreateUnauthorizedDoesNotWipeReplacementSession() async throws {
        let setup = try makeSUT(testName: #function)
        setup.appModel.sessionState = .unlocked
        let started = AsyncGate()
        let release = AsyncGate()
        setup.repository.createHandler = {
            await started.open()
            await release.wait()
            throw APIError.unauthorized
        }

        let creation = Task {
            try await setup.appModel.addAccount(
                preview: validPreview(),
                service: "Example",
                account: "person@example.com"
            )
        }
        await started.wait()
        try replaceSession(in: setup)
        await release.open()

        do {
            try await creation.value
            XCTFail("Expected stale creation cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }
        XCTAssertEqual(setup.appModel.sessionState, .unlocked)
        XCTAssertEqual(setup.secretStore.loadAPIKey(), "replacement-key")
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

    func testUnknownCreationOutcomeBecomesCancellationWhenSessionChangesDuringReconciliation() async throws {
        let reconciliationStarted = AsyncGate()
        let releaseReconciliation = AsyncGate()
        var scheduleCount = 0
        var watchPushCount = 0
        let setup = try makeSUT(
            testName: #function,
            scheduleBackgroundRefresh: { scheduleCount += 1 },
            pushWatchSnapshot: { watchPushCount += 1 }
        )
        setup.repository.createHandler = {
            throw APIError.transport("connection lost")
        }
        setup.repository.syncHandler = {
            await reconciliationStarted.open()
            await releaseReconciliation.wait()
            return .transient("offline")
        }

        let creation = Task {
            try await setup.appModel.addAccount(
                preview: validPreview(),
                service: "Example",
                account: "person@example.com"
            )
        }
        await reconciliationStarted.wait()
        try replaceSession(in: setup)
        await releaseReconciliation.open()

        do {
            try await creation.value
            XCTFail("Expected stale reconciliation cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }
        XCTAssertEqual(scheduleCount, 0)
        XCTAssertEqual(watchPushCount, 0)
    }

    func testCreatedAccountIconIsAllowedWhenRefreshFails() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let iconURL = URL(string: "https://example.com/storage/icons/new.png")!
        let iconData = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, iconData)
        }
        let cache = AccountIconCache(session: makeMockedURLSession(), cacheDirectory: directory)
        await cache.prune(keeping: [], sessionRevision: 0)
        let setup = try makeSUT(testName: #function, iconCache: cache)
        setup.repository.createdAccount = AccountEntity(
            remoteID: 10,
            service: "Example",
            account: "person@example.com",
            otpType: "totp",
            digits: 6,
            algorithm: "SHA1",
            period: 30,
            iconFilename: "new.png",
            encryptedSecret: nil,
            updatedAt: Date()
        )
        setup.repository.syncHandler = { .transient("offline") }

        try await setup.appModel.addAccount(
            preview: validPreview(),
            service: "Example",
            account: "person@example.com"
        )
        let loadedData = await setup.appModel.iconData(
            for: iconURL,
            sessionRevision: setup.configStore.sessionRevision
        )

        let image = try XCTUnwrap(UIImage(data: try XCTUnwrap(loadedData)))
        XCTAssertEqual(image.size, CGSize(width: 128, height: 128))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(try XCTUnwrap(image.cgImage), in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertGreaterThan(pixel[3], 0)
        XCTAssertGreaterThan(pixel[2], pixel[0])
        try? FileManager.default.removeItem(at: directory)
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

    private func replaceSession(in setup: SUT) throws {
        setup.configStore.sessionRevision += 1
        try setup.secretStore.saveAPIKey("replacement-key")
        setup.appModel.sessionState = .unlocked
    }

    private func makeSUT(
        testName: String,
        scheduleBackgroundRefresh: @escaping () -> Void = {},
        pushWatchSnapshot: @escaping () -> Void = {},
        iconCache: AccountIconCache = .shared
    ) throws -> SUT {
        let container = try makeInMemoryModelContainer()
        let configStore = makeTestConfigStore(testName: testName)
        configStore.baseURLString = "https://example.com"
        let secretStore = KeychainSecretStore()
        try secretStore.saveAPIKey("api-key")
        let repository = AddAccountTestRepository()
        let modelContext = ModelContext(container)
        let appModel = AppModel(
            modelContext: modelContext,
            configStore: configStore,
            secretStore: secretStore,
            repository: repository,
            scheduleBackgroundRefresh: scheduleBackgroundRefresh,
            pushWatchSnapshot: pushWatchSnapshot,
            clearWatchSnapshot: {},
            iconCache: iconCache
        )
        return SUT(
            appModel: appModel,
            repository: repository,
            configStore: configStore,
            secretStore: secretStore,
            modelContext: modelContext
        )
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
