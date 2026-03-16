import Foundation
import SwiftData
import XCTest
@testable import TwoFAuth

@MainActor
final class AccountRepositoryTests: XCTestCase {
    nonisolated(unsafe) private let secretStore = SecretStore()

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
            [{"id":101,"group_id":1,"service":"GitHub","account":"ryan","icon":null,"otp_type":"totp","secret":null,"digits":6,"algorithm":"SHA1","period":30,"counter":null}]
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
            includeSecrets: true
        )

        XCTAssertTrue(matches(result, expected: .success))
        let stored = try context.fetch(FetchDescriptor<AccountEntity>())
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.remoteID, 101)
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
            includeSecrets: false
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
            includeSecrets: false
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
            includeSecrets: false
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
            includeSecrets: false
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
            includeSecrets: false
        )

        guard case .transient(let message) = result else {
            return XCTFail("Expected transient message")
        }
        XCTAssertEqual(message, String(localized: "sync.error.generic_failed"))
    }

    private func makeRepository() -> AccountRepository {
        let apiClient = APIClient(session: makeMockedURLSession())
        let cryptoStore = CryptoStore(secretStore: secretStore)
        return AccountRepository(apiClient: apiClient, cryptoStore: cryptoStore)
    }

    private func matches(_ actual: SyncResult, expected: SyncResult) -> Bool {
        switch (actual, expected) {
        case (.success, .success), (.unauthorized, .unauthorized):
            return true
        default:
            return false
        }
    }
}
