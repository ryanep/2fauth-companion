import Combine
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

struct AddAccountPreview: Equatable {
    let service: String?
    let account: String
    let icon: String?
    let otpType: String
    let digits: Int
    let period: Int
    let algorithm: String
    let secret: String
}

enum AddAccountError: Error, Equatable, LocalizedError {
    case invalidURI
    case unsupportedOTPType
    case authenticationRequired
    case permissionDenied
    case validation
    case network(String)
    case server(Int)
    case invalidResponse
    case creationOutcomeUnknown
    case createdButNotCached

    var errorDescription: String? {
        switch self {
        case .invalidURI:
            String(localized: "add_account.error.invalid_uri")
        case .unsupportedOTPType:
            String(localized: "add_account.error.unsupported_type")
        case .authenticationRequired:
            String(localized: "add_account.error.authentication_required")
        case .permissionDenied:
            String(localized: "add_account.error.permission_denied")
        case .validation:
            String(localized: "add_account.error.validation")
        case .network(let reason):
            String.localizedStringWithFormat(String(localized: "add_account.error.network"), reason)
        case .server(let statusCode):
            String.localizedStringWithFormat(String(localized: "add_account.error.server"), statusCode)
        case .invalidResponse:
            String(localized: "add_account.error.invalid_response")
        case .creationOutcomeUnknown:
            String(localized: "add_account.error.creation_outcome_unknown")
        case .createdButNotCached:
            String(localized: "add_account.error.created_not_cached")
        }
    }
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
    @Published var currentTime: Date = .init()

    private var timerCancellable: AnyCancellable?

    private let modelContext: ModelContext
    private var configStore: any AppConfigStore
    private let secretStore: any SecretStore
    private let repository: any AccountRepository
    private let scheduleBackgroundRefresh: () -> Void
    private let pushWatchSnapshot: () -> Void
    private let clearWatchSnapshot: () -> Void
    private let biometricAuthenticator: any BiometricAuthenticator

    private var unlockedState: SessionState = .unlocked
    private var backgroundedAt: Date?
    private var isUnlockInProgress = false
    private var isForegroundSyncActive = false
    private var foregroundSyncWaiters: [CheckedContinuation<Void, Never>] = []

    var requiresOnboarding: Bool {
        return !hasSessionConfiguration
    }

    init(
        modelContext: ModelContext,
        configStore: any AppConfigStore,
        secretStore: any SecretStore,
        repository: any AccountRepository,
        scheduleBackgroundRefresh: @escaping () -> Void,
        pushWatchSnapshot: @escaping () -> Void,
        clearWatchSnapshot: @escaping () -> Void,
        biometricAuthenticator: any BiometricAuthenticator = LocalBiometricAuthenticator()
    ) {
        self.modelContext = modelContext
        self.configStore = configStore
        self.secretStore = secretStore
        self.repository = repository
        self.scheduleBackgroundRefresh = scheduleBackgroundRefresh
        self.pushWatchSnapshot = pushWatchSnapshot
        self.clearWatchSnapshot = clearWatchSnapshot
        self.biometricAuthenticator = biometricAuthenticator
        self.baseURLInput = configStore.baseURLString ?? ""
        self.autoLockTimeoutSeconds = configStore.autoLockTimeoutSeconds
        self.lastSuccessfulSyncAt = configStore.lastSuccessfulSyncAt
    }

    func bootstrap() async {
        #if DEBUG
            if ProcessInfo.processInfo.environment["UI_TEST_FORCE_LOGGED_OUT"] == "1" {
                unlockedState = .unlocked
                sessionState = .loggedOut
                return
            }

            if ProcessInfo.processInfo.environment["UI_TEST_START_RELOGIN_REQUIRED"] == "1" {
                unlockedState = .unlocked
                sessionState = .reloginRequired
                return
            }

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
            pushWatchSnapshot()
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
                startTimer()
                pushWatchSnapshot()
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
                startTimer()
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

    @discardableResult
    func syncNow() async -> SyncResult? {
        await acquireForegroundSync()
        defer { releaseForegroundSync() }

        guard !Task.isCancelled else {
            return nil
        }

        guard let baseURL = configuredBaseURL(), let apiKey = secretStore.loadAPIKey() else {
            if sessionState == .unlocked || sessionState == .degradedOffline {
                sessionState = .loggedOut
            }
            return nil
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
            startTimer()
            pushWatchSnapshot()
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
        return result
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
            stopTimer()
        case .active:
            guard let backgroundedAt else { return }
            let elapsed = Date().timeIntervalSince(backgroundedAt)
            self.backgroundedAt = nil
            if shouldAutoLock(after: elapsed) {
                sessionState = .locked
            }
            startTimer()
        default:
            break
        }
    }

    func startTimer() {
        timerCancellable = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] date in
                self?.currentTime = date
            }
    }

    func stopTimer() {
        timerCancellable?.cancel()
        timerCancellable = nil
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

    private func acquireForegroundSync() async {
        if !isForegroundSyncActive {
            isForegroundSyncActive = true
            return
        }

        await withCheckedContinuation { continuation in
            foregroundSyncWaiters.append(continuation)
        }
    }

    private func releaseForegroundSync() {
        guard !foregroundSyncWaiters.isEmpty else {
            isForegroundSyncActive = false
            return
        }

        foregroundSyncWaiters.removeFirst().resume()
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
        clearWatchSnapshot()
    }
}

