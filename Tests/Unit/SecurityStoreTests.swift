import Foundation
import Security
import XCTest

@testable import TwoFAuth

@MainActor
final class SecurityStoreTests: XCTestCase {
    nonisolated(unsafe) private let secretStore = KeychainSecretStore()

    override func setUp() {
        super.setUp()
        _ = secretStore.deleteAPIKey()
        _ = secretStore.deleteEncryptionKey()
    }

    override func tearDown() {
        _ = secretStore.deleteAPIKey()
        _ = secretStore.deleteEncryptionKey()
        super.tearDown()
    }

    func testKeychainAccessibilityPolicyIsAfterFirstUnlockDeviceOnly() {
        XCTAssertEqual(
            KeychainSecretStore.keychainAccessibilityValue,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
    }

    func testStoredAPIKeyUsesConfiguredAccessibilityPolicy() throws {
        try secretStore.saveAPIKey("policy-key")

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainSecretStore.serviceIdentifier,
            kSecAttrAccount as String: KeychainSecretStore.apiKeyAccountIdentifier,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        XCTAssertEqual(status, errSecSuccess)

        let attributes = item as? [String: Any]
        let accessible = attributes?[kSecAttrAccessible as String] as? String
        XCTAssertEqual(accessible, KeychainSecretStore.keychainAccessibilityValue)
    }

    func testDecryptFailsForTamperedPayload() throws {
        let cryptoStore = AESGCMCryptoStore(secretStore: secretStore)
        let encrypted = try cryptoStore.encrypt("ABCDEF")
        var tampered = encrypted
        tampered[tampered.startIndex] ^= 0xFF

        XCTAssertThrowsError(try cryptoStore.decrypt(tampered))
    }

    func testResetEncryptionKeyBreaksOldCiphertextAndAllowsFreshRoundTrip() throws {
        let cryptoStore = AESGCMCryptoStore(secretStore: secretStore)
        let encryptedBeforeReset = try cryptoStore.encrypt("FIRST")

        XCTAssertTrue(cryptoStore.resetEncryptionKey())
        XCTAssertThrowsError(try cryptoStore.decrypt(encryptedBeforeReset))

        let encryptedAfterReset = try cryptoStore.encrypt("SECOND")
        XCTAssertEqual(try cryptoStore.decrypt(encryptedAfterReset), "SECOND")
    }
}
