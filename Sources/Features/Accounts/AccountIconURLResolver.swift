import CryptoKit
import Foundation

enum AccountIconURLResolver {
    private static let cacheVersion = "2"

    static func iconURL(baseURL: URL, iconFilename: String?) -> URL? {
        let value = iconFilename?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty,
            var baseComponents = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
            let scheme = baseComponents.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            baseComponents.host != nil
        else {
            return nil
        }

        baseComponents.user = nil
        baseComponents.password = nil
        baseComponents.query = nil
        baseComponents.fragment = nil
        guard let sanitizedBaseURL = baseComponents.url else {
            return nil
        }

        let iconRoot =
            sanitizedBaseURL
            .appendingPathComponent("storage", isDirectory: true)
            .appendingPathComponent("icons", isDirectory: true)

        if let absoluteURL = URL(string: value), absoluteURL.scheme != nil {
            guard sameOrigin(absoluteURL, sanitizedBaseURL),
                absoluteURL.user == nil,
                absoluteURL.password == nil,
                absoluteURL.query == nil,
                absoluteURL.fragment == nil,
                !hasUnsafeEncodedPathSegment(absoluteURL),
                isDirectChild(absoluteURL, of: iconRoot)
            else {
                return nil
            }
            return absoluteURL
        }

        let pathComponents =
            value
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        let filename: String
        if pathComponents.count == 3,
            pathComponents[0] == "storage",
            pathComponents[1] == "icons"
        {
            filename = pathComponents[2]
        } else if pathComponents.count == 1 {
            filename = pathComponents[0]
        } else {
            return nil
        }

        guard isSafeFilename(filename) else {
            return nil
        }
        return iconRoot.appendingPathComponent(filename, isDirectory: false)
    }

    static func cacheURL(for url: URL, in cacheDirectory: URL) -> URL {
        cacheDirectory.appendingPathComponent(cacheFilename(for: url), isDirectory: false)
    }

    static func cacheFilename(for url: URL) -> String {
        SHA256.hash(data: Data("\(cacheVersion)|\(url.absoluteString)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private static func isSafeFilename(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
    }

    private static func isDirectChild(_ url: URL, of directory: URL) -> Bool {
        let parentPath = directory.standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let candidatePath = url.standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard candidatePath.hasPrefix(parentPath + "/") else {
            return false
        }
        return !candidatePath.dropFirst(parentPath.count + 1).contains("/")
    }

    private static func hasUnsafeEncodedPathSegment(_ url: URL) -> Bool {
        guard let percentEncodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath
        else {
            return true
        }
        return percentEncodedPath.split(separator: "/").contains { segment in
            guard let decoded = String(segment).removingPercentEncoding else {
                return true
            }
            return decoded == "." || decoded == ".." || decoded.contains("\\")
        }
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port {
            return port
        }
        switch url.scheme?.lowercased() {
        case "http":
            return 80
        case "https":
            return 443
        default:
            return nil
        }
    }
}
