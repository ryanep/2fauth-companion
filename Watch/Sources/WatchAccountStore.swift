import Foundation
import OSLog
import WatchConnectivity

private let watchSecurityLogger = Logger(subsystem: "com.ryanep.2fauth.watch", category: "security")

struct WatchAccountModel: Identifiable {
    var id: Int
    var service: String?
    var account: String
    var otpType: String
    var digits: Int?
    var algorithm: String?
    var period: Int?
    var secret: String?
}

private struct WatchAccountMetadata: Codable {
    var id: Int
    var service: String?
    var account: String
    var otpType: String
    var digits: Int?
    var algorithm: String?
    var period: Int?
}

@MainActor
final class WatchAccountStore: NSObject, ObservableObject {
    private enum Keys {
        static let snapshot = "snapshot"
        static let accountMetadata = "watch.account.metadata"
        static let generatedAt = "watch.snapshot.generatedAt"
    }

    @Published private(set) var accounts: [WatchAccountModel] = []
    @Published private(set) var generatedAt: Date?

    private let defaults: UserDefaults
    private let secretStore: WatchSecretStore
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(
        defaults: UserDefaults = .standard,
        secretStore: WatchSecretStore? = nil
    ) {
        self.defaults = defaults
        self.secretStore = secretStore ?? WatchSecretStore { event, id, status in
            watchSecurityLogger.error("\(event, privacy: .public) id=\(id, privacy: .public) status=\(status, privacy: .public)")
        }
        super.init()
        loadPersistedState()
    }

    func activateSession() {
        guard WCSession.isSupported() else {
            return
        }

        let session = WCSession.default
        session.delegate = self
        session.activate()

        handleApplicationContext(session.receivedApplicationContext)
    }

    func code(for account: WatchAccountModel, at date: Date = Date()) -> String {
        switch normalizedOTPType(account.otpType) {
        case "totp":
            guard let secret = account.secret else {
                return "------"
            }
            let digits = OTPDigits(rawValue: account.digits ?? OTPDigits.default.rawValue) ?? .default
            let algorithm = OTPAlgorithm(value: account.algorithm ?? OTPAlgorithm.default.rawValue) ?? .default
            let period = account.period ?? 30
            return TOTPGenerator.generate(secret: secret, digits: digits, period: period, algorithm: algorithm, at: date) ?? "------"
        case "steamtotp":
            guard let secret = account.secret else {
                return "-----"
            }
            let period = account.period ?? 30
            return SteamGuardGenerator.generate(secret: secret, period: period, at: date) ?? "-----"
        default:
            return "------"
        }
    }

    func secondsRemaining(for account: WatchAccountModel, now: Date = Date()) -> Int {
        guard supportsLiveCountdown(account.otpType) else {
            return 0
        }
        let configured = account.period ?? 30
        let period = max(configured, 1)
        let elapsed = Int(now.timeIntervalSince1970).quotientAndRemainder(dividingBy: period).remainder
        let remaining = period - elapsed
        return remaining > 0 ? remaining : 1
    }

    func supportsLiveCountdown(_ otpType: String) -> Bool {
        let normalized = normalizedOTPType(otpType)
        return normalized == "totp" || normalized == "steamtotp"
    }

    private func apply(snapshot: WatchSnapshotPayload) {
        let supportedAccounts = snapshot.accounts.filter { supportsLiveCountdown($0.otpType) }
        let metadata = supportedAccounts.map {
            WatchAccountMetadata(
                id: $0.id,
                service: $0.service,
                account: $0.account,
                otpType: $0.otpType,
                digits: $0.digits,
                algorithm: $0.algorithm,
                period: $0.period
            )
        }
        .sorted { compareAccountsForDisplay($0, $1) }

        let ids = Set(supportedAccounts.map(\.id))
        for account in supportedAccounts {
            if let secret = account.secret {
                let saved = secretStore.saveSecret(secret, id: account.id)
                if !saved {
                    watchSecurityLogger.error("watch.snapshot.secret_save_failed id=\(account.id, privacy: .public)")
                }
            } else {
                let deleted = secretStore.deleteSecret(id: account.id)
                if !deleted {
                    watchSecurityLogger.error("watch.snapshot.secret_delete_failed id=\(account.id, privacy: .public)")
                }
            }
        }

        removeSecretsNotInSnapshot(ids: ids)

        if let encodedMetadata = try? encoder.encode(metadata) {
            defaults.set(encodedMetadata, forKey: Keys.accountMetadata)
        }
        defaults.set(snapshot.generatedAt.timeIntervalSince1970, forKey: Keys.generatedAt)

        generatedAt = snapshot.generatedAt
        accounts = metadata.map(makeAccount)
    }

