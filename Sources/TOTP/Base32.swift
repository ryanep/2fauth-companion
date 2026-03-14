import Foundation

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
