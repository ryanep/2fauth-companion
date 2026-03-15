import Foundation
import LocalAuthentication
import SwiftData
import SwiftUI

enum SessionState {
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
    private let configStore: AppConfigStore
    private let secretStore: SecretStore
    private let repository: AccountRepository
    private let scheduleBackgroundRefresh: () -> Void
    private let biometricAuthenticator = BiometricAuthenticator()

    private var unlockedState: SessionState = .unlocked
    private var backgroundedAt: Date?
    private var isUnlockInProgress = false

    var requiresOnboarding: Bool {
        return !hasSessionConfiguration
    }

    init(
        modelContext: ModelContext,
        configStore: AppConfigStore,
        secretStore: SecretStore,
        repository: AccountRepository,
        scheduleBackgroundRefresh: @escaping () -> Void
    ) {
        self.modelContext = modelContext
        self.configStore = configStore
        self.secretStore = secretStore
        self.repository = repository
        self.scheduleBackgroundRefresh = scheduleBackgroundRefresh
        self.baseURLInput = configStore.baseURLString ?? ""
        self.autoLockTimeoutSeconds = configStore.autoLockTimeoutSeconds
        self.lastSuccessfulSyncAt = configStore.lastSuccessfulSyncAt
    }

    func bootstrap() async {
        let environment = ProcessInfo.processInfo.environment
        if environment["UI_TEST_START_UNLOCKED"] == "1" {
            unlockedState = .unlocked
            sessionState = .unlocked
            return
        }

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
                loginError = String(localized: "login.error.secure_store_failed")
            }
        case .unauthorized:
            loginError = String(localized: "login.error.invalid_credentials")
        case .transient(let reason):
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
            await enforceReloginWipe()
        case .transient(let reason):
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
        let normalized = AppConfigStore.normalizeAutoLockTimeout(seconds)
        autoLockTimeoutSeconds = normalized
        configStore.autoLockTimeoutSeconds = normalized
    }

    func generateTOTP(for account: AccountEntity, at date: Date = Date()) -> String? {
        guard normalizedOTPType(account.otpType) == "totp", let encryptedSecret = account.encryptedSecret else {
            return nil
        }

        do {
            let secret = try repository.decryptSecret(encryptedSecret)
            let digits = account.digits ?? 6
            let period = account.period ?? 30
            return TOTPGenerator.generate(secret: secret, digits: digits, period: period, at: date)
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
            let digits = account.digits ?? 6
            let counter = UInt64(max(account.counter ?? 0, 0))
            let code = HOTPGenerator.generate(secret: secret, digits: digits, counter: counter)
            account.counter = Int(counter + 1)
            try modelContext.save()
            return code
        } catch {
            return nil
        }
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

    private func normalizedOTPType(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func validatedBaseURL(from input: String) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme) else {
            return nil
        }
        return url
    }

    private func enforceReloginWipe() async {
        sessionState = .reloginRequired
        await wipeAllData(requireRelogin: true)
        syncMessage = String(localized: "sync.status.session_expired")
    }

    private func wipeAllData(requireRelogin: Bool) async {
        let environment = ProcessInfo.processInfo.environment
        if let delayMS = UInt64(environment["UI_TEST_WIPE_DELAY_MS"] ?? ""), delayMS > 0 {
            try? await Task.sleep(nanoseconds: delayMS * 1_000_000)
        }

        do {
            try repository.wipeCachedData(context: modelContext)
        } catch {
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

struct BiometricAuthenticator {
    func authenticate(reason: String) async throws -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw error ?? NSError(domain: "Biometric", code: -1)
        }

        return try await withCheckedThrowingContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, evalError in
                if let evalError {
                    continuation.resume(throwing: evalError)
                } else {
                    continuation.resume(returning: success)
                }
            }
        }
    }
}
