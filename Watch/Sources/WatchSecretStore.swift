import Foundation
import Security

final class WatchSecretStore {
    private let service: String
    private let report: (String, Int, OSStatus) -> Void

    init(
        service: String = "com.ryanep.2fauth.watch.secretstore",
        report: @escaping (String, Int, OSStatus) -> Void = { _, _, _ in }
    ) {
        self.service = service
        self.report = report
    }

    @discardableResult
    func saveSecret(_ value: String, id: Int) -> Bool {
        let account = accountKey(for: id)
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]

        let deleteStatus = SecItemDelete(query as CFDictionary)
        if deleteStatus != errSecSuccess && deleteStatus != errSecItemNotFound {
            report("watch.keychain.delete_failed", id, deleteStatus)
            return false
        }

        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus != errSecSuccess {
            report("watch.keychain.add_failed", id, addStatus)
            return false
        }

        return true
    }

    func loadSecret(id: Int) -> String? {
        let account = accountKey(for: id)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
            let data = item as? Data,
            let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return value
    }

    @discardableResult
    func deleteSecret(id: Int) -> Bool {
        let account = accountKey(for: id)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            return true
        }

        report("watch.keychain.delete_failed", id, status)
        return false
    }

    @discardableResult
    func deleteAllSecrets() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            return true
        }

        report("watch.keychain.delete_all_failed", -1, status)
        return false
    }

    private func accountKey(for id: Int) -> String {
        "secret-\(id)"
    }
}
