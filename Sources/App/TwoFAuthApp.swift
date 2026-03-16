import SwiftData
import SwiftUI

@main
struct TwoFAuthApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let appModel: AppModel?
    private let backgroundSyncManager: BackgroundSyncManager?
    private let modelContainer: ModelContainer?
    private let startupErrorMessage: String?

    init() {
        do {
            let container = try ModelContainer(for: AccountEntity.self)
            let configStore = AppConfigStore()
            let secretStore = SecretStore()
            let cryptoStore = CryptoStore(secretStore: secretStore)
            let repository = AccountRepository(apiClient: APIClient(), cryptoStore: cryptoStore)
            let backgroundManager = BackgroundSyncManager(
                modelContainer: container,
                configStore: configStore,
                secretStore: secretStore,
                repository: repository
            )

            backgroundManager.register()

            self.appModel = AppModel(
                modelContext: container.mainContext,
                configStore: configStore,
                secretStore: secretStore,
                repository: repository,
                scheduleBackgroundRefresh: {
                    backgroundManager.scheduleAppRefresh()
                }
            )
            self.backgroundSyncManager = backgroundManager
            self.modelContainer = container
            self.startupErrorMessage = nil
        } catch {
#if DEBUG
            fatalError("Failed to create ModelContainer: \(error)")
#else
            self.appModel = nil
            self.backgroundSyncManager = nil
            self.modelContainer = nil
            self.startupErrorMessage = String(localized: "startup.error.model_container")
#endif
        }
    }

    var body: some Scene {
        WindowGroup {
            if let appModel, let modelContainer, let backgroundSyncManager {
                ContentView()
                    .environmentObject(appModel)
                    .modelContainer(modelContainer)
                    .task {
                        await appModel.bootstrap()
                        backgroundSyncManager.scheduleAppRefresh()
                    }
                    .onChange(of: scenePhase) { _, newPhase in
                        appModel.handleScenePhaseChange(newPhase)
                        if newPhase == .background {
                            backgroundSyncManager.scheduleAppRefresh()
                        }
                    }
            } else {
                StartupErrorView(message: startupErrorMessage ?? String(localized: "startup.error.generic"))
            }
        }
    }
}

private struct StartupErrorView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(String(localized: "startup.error.title"))
                .font(.headline)
            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(24)
    }
}
