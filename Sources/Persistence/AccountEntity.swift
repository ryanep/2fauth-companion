import Foundation
import SwiftData

@Model
final class AccountEntity {
    @Attribute(.unique) var remoteID: Int
    var service: String?
    var account: String
    var otpType: String
    var digits: Int?
    var algorithm: String?
    var period: Int?
    var encryptedSecret: Data?
    var updatedAt: Date

    init(
        remoteID: Int,
        service: String?,
        account: String,
        otpType: String,
        digits: Int?,
        algorithm: String?,
        period: Int?,
        encryptedSecret: Data?,
        updatedAt: Date
    ) {
        self.remoteID = remoteID
        self.service = service
        self.account = account
        self.otpType = otpType
        self.digits = digits
        self.algorithm = algorithm
        self.period = period
        self.encryptedSecret = encryptedSecret
        self.updatedAt = updatedAt
    }
}
