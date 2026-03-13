import Foundation
import SwiftData

enum SyncResult {
    case success
    case unauthorized
    case transient(String)
}

@MainActor
final class AccountRepository {
    private let apiClient: APIClient
    private let cryptoStore: CryptoStore

    init(apiClient: APIClient, cryptoStore: CryptoStore) {
        self.apiClient = apiClient
        self.cryptoStore = cryptoStore
    }

    func ensureEncryptionKey() throws {
        _ = try cryptoStore.ensureEncryptionKey()
    }

    func decryptSecret(_ encrypted: Data) throws -> String {
        try cryptoStore.decrypt(encrypted)
    }

    func syncAccounts(context: ModelContext, baseURL: URL, apiKey: String, includeSecrets: Bool) async -> SyncResult {
        do {
            let remoteAccounts = try await apiClient.fetchAccounts(
                baseURL: baseURL,
                apiKey: apiKey,
                includeSecrets: includeSecrets
            )
            try upsert(remoteAccounts: remoteAccounts, context: context)
            return .success
        } catch APIError.unauthorized {
            return .unauthorized
        } catch APIError.forbidden {
            return .unauthorized
        } catch APIError.server(let code) {
            return .transient("Server error (\(code))")
        } catch APIError.transport(let message) {
            return .transient(message)
        } catch {
            return .transient("Sync failed")
        }
    }

    func wipeCachedData(context: ModelContext) throws {
        let all = try context.fetch(FetchDescriptor<AccountEntity>())
        for account in all {
            context.delete(account)
        }
        try context.save()
    }

    private func upsert(remoteAccounts: [APIAccount], context: ModelContext) throws {
        let existing = try context.fetch(FetchDescriptor<AccountEntity>())
        var byID: [Int: AccountEntity] = [:]
        for account in existing {
            byID[account.remoteID] = account
        }

        var seen: Set<Int> = []
        let now = Date()
        for remote in remoteAccounts {
            guard let id = remote.id else {
                continue
            }
            seen.insert(id)

            let entity = byID[id] ?? AccountEntity(
                remoteID: id,
                groupID: remote.groupID,
                service: remote.service,
                account: remote.account,
                icon: remote.icon,
                otpType: remote.otpType,
                digits: remote.digits,
                algorithm: remote.algorithm,
                period: remote.period,
                counter: remote.counter,
                encryptedSecret: nil,
                updatedAt: now
            )

            entity.groupID = remote.groupID
            entity.service = remote.service
            entity.account = remote.account
            entity.icon = remote.icon
            entity.otpType = remote.otpType
            entity.digits = remote.digits
            entity.algorithm = remote.algorithm
            entity.period = remote.period
            entity.counter = remote.counter
            entity.updatedAt = now

            if let secret = remote.secret {
                entity.encryptedSecret = try cryptoStore.encrypt(secret)
            }

            if byID[id] == nil {
                context.insert(entity)
                byID[id] = entity
            }
        }

        for account in existing where !seen.contains(account.remoteID) {
            context.delete(account)
        }

        try context.save()
    }
}
