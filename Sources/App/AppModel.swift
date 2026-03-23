import Foundation
import LocalAuthentication
import OSLog
import SwiftData
import SwiftUI

enum SessionState: Equatable {
    case loggedOut
    case locked
    case unlocked
    case degradedOffline
    case reloginRequired
}

@MainActor
final class AppModel: ObservableObject {
    @Published var sessionState: SessionState = .loggedOut
    @Published var baseURLInput: String = ""
    @Published var loginError: String?
    @Published var syncMessage: String?
    @Published var isSyncing: Bool = false
    @Published var autoLockTimeoutSeconds: Int
    @Published var lastSuccessfulSyncAt: Date?

    private let modelContext: ModelContext
    private var configStore: any AppConfigStore
    private let secretStore: any SecretStore
    private let repository: any AccountRepository
    private let scheduleBackgroundRefresh: () -> Void
    private let biometricAuthenticator: any BiometricAuthenticator

    private var unlockedState: SessionState = .unlocked
    private var backgroundedAt: Date?
    private var isUnlockInProgress = false

    var requiresOnboarding: Bool {
        return !hasSessionConfiguration
    }

    init(
        modelContext: ModelContext,
        configStore: any AppConfigStore,
        secretStore: any SecretStore,
        repository: any AccountRepository,
        scheduleBackgroundRefresh: @escaping () -> Void,
        biometricAuthenticator: any BiometricAuthenticator = LocalBiometricAuthenticator()
    ) {
        self.modelContext = modelContext
        self.configStore = configStore
        self.secretStore = secretStore
        self.repository = repository
        self.scheduleBackgroundRefresh = scheduleBackgroundRefresh
        self.biometricAuthenticator = biometricAuthenticator
        self.baseURLInput = configStore.baseURLString ?? ""
        self.autoLockTimeoutSeconds = configStore.autoLockTimeoutSeconds
        self.lastSuccessfulSyncAt = configStore.lastSuccessfulSyncAt
    }

    func bootstrap() async {
        #if DEBUG
            if ProcessInfo.processInfo.environment["UI_TEST_START_UNLOCKED"] == "1" {
                unlockedState = .unlocked
                sessionState = .unlocked
                return
            }
        #endif

        baseURLInput = configStore.baseURLString ?? ""

        if configStore.requiresRelogin {
            sessionState = .reloginRequired
            return
        }

        if hasSessionConfiguration {
            sessionState = .locked
        } else {
            sessionState = .loggedOut
        }
    }

    func attemptLogin(apiKey: String) async {
        loginError = nil
        syncMessage = nil

        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            loginError = String(localized: "login.error.api_key_required")
            return
        }

        guard let baseURL = validatedBaseURL(from: baseURLInput) else {
            loginError = String(localized: "login.error.invalid_base_url")
            return
        }

        isSyncing = true
        let syncResult = await repository.syncAccounts(
            context: modelContext,
            baseURL: baseURL,
            apiKey: apiKey,
            includeSecrets: true
        )
        isSyncing = false

