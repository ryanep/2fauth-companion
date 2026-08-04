import Foundation
import SwiftData
import XCTest

@testable import TwoFAuth

private final class RepositoryRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isSuspended = false
    private let release = DispatchSemaphore(value: 0)

    func suspendResponse() {
        lock.withLock { isSuspended = true }
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

@MainActor
final class AccountRepositoryTests: XCTestCase {
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

    func testSyncAccountsSuccessInsertsEntities() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = """
                [{"id":101,"service":"GitHub","account":"ryan","icon":"github.svg","otp_type":"totp","secret":null,"digits":6,"algorithm":"SHA1","period":30}]
                """
            return (response, Data(json.utf8))
        }

        let container = try makeInMemoryModelContainer()
        let context = ModelContext(container)
        let sut = makeRepository()

        let result = await sut.syncAccounts(
            context: context,
            baseURL: URL(string: "https://example.com")!,
            apiKey: "key",
            includeSecrets: true,
            isCurrentSession: { true }
        )

        XCTAssertTrue(matches(result, expected: .success))
        let stored = try context.fetch(FetchDescriptor<AccountEntity>())
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.remoteID, 101)
        XCTAssertEqual(stored.first?.iconFilename, "github.svg")
    }

    func testSyncAccountsUpdatesIconMetadata() async throws {
        let container = try makeInMemoryModelContainer()
        let context = ModelContext(container)
        let sut = makeRepository()

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = """
                [{"id":101,"service":"GitHub","account":"ryan","icon":"old.svg","otp_type":"totp","secret":null,"digits":6,"algorithm":"SHA1","period":30}]
                """
            return (response, Data(json.utf8))
        }
        _ = await sut.syncAccounts(
            context: context,
            baseURL: URL(string: "https://example.com")!,
            apiKey: "key",
            includeSecrets: false,
            isCurrentSession: { true }
        )

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = """
                [{"id":101,"service":"GitHub","account":"ryan","icon":"new.svg","otp_type":"totp","secret":null,"digits":6,"algorithm":"SHA1","period":30}]
                """
            return (response, Data(json.utf8))
        }
        _ = await sut.syncAccounts(
            context: context,
            baseURL: URL(string: "https://example.com")!,
            apiKey: "key",
            includeSecrets: false,
            isCurrentSession: { true }
        )

        let stored = try XCTUnwrap(context.fetch(FetchDescriptor<AccountEntity>()).first)
        XCTAssertEqual(stored.iconFilename, "new.svg")
    }

    func testSyncAccountsMapsUnauthorizedFor401() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let container = try makeInMemoryModelContainer()
        let context = ModelContext(container)
        let sut = makeRepository()

        let result = await sut.syncAccounts(
            context: context,
            baseURL: URL(string: "https://example.com")!,
            apiKey: "key",
            includeSecrets: false,
            isCurrentSession: { true }
        )

        XCTAssertTrue(matches(result, expected: .unauthorized))
    }

    func testSyncAccountsMapsUnauthorizedFor403() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let container = try makeInMemoryModelContainer()
        let context = ModelContext(container)
        let sut = makeRepository()

        let result = await sut.syncAccounts(
            context: context,
            baseURL: URL(string: "https://example.com")!,
            apiKey: "key",
            includeSecrets: false,
            isCurrentSession: { true }
        )

        XCTAssertTrue(matches(result, expected: .unauthorized))
    }

    func testSyncAccountsMapsServerErrorToLocalizedMessage() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 502, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let container = try makeInMemoryModelContainer()
        let context = ModelContext(container)
        let sut = makeRepository()

        let result = await sut.syncAccounts(
            context: context,
            baseURL: URL(string: "https://example.com")!,
            apiKey: "key",
            includeSecrets: false,
            isCurrentSession: { true }
        )

        guard case .transient(let message) = result else {
            return XCTFail("Expected transient message")
        }
        XCTAssertEqual(message, String.localizedStringWithFormat(String(localized: "sync.error.server_error"), 502))
    }

    func testSyncAccountsMapsTransportErrors() async throws {
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        let container = try makeInMemoryModelContainer()
        let context = ModelContext(container)
        let sut = makeRepository()

        let result = await sut.syncAccounts(
            context: context,
            baseURL: URL(string: "https://example.com")!,
            apiKey: "key",
            includeSecrets: false,
            isCurrentSession: { true }
        )

        guard case .transient(let message) = result else {
            return XCTFail("Expected transient message")
        }
        XCTAssertFalse(message.isEmpty)
    }

    func testSyncAccountsMapsDecodingErrorsToGenericMessage() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("{\"bad\":\"payload\"}".utf8))
        }

        let container = try makeInMemoryModelContainer()
        let context = ModelContext(container)
        let sut = makeRepository()

        let result = await sut.syncAccounts(
            context: context,
            baseURL: URL(string: "https://example.com")!,
            apiKey: "key",
            includeSecrets: false,
            isCurrentSession: { true }
        )

        guard case .transient(let message) = result else {
            return XCTFail("Expected transient message")
        }
        XCTAssertEqual(message, String(localized: "sync.error.generic_failed"))
    }

    func testSyncAccountsDoesNotApplySuccessfulResponseAfterSessionInvalidation() async throws {
        let gate = RepositoryRequestGate()
        MockURLProtocol.requestHandler = { request in
            gate.suspendResponse()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = """
                [{"id":101,"service":"Old","account":"old","icon":"old.svg","otp_type":"totp","secret":null,"digits":6,"algorithm":"SHA1","period":30}]
                """
            return (response, Data(json.utf8))
        }
        let container = try makeInMemoryModelContainer()
        let context = ModelContext(container)
        context.insert(AccountEntity(
            remoteID: 202,
            service: "Replacement",
            account: "replacement",
            otpType: "totp",
            digits: 6,
            algorithm: "SHA1",
            period: 30,
            iconFilename: "replacement.svg",
            encryptedSecret: nil,
            updatedAt: Date()
        ))
        try context.save()
        let sut = makeRepository()
        var isCurrentSession = true

        let sync = Task {
            await sut.syncAccounts(
                context: context,
                baseURL: URL(string: "https://example.com")!,
                apiKey: "key",
                includeSecrets: false,
                isCurrentSession: { isCurrentSession }
            )
        }
        await gate.waitUntilSuspended()
        isCurrentSession = false
        gate.resumeResponse()
        let result = await sync.value

        XCTAssertTrue(matches(result, expected: .stale))
        XCTAssertEqual(try context.fetch(FetchDescriptor<AccountEntity>()).map(\.remoteID), [202])
    }

    func testSyncAccountsMapsUnauthorizedToStaleAfterSessionInvalidation() async throws {
        let gate = RepositoryRequestGate()
        MockURLProtocol.requestHandler = { request in
            gate.suspendResponse()
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let container = try makeInMemoryModelContainer()
        let context = ModelContext(container)
        let sut = makeRepository()
        var isCurrentSession = true

        let sync = Task {
            await sut.syncAccounts(
                context: context,
                baseURL: URL(string: "https://example.com")!,
                apiKey: "key",
                includeSecrets: false,
                isCurrentSession: { isCurrentSession }
            )
        }
        await gate.waitUntilSuspended()
        isCurrentSession = false
        gate.resumeResponse()
        let result = await sync.value

        XCTAssertTrue(matches(result, expected: .stale))
    }

    func testCreateAccountStoresReturnedSecretEncrypted() async throws {
        MockURLProtocol.requestHandler = { request in
            let json = """
                {"id":42,"service":"Example","account":"person@example.com","icon":"example.svg","otp_type":"totp","secret":"JBSWY3DPEHPK3PXP","digits":6,"algorithm":"SHA1","period":30}
                """
            let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            return (response, Data(json.utf8))
        }

        let container = try makeInMemoryModelContainer()
        let context = ModelContext(container)
        let sut = makeRepository()
        try sut.ensureEncryptionKey()

        try await sut.createAccount(
            context: context,
            baseURL: URL(string: "https://example.com")!,
            apiKey: "key",
            requestBody: AccountCreationRequest(
                service: "Example",
                account: "person@example.com",
                icon: nil,
                otpType: "totp",
                secret: "JBSWY3DPEHPK3PXP",
                digits: 6,
                algorithm: "SHA1",
                period: 30
            ),
            isCurrentSession: { true }
        )

        let stored = try XCTUnwrap(context.fetch(FetchDescriptor<AccountEntity>()).first)
        let encryptedSecret = try XCTUnwrap(stored.encryptedSecret)
        XCTAssertNotEqual(encryptedSecret, Data("JBSWY3DPEHPK3PXP".utf8))
        XCTAssertEqual(try sut.decryptSecret(encryptedSecret), "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(stored.iconFilename, "example.svg")
    }

    func testCreateAccountDoesNotMutateAfterSessionInvalidation() async throws {
        let gate = RepositoryRequestGate()
        MockURLProtocol.requestHandler = { request in
            gate.suspendResponse()
            let json = """
                {"id":42,"service":"Old","account":"old@example.com","icon":"old.svg","otp_type":"totp","secret":"JBSWY3DPEHPK3PXP","digits":6,"algorithm":"SHA1","period":30}
                """
            let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            return (response, Data(json.utf8))
        }
        let container = try makeInMemoryModelContainer()
        let context = ModelContext(container)
        let sut = makeRepository()
        var isCurrentSession = true

        let creation = Task {
            try await sut.createAccount(
                context: context,
                baseURL: URL(string: "https://example.com")!,
                apiKey: "key",
                requestBody: AccountCreationRequest(
                    service: "Old",
                    account: "old@example.com",
                    icon: nil,
                    otpType: "totp",
                    secret: "JBSWY3DPEHPK3PXP",
                    digits: 6,
                    algorithm: "SHA1",
                    period: 30
                ),
                isCurrentSession: { isCurrentSession }
            )
        }
        await gate.waitUntilSuspended()
        isCurrentSession = false
        gate.resumeResponse()

        do {
            try await creation.value
            XCTFail("Expected stale session")
        } catch AccountRepositoryError.staleSession {
        } catch {
            XCTFail("Expected stale session, got \(error)")
        }
        XCTAssertTrue(try context.fetch(FetchDescriptor<AccountEntity>()).isEmpty)
    }

    private func makeRepository() -> DefaultAccountRepository {
        let apiClient = URLSessionAPIClient(session: makeMockedURLSession())
        let cryptoStore = AESGCMCryptoStore(secretStore: secretStore)
        return DefaultAccountRepository(apiClient: apiClient, cryptoStore: cryptoStore)
    }

    private func matches(_ actual: SyncResult, expected: SyncResult) -> Bool {
        switch (actual, expected) {
        case (.success, .success), (.unauthorized, .unauthorized), (.stale, .stale):
            return true
        default:
            return false
        }
    }
}
