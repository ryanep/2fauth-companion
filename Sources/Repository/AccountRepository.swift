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
            ErrorReporter.report("repository.sync_server_error", metadata: ["status": String(code)])
            return .transient(
                String.localizedStringWithFormat(
                    String(localized: "sync.error.server_error"),
                    code
                )
            )
        } catch APIError.transport(let message) {
            ErrorReporter.report("repository.sync_transport_error")
            return .transient(message)
        } catch {
            ErrorReporter.report("repository.sync_generic_error")
            return .transient(String(localized: "sync.error.generic_failed"))
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

        var hasAnyMutation = false

        var seen: Set<Int> = []
        let now = Date()
        for remote in remoteAccounts {
            guard let id = remote.id else {
                continue
            }
            seen.insert(id)

            guard let entity = byID[id] else {
                let insertedEntity = AccountEntity(
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
                if let secret = remote.secret {
                    insertedEntity.encryptedSecret = try cryptoStore.encrypt(secret)
                }

                context.insert(insertedEntity)
                byID[id] = insertedEntity
                hasAnyMutation = true
                continue
            }

            let metadataChanged =
                entity.groupID != remote.groupID || entity.service != remote.service || entity.account != remote.account
                || entity.icon != remote.icon || entity.otpType != remote.otpType || entity.digits != remote.digits
                || entity.algorithm != remote.algorithm || entity.period != remote.period
                || entity.counter != remote.counter

            var secretChanged = false
            if let remoteSecret = remote.secret {
                let shouldRewriteSecret: Bool
                if let encryptedSecret = entity.encryptedSecret {
                    if let localSecret = try? cryptoStore.decrypt(encryptedSecret) {
                        shouldRewriteSecret = localSecret != remoteSecret
                    } else {
                        shouldRewriteSecret = true
                    }
                } else {
                    shouldRewriteSecret = true
                }

                if shouldRewriteSecret {
                    entity.encryptedSecret = try cryptoStore.encrypt(remoteSecret)
                    secretChanged = true
                }
            }

            if metadataChanged || secretChanged {
                if metadataChanged {
                    entity.groupID = remote.groupID
                    entity.service = remote.service
                    entity.account = remote.account
                    entity.icon = remote.icon
                    entity.otpType = remote.otpType
                    entity.digits = remote.digits
                    entity.algorithm = remote.algorithm
                    entity.period = remote.period
                    entity.counter = remote.counter
                }

                entity.updatedAt = now
                hasAnyMutation = true
            }
        }

        for account in existing where !seen.contains(account.remoteID) {
            context.delete(account)
            hasAnyMutation = true
        }

        if hasAnyMutation {
            try context.save()
        }
    }
}
