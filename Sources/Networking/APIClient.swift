import Foundation

@MainActor
final class APIClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchAccounts(baseURL: URL, apiKey: String, includeSecrets: Bool) async throws -> [APIAccount] {
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
