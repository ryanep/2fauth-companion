import SwiftUI

@main
struct TwoFAuthWatchApp: App {
    @StateObject private var accountStore = WatchAccountStore()

    var body: some Scene {
        WindowGroup {
            WatchAccountsView()
                .environmentObject(accountStore)
                .task {
                    accountStore.activateSession()
                }
        }
    }
}
