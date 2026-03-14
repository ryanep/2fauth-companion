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

    private var lastSuccessfulSyncText: String {
        guard let date = appModel.lastSuccessfulSyncAt else {
            return "Never"
        }
        return Self.lastSyncFormatter.string(from: date)
    }

    private var serverURLText: String {
        let value = appModel.baseURLInput.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return value.isEmpty ? "Not set" : value
    }

    var body: some View {
        Form {
            Section("Sync") {
                LabeledContent("Server URL", value: serverURLText)
                LabeledContent("Last Sync", value: lastSuccessfulSyncText)
            }

            Section("Session") {
                Picker("Auto-Lock", selection: autoLockTimeoutBinding) {
                    ForEach(AppConfigStore.autoLockTimeoutOptionsSeconds, id: \.self) { seconds in
                        Text(autoLockLabel(for: seconds)).tag(seconds)
                    }
                }
                .pickerStyle(.menu)

                Button("Log Out", role: .destructive) {
                    showingLogoutConfirmation = true
                }
            }
        }
        .navigationTitle("Settings")
        .alert("Log Out?", isPresented: $showingLogoutConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Log Out", role: .destructive) {
                Task {
                    await appModel.logout()
                }
            }
        } message: {
            Text("You will need your API key to sign back in.")
        }
    }
}
