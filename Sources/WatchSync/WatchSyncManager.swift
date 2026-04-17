import Foundation
import SwiftData

#if os(iOS)
import WatchConnectivity

enum WatchSessionActivationState: String {
    case notActivated
    case inactive
    case activated
}

protocol WatchSession: AnyObject {
    var delegate: WCSessionDelegate? { get set }
    var isPaired: Bool { get }
    var isWatchAppInstalled: Bool { get }
    var activationState: WatchSessionActivationState { get }
    func activate()
    func updateApplicationContext(_ applicationContext: [String: Any]) throws
}

private final class WCSessionAdapter: WatchSession {
    private let session: WCSession

    init(session: WCSession) {
        self.session = session
    }

    var delegate: WCSessionDelegate? {
        get { session.delegate }
        set { session.delegate = newValue }
    }

    var isPaired: Bool {
        session.isPaired
    }

    var isWatchAppInstalled: Bool {
        session.isWatchAppInstalled
    }

    var activationState: WatchSessionActivationState {
        switch session.activationState {
        case .activated:
            .activated
        case .inactive:
            .inactive
        case .notActivated:
            .notActivated
        @unknown default:
            .notActivated
        }
    }

    func activate() {
        session.activate()
    }

    func updateApplicationContext(_ applicationContext: [String: Any]) throws {
        try session.updateApplicationContext(applicationContext)
    }
}

final class WatchSyncManager: NSObject, WCSessionDelegate {
    private enum Keys {
        static let snapshot = "snapshot"
    }

    private let session: (any WatchSession)?
    private var configStore: any AppConfigStore
    private let report: (String, [String: String]) -> Void
    private var pendingSnapshot: WatchSnapshotPayload?

    init(
        session: (any WatchSession)? = WatchSyncManager.defaultSession(),
        configStore: any AppConfigStore = UserDefaultsAppConfigStore(),
        report: @escaping (String, [String: String]) -> Void = ErrorReporter.report
    ) {
        self.session = session
        self.configStore = configStore
        self.report = report
        super.init()
    }

    private static func defaultSession() -> (any WatchSession)? {
        guard WCSession.isSupported() else {
            return nil
        }
        return WCSessionAdapter(session: WCSession.default)
    }

    func activate() {
        guard let session else {
            report("watch.sync_activate_skipped_unsupported", [:])
            return
        }
        session.delegate = self
        session.activate()
    }

    @MainActor
    func pushLatestSnapshot(from context: ModelContext, repository: AccountRepository) {
        guard let session else {
            report("watch.sync_skipped_unsupported", [:])
            return
        }

        let descriptor = FetchDescriptor<AccountEntity>(sortBy: [SortDescriptor(\AccountEntity.account)])
        guard let entities = try? context.fetch(descriptor) else {
            return
        }

        var payloadAccounts: [WatchAccountPayload] = []
        payloadAccounts.reserveCapacity(entities.count)

        for entity in entities {
            let normalizedType = normalizedOTPType(entity.otpType)
            guard normalizedType == "totp" || normalizedType == "steamtotp" else {
                continue
            }

            let secret: String?
            if let encrypted = entity.encryptedSecret {
                secret = try? repository.decryptSecret(encrypted)
            } else {
                secret = nil
            }

            payloadAccounts.append(
                WatchAccountPayload(
                    id: entity.remoteID,
                    service: entity.service,
                    account: entity.account,
                    otpType: entity.otpType,
                    digits: entity.digits,
                    algorithm: entity.algorithm,
                    period: entity.period,
                    secret: secret
                )
            )
        }

        payloadAccounts.sort { compareWatchAccountsForDisplay($0, $1) }

        let payload = WatchSnapshotPayload(generatedAt: Date(), accounts: payloadAccounts)
        push(snapshot: payload, session: session)
    }

    @MainActor
    func pushEmptySnapshot() {
        guard let session else {
            report("watch.sync_skipped_unsupported", [:])
            return
        }

        configStore.hasPendingWatchClear = true
        let payload = WatchSnapshotPayload(generatedAt: Date(), accounts: [])
        push(snapshot: payload, session: session, clearsPendingWatchClear: true)
    }

    func resumePendingSyncIfNeeded() {
        guard let session else {
            return
        }

        if configStore.hasPendingWatchClear {
            let payload = WatchSnapshotPayload(generatedAt: Date(), accounts: [])
            push(snapshot: payload, session: session, clearsPendingWatchClear: true)
            return
        }

        guard let pendingSnapshot else {
            return
        }

        push(snapshot: pendingSnapshot, session: session)
    }

