import Foundation

final class AppConfigStore {
    private enum Keys {
        static let baseURL = "config.baseURL"
        static let requiresRelogin = "config.requiresRelogin"
        static let autoLockTimeoutSeconds = "config.autoLockTimeoutSeconds"
        static let lastSuccessfulSyncAt = "config.lastSuccessfulSyncAt"
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

    static func normalizeAutoLockTimeout(_ value: Int) -> Int {
        guard autoLockTimeoutOptionsSeconds.contains(value) else {
            return defaultAutoLockTimeoutSeconds
        }
        return value
    }
}
