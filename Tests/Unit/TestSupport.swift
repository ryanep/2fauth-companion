import Foundation
import SwiftData
import XCTest
@testable import TwoFAuth

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

func makeMockedURLSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: configuration)
}

func makeInMemoryModelContainer() throws -> ModelContainer {
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: AccountEntity.self, configurations: configuration)
}

func makeTestConfigStore(testName: String) -> AppConfigStore {
    let suiteName = "TwoFAuthTests.\(testName).\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        XCTFail("Could not create UserDefaults suite")
        return AppConfigStore()
    }
    defaults.removePersistentDomain(forName: suiteName)
    return AppConfigStore(defaults: defaults)
}
