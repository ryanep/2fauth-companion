import Foundation
import SwiftData

enum SyncResult {
    case success
    case unauthorized
    case transient(String)
}

enum AccountRepositoryError: Error {
    case unsupportedOTPType
    case createdButNotCached
}

@MainActor
final class DefaultAccountRepository: AccountRepository {
    private let apiClient: any APIClient
    private let cryptoStore: any CryptoStore

    init(apiClient: any APIClient, cryptoStore: any CryptoStore) {
        self.apiClient = apiClient
        self.cryptoStore = cryptoStore
    }

    func ensureEncryptionKey() throws {
        _ = try cryptoStore.ensureEncryptionKey()
    }

    func decryptSecret(_ encryptedSecret: Data) throws -> String {
        try cryptoStore.decrypt(encryptedSecret)
    }

    func syncAccounts(context: ModelContext, baseURL: URL, apiKey: String, includeSecrets: Bool) async -> SyncResult {
        do {
            let remoteAccounts = try await apiClient.fetchAccounts(
                baseURL: baseURL,
                apiKey: apiKey,
                includeSecrets: includeSecrets
            )
            let filteredAccounts = remoteAccounts.filter { $0.otpType.lowercased() != "hotp" }
            try upsert(remoteAccounts: filteredAccounts, context: context)
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

    func previewAccount(baseURL: URL, apiKey: String, uri: String, customOTP: String?) async throws -> APIAccount {
        let account = try await apiClient.previewAccount(
            baseURL: baseURL,
            apiKey: apiKey,
            uri: uri,
            customOTP: customOTP
        )
        guard isSupportedOTPType(account.otpType) else {
            throw AccountRepositoryError.unsupportedOTPType
        }
        return account
    }

    func createAccount(
        context: ModelContext,
        baseURL: URL,
        apiKey: String,
        requestBody: AccountCreationRequest
    ) async throws {
        let account = try await apiClient.createAccount(baseURL: baseURL, apiKey: apiKey, requestBody: requestBody)
        guard isSupportedOTPType(account.otpType) else {
            throw AccountRepositoryError.unsupportedOTPType
        }
        do {
            try upsert(remoteAccount: account, context: context)
        } catch {
            throw AccountRepositoryError.createdButNotCached
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
        var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.remoteID, $0) })

        var hasAnyMutation = false
        var seen: Set<Int> = []
        let now = Date()

        for remote in remoteAccounts {
            guard let id = remote.id else {
                continue
            }
            seen.insert(id)

            guard let entity = byID[id] else {
                let insertedEntity = try makeEntity(for: remote, id: id, updatedAt: now)
                context.insert(insertedEntity)
                byID[id] = insertedEntity
                hasAnyMutation = true
                continue
            }

            let metadataChanged = hasMetadataChanges(entity: entity, remote: remote)
            let secretChanged = try updateSecretIfNeeded(remoteSecret: remote.secret, entity: entity)

            if metadataChanged || secretChanged {
                if metadataChanged {
                    applyMetadata(from: remote, to: entity)
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

    private func upsert(remoteAccount: APIAccount, context: ModelContext) throws {
        guard
            let id = remoteAccount.id,
            let secret = remoteAccount.secret,
            !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw APIError.decoding
        }

        let existing = try context.fetch(FetchDescriptor<AccountEntity>())
        let now = Date()
        if let entity = existing.first(where: { $0.remoteID == id }) {
            applyMetadata(from: remoteAccount, to: entity)
            entity.encryptedSecret = try cryptoStore.encrypt(secret)
            entity.updatedAt = now
        } else {
            context.insert(try makeEntity(for: remoteAccount, id: id, updatedAt: now))
        }
        try context.save()
    }

    private func makeEntity(for remote: APIAccount, id: Int, updatedAt: Date) throws -> AccountEntity {
        let entity = AccountEntity(
            remoteID: id,
            service: remote.service,
            account: remote.account,
            otpType: remote.otpType,
            digits: remote.digits?.rawValue,
            algorithm: remote.algorithm?.rawValue,
            period: remote.period,
            encryptedSecret: nil,
            updatedAt: updatedAt
        )

        if let secret = remote.secret {
            entity.encryptedSecret = try cryptoStore.encrypt(secret)
        }

        return entity
    }

    private func hasMetadataChanges(entity: AccountEntity, remote: APIAccount) -> Bool {
        entity.service != remote.service
            || entity.account != remote.account
            || entity.otpType != remote.otpType
            || entity.digits != remote.digits?.rawValue
            || entity.algorithm != remote.algorithm?.rawValue
            || entity.period != remote.period
    }

    private func applyMetadata(from remote: APIAccount, to entity: AccountEntity) {
        entity.service = remote.service
        entity.account = remote.account
        entity.otpType = remote.otpType
        entity.digits = remote.digits?.rawValue
        entity.algorithm = remote.algorithm?.rawValue
        entity.period = remote.period
    }

    private func updateSecretIfNeeded(remoteSecret: String?, entity: AccountEntity) throws -> Bool {
        guard let remoteSecret else {
            return false
        }

        guard shouldRewriteSecret(remoteSecret: remoteSecret, encryptedSecret: entity.encryptedSecret) else {
            return false
        }

        entity.encryptedSecret = try cryptoStore.encrypt(remoteSecret)
        return true
    }

    private func shouldRewriteSecret(remoteSecret: String, encryptedSecret: Data?) -> Bool {
        guard let encryptedSecret else {
            return true
        }

        guard let localSecret = try? cryptoStore.decrypt(encryptedSecret) else {
            return true
        }

        return localSecret != remoteSecret
    }

    private func normalizedOTPType(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func isSupportedOTPType(_ value: String) -> Bool {
        let normalized = normalizedOTPType(value)
        return normalized == "totp" || normalized == "steamtotp"
    }
}
