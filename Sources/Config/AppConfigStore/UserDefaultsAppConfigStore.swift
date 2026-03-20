import Foundation

final class UserDefaultsAppConfigStore: AppConfigStore {
    private enum Keys {
        static let baseURL = "config.baseURL"
        static let requiresRelogin = "config.requiresRelogin"
        static let autoLockTimeoutSeconds = "config.autoLockTimeoutSeconds"
        static let lastSuccessfulSyncAt = "config.lastSuccessfulSyncAt"
        static let transportPolicy = "config.transportPolicy"
    }

    static let backgroundSyncIntervalMinutes = 15
    static let defaultAutoLockTimeoutSeconds = 0
    static let autoLockTimeoutOptionsSeconds = [0, 30, 60, 300]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var baseURLString: String? {
        get { defaults.string(forKey: Keys.baseURL) }
        set { defaults.set(newValue, forKey: Keys.baseURL) }
    }

    var requiresRelogin: Bool {
        get { defaults.bool(forKey: Keys.requiresRelogin) }
        set { defaults.set(newValue, forKey: Keys.requiresRelogin) }
    }

    var autoLockTimeoutSeconds: Int {
        get {
            let storedValue = defaults.integer(forKey: Keys.autoLockTimeoutSeconds)
            return Self.normalizeAutoLockTimeout(storedValue)
        }
        set {
            defaults.set(Self.normalizeAutoLockTimeout(newValue), forKey: Keys.autoLockTimeoutSeconds)
        }
    }

    var lastSuccessfulSyncAt: Date? {
        get { defaults.object(forKey: Keys.lastSuccessfulSyncAt) as? Date }
        set { defaults.set(newValue, forKey: Keys.lastSuccessfulSyncAt) }
    }

    var transportPolicy: TransportPolicy {
        get {
            guard
                let rawValue = defaults.string(forKey: Keys.transportPolicy),
                let policy = TransportPolicy(rawValue: rawValue)
            else {
                return .allowHTTP
            }
            return policy
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.transportPolicy)
        }
    }

    static func normalizeAutoLockTimeout(_ value: Int) -> Int {
        guard autoLockTimeoutOptionsSeconds.contains(value) else {
            return defaultAutoLockTimeoutSeconds
        }
        return value
    }
}
