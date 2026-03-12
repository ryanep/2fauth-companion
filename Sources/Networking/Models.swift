import Foundation

struct APIAccount: Decodable {
    let id: Int?
    let groupID: Int?
    let service: String?
    let account: String
    let icon: String?
    let otpType: String
    let secret: String?
    let digits: Int?
    let algorithm: String?
    let period: Int?
    let counter: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case groupID = "group_id"
        case service
        case account
        case icon
        case otpType = "otp_type"
        case secret
        case digits
        case algorithm
        case period
        case counter
    }
}
