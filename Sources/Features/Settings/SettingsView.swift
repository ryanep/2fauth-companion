import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appModel: AppModel

    private var backgroundSyncBinding: Binding<Int> {
        Binding(
            get: { appModel.backgroundSyncIntervalMinutes },
            set: { appModel.updateBackgroundSyncInterval(minutes: $0) }
        )
    }

    private var autoLockTimeoutBinding: Binding<Int> {
        Binding(
            get: { appModel.autoLockTimeoutSeconds },
            set: { appModel.updateAutoLockTimeout(seconds: $0) }
        )
    }

    private func autoLockLabel(for seconds: Int) -> String {
        switch seconds {
        case 0:
            return "Immediately"
        case 30:
            return "30 seconds"
        case 60:
            return "1 minute"
        case 300:
            return "5 minutes"
        default:
            return "Immediately"
        }
    }

    var body: some View {
        Form {
            Section("Background Sync") {
                Stepper(
                    value: backgroundSyncBinding,
                    in: AppConfigStore.minimumBackgroundSyncIntervalMinutes...AppConfigStore.maximumBackgroundSyncIntervalMinutes,
                    step: 5
                ) {
                    Text("Every \(appModel.backgroundSyncIntervalMinutes) minutes")
                }

                Text("iOS runs refresh tasks opportunistically, so actual timing may vary.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Session") {
                Picker("Auto-Lock", selection: autoLockTimeoutBinding) {
                    ForEach(AppConfigStore.autoLockTimeoutOptionsSeconds, id: \.self) { seconds in
                        Text(autoLockLabel(for: seconds)).tag(seconds)
                    }
                }
                .pickerStyle(.menu)

                Button("Log Out", role: .destructive) {
                    Task {
                        await appModel.logout()
                    }
                }
            }
        }
        .navigationTitle("Settings")
    }
}
