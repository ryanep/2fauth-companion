import Foundation

final class AppConfigStore {
    private enum Keys {
        static let baseURL = "config.baseURL"
        static let requiresRelogin = "config.requiresRelogin"
        static let backgroundSyncIntervalMinutes = "config.backgroundSyncIntervalMinutes"
        static let autoLockTimeoutSeconds = "config.autoLockTimeoutSeconds"
    }

    static let defaultBackgroundSyncIntervalMinutes = 15
    static let minimumBackgroundSyncIntervalMinutes = 5
    static let maximumBackgroundSyncIntervalMinutes = 240
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

    var backgroundSyncIntervalMinutes: Int {
        get {
            let storedValue = defaults.integer(forKey: Keys.backgroundSyncIntervalMinutes)
            let candidate = storedValue == 0 ? Self.defaultBackgroundSyncIntervalMinutes : storedValue
            return Self.clampSyncInterval(candidate)
        }
        set {
            defaults.set(Self.clampSyncInterval(newValue), forKey: Keys.backgroundSyncIntervalMinutes)
        }
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

    private static func clampSyncInterval(_ value: Int) -> Int {
        min(max(value, minimumBackgroundSyncIntervalMinutes), maximumBackgroundSyncIntervalMinutes)
    }

    static func normalizeAutoLockTimeout(_ value: Int) -> Int {
        guard autoLockTimeoutOptionsSeconds.contains(value) else {
            return defaultAutoLockTimeoutSeconds
        }
        return value
    }
}
