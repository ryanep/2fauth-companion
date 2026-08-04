import Foundation
import BackgroundTasks
import ImageIO
import SwiftData
import SwiftUI
import WatchConnectivity
import XCTest

#if canImport(UIKit)
    import UIKit
#endif

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

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.withLock {
            value += 1
        }
    }

    var count: Int {
        lock.withLock {
            value
        }
    }
}

private final class RequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isSuspended = false
    private let release = DispatchSemaphore(value: 0)

    func suspendResponse() {
        lock.withLock {
            isSuspended = true
        }
        release.wait()
    }

    func waitUntilSuspended() async {
        while !lock.withLock({ isSuspended }) {
            await Task.yield()
        }
    }

    func resumeResponse() {
        release.signal()
    }
}

private final class CacheOperationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isSuspended = false
    private var didSuspend = false
    private let release = DispatchSemaphore(value: 0)

    func waitUntilSuspended() async {
        while !lock.withLock({ isSuspended }) {
            await Task.yield()
        }
    }

    func resume() {
        release.signal()
    }

    func suspendOnce() {
        let shouldSuspend = lock.withLock {
            guard !didSuspend else { return false }
            didSuspend = true
            isSuspended = true
            return true
        }
        if shouldSuspend {
            release.wait()
        }
    }
}

private final class GatedCacheFileManager: FileManager {
    enum Operation {
        case prune
        case clear
    }

    private let operation: Operation
    private let gate: CacheOperationGate

    init(operation: Operation, gate: CacheOperationGate) {
        self.operation = operation
        self.gate = gate
        super.init()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        if operation == .prune {
            gate.suspendOnce()
        }
        return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }

    override func removeItem(at URL: URL) throws {
        if operation == .clear {
            gate.suspendOnce()
        }
        try super.removeItem(at: URL)
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        guard !isOpen else {
            return
        }

        isOpen = true
        let currentWaiters = waiters
        waiters.removeAll()
        for waiter in currentWaiters {
            waiter.resume()
        }
    }

