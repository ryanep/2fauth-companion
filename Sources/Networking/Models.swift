import Foundation

struct APIAccount: Decodable {
    let id: Int?
    let service: String?
    let account: String
    let otpType: String
    let secret: String?
    let digits: OTPDigits?
    let algorithm: OTPAlgorithm?
    let period: Int?
    let counter: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case service
        case account
        case otpType = "otp_type"
        case secret
        case digits
        case algorithm
        case period
        case counter
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id)
        service = try container.decodeIfPresent(String.self, forKey: .service)
        account = try container.decode(String.self, forKey: .account)
        otpType = try container.decode(String.self, forKey: .otpType)
        secret = try container.decodeIfPresent(String.self, forKey: .secret)

        if let rawDigits = try container.decodeIfPresent(Int.self, forKey: .digits) {
            digits = OTPDigits(rawValue: rawDigits)
        } else {
            digits = nil
        }

        if let rawAlgorithm = try container.decodeIfPresent(String.self, forKey: .algorithm) {
            algorithm = OTPAlgorithm(value: rawAlgorithm)
        } else {
            algorithm = nil
        }
        period = try container.decodeIfPresent(Int.self, forKey: .period)
        counter = try container.decodeIfPresent(Int.self, forKey: .counter)
    }
}
