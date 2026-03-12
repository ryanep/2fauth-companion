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
    @Published var backgroundSyncIntervalMinutes: Int
    @Published var autoLockTimeoutSeconds: Int

    private let modelContext: ModelContext
    private let configStore: AppConfigStore
    private let secretStore: SecretStore
    private let repository: AccountRepository
    private let scheduleBackgroundRefresh: () -> Void
    private let biometricAuthenticator = BiometricAuthenticator()

    private var unlockedState: SessionState = .unlocked
    private var backgroundedAt: Date?
    private var isUnlockInProgress = false

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
        self.backgroundSyncIntervalMinutes = configStore.backgroundSyncIntervalMinutes
        self.autoLockTimeoutSeconds = configStore.autoLockTimeoutSeconds
    }

    func bootstrap() async {
        baseURLInput = configStore.baseURLString ?? ""

        if configStore.requiresRelogin {
            sessionState = .reloginRequired
            return
        }

        if secretStore.loadAPIKey() != nil {
            sessionState = .locked
        } else {
            sessionState = .loggedOut
        }
    }

    func attemptLogin(apiKey: String) async {
        loginError = nil
        syncMessage = nil

        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            loginError = "API key is required."
            return
        }

        guard let baseURL = validatedBaseURL(from: baseURLInput) else {
            loginError = "Enter a valid base URL (http:// or https://)."
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
                unlockedState = .unlocked
                sessionState = .unlocked
                scheduleBackgroundRefresh()
            } catch {
                loginError = "Could not store credentials securely."
            }
        case .unauthorized:
            loginError = "Login failed. Check API key and server URL."
        case .transient(let reason):
            loginError = "Could not reach server: \(reason)"
        }
    }

    func unlock() async {
        guard sessionState == .locked, !isUnlockInProgress else {
            return
        }

        isUnlockInProgress = true
        defer {
            isUnlockInProgress = false
        }

        do {
            let authenticated = try await biometricAuthenticator.authenticate(reason: "Unlock 2FAuth")
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
            syncMessage = "Biometric unlock failed."
        }
    }

    func syncNow() async {
        guard let baseURL = configuredBaseURL(), let apiKey = secretStore.loadAPIKey() else {
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
            syncMessage = "Offline mode: \(reason)"
        }
    }

    func logout() async {
        await wipeAllData(requireRelogin: false)
        sessionState = .loggedOut
        loginError = nil
        syncMessage = nil
    }

    func updateBackgroundSyncInterval(minutes: Int) {
        let clamped = min(
            max(minutes, AppConfigStore.minimumBackgroundSyncIntervalMinutes),
            AppConfigStore.maximumBackgroundSyncIntervalMinutes
        )
        backgroundSyncIntervalMinutes = clamped
        configStore.backgroundSyncIntervalMinutes = clamped
        scheduleBackgroundRefresh()
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
            let code = TOTPGenerator.generate(secret: secret, digits: digits, counter: counter)
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
        return URL(string: value)
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
        await wipeAllData(requireRelogin: true)
        syncMessage = "Session expired. Please log in again."
        sessionState = .reloginRequired
    }

    private func wipeAllData(requireRelogin: Bool) async {
        do {
            try repository.wipeCachedData(context: modelContext)
        } catch {
            syncMessage = "Could not clear local cache."
        }

        _ = secretStore.deleteAPIKey()
        _ = secretStore.deleteEncryptionKey()

        configStore.requiresRelogin = requireRelogin
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
