import Foundation

enum OTPAuthURIValidationError: Error {
    case invalidURI
    case unsupportedOTPType
}

enum OTPAuthURIValidator {
    static func validate(_ input: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            let components = URLComponents(string: trimmed),
            components.scheme?.lowercased() == "otpauth",
            let otpType = components.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            !otpType.isEmpty
        else {
            throw OTPAuthURIValidationError.invalidURI
        }

        guard otpType == "totp" else {
            throw OTPAuthURIValidationError.unsupportedOTPType
        }

        guard
            let secret = components.queryItems?.first(where: { $0.name.lowercased() == "secret" })?.value,
            !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw OTPAuthURIValidationError.invalidURI
        }

        return trimmed
    }

    static func isSteamAccount(_ input: String) -> Bool {
        guard let components = URLComponents(string: input) else { return false }
        let issuer = components.queryItems?
            .first(where: { $0.name.caseInsensitiveCompare("issuer") == .orderedSame })?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if issuer?.caseInsensitiveCompare("Steam") == .orderedSame {
            return true
        }

        let label =
            components.percentEncodedPath
            .removingPercentEncoding?
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        return label.lowercased().hasPrefix("steam:")
    }
}
