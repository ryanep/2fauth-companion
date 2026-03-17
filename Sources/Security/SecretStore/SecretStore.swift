import Foundation

protocol SecretStore {
    func saveAPIKey(_ value: String) throws
    func loadAPIKey() -> String?
    @discardableResult
    func deleteAPIKey() -> Bool

    func saveEncryptionKey(_ value: Data) throws
    func loadEncryptionKey() -> Data?
    @discardableResult
    func deleteEncryptionKey() -> Bool
}
