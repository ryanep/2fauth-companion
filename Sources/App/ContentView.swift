import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var appModel: AppModel
    @State private var suppressShieldUntil: Date?

    var body: some View {
        ZStack {
            Group {
                switch appModel.sessionState {
                case .loggedOut, .reloginRequired:
                    LoginView()
                case .locked:
                    LockScreenView()
                case .unlocked, .degradedOffline:
                    if appModel.requiresOnboarding {
                        LoginView()
                    } else {
                        MainTabView()
                    }
                }
            }

            if shouldShowPrivacyShield {
                Color.black
                    .ignoresSafeArea()

                VStack(spacing: 10) {
                    Image(systemName: "lock.fill")
                        .font(.title2)
                    Text("privacy_shield.title")
                        .font(.headline)
                }
                .foregroundStyle(.white)
            }
        }
        .onChange(of: appModel.sessionState) { _, newState in
            guard newState == .unlocked || newState == .degradedOffline else {
                return
            }
            suppressShieldUntil = Date().addingTimeInterval(2)
        }
    }

    private var shouldShowPrivacyShield: Bool {
        if let suppressShieldUntil, Date() < suppressShieldUntil {
            return false
        }

        guard scenePhase != .active else {
            return false
        }

        return appModel.sessionState == .unlocked || appModel.sessionState == .degradedOffline
    }
}
