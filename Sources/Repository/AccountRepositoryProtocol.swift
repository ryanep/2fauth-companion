import Foundation
import SwiftData

@MainActor
protocol AccountRepository {
    func ensureEncryptionKey() throws
    func decryptSecret(_ encryptedSecret: Data) throws -> String
    func syncAccounts(context: ModelContext, baseURL: URL, apiKey: String, includeSecrets: Bool) async -> SyncResult
    func previewAccount(baseURL: URL, apiKey: String, uri: String, customOTP: String?) async throws -> APIAccount
    func createAccount(
        context: ModelContext,
        baseURL: URL,
        apiKey: String,
        requestBody: AccountCreationRequest
    ) async throws
    func wipeCachedData(context: ModelContext) throws
}
