import Foundation

@MainActor
final class URLSessionAPIClient: APIClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchAccounts(baseURL: URL, apiKey: String, includeSecrets: Bool) async throws -> [APIAccount] {
        #if DEBUG
            let fixtureMode = ProcessInfo.processInfo.environment["UI_TEST_LOGIN_FIXTURE"]
            if fixtureMode == "all-variants" {
                let body = "[{\"id\":101,\"service\":\"TOTP 6 SHA1\",\"account\":\"totp-6\",\"otp_type\":\"totp\",\"secret\":\"JBSWY3DPEHPK3PXP\",\"digits\":6,\"algorithm\":\"SHA1\",\"period\":30},{\"id\":102,\"service\":\"TOTP 7 SHA256\",\"account\":\"totp-7\",\"otp_type\":\"totp\",\"secret\":\"JBSWY3DPEHPK3PXP\",\"digits\":7,\"algorithm\":\"SHA256\",\"period\":30},{\"id\":103,\"service\":\"TOTP 8 SHA512\",\"account\":\"totp-8\",\"otp_type\":\"totp\",\"secret\":\"JBSWY3DPEHPK3PXP\",\"digits\":8,\"algorithm\":\"SHA512\",\"period\":30},{\"id\":104,\"service\":\"TOTP 9 MD5\",\"account\":\"totp-9\",\"otp_type\":\"totp\",\"secret\":\"JBSWY3DPEHPK3PXP\",\"digits\":9,\"algorithm\":\"MD5\",\"period\":30},{\"id\":105,\"service\":\"TOTP 10 SHA1\",\"account\":\"totp-10\",\"otp_type\":\"totp\",\"secret\":\"JBSWY3DPEHPK3PXP\",\"digits\":10,\"algorithm\":\"SHA1\",\"period\":30},{\"id\":106,\"service\":\"Steam Fixture\",\"account\":\"steam-user\",\"otp_type\":\"steamtotp\",\"secret\":\"JBSWY3DPEHPK3PXP\",\"digits\":6,\"algorithm\":\"SHA1\",\"period\":30}]"
                return try JSONDecoder().decode([APIAccount].self, from: Data(body.utf8))
            }

            if fixtureMode == "1" {
                let body = "[{\"id\":1,\"service\":\"GitHub\",\"account\":\"ui-test\",\"otp_type\":\"totp\",\"secret\":\"JBSWY3DPEHPK3PXP\",\"digits\":6,\"algorithm\":\"SHA1\",\"period\":30}]"
                return try JSONDecoder().decode([APIAccount].self, from: Data(body.utf8))
            }
        #endif

        guard
            let url = endpointURL(
                baseURL: baseURL, path: "/api/v1/twofaccounts",
                query: [
                    URLQueryItem(name: "withSecret", value: includeSecrets ? "1" : "0")
                ])
        else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw APIError.transport("Network error (\(error.code.rawValue))")
        } catch {
            throw APIError.transport("Network error")
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.transport("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw APIError.unauthorized
        case 403:
            throw APIError.forbidden
        case 500...599:
            throw APIError.server(statusCode: httpResponse.statusCode)
        default:
            throw APIError.transport("HTTP \(httpResponse.statusCode)")
        }

        do {
            return try JSONDecoder().decode([APIAccount].self, from: data)
        } catch {
            throw APIError.decoding
        }
    }

    private func endpointURL(baseURL: URL, path: String, query: [URLQueryItem]) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let left = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let right = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [left, right].filter { !$0.isEmpty }.joined(separator: "/")
        components.queryItems = query
        return components.url
    }
}
