import XCTest

@testable import TwoFAuth

final class TransportURLValidatorTests: XCTestCase {
    func testValidateBaseURLAllowsHTTPSForSecureOnlyPolicy() {
        let result = TransportURLValidator.validateBaseURL("https://example.com", policy: .secureOnly)

        switch result {
        case .success(let url):
            XCTAssertEqual(url.scheme, "https")
        case .failure(let error):
            XCTFail("Expected success, got \(error)")
        }
    }

    func testValidateBaseURLAllowsHTTPForAllowHTTPPolicy() {
        let result = TransportURLValidator.validateBaseURL("http://example.com", policy: .allowHTTP)

        switch result {
        case .success(let url):
            XCTAssertEqual(url.scheme, "http")
        case .failure(let error):
            XCTFail("Expected success, got \(error)")
        }
    }

    func testValidateBaseURLRejectsHTTPForSecureOnlyPolicy() {
        let result = TransportURLValidator.validateBaseURL("http://example.com", policy: .secureOnly)

        XCTAssertEqual(result, .failure(.insecureSchemeNotAllowed))
    }

    func testValidateBaseURLRejectsInvalidURL() {
        let result = TransportURLValidator.validateBaseURL("not-a-url", policy: .allowHTTP)

        XCTAssertEqual(result, .failure(.invalid))
    }

    func testValidateBaseURLRejectsUnsupportedScheme() {
        let result = TransportURLValidator.validateBaseURL("ftp://example.com", policy: .allowHTTP)

        XCTAssertEqual(result, .failure(.invalid))
    }

    func testValidateBaseURLRejectsMissingHost() {
        let result = TransportURLValidator.validateBaseURL("https://", policy: .allowHTTP)

        XCTAssertEqual(result, .failure(.invalid))
    }
}