        switch syncResult {
        case .success:
            configStore.baseURLString = baseURL.absoluteString
            configStore.requiresRelogin = false
            do {
                try secretStore.saveAPIKey(apiKey)
                try repository.ensureEncryptionKey()
                let syncedAt = Date()
                configStore.lastSuccessfulSyncAt = syncedAt
                lastSuccessfulSyncAt = syncedAt
                unlockedState = .unlocked
                sessionState = .unlocked
                scheduleBackgroundRefresh()
            } catch {
                ErrorReporter.report("login.secure_store_failed")
                loginError = String(localized: "login.error.secure_store_failed")
            }
        case .unauthorized:
            loginError = String(localized: "login.error.invalid_credentials")
        case .transient(let reason):
            ErrorReporter.report("login.sync_transient")
            loginError = String.localizedStringWithFormat(
                String(localized: "login.error.server_unreachable"),
                reason
            )
        }
    }

    func unlock() async {
        guard sessionState == .locked, !isUnlockInProgress else {
            return
        }

        guard hasSessionConfiguration else {
            sessionState = .loggedOut
            return
        }

        isUnlockInProgress = true
        defer {
            isUnlockInProgress = false
        }

        do {
            let authenticated = try await biometricAuthenticator.authenticate(reason: String(localized: "lock.title"))
            if authenticated {
                sessionState = unlockedState
                syncMessage = nil
            }
        } catch {
            if let authError = error as? LAError,
                authError.code == .userCancel || authError.code == .systemCancel || authError.code == .appCancel
            {
                return
            }
            let code = (error as? LAError)?.code.rawValue ?? -1
            ErrorReporter.report("unlock.biometric_failed", metadata: ["code": String(code)])
            syncMessage = String(localized: "sync.error.biometric_failed")
        }
    }

    func syncNow() async {
        guard let baseURL = configuredBaseURL(), let apiKey = secretStore.loadAPIKey() else {
            if sessionState == .unlocked || sessionState == .degradedOffline {
                sessionState = .loggedOut
            }
            return
        }

        isSyncing = true
        let result = await repository.syncAccounts(
            context: modelContext,
            baseURL: baseURL,
            apiKey: apiKey,
            includeSecrets: true
        )
        isSyncing = false

        switch result {
        case .success:
            let syncedAt = Date()
            configStore.lastSuccessfulSyncAt = syncedAt
            lastSuccessfulSyncAt = syncedAt
            unlockedState = .unlocked
            if sessionState != .locked {
                sessionState = .unlocked
            }
            syncMessage = nil
        case .unauthorized:
            ErrorReporter.report("sync.unauthorized")
            await enforceReloginWipe()
        case .transient(let reason):
            ErrorReporter.report("sync.transient")
            unlockedState = .degradedOffline
            if sessionState != .locked {
                sessionState = .degradedOffline
            }
            syncMessage = String.localizedStringWithFormat(
                String(localized: "sync.status.offline_mode"),
                reason
            )
        }
    }

    func logout() async {
        sessionState = .loggedOut
        loginError = nil
        syncMessage = nil
        await wipeAllData(requireRelogin: false)
    }

    func updateAutoLockTimeout(seconds: Int) {
        let normalized = UserDefaultsAppConfigStore.normalizeAutoLockTimeout(seconds)
        autoLockTimeoutSeconds = normalized
        configStore.autoLockTimeoutSeconds = normalized
    }

    func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .background:
            backgroundedAt = Date()
        case .active:
            guard let backgroundedAt else { return }
            let elapsed = Date().timeIntervalSince(backgroundedAt)
            self.backgroundedAt = nil
            if shouldAutoLock(after: elapsed) {
                sessionState = .locked
            }
        default:
            break
        }
    }

    private func shouldAutoLock(after elapsed: TimeInterval) -> Bool {
        guard sessionState == .unlocked || sessionState == .degradedOffline else {
            return false
        }

        if autoLockTimeoutSeconds == 0 {
            return true
        }

        return elapsed >= TimeInterval(autoLockTimeoutSeconds)
    }

    private func configuredBaseURL() -> URL? {
        guard let value = configStore.baseURLString else {
            return nil
        }
        return validatedBaseURL(from: value)
    }

    private var hasSessionConfiguration: Bool {
        configuredBaseURL() != nil && secretStore.loadAPIKey() != nil
    }

    private func validatedBaseURL(from input: String) -> URL? {
        switch TransportURLValidator.validateBaseURL(input, policy: configStore.transportPolicy) {
        case .success(let url):
            return url
        case .failure:
            return nil
        }
    }

    private func enforceReloginWipe() async {
        sessionState = .reloginRequired
        await wipeAllData(requireRelogin: true)
        syncMessage = String(localized: "sync.status.session_expired")
    }

    private func wipeAllData(requireRelogin: Bool) async {
        #if DEBUG
            if let delayMS = UInt64(ProcessInfo.processInfo.environment["UI_TEST_WIPE_DELAY_MS"] ?? ""), delayMS > 0 {
                try? await Task.sleep(nanoseconds: delayMS * 1_000_000)
            }
        #endif

        do {
            try repository.wipeCachedData(context: modelContext)
        } catch {
            ErrorReporter.report("sync.cache_clear_failed")
            syncMessage = String(localized: "sync.error.cache_clear_failed")
        }

        _ = secretStore.deleteAPIKey()
        _ = secretStore.deleteEncryptionKey()

        configStore.requiresRelogin = requireRelogin
        configStore.lastSuccessfulSyncAt = nil
        lastSuccessfulSyncAt = nil
        baseURLInput = configStore.baseURLString ?? ""
        unlockedState = .unlocked
    }
}

extension AppModel {
    func generateTOTP(for account: AccountEntity, at date: Date = Date()) -> String? {
        guard normalizedOTPType(account.otpType) == "totp", let encryptedSecret = account.encryptedSecret else {
            return nil
        }

        do {
            let secret = try repository.decryptSecret(encryptedSecret)
            let digits = OTPDigits(rawValue: account.digits ?? OTPDigits.default.rawValue) ?? OTPDigits.default
            let algorithm = OTPAlgorithm(value: account.algorithm ?? OTPAlgorithm.default.rawValue) ?? OTPAlgorithm.default
            let period = account.period ?? 30
            return TOTPGenerator.generate(secret: secret, digits: digits, period: period, algorithm: algorithm, at: date)
        } catch {
            return nil
        }
    }

    func generateSteamGuard(for account: AccountEntity, at date: Date = Date()) -> String? {
        guard normalizedOTPType(account.otpType) == "steamtotp", let encryptedSecret = account.encryptedSecret else {
            return nil
        }

        do {
            let secret = try repository.decryptSecret(encryptedSecret)
            let period = account.period ?? 30
            return SteamGuardGenerator.generate(secret: secret, period: period, at: date)
        } catch {
            return nil
        }
    }

    func generateHOTP(for account: AccountEntity) -> String? {
        guard normalizedOTPType(account.otpType) == "hotp", let encryptedSecret = account.encryptedSecret else {
            return nil
        }

        do {
            let secret = try repository.decryptSecret(encryptedSecret)
            let digits = OTPDigits(rawValue: account.digits ?? OTPDigits.default.rawValue) ?? OTPDigits.default
            let algorithm = OTPAlgorithm(value: account.algorithm ?? OTPAlgorithm.default.rawValue) ?? OTPAlgorithm.default
            let counter = UInt64(max(account.counter ?? 0, 0))
            let code = HOTPGenerator.generate(secret: secret, digits: digits, counter: counter, algorithm: algorithm)
            account.counter = Int(counter + 1)
            try modelContext.save()
            return code
        } catch {
            return nil
        }
    }

    private func normalizedOTPType(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
