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
                Label("Accounts", systemImage: "person.2")
            }

            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }
}
