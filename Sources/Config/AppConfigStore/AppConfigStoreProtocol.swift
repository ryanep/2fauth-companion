import Foundation

enum TransportPolicy: String, CaseIterable {
    case secureOnly
    case allowHTTP
}

protocol AppConfigStore {
    var baseURLString: String? { get set }
    var requiresRelogin: Bool { get set }
    var autoLockTimeoutSeconds: Int { get set }
    var lastSuccessfulSyncAt: Date? { get set }
    var transportPolicy: TransportPolicy { get set }
}
