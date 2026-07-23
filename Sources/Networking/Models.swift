import Foundation

struct OTPAuthURIRequest: Encodable {
    let uri: String
    let customOTP: String?

    enum CodingKeys: String, CodingKey {
        case uri
        case customOTP = "custom_otp"
    }
}

struct AccountCreationRequest: Encodable {
    let service: String?
    let account: String
    let icon: String?
    let otpType: String
    let secret: String
    let digits: Int
    let algorithm: String
    let period: Int

    enum CodingKeys: String, CodingKey {
        case service
        case account
        case icon
        case otpType = "otp_type"
        case secret
        case digits
        case algorithm
        case period
    }
}

struct APIAccount: Decodable {
    let id: Int?
    let service: String?
    let account: String
    let icon: String?
    let otpType: String
    let secret: String?
    let digits: OTPDigits?
    let algorithm: OTPAlgorithm?
    let period: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case service
        case account
        case icon
        case otpType = "otp_type"
        case secret
        case digits
        case algorithm
        case period
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id)
        service = try container.decodeIfPresent(String.self, forKey: .service)
        account = try container.decode(String.self, forKey: .account)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        otpType = try container.decode(String.self, forKey: .otpType)
        secret = try container.decodeIfPresent(String.self, forKey: .secret)

        if let rawDigits = try container.decodeIfPresent(Int.self, forKey: .digits) {
            guard let parsedDigits = OTPDigits(rawValue: rawDigits) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .digits,
                    in: container,
                    debugDescription: "Unsupported OTP digit count"
                )
            }
            digits = parsedDigits
        } else {
            digits = nil
        }

        if let rawAlgorithm = try container.decodeIfPresent(String.self, forKey: .algorithm) {
            guard let parsedAlgorithm = OTPAlgorithm(value: rawAlgorithm) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .algorithm,
                    in: container,
                    debugDescription: "Unsupported OTP algorithm"
                )
            }
            algorithm = parsedAlgorithm
        } else {
            algorithm = nil
        }
        period = try container.decodeIfPresent(Int.self, forKey: .period)
    }
}
