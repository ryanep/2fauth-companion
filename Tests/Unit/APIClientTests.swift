import Foundation
import XCTest

@testable import TwoFAuth

@MainActor
final class APIClientTests: XCTestCase {
    private let baseURL = URL(string: "https://example.com")!

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testFetchAccountsSuccessDecodesResponse() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.com/api/v1/twofaccounts?withSecret=1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")

            let json = """
                [{"id":1,"group_id":2,"service":"GitHub","account":"ryan","icon":null,"otp_type":"totp","secret":null,"digits":6,"algorithm":"SHA1","period":30,"counter":null}]
                """
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(json.utf8))
        }

        let sut = APIClient(session: makeMockedURLSession())
        let accounts = try await sut.fetchAccounts(baseURL: baseURL, apiKey: "test-key", includeSecrets: true)

        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.id, 1)
        XCTAssertEqual(accounts.first?.otpType, "totp")
    }

    func testFetchAccountsUnauthorizedMaps401() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let sut = APIClient(session: makeMockedURLSession())

        do {
            _ = try await sut.fetchAccounts(baseURL: baseURL, apiKey: "test-key", includeSecrets: false)
            XCTFail("Expected unauthorized error")
        } catch APIError.unauthorized {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchAccountsForbiddenMaps403() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let sut = APIClient(session: makeMockedURLSession())

        do {
            _ = try await sut.fetchAccounts(baseURL: baseURL, apiKey: "test-key", includeSecrets: false)
            XCTFail("Expected forbidden error")
        } catch APIError.forbidden {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchAccountsServerErrorMaps5xx() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let sut = APIClient(session: makeMockedURLSession())

        do {
            _ = try await sut.fetchAccounts(baseURL: baseURL, apiKey: "test-key", includeSecrets: false)
            XCTFail("Expected server error")
        } catch APIError.server(let statusCode) {
            XCTAssertEqual(statusCode, 503)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchAccountsTransportError() async {
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.timedOut)
        }

        let sut = APIClient(session: makeMockedURLSession())

        do {
            _ = try await sut.fetchAccounts(baseURL: baseURL, apiKey: "test-key", includeSecrets: false)
            XCTFail("Expected transport error")
        } catch APIError.transport(let message) {
            XCTAssertFalse(message.isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFetchAccountsDecodingError() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("{\"not\":\"an array\"}".utf8))
        }

        let sut = APIClient(session: makeMockedURLSession())

        do {
            _ = try await sut.fetchAccounts(baseURL: baseURL, apiKey: "test-key", includeSecrets: false)
            XCTFail("Expected decoding error")
        } catch APIError.decoding {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
