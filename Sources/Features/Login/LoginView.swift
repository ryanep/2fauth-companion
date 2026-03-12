import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var apiKey: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("https://example.com", text: $appModel.baseURLInput)
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)

                    SecureField("API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
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
                            Text("Log In")
                        }
                    }
                    .disabled(appModel.isSyncing)
                }
            }
            .navigationTitle("2FAuth Login")
        }
    }
}
