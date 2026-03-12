import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        ZStack {
            Group {
                switch appModel.sessionState {
                case .loggedOut, .reloginRequired:
                    LoginView()
                case .locked:
                    LockScreenView()
                case .unlocked, .degradedOffline:
                    MainTabView()
                }
            }

            if shouldShowPrivacyShield {
                Color.black
                    .ignoresSafeArea()

                VStack(spacing: 10) {
                    Image(systemName: "lock.fill")
                        .font(.title2)
                    Text("Protected")
                        .font(.headline)
                }
                .foregroundStyle(.white)
            }
        }
    }

    private var shouldShowPrivacyShield: Bool {
        guard scenePhase != .active else {
            return false
        }

        return appModel.sessionState == .unlocked || appModel.sessionState == .degradedOffline
    }
}
