import Foundation
import SwiftData

#if os(iOS)
    import BackgroundTasks

    @MainActor
    final class BackgroundSyncManager {
        static let taskIdentifier = "com.ryanep.2fauth.sync.refresh"

        private let modelContainer: ModelContainer
        private var configStore: any AppConfigStore
        private let secretStore: any SecretStore
        private let repository: any AccountRepository

        init(
            modelContainer: ModelContainer,
            configStore: any AppConfigStore,
            secretStore: any SecretStore,
            repository: any AccountRepository
        ) {
            self.modelContainer = modelContainer
            self.configStore = configStore
            self.secretStore = secretStore
            self.repository = repository
        }

        func register() {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil) {
                [weak self] task in
                guard let self, let refreshTask = task as? BGAppRefreshTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.handle(task: refreshTask)
            }
        }

        func scheduleAppRefresh() {
            let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
            let minutes = UserDefaultsAppConfigStore.backgroundSyncIntervalMinutes
            request.earliestBeginDate = Date(timeIntervalSinceNow: TimeInterval(minutes * 60))
            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                ErrorReporter.report("background.schedule_submit_failed")
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
                ErrorReporter.report("background.task_expired")
            }
        }

        private func runBackgroundSync() async -> Bool {
            await runBackgroundSync(isCancelled: { Task.isCancelled })
        }

        func runBackgroundSync(isCancelled: () -> Bool) async -> Bool {
            if isCancelled() {
                ErrorReporter.report("background.sync_cancelled_preflight")
                return false
            }

            guard let apiKey = secretStore.loadAPIKey(), let baseURLString = configStore.baseURLString,
                let baseURL = URL(string: baseURLString)
            else {
                return true
            }

            let context = ModelContext(modelContainer)
            let result = await repository.syncAccounts(
                context: context,
                baseURL: baseURL,
                apiKey: apiKey,
                includeSecrets: true
            )

            if isCancelled() {
                ErrorReporter.report("background.sync_cancelled_after_network")
                return false
            }

            switch result {
            case .success:
                return true
            case .unauthorized:
                if isCancelled() {
                    ErrorReporter.report("background.sync_cancelled_before_wipe")
                    return false
                }
                do {
                    try repository.wipeCachedData(context: context)
                } catch {
                    ErrorReporter.report("background.wipe_failed")
                    return false
                }
                _ = secretStore.deleteAPIKey()
                _ = secretStore.deleteEncryptionKey()
                configStore.requiresRelogin = true
                ErrorReporter.report("background.sync_unauthorized_relogin")
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
            configStore: any AppConfigStore,
            secretStore: any SecretStore,
            repository: any AccountRepository
        ) {}

        func register() {}

        func scheduleAppRefresh() {}
    }

#endif