    func wait() async {
        guard !isOpen else {
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
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

    #if canImport(UIKit)
        private func visiblePNGData(color: UIColor = .systemBlue) -> Data {
            UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 1, height: 2))
                UIColor.clear.setFill()
                context.fill(CGRect(x: 1, y: 0, width: 1, height: 2))
            }
        }

        private func transparentPNGData() -> Data {
            UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).pngData { _ in }
        }

    #endif

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

    func testLogoutAdvancesSessionRevisionOnce() async throws {
        let setup = try makeSUT(testName: #function)
        setup.configStore.sessionRevision = 41

        await setup.appModel.logout()

        XCTAssertEqual(setup.configStore.sessionRevision, 42)
    }

    func testMissingSessionSyncLogoutAdvancesSessionRevisionOnce() async throws {
        let setup = try makeSUT(testName: #function)
        setup.configStore.sessionRevision = 41
        setup.appModel.sessionState = .unlocked

        _ = await setup.appModel.syncNow()

        XCTAssertEqual(setup.configStore.sessionRevision, 42)
        XCTAssertEqual(setup.appModel.sessionState, .loggedOut)
    }

    func testForegroundUnauthorizedAdvancesSessionRevisionOnce() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let setup = try makeSUT(testName: #function)
        setup.configStore.baseURLString = "https://example.com"
        setup.configStore.sessionRevision = 41
        try secretStore.saveAPIKey("api-key")
        setup.appModel.sessionState = .unlocked

        _ = await setup.appModel.syncNow()

        XCTAssertEqual(setup.configStore.sessionRevision, 42)
        XCTAssertEqual(setup.appModel.sessionState, .reloginRequired)
    }

    func testIconURLBuildsStorageIconURL() throws {
        let setup = try makeSUT(testName: #function)
        setup.configStore.baseURLString = "https://example.com/base"

        let url = setup.appModel.iconURL(for: "github.png")

        XCTAssertEqual(url?.absoluteString, "https://example.com/base/storage/icons/github.png")
    }

    func testAccountIconLoadingAllowsInactiveForegroundTransition() {
        XCTAssertTrue(canLoadAccountIcon(in: .active))
        XCTAssertTrue(canLoadAccountIcon(in: .inactive))
        XCTAssertFalse(canLoadAccountIcon(in: .background))
    }

    func testIconURLAcceptsStorageIconPath() throws {
        let setup = try makeSUT(testName: #function)
        setup.configStore.baseURLString = "https://example.com/base"

        let url = setup.appModel.iconURL(for: "/storage/icons/github.svg")

        XCTAssertEqual(url?.absoluteString, "https://example.com/base/storage/icons/github.svg")
    }

    func testIconURLAcceptsSameOriginAbsoluteURL() throws {
        let setup = try makeSUT(testName: #function)
        setup.configStore.baseURLString = "https://example.com/base"

        let url = setup.appModel.iconURL(for: "https://example.com/base/storage/icons/github.png")

        XCTAssertEqual(url?.absoluteString, "https://example.com/base/storage/icons/github.png")
    }

    func testIconURLRejectsUnsafeLocations() throws {
        let setup = try makeSUT(testName: #function)
        setup.configStore.baseURLString = "https://example.com"

        XCTAssertNil(setup.appModel.iconURL(for: "../github.png"))
        XCTAssertNil(setup.appModel.iconURL(for: "nested/github.png"))
        XCTAssertNil(setup.appModel.iconURL(for: "/storage/icons/../github.png"))
        XCTAssertNil(setup.appModel.iconURL(for: "https://example.com/storage/icons/%2e%2e"))
        XCTAssertNil(setup.appModel.iconURL(for: "https://example.com/storage/icons/%2E%2E"))
        XCTAssertNil(setup.appModel.iconURL(for: "https://example.com/storage/icons/..%5cgithub.png"))
        XCTAssertNil(setup.appModel.iconURL(for: "https://example.com/storage/icons/..%5Cgithub.png"))
        XCTAssertNil(setup.appModel.iconURL(for: "https://cdn.example.com/storage/icons/github.png"))
        XCTAssertNil(setup.appModel.iconURL(for: "http://example.com/storage/icons/github.png"))
    }

    func testIconURLRemovesCredentialsQueryAndFragmentFromBaseURL() throws {
        let url = AccountIconCache.iconURL(
            baseURL: URL(string: "https://user:password@example.com/base?token=secret#fragment")!,
            iconFilename: "github.png"
        )

        XCTAssertEqual(url?.absoluteString, "https://example.com/base/storage/icons/github.png")
    }

    func testAccountIconCachePruneRemovesOnlyStaleIcons() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cache = AccountIconCache(cacheDirectory: directory)
        let keptURL = URL(string: "https://example.com/storage/icons/github.png")!
        let staleURL = URL(string: "https://example.com/storage/icons/gitlab.png")!

        await cache.cache(data: Data("kept".utf8), for: keptURL)
        await cache.cache(data: Data("stale".utf8), for: staleURL)

        await cache.prune(keeping: [keptURL], sessionRevision: 0)

        let keptExists = await cache.hasCachedData(for: keptURL)
        let staleExists = await cache.hasCachedData(for: staleURL)
        XCTAssertTrue(keptExists)
        XCTAssertFalse(staleExists)

        try? FileManager.default.removeItem(at: directory)
    }

    func testAccountIconCacheRejectsStalePruneAfterReplacementSessionAdmission() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cache = AccountIconCache(cacheDirectory: directory)
        let replacementURL = URL(string: "https://replacement.example/storage/icons/replacement.png")!

        await cache.advanceSession(to: 2)
        await cache.cache(data: Data("replacement".utf8), for: replacementURL)
        await cache.prune(keeping: [], sessionRevision: 1)

        let hasReplacement = await cache.hasCachedData(for: replacementURL)
        XCTAssertTrue(hasReplacement)
        try? FileManager.default.removeItem(at: directory)
    }

    func testAccountIconCacheRejectsStaleClearAfterReplacementSessionAdmission() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cache = AccountIconCache(cacheDirectory: directory)
        let replacementURL = URL(string: "https://replacement.example/storage/icons/replacement.png")!

        await cache.advanceSession(to: 2)
        await cache.cache(data: Data("replacement".utf8), for: replacementURL)
        await cache.clear(sessionRevision: 1)

        let hasReplacement = await cache.hasCachedData(for: replacementURL)
        XCTAssertTrue(hasReplacement)
        try? FileManager.default.removeItem(at: directory)
    }

    func testAccountIconCacheReplacementAdmissionClearsStaleAllowlist() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cache = AccountIconCache(cacheDirectory: directory)
        let replacementURL = URL(string: "https://replacement.example/storage/icons/replacement.png")!

        await cache.advanceSession(to: 1)
        await cache.prune(keeping: [], sessionRevision: 1)
        await cache.advanceSession(to: 2)
        await cache.cache(data: visiblePNGData(), for: replacementURL)

        let loaded = await cache.imageData(for: replacementURL, allowRemoteLoad: false)
        XCTAssertNotNil(loaded)
        try? FileManager.default.removeItem(at: directory)
    }

    func testQueuedStalePruneCompletesBeforeReplacementCacheWork() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let gate = CacheOperationGate()
        let cache = AccountIconCache(
            fileManager: GatedCacheFileManager(operation: .prune, gate: gate),
            cacheDirectory: directory
        )
        let replacementURL = URL(string: "https://replacement.example/storage/icons/replacement.png")!
        await cache.advanceSession(to: 1)

        let stalePrune = Task {
            await cache.prune(keeping: [], sessionRevision: 1)
        }
        await gate.waitUntilSuspended()
        let replacementAdmission = Task {
            await cache.advanceSession(to: 2)
        }
        gate.resume()
        await stalePrune.value
        await replacementAdmission.value
        await cache.cache(data: visiblePNGData(), for: replacementURL)

        let loaded = await cache.imageData(for: replacementURL, allowRemoteLoad: false)
        XCTAssertNotNil(loaded)
        try? FileManager.default.removeItem(at: directory)
    }

    func testQueuedStaleClearCompletesBeforeReplacementCacheWork() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let gate = CacheOperationGate()
        let cache = AccountIconCache(
            fileManager: GatedCacheFileManager(operation: .clear, gate: gate),
            cacheDirectory: directory
        )
        let oldURL = URL(string: "https://old.example/storage/icons/old.png")!
        let replacementURL = URL(string: "https://replacement.example/storage/icons/replacement.png")!
        await cache.advanceSession(to: 1)
        await cache.cache(data: Data("old".utf8), for: oldURL)

        let staleClear = Task {
            await cache.clear(sessionRevision: 1)
        }
        await gate.waitUntilSuspended()
        let replacementAdmission = Task {
            await cache.advanceSession(to: 2)
        }
        gate.resume()
        await staleClear.value
        await replacementAdmission.value
        await cache.cache(data: Data("replacement".utf8), for: replacementURL)

        let hasReplacement = await cache.hasCachedData(for: replacementURL)
        XCTAssertTrue(hasReplacement)
        try? FileManager.default.removeItem(at: directory)
    }

    func testAccountIconCacheRasterizesSVGBeforeCaching() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = URL(string: "https://example.com/storage/icons/github.svg")!
        let svgData = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".utf8)
        let rasterizedData = visiblePNGData()

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url, url)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, svgData)
        }

        let cache = AccountIconCache(
            session: makeMockedURLSession(),
            cacheDirectory: directory,
            rasterizeSVG: { data in
                data == svgData ? rasterizedData : nil
            }
        )

        let firstLoad = await cache.imageData(for: url)
        MockURLProtocol.requestHandler = nil
        let cachedLoad = await cache.imageData(for: url)

        XCTAssertEqual(firstLoad, rasterizedData)
        XCTAssertEqual(cachedLoad, rasterizedData)

        try? FileManager.default.removeItem(at: directory)
    }

    func testAccountIconCacheCoalescesConcurrentSVGLoads() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = URL(string: "https://example.com/storage/icons/github.svg")!
        let svgData = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".utf8)
        let rasterizedData = visiblePNGData()
        let requestCounter = LockedCounter()
        let rasterizeCounter = LockedCounter()
        let rasterizerStarted = AsyncGate()
        let releaseRasterizer = AsyncGate()

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url, url)
            requestCounter.increment()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, svgData)
        }

        let cache = AccountIconCache(
            session: makeMockedURLSession(),
            cacheDirectory: directory,
            rasterizeSVG: { data in
                rasterizeCounter.increment()
                await rasterizerStarted.open()
                await releaseRasterizer.wait()
                return data == svgData ? rasterizedData : nil
            }
        )

        let firstLoad = Task {
            await cache.imageData(for: url)
        }
        await rasterizerStarted.wait()

        let results = await withTaskGroup(of: Data?.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    await cache.imageData(for: url)
                }
            }

            await releaseRasterizer.open()

            var values: [Data?] = []
            for await value in group {
                values.append(value)
            }
            return values
        }
        let firstResult = await firstLoad.value

        XCTAssertEqual(firstResult, rasterizedData)
        XCTAssertEqual(results, Array(repeating: rasterizedData, count: 4))
        XCTAssertEqual(requestCounter.count, 1)
        XCTAssertEqual(rasterizeCounter.count, 1)

        try? FileManager.default.removeItem(at: directory)
    }

    func testAccountIconCacheCancelsInFlightLoadsWhenSuspended() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = URL(string: "https://example.com/storage/icons/github.svg")!
        let svgData = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".utf8)
        let rasterData = visiblePNGData()
        let rasterizerStarted = AsyncGate()
        let releaseRasterizer = AsyncGate()
        let cancelledRasterizer = LockedCounter()
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, svgData)
        }
        let cache = AccountIconCache(
            session: makeMockedURLSession(),
            cacheDirectory: directory,
            rasterizeSVG: { _ in
                await rasterizerStarted.open()
                await releaseRasterizer.wait()
                if Task.isCancelled {
                    cancelledRasterizer.increment()
                }
                return rasterData
            }
        )
        let load = Task { await cache.imageData(for: url) }
        await rasterizerStarted.wait()

        load.cancel()
        try await Task.sleep(for: .milliseconds(10))
        await releaseRasterizer.open()

        let loadedData = await load.value
        let hasCachedData = await cache.hasCachedData(for: url)
        XCTAssertNil(loadedData)
        XCTAssertFalse(hasCachedData)
        XCTAssertEqual(cancelledRasterizer.count, 1)
        try? FileManager.default.removeItem(at: directory)
    }

    func testAccountIconCacheKeepsCoalescedLoadForRemainingWaiter() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = URL(string: "https://example.com/storage/icons/github.svg")!
        let svgData = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".utf8)
        let rasterData = visiblePNGData()
        let rasterizerStarted = AsyncGate()
        let releaseRasterizer = AsyncGate()
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, svgData)
        }
        let cache = AccountIconCache(
            session: makeMockedURLSession(),
            cacheDirectory: directory,
            rasterizeSVG: { _ in
                await rasterizerStarted.open()
                await releaseRasterizer.wait()
                return rasterData
            }
        )
        let cancelledWaiter = Task { await cache.imageData(for: url) }
        let remainingWaiter = Task { await cache.imageData(for: url) }
        await rasterizerStarted.wait()
        try await Task.sleep(for: .milliseconds(10))

        cancelledWaiter.cancel()
        await releaseRasterizer.open()

        let cancelledResult = await cancelledWaiter.value
        let remainingResult = await remainingWaiter.value
        XCTAssertNil(cancelledResult)
        XCTAssertEqual(remainingResult, rasterData)
        try? FileManager.default.removeItem(at: directory)
    }

    func testAccountIconCacheCancelsUnownedStaleRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = URL(string: "https://example.com/storage/icons/github.png")!
        let cachedData = visiblePNGData()
        let svgData = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".utf8)
        let rasterizerStarted = AsyncGate()
        let releaseRasterizer = AsyncGate()
        let cancelledRasterizer = LockedCounter()
        let writer = AccountIconCache(cacheDirectory: directory)
        await writer.cache(data: cachedData, for: url)
        let cacheFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)],
            ofItemAtPath: cacheFile.path
        )
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, svgData)
        }
        let cache = AccountIconCache(
            session: makeMockedURLSession(),
            cacheDirectory: directory,
            rasterizeSVG: { _ in
                await rasterizerStarted.open()
                await releaseRasterizer.wait()
                if Task.isCancelled {
                    cancelledRasterizer.increment()
                }
                return cachedData
            }
        )

        let loadedData = await cache.imageData(for: url)
        XCTAssertEqual(loadedData, cachedData)
        await rasterizerStarted.wait()
        await cache.cancelUnownedRefreshes()
        await releaseRasterizer.open()

        XCTAssertEqual(cancelledRasterizer.count, 1)
        XCTAssertEqual(try Data(contentsOf: cacheFile), cachedData)
        try? FileManager.default.removeItem(at: directory)
    }

    func testAccountIconCacheRejectsBlankRasterizedSVG() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = URL(string: "https://example.com/storage/icons/github.svg")!
        let svgData = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".utf8)
        let blankPNGData = transparentPNGData()

        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url, url)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, svgData)
        }

        let cache = AccountIconCache(
            session: makeMockedURLSession(),
            cacheDirectory: directory,
            rasterizeSVG: { data in
                data == svgData ? blankPNGData : nil
            }
        )

        let loadedData = await cache.imageData(for: url)
        let hasCachedData = await cache.hasCachedData(for: url)

        XCTAssertNil(loadedData)
        XCTAssertFalse(hasCachedData)

        try? FileManager.default.removeItem(at: directory)
    }

    func testAccountIconCacheRasterizesPreviouslyCachedSVG() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = URL(string: "https://example.com/storage/icons/github.svg")!
        let svgData = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".utf8)
        let rasterizedData = visiblePNGData()
        let cache = AccountIconCache(
            cacheDirectory: directory,
            rasterizeSVG: { data in
                rasterizedData
            }
        )

        await cache.cache(data: svgData, for: url)

        let migratedLoad = await cache.imageData(for: url)
        let cachedLoad = await cache.imageData(for: url)

        XCTAssertEqual(migratedLoad, rasterizedData)
        XCTAssertEqual(cachedLoad, rasterizedData)

        try? FileManager.default.removeItem(at: directory)
    }

    func testAccountIconCacheRejectsIncompleteCachedRaster() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = URL(string: "https://example.com/storage/icons/github.png")!
        let pngData = visiblePNGData()
        let metadataOnlyData = try XCTUnwrap(
            (16..<pngData.count).lazy
                .map { Data(pngData.prefix($0)) }
                .first { data in
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                        return false
                    }
                    return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) != nil
                        && CGImageSourceCreateImageAtIndex(source, 0, nil) == nil
                }
        )
        let replacementData = visiblePNGData(color: .systemRed)
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, replacementData)
        }
        let cache = AccountIconCache(session: makeMockedURLSession(), cacheDirectory: directory)
        await cache.cache(data: metadataOnlyData, for: url)

        let loadedData = await cache.imageData(for: url)

        XCTAssertEqual(loadedData, replacementData)
        try? FileManager.default.removeItem(at: directory)
    }

    func testAccountIconCacheDoesNotCacheInvalidImageResponse() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = URL(string: "https://example.com/storage/icons/github.png")!
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("<html>temporarily unavailable</html>".utf8))
        }
        let cache = AccountIconCache(session: makeMockedURLSession(), cacheDirectory: directory)

        let loadedData = await cache.imageData(for: url)
        let hasCachedData = await cache.hasCachedData(for: url)

        XCTAssertNil(loadedData)
        XCTAssertFalse(hasCachedData)
        try? FileManager.default.removeItem(at: directory)
    }

    func testAccountIconCacheCacheOnlyMissDoesNotStartNetworkLoad() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = URL(string: "https://example.com/storage/icons/github.png")!
        let requestCounter = LockedCounter()
        let responseData = visiblePNGData()
        MockURLProtocol.requestHandler = { request in
            requestCounter.increment()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, responseData)
        }
        let cache = AccountIconCache(session: makeMockedURLSession(), cacheDirectory: directory)

        let loadedData = await cache.imageData(for: url, allowRemoteLoad: false)

        XCTAssertNil(loadedData)
        XCTAssertEqual(requestCounter.count, 0)
        try? FileManager.default.removeItem(at: directory)
    }

    func testAccountIconCacheReturnsStaleIconBeforeRefreshing() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = URL(string: "https://example.com/storage/icons/github.png")!
        let cachedData = visiblePNGData()
        let refreshedData = visiblePNGData(color: .systemRed)
        let cacheWriter = AccountIconCache(cacheDirectory: directory)
        await cacheWriter.cache(data: cachedData, for: url)
        let cacheFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)],
            ofItemAtPath: cacheFile.path
        )
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, refreshedData)
        }
        let cache = AccountIconCache(session: makeMockedURLSession(), cacheDirectory: directory)

        let loadedData = await cache.imageData(for: url)

        XCTAssertEqual(loadedData, cachedData)
        for _ in 0..<50 where (try? Data(contentsOf: cacheFile)) != refreshedData {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(try Data(contentsOf: cacheFile), refreshedData)
        try? FileManager.default.removeItem(at: directory)
    }

    func testLogoutClearsAccountIconCache() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cache = AccountIconCache(cacheDirectory: directory)
        let url = URL(string: "https://example.com/storage/icons/github.png")!
        await cache.cache(data: visiblePNGData(), for: url)
        let setup = try makeSUT(testName: #function, iconCache: cache)

        await setup.appModel.logout()

        let hasCachedData = await cache.hasCachedData(for: url)
        XCTAssertFalse(hasCachedData)
        try? FileManager.default.removeItem(at: directory)
    }

    func testSuccessfulSyncPrunesUnusedAccountIcons() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cache = AccountIconCache(cacheDirectory: directory)
        let keptURL = URL(string: "https://example.com/storage/icons/github.png")!
        let staleURL = URL(string: "https://example.com/storage/icons/gitlab.png")!
        await cache.cache(data: visiblePNGData(), for: keptURL)
        await cache.cache(data: visiblePNGData(), for: staleURL)
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = """
                [{"id":101,"service":"GitHub","account":"ryan","icon":"github.png","otp_type":"totp","secret":null,"digits":6,"algorithm":"SHA1","period":30}]
                """
            return (response, Data(json.utf8))
        }
        let setup = try makeSUT(testName: #function, iconCache: cache)
        setup.configStore.baseURLString = "https://example.com"
        try secretStore.saveAPIKey("api-key")

        _ = await setup.appModel.syncNow()

        let keptExists = await cache.hasCachedData(for: keptURL)
        let staleExists = await cache.hasCachedData(for: staleURL)
        XCTAssertTrue(keptExists)
        XCTAssertFalse(staleExists)
        try? FileManager.default.removeItem(at: directory)
    }

    func testStaleForegroundSuccessCannotAffectReplacementSession() async throws {
        let gate = RequestGate()
        MockURLProtocol.requestHandler = { request in
            gate.suspendResponse()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = """
                [{"id":1,"service":"Old","account":"old","icon":"old.png","otp_type":"totp","secret":null,"digits":6,"algorithm":"SHA1","period":30}]
                """
            return (response, Data(json.utf8))
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cache = AccountIconCache(cacheDirectory: directory)
        let replacementIconURL = URL(string: "https://replacement.example/storage/icons/replacement.png")!
        var watchPushCount = 0
        let setup = try makeSUT(
            testName: #function,
            pushWatchSnapshot: { watchPushCount += 1 },
            iconCache: cache
        )
        setup.configStore.baseURLString = "https://old.example"
        try secretStore.saveAPIKey("old-key")
        setup.appModel.sessionState = .unlocked

        let sync = Task { await setup.appModel.syncNow() }
        await gate.waitUntilSuspended()
        await setup.appModel.logout()

        setup.configStore.baseURLString = "https://replacement.example"
        try secretStore.saveAPIKey("replacement-key")
        let replacementSyncDate = Date(timeIntervalSince1970: 12345)
        setup.configStore.lastSuccessfulSyncAt = replacementSyncDate
        setup.appModel.lastSuccessfulSyncAt = replacementSyncDate
        let replacement = AccountEntity(
            remoteID: 2,
            service: "Replacement",
            account: "replacement",
            otpType: "totp",
            digits: 6,
            algorithm: "SHA1",
            period: 30,
            iconFilename: "replacement.png",
            encryptedSecret: nil,
            updatedAt: replacementSyncDate
        )
        setup.modelContext.insert(replacement)
        try setup.modelContext.save()
        await cache.cache(data: Data("replacement-icon".utf8), for: replacementIconURL)

        gate.resumeResponse()
        let result = await sync.value

        XCTAssertEqual(setup.appModel.sessionState, .loggedOut)
        XCTAssertEqual(setup.appModel.lastSuccessfulSyncAt, replacementSyncDate)
        XCTAssertEqual(setup.configStore.lastSuccessfulSyncAt, replacementSyncDate)
        XCTAssertEqual(try setup.modelContext.fetch(FetchDescriptor<AccountEntity>()).map(\.remoteID), [2])
        XCTAssertEqual(watchPushCount, 0)
        let hasReplacementIcon = await cache.hasCachedData(for: replacementIconURL)
        XCTAssertTrue(hasReplacementIcon)
        if case .stale = result {
        } else {
            XCTFail("Expected stale result")
        }
        try? FileManager.default.removeItem(at: directory)
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
        pushWatchSnapshot: @escaping () -> Void = {},
        clearWatchSnapshot: @escaping () -> Void = {},
        biometricAuthenticator: any BiometricAuthenticator = MockBiometricAuthenticator(result: .success(true)),
        iconCache: AccountIconCache = .shared
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
            pushWatchSnapshot: pushWatchSnapshot,
            clearWatchSnapshot: clearWatchSnapshot,
            biometricAuthenticator: biometricAuthenticator,
            iconCache: iconCache
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

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cache = AccountIconCache(cacheDirectory: directory)
        let iconURL = URL(string: "https://example.com/storage/icons/github.png")!
        await cache.cache(data: Data("icon".utf8), for: iconURL)
        let setup = try makeSUT(testName: #function, iconCache: cache)
        setup.configStore.baseURLString = "https://example.com"
        try secretStore.saveAPIKey("api-key")

        let result = await setup.manager.runBackgroundSync(isCancelled: { false })

        XCTAssertTrue(result)
        XCTAssertTrue(setup.configStore.requiresRelogin)
        XCTAssertNil(secretStore.loadAPIKey())
        let hasCachedData = await cache.hasCachedData(for: iconURL)
        XCTAssertFalse(hasCachedData)
        try? FileManager.default.removeItem(at: directory)
    }

    func testBackgroundUnauthorizedAdvancesSessionRevisionOnce() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let setup = try makeSUT(testName: #function)
        setup.configStore.baseURLString = "https://example.com"
        setup.configStore.sessionRevision = 41
        try secretStore.saveAPIKey("api-key")

        _ = await setup.manager.runBackgroundSync(isCancelled: { false })

        XCTAssertEqual(setup.configStore.sessionRevision, 42)
        XCTAssertTrue(setup.configStore.requiresRelogin)
    }

    func testStaleBackgroundSuccessCannotAffectReplacementSession() async throws {
        let gate = RequestGate()
        MockURLProtocol.requestHandler = { request in
            gate.suspendResponse()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = """
                [{"id":1,"service":"Old","account":"old","icon":"old.png","otp_type":"totp","secret":null,"digits":6,"algorithm":"SHA1","period":30}]
                """
            return (response, Data(json.utf8))
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cache = AccountIconCache(cacheDirectory: directory)
        let replacementIconURL = URL(string: "https://replacement.example/storage/icons/replacement.png")!
        let setup = try makeSUT(testName: #function, iconCache: cache)
        setup.configStore.baseURLString = "https://old.example"
        try secretStore.saveAPIKey("old-key")

        let sync = Task { await setup.manager.runBackgroundSync(isCancelled: { false }) }
        await gate.waitUntilSuspended()
        setup.configStore.baseURLString = "https://replacement.example"
        try secretStore.saveAPIKey("replacement-key")
        let context = ModelContext(setup.modelContainer)
        context.insert(AccountEntity(
            remoteID: 2,
            service: "Replacement",
            account: "replacement",
            otpType: "totp",
            digits: 6,
            algorithm: "SHA1",
            period: 30,
            iconFilename: "replacement.png",
            encryptedSecret: nil,
            updatedAt: Date()
        ))
        try context.save()
        await cache.cache(data: Data("replacement-icon".utf8), for: replacementIconURL)

        gate.resumeResponse()
        _ = await sync.value

        XCTAssertEqual(try context.fetch(FetchDescriptor<AccountEntity>()).map(\.remoteID), [2])
        XCTAssertEqual(secretStore.loadAPIKey(), "replacement-key")
        XCTAssertFalse(setup.configStore.requiresRelogin)
        let hasReplacementIcon = await cache.hasCachedData(for: replacementIconURL)
        XCTAssertTrue(hasReplacementIcon)
        try? FileManager.default.removeItem(at: directory)
    }

    func testStaleBackgroundUnauthorizedCannotWipeReplacementSession() async throws {
        let gate = RequestGate()
        MockURLProtocol.requestHandler = { request in
            gate.suspendResponse()
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cache = AccountIconCache(cacheDirectory: directory)
        let replacementIconURL = URL(string: "https://replacement.example/storage/icons/replacement.png")!
        var watchClearCount = 0
        let setup = try makeSUT(
            testName: #function,
            clearWatchSnapshot: { watchClearCount += 1 },
            iconCache: cache
        )
        setup.configStore.baseURLString = "https://old.example"
        try secretStore.saveAPIKey("old-key")

        let sync = Task { await setup.manager.runBackgroundSync(isCancelled: { false }) }
        await gate.waitUntilSuspended()
        setup.configStore.baseURLString = "https://replacement.example"
        try secretStore.saveAPIKey("replacement-key")
        let context = ModelContext(setup.modelContainer)
        context.insert(AccountEntity(
            remoteID: 2,
            service: "Replacement",
            account: "replacement",
            otpType: "totp",
            digits: 6,
            algorithm: "SHA1",
            period: 30,
            iconFilename: "replacement.png",
            encryptedSecret: nil,
            updatedAt: Date()
        ))
        try context.save()
        await cache.cache(data: Data("replacement-icon".utf8), for: replacementIconURL)

        gate.resumeResponse()
        _ = await sync.value

        XCTAssertEqual(try context.fetch(FetchDescriptor<AccountEntity>()).map(\.remoteID), [2])
        XCTAssertEqual(secretStore.loadAPIKey(), "replacement-key")
        XCTAssertFalse(setup.configStore.requiresRelogin)
        XCTAssertEqual(watchClearCount, 0)
        let hasReplacementIcon = await cache.hasCachedData(for: replacementIconURL)
        XCTAssertTrue(hasReplacementIcon)
        try? FileManager.default.removeItem(at: directory)
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
        clearWatchSnapshot: @escaping () -> Void = {},
        iconCache: AccountIconCache = .shared
    ) throws -> (
        manager: BackgroundSyncManager,
        configStore: UserDefaultsAppConfigStore,
        modelContainer: ModelContainer
    ) {
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
            clearWatchSnapshot: clearWatchSnapshot,
            iconCache: iconCache
        )
        return (manager, configStore, container)
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
