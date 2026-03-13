import SwiftData
import SwiftUI

@main
struct TwoFAuthApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var appModel: AppModel
    private let backgroundSyncManager: BackgroundSyncManager
    private let modelContainer: ModelContainer

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: AccountEntity.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }

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

        _appModel = StateObject(
            wrappedValue: AppModel(
                modelContext: container.mainContext,
                configStore: configStore,
                secretStore: secretStore,
                repository: repository,
                scheduleBackgroundRefresh: {
                    backgroundManager.scheduleAppRefresh()
                }
            )
        )
        self.backgroundSyncManager = backgroundManager
        self.modelContainer = container
    }

    var body: some Scene {
        WindowGroup {
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
        }
    }
}
