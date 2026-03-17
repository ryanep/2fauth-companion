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
            let container = try Self.makeModelContainer()
            let configStore = AppConfigStore()
            let secretStore = KeychainSecretStore()
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
                StartupErrorView(
                    message: startupErrorMessage ?? String(localized: "startup.error.generic"),
                    onResetData: resetPersistentData
                )
            }
        }
    }

    private static func makeModelContainer() throws -> ModelContainer {
        let configuration = ModelConfiguration(url: try persistentStoreURL())
        return try ModelContainer(for: AccountEntity.self, configurations: configuration)
    }

    private static func persistentStoreURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport.appendingPathComponent("2FAuth.store")
    }

    private func resetPersistentData() throws {
        let baseURL = try Self.persistentStoreURL()
        let fileManager = FileManager.default
        let urls = [
            baseURL,
            URL(fileURLWithPath: baseURL.path + "-shm"),
            URL(fileURLWithPath: baseURL.path + "-wal"),
        ]

        for url in urls where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}

private struct StartupErrorView: View {
    let message: String
    let onResetData: () throws -> Void
    @State private var recoveryMessage: String?

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
            Button(String(localized: "startup.error.reset_data"), role: .destructive) {
                do {
                    try onResetData()
                    recoveryMessage = String(localized: "startup.error.reset_success")
                } catch {
                    recoveryMessage = String(localized: "startup.error.reset_failed")
                }
            }
            .padding(.top, 8)
            if let recoveryMessage {
                Text(recoveryMessage)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 420)
        .padding(24)
    }
}
