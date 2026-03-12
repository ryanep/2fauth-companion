import Foundation
import OSLog

enum ErrorReporter {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.ryanep.2fauth",
        category: "diagnostics"
    )

    static func report(_ event: String, metadata: [String: String] = [:]) {
        guard !metadata.isEmpty else {
            logger.error("event=\(event, privacy: .public)")
            return
        }

        let details =
            metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")

        logger.error("event=\(event, privacy: .public) \(details, privacy: .public)")
    }
}
