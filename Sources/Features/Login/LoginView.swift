import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var apiKey: String = ""
    @State private var didTriggerAutoLogin = false

    private var usesInsecureHTTP: Bool {
        appModel.baseURLInput
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("http://")
    }

    var body: some View {
        NavigationStack {
            loginForm
        }
    }

    private var loginForm: some View {
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

            if usesInsecureHTTP {
                Section {
                    Text("login.warning.insecure_transport")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
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
        .onAppear {
            applyUITestHooksIfNeeded()
        }
    }

    private func applyUITestHooksIfNeeded() {
        #if DEBUG
            if let baseURL = ProcessInfo.processInfo.environment["UI_TEST_BASE_URL"], !baseURL.isEmpty {
                appModel.baseURLInput = baseURL
            }

            if let token = ProcessInfo.processInfo.environment["UI_TEST_API_TOKEN"], !token.isEmpty {
                apiKey = token
            }

            if ProcessInfo.processInfo.environment["UI_TEST_AUTO_LOGIN"] == "1",
                !didTriggerAutoLogin,
                !appModel.baseURLInput.isEmpty,
                !apiKey.isEmpty
            {
                didTriggerAutoLogin = true
                let loginToken = apiKey
                Task {
                    await appModel.attemptLogin(apiKey: loginToken)
                    apiKey = ""
                }
            }
        #endif
    }
}
