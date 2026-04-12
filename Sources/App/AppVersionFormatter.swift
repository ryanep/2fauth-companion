import Foundation

enum AppVersionFormatter {
    static func displayVersion(from bundle: Bundle = .main) -> String {
        displayVersion(
            shortVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            buildVersion: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        )
    }

    static func displayVersion(shortVersion: String?, buildVersion: String?) -> String {
        guard let shortVersion = shortVersion?.trimmingCharacters(in: .whitespacesAndNewlines), !shortVersion.isEmpty else {
            return String(localized: "settings.app_version.unknown")
        }

        guard let buildVersion = buildVersion?.trimmingCharacters(in: .whitespacesAndNewlines), !buildVersion.isEmpty else {
            return shortVersion
        }

        return "\(shortVersion) (\(buildVersion))"
    }
}
