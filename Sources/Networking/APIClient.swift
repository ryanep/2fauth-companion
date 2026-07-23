import Foundation

@MainActor
final class URLSessionAPIClient: APIClient {
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

    func previewAccount(baseURL: URL, apiKey: String, uri: String, customOTP: String?) async throws -> APIAccount {
        guard let url = endpointURL(baseURL: baseURL, path: "/api/v1/twofaccounts/preview", query: []) else {
            throw APIError.invalidURL
        }
        let body = try JSONEncoder().encode(OTPAuthURIRequest(uri: uri, customOTP: customOTP))
        return try await postAccount(url: url, apiKey: apiKey, body: body, expectedStatusCode: 200)
    }

    func createAccount(baseURL: URL, apiKey: String, requestBody: AccountCreationRequest) async throws -> APIAccount {
        guard let url = endpointURL(baseURL: baseURL, path: "/api/v1/twofaccounts", query: []) else {
            throw APIError.invalidURL
        }
        let body = try JSONEncoder().encode(requestBody)
        return try await postAccount(url: url, apiKey: apiKey, body: body, expectedStatusCode: 201)
    }

    private func postAccount(
        url: URL,
        apiKey: String,
        body: Data,
        expectedStatusCode: Int
    ) async throws -> APIAccount {

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw APIError.transport("Network error (\(error.code.rawValue))")
        } catch {
            throw APIError.transport("Network error")
        }

        return try decodeAccount(data: data, response: response, expectedStatusCode: expectedStatusCode)
    }

    private func decodeAccount(data: Data, response: URLResponse, expectedStatusCode: Int) throws -> APIAccount {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.transport("Invalid response")
        }

        switch httpResponse.statusCode {
        case expectedStatusCode:
            do {
                return try JSONDecoder().decode(APIAccount.self, from: data)
            } catch {
                throw APIError.decoding
            }
        case 400, 422:
            throw APIError.validation
        case 401:
            throw APIError.unauthorized
        case 403:
            throw APIError.forbidden
        case 500...599:
            throw APIError.server(statusCode: httpResponse.statusCode)
        default:
            throw APIError.transport("HTTP \(httpResponse.statusCode)")
        }
    }

    private func endpointURL(baseURL: URL, path: String, query: [URLQueryItem]) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let left = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let right = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [left, right].filter { !$0.isEmpty }.joined(separator: "/")
        components.queryItems = query.isEmpty ? nil : query
        return components.url
    }
}
