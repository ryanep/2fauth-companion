import Foundation

enum TransportPolicy: String, CaseIterable {
    case secureOnly
    case allowHTTP
}

enum TransportURLValidationError: Error, Equatable {
    case invalid
    case insecureSchemeNotAllowed
}

enum TransportURLValidator {
    static func validateBaseURL(
        _ input: String,
        policy: TransportPolicy
    ) -> Result<URL, TransportURLValidationError> {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, var components = URLComponents(string: value),
            let scheme = components.scheme?.lowercased(), let host = components.host, !host.isEmpty
        else {
            return .failure(.invalid)
        }

        components.scheme = scheme

        switch scheme {
        case "https":
            guard let url = components.url else {
                return .failure(.invalid)
            }
            return .success(url)
        case "http":
            guard policy == .allowHTTP else {
                return .failure(.insecureSchemeNotAllowed)
            }
            guard let url = components.url else {
                return .failure(.invalid)
            }
            return .success(url)
        default:
            return .failure(.invalid)
        }
    }
}

protocol AppConfigStore {
    var baseURLString: String? { get set }
    var requiresRelogin: Bool { get set }
    var hasPendingWatchClear: Bool { get set }
    var autoLockTimeoutSeconds: Int { get set }
    var lastSuccessfulSyncAt: Date? { get set }
    var transportPolicy: TransportPolicy { get set }
}
