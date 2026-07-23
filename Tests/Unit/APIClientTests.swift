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
                [{"id":1,"service":"GitHub","account":"ryan","otp_type":"totp","secret":null,"digits":6,"algorithm":"SHA1","period":30}]
                """
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(json.utf8))
        }

        let sut = URLSessionAPIClient(session: makeMockedURLSession())
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

        let sut = URLSessionAPIClient(session: makeMockedURLSession())

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

        let sut = URLSessionAPIClient(session: makeMockedURLSession())

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

        let sut = URLSessionAPIClient(session: makeMockedURLSession())

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

        let sut = URLSessionAPIClient(session: makeMockedURLSession())

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

        let sut = URLSessionAPIClient(session: makeMockedURLSession())

        do {
            _ = try await sut.fetchAccounts(baseURL: baseURL, apiKey: "test-key", includeSecrets: false)
            XCTFail("Expected decoding error")
        } catch APIError.decoding {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPreviewAccountPostsURIAndSteamOverride() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.com/api/v1/twofaccounts/preview")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            let body = try XCTUnwrap(requestBodyData(request))
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(payload["uri"], "otpauth://totp/Steam:user?secret=ABC")
            XCTAssertEqual(payload["custom_otp"], "steamtotp")

            let json = """
                {"id":null,"service":"Steam","account":"user","otp_type":"steamtotp","secret":"ABC","digits":5,"algorithm":"SHA1","period":30}
                """
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(json.utf8))
        }

        let sut = URLSessionAPIClient(session: makeMockedURLSession())
        let account = try await sut.previewAccount(
            baseURL: baseURL,
            apiKey: "test-key",
            uri: "otpauth://totp/Steam:user?secret=ABC",
            customOTP: "steamtotp"
        )

        XCTAssertEqual(account.otpType, "steamtotp")
        XCTAssertEqual(account.digits, .five)
    }

    func testCreateAccountPostsAllFieldsAndDecodesCreatedAccount() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://example.com/api/v1/twofaccounts")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try XCTUnwrap(requestBodyData(request))
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(payload["service"] as? String, "Example")
            XCTAssertEqual(payload["account"] as? String, "person@example.com")
            XCTAssertEqual(payload["otp_type"] as? String, "totp")
            XCTAssertEqual(payload["digits"] as? Int, 6)
            XCTAssertEqual(payload["algorithm"] as? String, "SHA1")
            XCTAssertEqual(payload["period"] as? Int, 30)

            let json = """
                {"id":42,"service":"Example","account":"person@example.com","otp_type":"totp","secret":"JBSWY3DPEHPK3PXP","digits":6,"algorithm":"SHA1","period":30}
                """
            let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            return (response, Data(json.utf8))
        }

        let sut = URLSessionAPIClient(session: makeMockedURLSession())
        let account = try await sut.createAccount(
            baseURL: baseURL,
            apiKey: "test-key",
            requestBody: AccountCreationRequest(
                service: "Example",
                account: "person@example.com",
                icon: nil,
                otpType: "totp",
                secret: "JBSWY3DPEHPK3PXP",
                digits: 6,
                algorithm: "SHA1",
                period: 30
            )
        )

        XCTAssertEqual(account.id, 42)
    }

    func testCreateAccountMapsForbiddenWithoutRetrying() async {
        var requestCount = 0
        MockURLProtocol.requestHandler = { request in
            requestCount += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let sut = URLSessionAPIClient(session: makeMockedURLSession())
        do {
            _ = try await sut.createAccount(
                baseURL: baseURL,
                apiKey: "test-key",
                requestBody: AccountCreationRequest(
                    service: nil,
                    account: "person@example.com",
                    icon: nil,
                    otpType: "totp",
                    secret: "JBSWY3DPEHPK3PXP",
                    digits: 6,
                    algorithm: "SHA1",
                    period: 30
                )
            )
            XCTFail("Expected forbidden error")
        } catch APIError.forbidden {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(requestCount, 1)
    }
}
