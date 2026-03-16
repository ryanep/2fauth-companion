import Foundation
import SwiftData

@MainActor
protocol AccountRepository {
    func ensureEncryptionKey() throws
    func decryptSecret(_ encryptedSecret: Data) throws -> String
    func syncAccounts(context: ModelContext, baseURL: URL, apiKey: String, includeSecrets: Bool) async -> SyncResult
    func wipeCachedData(context: ModelContext) throws
}
