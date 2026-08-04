import Foundation

struct AccountIconDownloader {
    private let session: URLSession
    private let maximumSourceBytes: Int

    init(session: URLSession?, maximumSourceBytes: Int) {
        self.session = session ?? Self.makeSession()
        self.maximumSourceBytes = maximumSourceBytes
    }

    func downloadImageData(from url: URL) async throws -> Data? {
        let (bytes, response) = try await session.bytes(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
            httpResponse.statusCode == 200,
            httpResponse.expectedContentLength <= Int64(maximumSourceBytes),
            let responseURL = httpResponse.url,
            AccountIconURLResolver.sameOrigin(responseURL, url),
            responseURL.standardized.path == url.standardized.path
        else {
            return nil
        }

        var data = Data()
        if httpResponse.expectedContentLength > 0 {
            data.reserveCapacity(Int(httpResponse.expectedContentLength))
        }
        for try await byte in bytes {
            guard !Task.isCancelled else {
                throw CancellationError()
            }
            guard data.count < maximumSourceBytes else {
                throw URLError(.dataLengthExceedsMaximum)
            }
            data.append(byte)
        }
        return data
    }

    private static func makeSession() -> URLSession {
        URLSession(
            configuration: .ephemeral,
            delegate: AccountIconURLSessionDelegate(),
            delegateQueue: nil
        )
    }
}

private final class AccountIconURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
