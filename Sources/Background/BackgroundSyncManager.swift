import Foundation
import SwiftData

#if os(iOS)
    import BackgroundTasks

    protocol BackgroundTaskScheduling {
        func register(
            forTaskWithIdentifier identifier: String,
            using queue: DispatchQueue?,
            launchHandler: @escaping (BGTask) -> Void
        ) -> Bool
        func submit(_ taskRequest: BGTaskRequest) throws
    }

    extension BGTaskScheduler: BackgroundTaskScheduling {}

    @MainActor
    final class BackgroundSyncManager {
        static let taskIdentifier = "com.ryanep.2fauth.sync.refresh"

        private let modelContainer: ModelContainer
        private var configStore: any AppConfigStore
        private let secretStore: any SecretStore
        private let repository: any AccountRepository
        private let taskScheduler: any BackgroundTaskScheduling
        private let report: (String, [String: String]) -> Void

        init(
            modelContainer: ModelContainer,
            configStore: any AppConfigStore,
            secretStore: any SecretStore,
            repository: any AccountRepository,
            taskScheduler: any BackgroundTaskScheduling = BGTaskScheduler.shared,
            report: @escaping (String, [String: String]) -> Void = ErrorReporter.report
        ) {
            self.modelContainer = modelContainer
            self.configStore = configStore
            self.secretStore = secretStore
            self.repository = repository
            self.taskScheduler = taskScheduler
            self.report = report
        }

        func register() {
            let didRegister = taskScheduler.register(
                forTaskWithIdentifier: Self.taskIdentifier,
                using: nil
            ) { [weak self] task in
                guard let self, let refreshTask = task as? BGAppRefreshTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.handle(task: refreshTask)
            }

            if !didRegister {
                report("background.register_failed", ["taskIdentifier": Self.taskIdentifier])
            }
        }

        func scheduleAppRefresh() {
            let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
            let minutes = UserDefaultsAppConfigStore.backgroundSyncIntervalMinutes
            request.earliestBeginDate = Date(timeIntervalSinceNow: TimeInterval(minutes * 60))
            do {
                try taskScheduler.submit(request)
            } catch {
                report(
                    "background.schedule_submit_failed",
                    [
                        "taskIdentifier": Self.taskIdentifier,
                        "error": error.localizedDescription,
                    ]
                )
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

            guard let apiKey = secretStore.loadAPIKey(), let baseURL = validatedBaseURLForBackgroundSync() else {
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

        private func validatedBaseURLForBackgroundSync() -> URL? {
            guard let baseURLString = configStore.baseURLString else {
                return nil
            }

            switch TransportURLValidator.validateBaseURL(baseURLString, policy: configStore.transportPolicy) {
            case .success(let url):
                return url
            case .failure(.insecureSchemeNotAllowed):
                ErrorReporter.report("background.sync_skipped_insecure_transport")
                return nil
            case .failure(.invalid):
                ErrorReporter.report("background.sync_skipped_invalid_base_url")
                return nil
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
