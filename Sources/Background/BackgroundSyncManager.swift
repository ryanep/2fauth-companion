import Foundation
import SwiftData

#if os(iOS)
import BackgroundTasks

@MainActor
final class BackgroundSyncManager {
    static let taskIdentifier = "com.ryanep.2fauth.sync.refresh"

    private let modelContainer: ModelContainer
    private let configStore: AppConfigStore
    private let secretStore: SecretStore
    private let repository: AccountRepository

    init(
        modelContainer: ModelContainer,
        configStore: AppConfigStore,
        secretStore: SecretStore,
        repository: AccountRepository
    ) {
        self.modelContainer = modelContainer
        self.configStore = configStore
        self.secretStore = secretStore
        self.repository = repository
    }

    func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil) { [weak self] task in
            guard let self, let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handle(task: refreshTask)
        }
    }

    func scheduleAppRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        let minutes = AppConfigStore.backgroundSyncIntervalMinutes
        request.earliestBeginDate = Date(timeIntervalSinceNow: TimeInterval(minutes * 60))
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            return
        }
    }

    private func handle(task: BGAppRefreshTask) {
        scheduleAppRefresh()
        let worker = Task {
            let success = await runBackgroundSync()
            task.setTaskCompleted(success: success)
        }

        task.expirationHandler = {
            worker.cancel()
        }
    }

    private func runBackgroundSync() async -> Bool {
        guard let apiKey = secretStore.loadAPIKey(), let baseURLString = configStore.baseURLString, let baseURL = URL(string: baseURLString) else {
            return true
        }

        let context = ModelContext(modelContainer)
        let result = await repository.syncAccounts(
            context: context,
            baseURL: baseURL,
            apiKey: apiKey,
            includeSecrets: true
        )

        switch result {
        case .success:
            return true
        case .unauthorized:
            do {
                try repository.wipeCachedData(context: context)
            } catch {
                return false
            }
            _ = secretStore.deleteAPIKey()
            _ = secretStore.deleteEncryptionKey()
            configStore.requiresRelogin = true
            return true
        case .transient:
            return true
        }
    }
}

#else

final class BackgroundSyncManager {
    static let taskIdentifier = "com.ryanep.2fauth.sync.refresh"

    init(
        modelContainer: ModelContainer,
        configStore: AppConfigStore,
        secretStore: SecretStore,
        repository: AccountRepository
    ) {}

    func register() {}

    func scheduleAppRefresh() {}
}

#endif
