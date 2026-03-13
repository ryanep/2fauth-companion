import Foundation
import SwiftData

@Model
final class AccountEntity {
    @Attribute(.unique) var remoteID: Int
    var groupID: Int?
    var service: String?
    var account: String
    var icon: String?
    var otpType: String
    var digits: Int?
    var algorithm: String?
    var period: Int?
    var counter: Int?
    var encryptedSecret: Data?
    var updatedAt: Date

    init(
        remoteID: Int,
        groupID: Int?,
        service: String?,
        account: String,
        icon: String?,
        otpType: String,
        digits: Int?,
        algorithm: String?,
        period: Int?,
        counter: Int?,
        encryptedSecret: Data?,
        updatedAt: Date
    ) {
        self.remoteID = remoteID
        self.groupID = groupID
        self.service = service
        self.account = account
        self.icon = icon
        self.otpType = otpType
        self.digits = digits
        self.algorithm = algorithm
        self.period = period
        self.counter = counter
        self.encryptedSecret = encryptedSecret
        self.updatedAt = updatedAt
    }
}
