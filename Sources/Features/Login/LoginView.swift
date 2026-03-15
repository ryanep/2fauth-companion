import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var apiKey: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("login.section.server") {
                    TextField("login.base_url.placeholder", text: $appModel.baseURLInput)
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .accessibilityIdentifier("login.baseURL")

                    SecureField("login.api_key.placeholder", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .accessibilityIdentifier("login.apiKey")
                }

                if let message = appModel.loginError {
                    Section {
                        Text(message)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task {
                            await appModel.attemptLogin(apiKey: apiKey)
                            apiKey = ""
                        }
                    } label: {
                        if appModel.isSyncing {
                            ProgressView()
                        } else {
                            Text("login.button.submit")
                        }
                    }
                    .disabled(appModel.isSyncing)
                    .accessibilityIdentifier("login.submit")
                }
            }
            .navigationTitle("login.title")
            .accessibilityIdentifier("login.screen")
        }
    }
}