    private func push(
        snapshot: WatchSnapshotPayload,
        session: any WatchSession,
        clearsPendingWatchClear: Bool = false
    ) {
        if !snapshot.accounts.isEmpty {
            configStore.hasPendingWatchClear = false
        }

        let watchAppInstalled = session.isWatchAppInstalled || uiTestAssumesWatchAppInstalled

        guard session.activationState == .activated else {
            pendingSnapshot = snapshot
            writeUITestMarker(event: "watch.sync_skipped_not_activated", metadata: ["state": session.activationState.rawValue])
            report("watch.sync_skipped_not_activated", ["state": session.activationState.rawValue])
            return
        }

        guard session.isPaired else {
            pendingSnapshot = snapshot
            writeUITestMarker(event: "watch.sync_skipped_not_paired", metadata: [:])
            report("watch.sync_skipped_not_paired", [:])
            return
        }

        guard watchAppInstalled else {
            pendingSnapshot = snapshot
            writeUITestMarker(event: "watch.sync_skipped_watch_app_not_installed", metadata: [:])
            report("watch.sync_skipped_watch_app_not_installed", [:])
            return
        }

        guard let data = try? WatchSnapshotPayload.encodeForSync(snapshot) else {
            writeUITestMarker(event: "watch.sync_encode_failed", metadata: [:])
            report("watch.sync_encode_failed", [:])
            return
        }

        do {
            try session.updateApplicationContext([Keys.snapshot: data])
            pendingSnapshot = nil
            if clearsPendingWatchClear || !snapshot.accounts.isEmpty {
                configStore.hasPendingWatchClear = false
            }
            writeUITestSnapshot(data)
            writeUITestMarker(event: "watch.sync_updated_context", metadata: ["accountCount": "\(snapshot.accounts.count)"])
            report("watch.sync_updated_context", ["accountCount": "\(snapshot.accounts.count)"])
        } catch {
            pendingSnapshot = snapshot
            writeUITestMarker(event: "watch.sync_update_context_failed", metadata: ["error": error.localizedDescription])
            report("watch.sync_update_context_failed", ["error": error.localizedDescription])
        }
    }

    private func compareWatchAccountsForDisplay(_ lhs: WatchAccountPayload, _ rhs: WatchAccountPayload) -> Bool {
        let lhsTitle = normalizedDisplayTitle(service: lhs.service)
        let rhsTitle = normalizedDisplayTitle(service: rhs.service)
        if lhsTitle != rhsTitle {
            return lhsTitle < rhsTitle
        }

        return lhs.account.localizedLowercase < rhs.account.localizedLowercase
    }

    private func normalizedDisplayTitle(service: String?) -> String {
        let trimmed = (service ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? String(localized: "accounts.unknown_service") : trimmed
        return title.localizedLowercase
    }

    private func writeUITestMarker(event: String, metadata: [String: String]) {
        #if DEBUG
            guard let path = ProcessInfo.processInfo.environment["UI_TEST_WATCH_SYNC_MARKER_PATH"], !path.isEmpty else {
                return
            }

            var payload = metadata
            payload["event"] = event
            payload["timestamp"] = ISO8601DateFormatter().string(from: Date())

            guard JSONSerialization.isValidJSONObject(payload),
                let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            else {
                return
            }

            FileManager.default.createFile(atPath: path, contents: data)
        #endif
    }

    private var uiTestAssumesWatchAppInstalled: Bool {
        #if DEBUG
            ProcessInfo.processInfo.environment["UI_TEST_ASSUME_WATCH_APP_INSTALLED"] == "1"
        #else
            false
        #endif
    }

    private func writeUITestSnapshot(_ data: Data) {
        #if DEBUG
            guard let path = ProcessInfo.processInfo.environment["UI_TEST_WATCH_SNAPSHOT_PATH"], !path.isEmpty else {
                return
            }
            FileManager.default.createFile(atPath: path, contents: data)
        #endif
    }

    private func normalizedOTPType(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard activationState == .activated, error == nil, self.session != nil else {
            return
        }

        resumePendingSyncIfNeeded()
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        resumePendingSyncIfNeeded()
    }
}

#else

final class WatchSyncManager {
    func activate() {}

    func pushLatestSnapshot(from context: ModelContext, repository: Any) {}

    func pushEmptySnapshot() {}
}

#endif
