import Foundation

@MainActor
protocol APIClient {
    func fetchAccounts(baseURL: URL, apiKey: String, includeSecrets: Bool) async throws -> [APIAccount]
    func previewAccount(baseURL: URL, apiKey: String, uri: String, customOTP: String?) async throws -> APIAccount
    func createAccount(baseURL: URL, apiKey: String, requestBody: AccountCreationRequest) async throws -> APIAccount
}
