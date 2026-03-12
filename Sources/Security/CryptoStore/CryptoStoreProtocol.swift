import CryptoKit
import Foundation

protocol CryptoStore {
    func ensureEncryptionKey() throws -> SymmetricKey
    func encrypt(_ value: String) throws -> Data
    func decrypt(_ payload: Data) throws -> String
    @discardableResult
    func resetEncryptionKey() -> Bool
}
