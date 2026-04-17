import Foundation

enum WatchSnapshotDecodeError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
}

struct WatchSnapshotPayload: Codable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var generatedAt: Date
    var accounts: [WatchAccountPayload]

    init(schemaVersion: Int = WatchSnapshotPayload.currentSchemaVersion, generatedAt: Date, accounts: [WatchAccountPayload]) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.accounts = accounts
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? WatchSnapshotPayload.currentSchemaVersion
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        accounts = try container.decode([WatchAccountPayload].self, forKey: .accounts)
    }

    static func decodeSupported(
        from data: Data,
        supportedSchemaVersion: Int = WatchSnapshotPayload.currentSchemaVersion,
        decoder: JSONDecoder = WatchSnapshotPayload.makeSyncDecoder()
    ) throws -> WatchSnapshotPayload {
        let payload = try decoder.decode(WatchSnapshotPayload.self, from: data)
        guard payload.schemaVersion <= supportedSchemaVersion else {
            throw WatchSnapshotDecodeError.unsupportedSchemaVersion(payload.schemaVersion)
        }
        return payload
    }

    static func encodeForSync(
        _ payload: WatchSnapshotPayload,
        encoder: JSONEncoder = WatchSnapshotPayload.makeSyncEncoder()
    ) throws -> Data {
        try encoder.encode(payload)
    }

    static func makeSyncEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    static func makeSyncDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            if let seconds = try? container.decode(Int.self) {
                return Date(timeIntervalSince1970: TimeInterval(seconds))
            }
            if let text = try? container.decode(String.self) {
                let formatter = ISO8601DateFormatter()
                if let date = formatter.date(from: text) {
                    return date
                }
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported date format for watch snapshot")
        }
        return decoder
    }
}

struct WatchAccountPayload: Codable, Identifiable {
    var id: Int
    var service: String?
    var account: String
    var otpType: String
    var digits: Int?
    var algorithm: String?
    var period: Int?
    var secret: String?
}
