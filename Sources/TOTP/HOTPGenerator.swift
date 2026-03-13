import Foundation

enum HOTPGenerator {
    static func generate(secret: String, digits: Int, counter: UInt64) -> String? {
        return OTPGeneratorCore.generate(secret: secret, digits: digits, counter: counter)
    }
}
