import CryptoKit
import Foundation

enum OTPGeneratorCore {
    static func generate(secret: String, digits: Int, counter: UInt64) -> String? {
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

        let binary =
            (UInt32(hash[offset]) & 0x7f) << 24 |
            (UInt32(hash[offset + 1]) & 0xff) << 16 |
            (UInt32(hash[offset + 2]) & 0xff) << 8 |
            (UInt32(hash[offset + 3]) & 0xff)

        let modulo = UInt32(pow(10.0, Double(digits)))
        let otp = binary % modulo
        return String(format: "%0*u", digits, otp)
    }
}
