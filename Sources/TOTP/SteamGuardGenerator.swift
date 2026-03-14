import CryptoKit
import Foundation

enum SteamGuardGenerator {
    private static let alphabet = Array("23456789BCDFGHJKMNPQRTVWXY")

    static func generate(secret: String, period: Int, at date: Date = Date()) -> String? {
        let timeCounter = UInt64(floor(date.timeIntervalSince1970 / Double(period)))
        return generate(secret: secret, counter: timeCounter)
    }

    static func generate(secret: String, counter: UInt64) -> String? {
        guard let secretData = Base32.decode(secret), !secretData.isEmpty else {
            return nil
        }

        var movingFactor = counter.bigEndian
        let counterData = Data(bytes: &movingFactor, count: MemoryLayout<UInt64>.size)
        let key = SymmetricKey(data: secretData)
        let digest = HMAC<Insecure.SHA1>.authenticationCode(for: counterData, using: key)
        let hash = Data(digest)

        guard let last = hash.last else {
            return nil
        }

        let offset = Int(last & 0x0f)
        if hash.count < offset + 4 {
            return nil
        }

        var code =
            (UInt32(hash[offset]) & 0x7f) << 24 |
            (UInt32(hash[offset + 1]) & 0xff) << 16 |
            (UInt32(hash[offset + 2]) & 0xff) << 8 |
            (UInt32(hash[offset + 3]) & 0xff)

        var result = ""
        for _ in 0..<5 {
            let index = Int(code % UInt32(alphabet.count))
            result.append(alphabet[index])
            code /= UInt32(alphabet.count)
        }
        return result
    }
}
