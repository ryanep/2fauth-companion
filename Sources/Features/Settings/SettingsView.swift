import Foundation
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var showingLogoutConfirmation = false
    private static let lastSyncFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var autoLockTimeoutBinding: Binding<Int> {
        Binding(
            get: { appModel.autoLockTimeoutSeconds },
            set: { appModel.updateAutoLockTimeout(seconds: $0) }
        )
    }

    private func autoLockLabel(for seconds: Int) -> String {
        switch seconds {
        case 0:
            return String(localized: "settings.auto_lock.immediate")
        case 30:
            return String(localized: "settings.auto_lock.30s")
        case 60:
            return String(localized: "settings.auto_lock.1m")
        case 300:
            return String(localized: "settings.auto_lock.5m")
        default:
            return String(localized: "settings.auto_lock.immediate")
        }
    }

    private var lastSuccessfulSyncText: String {
        guard let date = appModel.lastSuccessfulSyncAt else {
            return String(localized: "settings.last_sync.never")
        }
        return Self.lastSyncFormatter.string(from: date)
    }

    private var serverURLText: String {
        let value = appModel.baseURLInput.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return value.isEmpty ? String(localized: "settings.server_url.not_set") : value
    }

    private var appVersionText: String {
        AppVersionFormatter.displayVersion()
    }

    var body: some View {
        settingsForm
    }

    private var settingsForm: some View {
        Form {
            Section("settings.section.about") {
                settingsRow(label: String(localized: "settings.app_version.label"), value: appVersionText, identifier: "settings.app_version")
            }

            Section("settings.section.sync") {
                settingsRow(label: String(localized: "settings.server_url.label"), value: serverURLText, identifier: "settings.server_url")
                settingsRow(label: String(localized: "settings.last_sync.label"), value: lastSuccessfulSyncText, identifier: "settings.last_sync")
            }

            Section("settings.section.session") {
                Picker("settings.auto_lock.label", selection: autoLockTimeoutBinding) {
                    ForEach(UserDefaultsAppConfigStore.autoLockTimeoutOptionsSeconds, id: \.self) { seconds in
                        Text(autoLockLabel(for: seconds)).tag(seconds)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings.auto_lock")

                Button("settings.logout.button", role: .destructive) {
                    showingLogoutConfirmation = true
                }
                .accessibilityIdentifier("settings.logout")
            }
        }
        .navigationTitle("settings.title")
        .alert("settings.logout.alert.title", isPresented: $showingLogoutConfirmation) {
            Button("settings.logout.alert.cancel", role: .cancel) {}
            Button("settings.logout.button", role: .destructive) {
                Task {
                    await appModel.logout()
                }
            }
            .accessibilityIdentifier("settings.logout.confirm")
        } message: {
            Text("settings.logout.alert.message")
        }
        .accessibilityIdentifier("settings.screen")
    }

    private func settingsRow(label: String, value: String, identifier: String) -> some View {
        LabeledContent {
            Text(value)
                .accessibilityIdentifier(identifier)
        } label: {
            Text(label)
        }
    }
}
