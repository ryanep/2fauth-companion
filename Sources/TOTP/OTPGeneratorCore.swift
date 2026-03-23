import CryptoKit
import Foundation

enum OTPDigits: Int, CaseIterable, Codable {
    case six = 6
    case seven = 7
    case eight = 8
    case nine = 9
    case ten = 10

    static let `default`: OTPDigits = .six
}

enum OTPAlgorithm: String, CaseIterable, Codable {
    case sha1 = "SHA1"
    case sha256 = "SHA256"
    case sha512 = "SHA512"
    case md5 = "MD5"

    static let `default`: OTPAlgorithm = .sha1

    init?(value: String) {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case OTPAlgorithm.sha1.rawValue:
            self = .sha1
        case OTPAlgorithm.sha256.rawValue:
            self = .sha256
        case OTPAlgorithm.sha512.rawValue:
            self = .sha512
        case OTPAlgorithm.md5.rawValue:
            self = .md5
        default:
            return nil
        }
    }
}

enum OTPGeneratorCore {
    static func generate(secret: String, digits: OTPDigits, counter: UInt64, algorithm: OTPAlgorithm) -> String? {
        guard let secretData = Base32.decode(secret), !secretData.isEmpty else {
            return nil
        }

        var movingFactor = counter.bigEndian
        let counterData = Data(bytes: &movingFactor, count: MemoryLayout<UInt64>.size)
        guard let hash = hmac(secretData: secretData, counterData: counterData, algorithm: algorithm) else {
            return nil
        }

        guard let last = hash.last else {
            return nil
        }

        let offset = Int(last & 0x0f)
        if hash.count < offset + 4 {
            return nil
        }

        let binary =
            (UInt64(hash[offset]) & 0x7f) << 24 | (UInt64(hash[offset + 1]) & 0xff) << 16
            | (UInt64(hash[offset + 2]) & 0xff) << 8 | (UInt64(hash[offset + 3]) & 0xff)

        let modulo = UInt64(pow(10.0, Double(digits.rawValue)))
        let otp = binary % modulo
        return String(format: "%0*llu", digits.rawValue, otp)
    }

    private static func hmac(secretData: Data, counterData: Data, algorithm: OTPAlgorithm) -> Data? {
        let key = SymmetricKey(data: secretData)

        switch algorithm {
        case .sha1:
            return Data(HMAC<Insecure.SHA1>.authenticationCode(for: counterData, using: key))
        case .sha256:
            return Data(HMAC<SHA256>.authenticationCode(for: counterData, using: key))
        case .sha512:
            return Data(HMAC<SHA512>.authenticationCode(for: counterData, using: key))
        case .md5:
            return Data(HMAC<Insecure.MD5>.authenticationCode(for: counterData, using: key))
        }
    }
}
