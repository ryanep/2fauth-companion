import Foundation
import Security

final class KeychainSecretStore: SecretStore {
    static let serviceIdentifier = "com.ryanep.2fauth.secretstore"
    static let apiKeyAccountIdentifier = "api-key"
    static let encryptionKeyAccountIdentifier = "encryption-key"
    static let keychainAccessibilityValue = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String

    func saveAPIKey(_ value: String) throws {
        let data = Data(value.utf8)
        try save(data: data, account: Self.apiKeyAccountIdentifier)
    }

    func loadAPIKey() -> String? {
        guard let data = load(account: Self.apiKeyAccountIdentifier) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func deleteAPIKey() -> Bool {
        delete(account: Self.apiKeyAccountIdentifier)
    }

    func saveEncryptionKey(_ value: Data) throws {
        try save(data: value, account: Self.encryptionKeyAccountIdentifier)
    }

    func loadEncryptionKey() -> Data? {
        load(account: Self.encryptionKeyAccountIdentifier)
    }

    @discardableResult
    func deleteEncryptionKey() -> Bool {
        delete(account: Self.encryptionKeyAccountIdentifier)
    }

    private func save(data: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceIdentifier,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: Self.keychainAccessibilityValue,
            kSecValueData as String: data,
        ]

        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)

        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    private func load(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceIdentifier,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            return nil
        }

        return item as? Data
    }

    private func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceIdentifier,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
