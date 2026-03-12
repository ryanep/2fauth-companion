import CryptoKit
import Foundation

enum TOTPGenerator {
    static func generate(secret: String, digits: Int, period: Int, at date: Date = Date()) -> String? {
        let timeCounter = UInt64(floor(date.timeIntervalSince1970 / Double(period)))
        return generate(secret: secret, digits: digits, counter: timeCounter)
    }

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

enum Base32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    static func decode(_ input: String) -> Data? {
        let cleaned = input
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: " ", with: "")
            .uppercased()

        var bits = ""
        for char in cleaned {
            guard let index = alphabet.firstIndex(of: char) else {
                return nil
            }
            let binary = String(index, radix: 2)
            bits += String(repeating: "0", count: max(0, 5 - binary.count)) + binary
        }

        var bytes: [UInt8] = []
        var idx = bits.startIndex
        while bits.distance(from: idx, to: bits.endIndex) >= 8 {
            let end = bits.index(idx, offsetBy: 8)
            let chunk = bits[idx..<end]
            guard let value = UInt8(chunk, radix: 2) else {
                return nil
            }
            bytes.append(value)
            idx = end
        }
        return Data(bytes)
    }
}
