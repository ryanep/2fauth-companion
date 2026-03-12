import Foundation

enum HOTPGenerator {
    static func generate(
        secret: String,
        digits: OTPDigits,
        counter: UInt64,
        algorithm: OTPAlgorithm = .default
    ) -> String? {
        return OTPGeneratorCore.generate(secret: secret, digits: digits, counter: counter, algorithm: algorithm)
    }
}
