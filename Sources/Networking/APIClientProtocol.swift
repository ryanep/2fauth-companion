import Foundation

@MainActor
protocol APIClient {
    func fetchAccounts(baseURL: URL, apiKey: String, includeSecrets: Bool) async throws -> [APIAccount]
}
