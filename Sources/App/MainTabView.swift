import SwiftUI

struct MainTabView: View {
    var body: some View {
        if #available(iOS 26.0, *) {
            tabContent
                .tabBarMinimizeBehavior(.onScrollDown)
        } else {
            tabContent
        }
    }

    private var tabContent: some View {
        TabView {
            NavigationStack {
                AccountsView()
            }
            .tabItem {
                Label("tabs.accounts", systemImage: "person.2")
            }
            .accessibilityIdentifier("tab.accounts")

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("tabs.settings", systemImage: "gearshape")
            }
            .accessibilityIdentifier("tab.settings")
        }
    }
}
