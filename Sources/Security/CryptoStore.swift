import CryptoKit
import Foundation

final class CryptoStore {
    private let secretStore: SecretStore

    init(secretStore: SecretStore) {
        self.secretStore = secretStore
    }

    func ensureEncryptionKey() throws -> SymmetricKey {
        if let stored = secretStore.loadEncryptionKey() {
            return SymmetricKey(data: stored)
        }

        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        try secretStore.saveEncryptionKey(keyData)
        return key
    }

    func encrypt(_ value: String) throws -> Data {
        let key = try ensureEncryptionKey()
        let data = Data(value.utf8)
        let box = try AES.GCM.seal(data, using: key)
        guard let combined = box.combined else {
            throw NSError(domain: "CryptoStore", code: -1)
        }
        return combined
    }

    func decrypt(_ payload: Data) throws -> String {
        let key = try ensureEncryptionKey()
        let box = try AES.GCM.SealedBox(combined: payload)
        let data = try AES.GCM.open(box, using: key)
        guard let value = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "CryptoStore", code: -2)
        }
        return value
    }

    @discardableResult
    func resetEncryptionKey() -> Bool {
        secretStore.deleteEncryptionKey()
    }
}