    private func loadPersistedState() {
        if defaults.object(forKey: Keys.generatedAt) != nil {
            generatedAt = Date(timeIntervalSince1970: defaults.double(forKey: Keys.generatedAt))
        }

        guard let data = defaults.data(forKey: Keys.accountMetadata),
            let metadata = try? decoder.decode([WatchAccountMetadata].self, from: data)
        else {
            if defaults.object(forKey: Keys.accountMetadata) != nil {
                clearPersistedState()
            }
            accounts = []
            return
        }

        accounts = metadata.sorted { compareAccountsForDisplay($0, $1) }.map(makeAccount)
    }

    private func removeSecretsNotInSnapshot(ids: Set<Int>) {
        guard let data = defaults.data(forKey: Keys.accountMetadata),
            let existing = try? decoder.decode([WatchAccountMetadata].self, from: data)
        else {
            return
        }

        for metadata in existing where !ids.contains(metadata.id) {
            let deleted = secretStore.deleteSecret(id: metadata.id)
            if !deleted {
                watchSecurityLogger.error("watch.snapshot.stale_secret_delete_failed id=\(metadata.id, privacy: .public)")
            }
        }
    }

    private func makeAccount(_ metadata: WatchAccountMetadata) -> WatchAccountModel {
        WatchAccountModel(
            id: metadata.id,
            service: metadata.service,
            account: metadata.account,
            otpType: metadata.otpType,
            digits: metadata.digits,
            algorithm: metadata.algorithm,
            period: metadata.period,
            secret: secretStore.loadSecret(id: metadata.id)
        )
    }

    private func compareAccountsForDisplay(_ lhs: WatchAccountMetadata, _ rhs: WatchAccountMetadata) -> Bool {
        let lhsTitle = normalizedDisplayTitle(service: lhs.service)
        let rhsTitle = normalizedDisplayTitle(service: rhs.service)
        if lhsTitle != rhsTitle {
            return lhsTitle < rhsTitle
        }

        return lhs.account.localizedLowercase < rhs.account.localizedLowercase
    }

    private func normalizedDisplayTitle(service: String?) -> String {
        let trimmed = (service ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? "Unknown Service" : trimmed
        return title.localizedLowercase
    }

    private func normalizedOTPType(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func decodeSnapshot(from data: Data) -> WatchSnapshotPayload? {
        do {
            return try WatchSnapshotPayload.decodeSupported(from: data)
        } catch let WatchSnapshotDecodeError.unsupportedSchemaVersion(version) {
            watchSecurityLogger.error("watch.snapshot.decode_unsupported_schema version=\(version, privacy: .public)")
            return nil
        } catch {
            watchSecurityLogger.error("watch.snapshot.decode_failed error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func handleApplicationContext(_ applicationContext: [String: Any]) {
        handleApplicationContextData(
            applicationContext[Keys.snapshot] as? Data,
            hasContext: !applicationContext.isEmpty
        )
    }

    private func handleApplicationContextData(_ data: Data?, hasContext: Bool) {
        guard let data else {
            if hasContext {
                watchSecurityLogger.error("watch.snapshot.context_missing_snapshot")
            }
            return
        }

        let payload: WatchSnapshotPayload
        do {
            payload = try WatchSnapshotPayload.decodeSupported(from: data)
        } catch let WatchSnapshotDecodeError.unsupportedSchemaVersion(version) {
            watchSecurityLogger.error("watch.snapshot.decode_unsupported_schema version=\(version, privacy: .public)")
            clearPersistedState()
            return
        } catch {
            watchSecurityLogger.error("watch.snapshot.decode_failed error=\(error.localizedDescription, privacy: .public)")
            return
        }

        apply(snapshot: payload)
    }

    private func clearPersistedState() {
        accounts = []
        generatedAt = nil
        defaults.removeObject(forKey: Keys.accountMetadata)
        defaults.removeObject(forKey: Keys.generatedAt)

        if !secretStore.deleteAllSecrets() {
            watchSecurityLogger.error("watch.snapshot.clear_all_secrets_failed")
        }
    }
}

extension WatchAccountStore: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {}
    #endif

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let snapshotData = applicationContext[Keys.snapshot] as? Data
        let hasContext = !applicationContext.isEmpty
        Task { @MainActor [weak self] in
            self?.handleApplicationContextData(snapshotData, hasContext: hasContext)
        }
    }
}
