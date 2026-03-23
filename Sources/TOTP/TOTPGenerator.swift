import Foundation

enum TOTPGenerator {
    static func generate(
        secret: String,
        digits: OTPDigits,
        period: Int,
        algorithm: OTPAlgorithm = .default,
        at date: Date = Date()
    ) -> String? {
        let timeCounter = UInt64(floor(date.timeIntervalSince1970 / Double(period)))
        return OTPGeneratorCore.generate(secret: secret, digits: digits, counter: timeCounter, algorithm: algorithm)
    }
}
