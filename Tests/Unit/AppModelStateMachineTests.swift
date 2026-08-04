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

private final class RemovalFailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func record() {
        lock.withLock { value += 1 }
    }

    var count: Int {
        lock.withLock { value }
    }
}

private final class FailingRemovalFileManager: FileManager {
    private let failingPath: String
    private let recorder: RemovalFailureRecorder

    init(failingURL: URL, recorder: RemovalFailureRecorder) {
        failingPath = failingURL.path
        self.recorder = recorder
        super.init()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func removeItem(at url: URL) throws {
        if failingPath == url.path {
            recorder.record()
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: url)
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

private final class ConcurrentOperationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var startedValues: [String] = []
    private var operations: [UUID: (value: String, completion: () -> Void)] = [:]
    private var resumeCredits = 0
    private var activeCount = 0
    private var peakActiveCount = 0

    func suspend(value: String, completion: @escaping () -> Void) -> UUID {
        let id = UUID()
        let shouldResume = lock.withLock {
            startedValues.append(value)
            activeCount += 1
            peakActiveCount = max(peakActiveCount, activeCount)
            if resumeCredits > 0 {
                resumeCredits -= 1
                activeCount -= 1
                return true
            }
            operations[id] = (value, completion)
            return false
        }
        if shouldResume { completion() }
        return id
    }

    func resume(value: String) {
        let completion = lock.withLock { () -> (() -> Void)? in
            guard let entry = operations.first(where: { $0.value.value == value }) else { return nil }
            operations.removeValue(forKey: entry.key)
            activeCount -= 1
            return entry.value.completion
        }
        completion?()
    }

    func resumeCurrentAndNext(_ count: Int) {
        let completions = lock.withLock { () -> [() -> Void] in
            let current = operations.values.map(\.completion)
            operations.removeAll()
            activeCount -= current.count
            resumeCredits += max(0, count - current.count)
            return current
        }
        completions.forEach { $0() }
    }

    func cancel(id: UUID) {
        lock.withLock {
            guard operations.removeValue(forKey: id) != nil else { return }
            activeCount -= 1
        }
    }

    var started: [String] {
        lock.withLock { startedValues }
    }

    var peak: Int {
        lock.withLock { peakActiveCount }
    }

    var active: Int {
        lock.withLock { activeCount }
    }
}

private final class GatedIconURLProtocol: URLProtocol {
    nonisolated(unsafe) static var gate: ConcurrentOperationGate?
    nonisolated(unsafe) static var sourceData: @Sendable (URL) -> Data = { _ in Data() }
    private var operationID: UUID?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let gate = Self.gate, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        operationID = gate.suspend(value: url.lastPathComponent) { [weak self] in
            guard let self else { return }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.sourceData(url))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        if let operationID {
            Self.gate?.cancel(id: operationID)
        }
    }
}

private func makeGatedIconURLSession(
    gate: ConcurrentOperationGate,
    sourceData: @escaping @Sendable (URL) -> Data
) -> URLSession {
    GatedIconURLProtocol.gate = gate
    GatedIconURLProtocol.sourceData = sourceData
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [GatedIconURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func makeGatedIconURLSession(gate: ConcurrentOperationGate, sourceData: Data) -> URLSession {
    makeGatedIconURLSession(gate: gate) { _ in sourceData }
}

private actor RasterizationGate {
    private var startedValues: [String] = []
    private var activeCount = 0
    private var peakActiveCount = 0
    private var continuations: [String: CheckedContinuation<Void, Never>] = [:]

    func suspend(value: String) async {
        startedValues.append(value)
        activeCount += 1
        peakActiveCount = max(peakActiveCount, activeCount)
        await withCheckedContinuation { continuation in
            continuations[value] = continuation
        }
        activeCount -= 1
    }

    func resume(value: String) {
        continuations.removeValue(forKey: value)?.resume()
    }

    var started: [String] { startedValues }
    var peak: Int { peakActiveCount }
}

@MainActor
final class AppModelStateMachineTests: XCTestCase {
    private enum AsyncTestError: Error {
        case timedOut
    }

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

        private func visiblePNGData(dimension: Int, metadata: String? = nil) throws -> Data {
            let size = CGSize(width: dimension, height: dimension)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let data = UIGraphicsImageRenderer(size: size, format: format).pngData { context in
                UIColor.systemBlue.setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
            guard let metadata else {
                return data
            }
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let output = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
            let properties: [CFString: Any] = [
                kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGTitle: metadata]
            ]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return output as Data
        }

        private func visiblePNGData(width: Int, height: Int) -> Data {
            let size = CGSize(width: width, height: height)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
                UIColor.systemBlue.setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
        }

        private func assertNormalizedIcon(_ data: Data?, sourceData: Data? = nil) throws {
            let data = try XCTUnwrap(data)
            XCTAssertTrue(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let properties = try XCTUnwrap(
                CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            )
            XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 128)
            XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 128)
            let pngProperties = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any]
            XCTAssertNil(pngProperties?[kCGImagePropertyPNGTitle])
            let image = try XCTUnwrap(try XCTUnwrap(UIImage(data: data)).cgImage)
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
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            XCTAssertGreaterThan(pixel[3], 0)
            if let sourceData {
                XCTAssertNotEqual(data, sourceData)
            }
        }

        private func normalizedIconPixels(_ data: Data?) throws -> [UInt8] {
            let image = try XCTUnwrap(UIImage(data: try XCTUnwrap(data)))
            let target = CGFloat(128)
            let scale = min(target / image.size.width, target / image.size.height)
            let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let drawOrigin = CGPoint(x: (target - drawSize.width) / 2, y: (target - drawSize.height) / 2)
            let format = UIGraphicsImageRendererFormat()
            format.opaque = false
            format.scale = 1
            let normalizedImage = UIGraphicsImageRenderer(
                size: CGSize(width: target, height: target),
                format: format
            ).image { _ in
                image.draw(in: CGRect(origin: drawOrigin, size: drawSize))
            }
            let cgImage = try XCTUnwrap(normalizedImage.cgImage)
            var pixels = [UInt8](repeating: 0, count: 128 * 128 * 4)
            let context = try XCTUnwrap(CGContext(
                data: &pixels,
                width: 128,
                height: 128,
                bitsPerComponent: 8,
                bytesPerRow: 128 * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 128, height: 128))
            return pixels
        }

        private func assertSameIconSemantics(_ actual: Data?, _ expected: Data?) throws {
            XCTAssertEqual(try normalizedIconPixels(actual), try normalizedIconPixels(expected))
        }

        private func iconCachePolicy(
            maximumSourceBytes: Int = 2 * 1_024 * 1_024,
            maximumSourceDimension: Int = 2_048,
            maximumSourcePixels: Int = 4_194_304,
            maximumMemoryBytes: Int = 16 * 1_024 * 1_024,
            maximumDiskBytes: Int = 32 * 1_024 * 1_024,
            maximumDiskFileCount: Int = 256,
            maximumConcurrentDownloads: Int = 4,
            maximumConcurrentRasterizations: Int = 4
        ) -> AccountIconCachePolicy {
            AccountIconCachePolicy(
                maximumSourceBytes: maximumSourceBytes,
                maximumSourceDimension: maximumSourceDimension,
                maximumSourcePixels: maximumSourcePixels,
                normalizedDimension: 128,
                maximumMemoryBytes: maximumMemoryBytes,
                maximumDiskBytes: maximumDiskBytes,
                maximumDiskFileCount: maximumDiskFileCount,
                maximumConcurrentDownloads: maximumConcurrentDownloads,
                maximumConcurrentRasterizations: maximumConcurrentRasterizations
            )
        }

        private func consumeIconUpdates(
            _ updates: AsyncStream<Data>,
            received: XCTestExpectation? = nil
        ) -> Task<[Data], Never> {
            Task {
                var values: [Data] = []
                var fulfillmentCount = 0
                for await value in updates {
                    values.append(value)
                    if let received, fulfillmentCount < received.expectedFulfillmentCount {
                        fulfillmentCount += 1
                        received.fulfill()
                    }
                }
                return values
            }
        }

        private func waitUntil(
            timeout: Duration = .seconds(1),
            condition: @escaping () async -> Bool
        ) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now + timeout
            while !(await condition()), clock.now < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            guard await condition() else {
                XCTFail("Timed out waiting for asynchronous condition")
                throw AsyncTestError.timedOut
            }
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

    func testAccountIconImageStateClearsWhenURLOrSessionChanges() throws {
        let setup = try makeSUT(testName: #function)
        setup.configStore.baseURLString = "https://old.example"
        setup.configStore.sessionRevision = 1
        let original = setup.appModel.iconLoadIdentity(for: "github.png")

        setup.configStore.baseURLString = "https://new.example"
        let changedURL = setup.appModel.iconLoadIdentity(for: "github.png")
        setup.configStore.baseURLString = "https://old.example"
        setup.configStore.sessionRevision = 2
        let changedSession = setup.appModel.iconLoadIdentity(for: "github.png")

        XCTAssertFalse(shouldClearAccountIconImage(loadedIdentity: original, requestedIdentity: original))
        XCTAssertTrue(shouldClearAccountIconImage(loadedIdentity: original, requestedIdentity: changedURL))
        XCTAssertTrue(shouldClearAccountIconImage(loadedIdentity: original, requestedIdentity: changedSession))
    }

    func testAccountIconUpdateRequiresCurrentFilenameURLAndSessionMetadata() {
        let oldIdentity = AccountIconLoadIdentity(
            url: URL(string: "https://old.example/storage/icons/github.png"),
            sessionRevision: 1
        )
        let currentIdentity = AccountIconLoadIdentity(
            url: URL(string: "https://new.example/storage/icons/github.png"),
            sessionRevision: 2
        )

        XCTAssertTrue(canApplyAccountIconUpdate(
            requestedIdentity: currentIdentity,
            currentIdentity: currentIdentity,
            requestedFilename: "github.png",
            currentFilename: "github.png"
        ))
        XCTAssertFalse(canApplyAccountIconUpdate(
            requestedIdentity: oldIdentity,
            currentIdentity: currentIdentity,
            requestedFilename: "github.png",
            currentFilename: "github.png"
        ))
        XCTAssertFalse(canApplyAccountIconUpdate(
            requestedIdentity: currentIdentity,
            currentIdentity: currentIdentity,
            requestedFilename: "github.png",
            currentFilename: "replacement.png"
        ))
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

        try assertSameIconSemantics(firstLoad, rasterizedData)
        try assertSameIconSemantics(cachedLoad, rasterizedData)

        try? FileManager.default.removeItem(at: directory)
    }

    func testAccountIconCacheNormalizesSmallAndLargeRasterSources() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let smallURL = URL(string: "https://example.com/storage/icons/small.png")!
        let largeURL = URL(string: "https://example.com/storage/icons/large.png")!
        let sources = [
            smallURL: try visiblePNGData(dimension: 16, metadata: "small source"),
            largeURL: try visiblePNGData(dimension: 512, metadata: "large source")
        ]
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, sources[request.url!]!)
        }
        let cache = AccountIconCache(session: makeMockedURLSession(), cacheDirectory: directory)