extension AppModel {
    func previewAccount(uri input: String) async throws -> AddAccountPreview {
        let uri: String
        do {
            uri = try OTPAuthURIValidator.validate(input)
        } catch OTPAuthURIValidationError.unsupportedOTPType {
            throw AddAccountError.unsupportedOTPType
        } catch {
            throw AddAccountError.invalidURI
        }

        guard let baseURL = configuredBaseURL(), let apiKey = secretStore.loadAPIKey() else {
            throw AddAccountError.authenticationRequired
        }

        do {
            let customOTP = OTPAuthURIValidator.isSteamAccount(uri) ? "steamtotp" : nil
            let account = try await repository.previewAccount(
                baseURL: baseURL,
                apiKey: apiKey,
                uri: uri,
                customOTP: customOTP
            )
            guard
                let secret = account.secret,
                !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                account.period ?? 30 > 0
            else {
                throw AddAccountError.invalidResponse
            }

            let isSteam = normalizedOTPType(account.otpType) == "steamtotp"
            return AddAccountPreview(
                service: account.service,
                account: account.account,
                icon: account.icon,
                otpType: account.otpType,
                digits: isSteam ? 5 : account.digits?.rawValue ?? OTPDigits.default.rawValue,
                period: account.period ?? 30,
                algorithm: account.algorithm?.rawValue ?? OTPAlgorithm.default.rawValue,
                secret: secret
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw await addAccountError(from: error)
        }
    }

    func addAccount(preview: AddAccountPreview, service: String?, account: String) async throws {
        guard let baseURL = configuredBaseURL(), let apiKey = secretStore.loadAPIKey() else {
            throw AddAccountError.authenticationRequired
        }

        let accountName = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accountName.isEmpty, !preview.secret.isEmpty else {
            throw AddAccountError.validation
        }

        let serviceName = service?.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestBody = AccountCreationRequest(
            service: serviceName?.isEmpty == true ? nil : serviceName,
            account: accountName,
            icon: preview.icon,
            otpType: preview.otpType,
            secret: preview.secret,
            digits: preview.digits,
            algorithm: preview.algorithm,
            period: preview.period
        )

        do {
            try await repository.createAccount(
                context: modelContext,
                baseURL: baseURL,
                apiKey: apiKey,
                requestBody: requestBody
            )
            _ = await refreshAfterAccountCreation()
        } catch AccountRepositoryError.createdButNotCached {
            if await refreshAfterAccountCreation() {
                return
            }
            throw AddAccountError.createdButNotCached
        } catch {
            throw await createAccountError(from: error)
        }
    }

    func generateCode(for preview: AddAccountPreview, at date: Date = Date()) -> String? {
        switch normalizedOTPType(preview.otpType) {
        case "totp":
            guard
                let digits = OTPDigits(rawValue: preview.digits),
                let algorithm = OTPAlgorithm(value: preview.algorithm),
                preview.period > 0
            else {
                return nil
            }
            return TOTPGenerator.generate(
                secret: preview.secret,
                digits: digits,
                period: preview.period,
                algorithm: algorithm,
                at: date
            )
        case "steamtotp":
            guard preview.period > 0 else { return nil }
            return SteamGuardGenerator.generate(secret: preview.secret, period: preview.period, at: date)
        default:
            return nil
        }
    }
}

extension AppModel {
    fileprivate func refreshAfterAccountCreation() async -> Bool {
        guard let result = await syncNow() else {
            return false
        }

        switch result {
        case .success:
            return true
        case .transient:
            scheduleBackgroundRefresh()
            pushWatchSnapshot()
            return false
        case .unauthorized:
            return false
        }
    }

    fileprivate func addAccountError(from error: any Error) async -> AddAccountError {
        switch error {
        case AccountRepositoryError.unsupportedOTPType:
            return .unsupportedOTPType
        case AccountRepositoryError.createdButNotCached:
            scheduleBackgroundRefresh()
            return .createdButNotCached
        case APIError.unauthorized:
            ErrorReporter.report("add_account.unauthorized")
            await enforceReloginWipe()
            return .authenticationRequired
        case APIError.forbidden:
            ErrorReporter.report("add_account.forbidden")
            return .permissionDenied
        case APIError.validation:
            return .validation
        case APIError.server(let statusCode):
            ErrorReporter.report("add_account.server_error", metadata: ["status": String(statusCode)])
            return .server(statusCode)
        case APIError.transport(let reason):
            ErrorReporter.report("add_account.transport_error")
            return .network(reason)
        case APIError.invalidURL, APIError.decoding:
            ErrorReporter.report("add_account.invalid_response")
            return .invalidResponse
        default:
            ErrorReporter.report("add_account.generic_error")
            return .invalidResponse
        }
    }

    fileprivate func createAccountError(from error: any Error) async -> AddAccountError {
        if error is CancellationError {
            _ = await refreshAfterAccountCreationWithoutInheritedCancellation()
            ErrorReporter.report("add_account.creation_outcome_unknown")
            return .creationOutcomeUnknown
        }

        switch error {
        case AccountRepositoryError.unsupportedOTPType:
            _ = await refreshAfterAccountCreation()
            return .createdButNotCached
        case APIError.transport, APIError.decoding, APIError.server:
            _ = await refreshAfterAccountCreation()
            ErrorReporter.report("add_account.creation_outcome_unknown")
            return .creationOutcomeUnknown
        default:
            return await addAccountError(from: error)
        }
    }

    private func refreshAfterAccountCreationWithoutInheritedCancellation() async -> Bool {
        await Task { @MainActor [weak self] in
            guard let self else { return false }
            return await refreshAfterAccountCreation()
        }.value
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
            let algorithm =
                OTPAlgorithm(value: account.algorithm ?? OTPAlgorithm.default.rawValue) ?? OTPAlgorithm.default
            let period = account.period ?? 30
            return TOTPGenerator.generate(
                secret: secret,
                digits: digits,
                period: period,
                algorithm: algorithm,
                at: date
            )
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

    private func normalizedOTPType(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
