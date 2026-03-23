import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var appModel: AppModel
    @State private var suppressShieldUntil: Date?
    @State private var previousScenePhase: ScenePhase?

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
                PrivacyShieldView()
            }
        }
        .onAppear {
            previousScenePhase = scenePhase
        }
        .onChange(of: scenePhase) { oldPhase, _ in
            previousScenePhase = oldPhase
        }
        .onChange(of: appModel.sessionState) { _, newState in
            guard newState == .unlocked || newState == .degradedOffline else {
                return
            }
            suppressShieldUntil = Date().addingTimeInterval(2)
        }
    }

    private var shouldShowPrivacyShield: Bool {
        guard appModel.sessionState == .unlocked || appModel.sessionState == .degradedOffline else {
            return false
        }

        if let suppressShieldUntil, Date() < suppressShieldUntil {
            return false
        }

        switch scenePhase {
        case .background:
            return true
        case .inactive:
            return previousScenePhase == .active
        case .active:
            return false
        @unknown default:
            return false
        }
    }
}