        for (url, sourceData) in sources {
            try assertNormalizedIcon(await cache.imageData(for: url), sourceData: sourceData)
        }

        try? FileManager.default.removeItem(at: directory)
    }

    func testAccountIconCacheNormalizesSmallAndLargeSVGRasterizerOutputs() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let smallURL = URL(string: "https://example.com/storage/icons/small.svg")!
        let largeURL = URL(string: "https://example.com/storage/icons/large.svg")!
        let smallSVG = Data("<svg id=\"small\"></svg>".utf8)
        let largeSVG = Data("<svg id=\"large\"></svg>".utf8)
        let outputs = [
            smallSVG: try visiblePNGData(dimension: 16, metadata: "small rasterizer output"),
            largeSVG: try visiblePNGData(dimension: 512, metadata: "large rasterizer output")
        ]
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, request.url == smallURL ? smallSVG : largeSVG)
        }
        let cache = AccountIconCache(
            session: makeMockedURLSession(),
            cacheDirectory: directory,
            rasterizeSVG: { outputs[$0] }
        )

        try assertNormalizedIcon(await cache.imageData(for: smallURL), sourceData: outputs[smallSVG])
        try assertNormalizedIcon(await cache.imageData(for: largeURL), sourceData: outputs[largeSVG])

        try? FileManager.default.removeItem(at: directory)
    }

    func testAccountIconCacheAcceptsExactSourceByteLimitAndRejectsNextByte() async throws {
        let exactURL = URL(string: "https://example.com/storage/icons/exact-bytes.png")!
        let excessURL = URL(string: "https://example.com/storage/icons/excess-bytes.png")!
        let exactData = try visiblePNGData(dimension: 32)
        var excessData = exactData
        excessData.append(0)
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, request.url == exactURL ? exactData : excessData)
        }
        let policy = iconCachePolicy(maximumSourceBytes: exactData.count)
        let exactDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let excessDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let exactCache = AccountIconCache(
            session: makeMockedURLSession(),
            cacheDirectory: exactDirectory,
            policy: policy
        )
        let excessCache = AccountIconCache(
            session: makeMockedURLSession(),
            cacheDirectory: excessDirectory,
            policy: policy
        )

        let accepted = await exactCache.imageData(for: exactURL)
        let rejected = await excessCache.imageData(for: excessURL)

        XCTAssertNotNil(accepted)
        XCTAssertNil(rejected)
        try? FileManager.default.removeItem(at: exactDirectory)
        try? FileManager.default.removeItem(at: excessDirectory)
    }

    func testAccountIconCacheAcceptsExactSourceDimensionAndRejectsNextDimension() async throws {
        let exactURL = URL(string: "https://example.com/storage/icons/exact-dimension.png")!
        let excessURL = URL(string: "https://example.com/storage/icons/excess-dimension.png")!
        let exactData = visiblePNGData(width: 64, height: 64)
        let excessData = visiblePNGData(width: 65, height: 64)
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, request.url == exactURL ? exactData : excessData)
        }
        let policy = iconCachePolicy(maximumSourceDimension: 64, maximumSourcePixels: 65 * 64)
        let exactDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let excessDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let exactCache = AccountIconCache(
            session: makeMockedURLSession(),
            cacheDirectory: exactDirectory,
            policy: policy
        )
        let excessCache = AccountIconCache(
            session: makeMockedURLSession(),
            cacheDirectory: excessDirectory,
            policy: policy
        )

        let accepted = await exactCache.imageData(for: exactURL)
        let rejected = await excessCache.imageData(for: excessURL)

        XCTAssertNotNil(accepted)
        XCTAssertNil(rejected)
        try? FileManager.default.removeItem(at: exactDirectory)
        try? FileManager.default.removeItem(at: excessDirectory)
    }

    func testAccountIconCacheAcceptsExactSourcePixelsAndRejectsNextPixel() async throws {
        let exactURL = URL(string: "https://example.com/storage/icons/exact-pixels.png")!
        let excessURL = URL(string: "https://example.com/storage/icons/excess-pixels.png")!
        let exactData = visiblePNGData(width: 63, height: 65)
        let excessData = visiblePNGData(width: 64, height: 64)
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, request.url == exactURL ? exactData : excessData)
        }
        let policy = iconCachePolicy(maximumSourceDimension: 65, maximumSourcePixels: 4_095)
        let exactDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let excessDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let exactCache = AccountIconCache(
            session: makeMockedURLSession(),
            cacheDirectory: exactDirectory,
            policy: policy
        )
        let excessCache = AccountIconCache(
            session: makeMockedURLSession(),
            cacheDirectory: excessDirectory,
            policy: policy
        )

        let accepted = await exactCache.imageData(for: exactURL)
        let rejected = await excessCache.imageData(for: excessURL)

        XCTAssertNotNil(accepted)
        XCTAssertNil(rejected)
        try? FileManager.default.removeItem(at: exactDirectory)
        try? FileManager.default.removeItem(at: excessDirectory)
    }

    func testAccountIconCacheEvictsLeastRecentlyUsedMemoryEntryAtExactByteLimit() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceData = try visiblePNGData(dimension: 128)
        let urls = (1...3).map { URL(string: "https://example.com/storage/icons/\($0).png")! }
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, sourceData)
        }
        let probeCache = AccountIconCache(session: makeMockedURLSession(), cacheDirectory: directory)
        let probedData = await probeCache.imageData(for: urls[0])
        let normalizedData = try XCTUnwrap(probedData)
        await probeCache.clear(sessionRevision: 0)
        let cache = AccountIconCache(
            session: makeMockedURLSession(),
            cacheDirectory: directory,
            policy: iconCachePolicy(maximumMemoryBytes: normalizedData.count * 2)
        )

        _ = await cache.imageData(for: urls[0])
        _ = await cache.imageData(for: urls[1])
        _ = await cache.imageData(for: urls[0])
        _ = await cache.imageData(for: urls[2])
        try FileManager.default.removeItem(at: directory)

        let firstData = await cache.imageData(for: urls[0], allowRemoteLoad: false)
        let secondData = await cache.imageData(for: urls[1], allowRemoteLoad: false)
        let thirdData = await cache.imageData(for: urls[2], allowRemoteLoad: false)
        XCTAssertNotNil(firstData)
        XCTAssertNil(secondData)
        XCTAssertNotNil(thirdData)
    }

    func testAccountIconCacheTrimsDiskWhenOnlyFileCountLimitIsExceeded() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceData = try visiblePNGData(dimension: 128)
        let urls = (1...3).map { URL(string: "https://example.com/storage/icons/count-\($0).png")! }
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, sourceData)
        }
        let cache = AccountIconCache(
            session: makeMockedURLSession(),
            cacheDirectory: directory,
            policy: iconCachePolicy(maximumDiskBytes: .max, maximumDiskFileCount: 2)
        )

        for url in urls {
            _ = await cache.imageData(for: url)
        }

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        )
        XCTAssertEqual(files.count, 2)
        try? FileManager.default.removeItem(at: directory)
    }

    func testAccountIconCacheTrimsDiskWhenOnlyByteLimitIsExceeded() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let probeDirectory = directory.deletingLastPathComponent()
            .appendingPathComponent("\(UUID().uuidString)-probe", isDirectory: true)
        let sourceData = try visiblePNGData(dimension: 128)
        let urls = (1...3).map { URL(string: "https://example.com/storage/icons/bytes-\($0).png")! }
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, sourceData)
        }
        let probe = AccountIconCache(session: makeMockedURLSession(), cacheDirectory: probeDirectory)
        let probeData = await probe.imageData(for: urls[0])
        let normalizedSize = try XCTUnwrap(probeData).count
        let cache = AccountIconCache(
            session: makeMockedURLSession(),
            cacheDirectory: directory,
            policy: iconCachePolicy(
                maximumDiskBytes: normalizedSize * 2,
                maximumDiskFileCount: 10
            )
        )

        for url in urls {
            _ = await cache.imageData(for: url)
        }

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        )
        let byteCount = try files.reduce(0) {
            $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        XCTAssertEqual(files.count, 2)
        XCTAssertLessThanOrEqual(byteCount, normalizedSize * 2)
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: probeDirectory)
    }

    func testAccountIconCacheTrimsNonAllowlistedEntryBeforeAllowedEntries() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceData = try visiblePNGData(dimension: 128)
        let allowedURLs = (1...3).map { URL(string: "https://example.com/storage/icons/allowed-\($0).png")! }
        let nonAllowedURL = URL(string: "https://example.com/storage/icons/non-allowed.png")!
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, sourceData)
        }
        let cache = AccountIconCache(
            session: makeMockedURLSession(),
            cacheDirectory: directory,
            policy: iconCachePolicy(maximumDiskBytes: .max, maximumDiskFileCount: 3)
        )
        await cache.prune(keeping: Set(allowedURLs), sessionRevision: 0)
        await cache.cache(data: sourceData, for: allowedURLs[0])
        await cache.cache(data: sourceData, for: allowedURLs[1])
        await cache.cache(data: sourceData, for: nonAllowedURL)

        _ = await cache.imageData(for: allowedURLs[2])

        let hasNonAllowed = await cache.hasCachedData(for: nonAllowedURL)
        XCTAssertFalse(hasNonAllowed)
        for url in allowedURLs {
            let hasAllowed = await cache.hasCachedData(for: url)
            XCTAssertTrue(hasAllowed)
        }
        try? FileManager.default.removeItem(at: directory)
    }

    func testAccountIconCacheCountsHiddenFilesDuringDiskTrimming() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hiddenFile = directory.appendingPathComponent(".hidden-cache-entry")
        try Data("hidden".utf8).write(to: hiddenFile)
        let sourceData = try visiblePNGData(dimension: 128)
        let url = URL(string: "https://example.com/storage/icons/visible.png")!
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, sourceData)
        }
        let cache = AccountIconCache(
            session: makeMockedURLSession(),
            cacheDirectory: directory,
            policy: iconCachePolicy(maximumDiskBytes: .max, maximumDiskFileCount: 1)
        )

        _ = await cache.imageData(for: url)

        XCTAssertFalse(FileManager.default.fileExists(atPath: hiddenFile.path))
        let hasVisible = await cache.hasCachedData(for: url)
        XCTAssertTrue(hasVisible)
        try? FileManager.default.removeItem(at: directory)
    }

    func testAccountIconCacheContinuesDiskTrimmingAfterRemovalFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceData = try visiblePNGData(dimension: 128)
        let urls = (1...3).map { URL(string: "https://example.com/storage/icons/failure-\($0).png")! }
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, sourceData)
        }
        let writer = AccountIconCache(cacheDirectory: directory)
        await writer.cache(data: sourceData, for: urls[0])
        let oldestFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: oldestFile.path
        )
        await writer.cache(data: sourceData, for: urls[1])
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where file != oldestFile
        {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 2)],
                ofItemAtPath: file.path
            )
        }
        let recorder = RemovalFailureRecorder()
        let cache = AccountIconCache(
            session: makeMockedURLSession(),
            fileManager: FailingRemovalFileManager(failingURL: oldestFile, recorder: recorder),
            cacheDirectory: directory,
            policy: iconCachePolicy(maximumDiskBytes: .max, maximumDiskFileCount: 2)
        )

        _ = await cache.imageData(for: urls[2])

        let remainingFiles = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(recorder.count, 1)
        XCTAssertEqual(remainingFiles.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldestFile.path))
        try? FileManager.default.removeItem(at: directory)
    }

    func testAccountIconCacheBoundsConcurrentDownloads() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let gate = ConcurrentOperationGate()
        let sourceData = try visiblePNGData(dimension: 16)
        let cache = AccountIconCache(
            session: makeGatedIconURLSession(gate: gate, sourceData: sourceData),
            cacheDirectory: directory,
            policy: iconCachePolicy(maximumConcurrentDownloads: 2)
        )
        let loads = (1...5).map { index in
            Task { await cache.imageData(for: URL(string: "https://example.com/storage/icons/download-\(index).png")!) }
        }

        try await waitUntil { gate.started.count >= 2 }
        try await waitUntil { await cache.resourceAdmissionState().queuedDownloads >= 3 }
        let admission = await cache.resourceAdmissionState()
        let peak = gate.peak
        gate.resumeCurrentAndNext(5)
        for load in loads { _ = await load.value }

        XCTAssertEqual(peak, 2)
        XCTAssertEqual(admission.activeDownloads, 2)
        XCTAssertEqual(admission.queuedDownloads, 3)
        try? FileManager.default.removeItem(at: directory)
    }

    func testAccountIconCacheMaintainsDownloadOwnershipAcrossQueuedAndTransferredCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let gate = ConcurrentOperationGate()
        let sourceData = try visiblePNGData(dimension: 16)
        let cache = AccountIconCache(
            session: makeGatedIconURLSession(gate: gate, sourceData: sourceData),
            cacheDirectory: directory,
            policy: iconCachePolicy(maximumConcurrentDownloads: 1)
        )
        let first = Task { await cache.imageData(for: URL(string: "https://example.com/storage/icons/first.png")!) }
        try await waitUntil { gate.started.contains("first.png") }
        let queuedCancellation = Task {
            await cache.imageData(for: URL(string: "https://example.com/storage/icons/queued-cancel.png")!)
        }
        try await waitUntil { await cache.resourceAdmissionState().queuedDownloads >= 1 }
        queuedCancellation.cancel()
        try await waitUntil { await cache.resourceAdmissionState().queuedDownloads == 0 }
        let transferredCancellation = Task {
            await cache.imageData(for: URL(string: "https://example.com/storage/icons/transferred-cancel.png")!)
        }
        try await waitUntil { await cache.resourceAdmissionState().queuedDownloads >= 1 }
        gate.resume(value: "first.png")
        try await waitUntil { gate.started.contains("transferred-cancel.png") }
        transferredCancellation.cancel()
        try await waitUntil { await cache.resourceAdmissionState().activeDownloads == 0 }
        let newcomer = Task {
            await cache.imageData(for: URL(string: "https://example.com/storage/icons/newcomer.png")!)
        }
        try await waitUntil { gate.started.contains("newcomer.png") }
        let newcomerAdmission = await cache.resourceAdmissionState()
        gate.resume(value: "newcomer.png")
        _ = await first.value
        let queuedValue = await queuedCancellation.value
        let transferredValue = await transferredCancellation.value
        _ = await newcomer.value

        XCTAssertNil(queuedValue)
        XCTAssertNil(transferredValue)
        XCTAssertFalse(gate.started.contains("queued-cancel.png"))
        XCTAssertEqual(newcomerAdmission.activeDownloads, 1)
        XCTAssertEqual(newcomerAdmission.queuedDownloads, 0)
        XCTAssertEqual(gate.peak, 1)
        try? FileManager.default.removeItem(at: directory)
    }

    func testAccountIconCacheMaintainsRasterOwnershipAcrossQueuedAndTransferredCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let gate = RasterizationGate()
        let rasterData = try visiblePNGData(dimension: 16)
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("<svg id=\"\(request.url!.lastPathComponent)\"></svg>".utf8))
        }
        let cache = AccountIconCache(
            session: makeMockedURLSession(),
            cacheDirectory: directory,
            rasterizeSVG: { data in
                let value = String(decoding: data, as: UTF8.self)
                await gate.suspend(value: value)
                return rasterData
            },
            policy: iconCachePolicy(maximumConcurrentRasterizations: 1)
        )
        let first = Task { await cache.imageData(for: URL(string: "https://example.com/storage/icons/first.svg")!) }
        try await waitUntil { await gate.started.contains("<svg id=\"first.svg\"></svg>") }
        let queuedCancellation = Task {
            await cache.imageData(for: URL(string: "https://example.com/storage/icons/queued-cancel.svg")!)
        }
        try await waitUntil { await cache.resourceAdmissionState().queuedRasterizations >= 1 }
        queuedCancellation.cancel()
        try await waitUntil { await cache.resourceAdmissionState().queuedRasterizations == 0 }
        let transferredCancellation = Task {
            await cache.imageData(for: URL(string: "https://example.com/storage/icons/transferred-cancel.svg")!)
        }
        try await waitUntil { await cache.resourceAdmissionState().queuedRasterizations >= 1 }
        await gate.resume(value: "<svg id=\"first.svg\"></svg>")
        try await waitUntil { await gate.started.contains("<svg id=\"transferred-cancel.svg\"></svg>") }
        transferredCancellation.cancel()
        await gate.resume(value: "<svg id=\"transferred-cancel.svg\"></svg>")
        try await waitUntil { await cache.resourceAdmissionState().activeRasterizations == 0 }
        let newcomer = Task {
            await cache.imageData(for: URL(string: "https://example.com/storage/icons/newcomer.svg")!)
        }
        try await waitUntil { await gate.started.contains("<svg id=\"newcomer.svg\"></svg>") }
        let newcomerAdmission = await cache.resourceAdmissionState()
        await gate.resume(value: "<svg id=\"newcomer.svg\"></svg>")
        _ = await first.value
        let queuedValue = await queuedCancellation.value
        let transferredValue = await transferredCancellation.value
        _ = await newcomer.value
        let started = await gate.started
        let peak = await gate.peak

        XCTAssertEqual(peak, 1)
        XCTAssertNil(queuedValue)
        XCTAssertNil(transferredValue)
        XCTAssertFalse(started.contains { $0.contains("queued-cancel.svg") })
        XCTAssertEqual(newcomerAdmission.activeRasterizations, 1)
        XCTAssertEqual(newcomerAdmission.queuedRasterizations, 0)
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

        try assertSameIconSemantics(firstResult, rasterizedData)
        for result in results {
            try assertSameIconSemantics(result, rasterizedData)
        }
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
        try assertSameIconSemantics(remainingResult, rasterData)
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
        try assertSameIconSemantics(loadedData, cachedData)
        await rasterizerStarted.wait()
        await cache.cancelUnownedRefreshes()
        await releaseRasterizer.open()

        XCTAssertEqual(cancelledRasterizer.count, 1)
        try assertSameIconSemantics(try Data(contentsOf: cacheFile), cachedData)
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

        try assertSameIconSemantics(migratedLoad, rasterizedData)
        try assertSameIconSemantics(cachedLoad, rasterizedData)

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

        try assertSameIconSemantics(loadedData, replacementData)
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

    func testAccountIconCachePublishesStaleIconBeforeRefreshedIcon() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = URL(string: "https://example.com/storage/icons/github.png")!
        let cachedData = visiblePNGData()
        let refreshedData = visiblePNGData(color: .systemRed)
        let gate = ConcurrentOperationGate()
        let cacheWriter = AccountIconCache(cacheDirectory: directory)
        await cacheWriter.cache(data: cachedData, for: url)
        let cacheFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)],
            ofItemAtPath: cacheFile.path
        )
        let cache = AccountIconCache(
            session: makeGatedIconURLSession(gate: gate, sourceData: refreshedData),
            cacheDirectory: directory
        )

        let updates = await cache.imageUpdates(for: url, allowRemoteLoad: true)
        let valuesReceived = expectation(description: "stale and refreshed icons")
        valuesReceived.expectedFulfillmentCount = 2
        let consumer = consumeIconUpdates(updates, received: valuesReceived)
        try await waitUntil { gate.started.contains(url.lastPathComponent) }
        gate.resume(value: url.lastPathComponent)
        await fulfillment(of: [valuesReceived], timeout: 1)
        await cache.clear(sessionRevision: 0)
        let values = await consumer.value

        XCTAssertEqual(values.count, 2)
        try assertSameIconSemantics(values.first, cachedData)
        try assertSameIconSemantics(values.last, refreshedData)
        try? FileManager.default.removeItem(at: directory)
    }

    func testAccountIconUpdateDeliveryRetainsInitialBeforePendingReplacement() async throws {
        let staleData = visiblePNGData()
        let refreshedData = visiblePNGData(color: .systemRed)
        let (updates, delivery) = AccountIconUpdateDelivery.make(allowsRemoteUpdates: true)

        delivery.publishReplacement(refreshedData)
        delivery.publishInitial(staleData)
        delivery.finish()

        var values: [Data] = []
        for await value in updates {
            values.append(value)
        }
        XCTAssertEqual(values.count, 2)
        try assertSameIconSemantics(values.first, staleData)
        try assertSameIconSemantics(values.last, refreshedData)
    }

    func testAccountIconCacheDoesNotPublishDuplicateBytes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = URL(string: "https://example.com/storage/icons/github.png")!
        let writer = AccountIconCache(cacheDirectory: directory)
        await writer.cache(data: visiblePNGData(), for: url)
        let cache = AccountIconCache(cacheDirectory: directory)
        let updates = await cache.imageUpdates(for: url, allowRemoteLoad: false)
        let initialReceived = expectation(description: "initial icon")
        let consumer = consumeIconUpdates(updates, received: initialReceived)
        await fulfillment(of: [initialReceived], timeout: 1)
        let loadedData = await cache.imageData(for: url, allowRemoteLoad: false)
        let initialData = try XCTUnwrap(loadedData)

        await cache.cache(data: initialData, for: url)
        await cache.clear(sessionRevision: 0)
        let values = await consumer.value

        XCTAssertEqual(values.count, 1)
        try? FileManager.default.removeItem(at: directory)
    }

    func testCacheOnlyObserverDoesNotReceiveActiveObserversRemoteRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = URL(string: "https://example.com/storage/icons/github.png")!
        let staleData = visiblePNGData()
        let refreshedData = visiblePNGData(color: .systemRed)
        let writer = AccountIconCache(cacheDirectory: directory)
        await writer.cache(data: staleData, for: url)
        let cacheFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)],
            ofItemAtPath: cacheFile.path
        )
        let gate = ConcurrentOperationGate()
        let cache = AccountIconCache(
            session: makeGatedIconURLSession(gate: gate, sourceData: refreshedData),
            cacheDirectory: directory
        )
        let cacheOnlyUpdates = await cache.imageUpdates(for: url, allowRemoteLoad: false)
        let activeUpdates = await cache.imageUpdates(for: url, allowRemoteLoad: true)
        let cacheOnlyInitial = expectation(description: "cache-only initial icon")
        let activeValues = expectation(description: "active initial and refreshed icons")
        activeValues.expectedFulfillmentCount = 2
        let cacheOnlyConsumer = consumeIconUpdates(cacheOnlyUpdates, received: cacheOnlyInitial)
        let activeConsumer = consumeIconUpdates(activeUpdates, received: activeValues)

        await fulfillment(of: [cacheOnlyInitial], timeout: 1)
        try await waitUntil { gate.started.contains(url.lastPathComponent) }
        gate.resume(value: url.lastPathComponent)
        await fulfillment(of: [activeValues], timeout: 1)
        await cache.clear(sessionRevision: 0)
        let cacheOnlyValues = await cacheOnlyConsumer.value
        let remoteValues = await activeConsumer.value

        XCTAssertEqual(cacheOnlyValues.count, 1)
        try assertSameIconSemantics(cacheOnlyValues.first, staleData)
        XCTAssertEqual(remoteValues.count, 2)
        try assertSameIconSemantics(remoteValues.first, staleData)
        try assertSameIconSemantics(remoteValues.last, refreshedData)
        try? FileManager.default.removeItem(at: directory)
    }

    func testAccountIconCacheBuffersNewestPublishedBytes() async throws {
        let initialData = visiblePNGData()
        let olderReplacement = visiblePNGData(color: .systemRed)
        let newestReplacement = visiblePNGData(color: .systemGreen)
        let (updates, delivery) = AccountIconUpdateDelivery.make(allowsRemoteUpdates: true)

        delivery.publishReplacement(olderReplacement)
        delivery.publishReplacement(newestReplacement)
        delivery.publishInitial(initialData)
        delivery.finish()

        var values: [Data] = []
        for await value in updates {
            values.append(value)
        }
        XCTAssertEqual(values.count, 2)
        try assertSameIconSemantics(values.first, initialData)
        try assertSameIconSemantics(values.last, newestReplacement)
    }

    func testAccountIconCacheRemovesUpdateObserverOnCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = URL(string: "https://example.com/storage/icons/github.png")!
        let gate = ConcurrentOperationGate()
        let cache = AccountIconCache(
            session: makeGatedIconURLSession(gate: gate, sourceData: visiblePNGData()),
            cacheDirectory: directory
        )
        let updates = await cache.imageUpdates(for: url, allowRemoteLoad: true)
        let consumer = consumeIconUpdates(updates)
        try await waitUntil { gate.started.contains(url.lastPathComponent) }

        consumer.cancel()
        let values = await consumer.value
        try await waitUntil { gate.active == 0 }

        XCTAssertTrue(values.isEmpty)
        try? FileManager.default.removeItem(at: directory)
    }

    func testAccountIconCacheDoesNotPublishAfterBackgroundRefreshCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = URL(string: "https://example.com/storage/icons/github.png")!
        let writer = AccountIconCache(cacheDirectory: directory)
        await writer.cache(data: visiblePNGData(), for: url)
        let cacheFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 0)],
            ofItemAtPath: cacheFile.path
        )
        let gate = ConcurrentOperationGate()
        let cache = AccountIconCache(
            session: makeGatedIconURLSession(gate: gate, sourceData: visiblePNGData(color: .systemRed)),
            cacheDirectory: directory
        )
        let updates = await cache.imageUpdates(for: url, allowRemoteLoad: true)
        let initialReceived = expectation(description: "initial stale icon")
        let consumer = consumeIconUpdates(updates, received: initialReceived)
        await fulfillment(of: [initialReceived], timeout: 1)
        try await waitUntil { gate.started.contains(url.lastPathComponent) }

        await cache.cancelUnownedRefreshes()
        try await waitUntil { gate.active == 0 }
        await cache.clear(sessionRevision: 0)
        let values = await consumer.value

        XCTAssertEqual(values.count, 1)
        try assertSameIconSemantics(values.first, visiblePNGData())
        try? FileManager.default.removeItem(at: directory)
    }

    func testAccountIconCacheClearFinishesUpdateObservers() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = URL(string: "https://example.com/storage/icons/github.png")!
        let writer = AccountIconCache(cacheDirectory: directory)
        await writer.cache(data: visiblePNGData(), for: url)
        let cache = AccountIconCache(cacheDirectory: directory)
        let updates = await cache.imageUpdates(for: url, allowRemoteLoad: false)
        let initialReceived = expectation(description: "initial icon")
        let consumer = consumeIconUpdates(updates, received: initialReceived)
        await fulfillment(of: [initialReceived], timeout: 1)

        await cache.clear(sessionRevision: 0)
        let values = await consumer.value

        XCTAssertEqual(values.count, 1)
        try? FileManager.default.removeItem(at: directory)
    }

    func testAccountIconCachePruneFinishesObserversForRemovedURLs() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = URL(string: "https://example.com/storage/icons/github.png")!
        let writer = AccountIconCache(cacheDirectory: directory)
        await writer.cache(data: visiblePNGData(), for: url)
        let cache = AccountIconCache(cacheDirectory: directory)
        let updates = await cache.imageUpdates(for: url, allowRemoteLoad: false)
        let initialReceived = expectation(description: "initial icon")
        let consumer = consumeIconUpdates(updates, received: initialReceived)
        await fulfillment(of: [initialReceived], timeout: 1)

        await cache.prune(keeping: [], sessionRevision: 0)
        let values = await consumer.value

        XCTAssertEqual(values.count, 1)
        try? FileManager.default.removeItem(at: directory)
    }

    func testAccountIconCacheSessionAdvanceFinishesUpdateObservers() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TwoFAuthTests.", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = URL(string: "https://example.com/storage/icons/github.png")!
        let writer = AccountIconCache(cacheDirectory: directory)
        await writer.cache(data: visiblePNGData(), for: url)
        let cache = AccountIconCache(cacheDirectory: directory)
        let updates = await cache.imageUpdates(for: url, allowRemoteLoad: false)
        let initialReceived = expectation(description: "initial icon")
        let consumer = consumeIconUpdates(updates, received: initialReceived)
        await fulfillment(of: [initialReceived], timeout: 1)

        await cache.advanceSession(to: 1)
        let values = await consumer.value

        XCTAssertEqual(values.count, 1)
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
