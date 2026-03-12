import SwiftUI

struct LockScreenView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var didAutoPrompt = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "faceid")
                .font(.system(size: 48))
            Text("lock.title")
                .font(.title2.bold())
            Button("lock.button.biometric") {
                Task {
                    await appModel.unlock()
                }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("lock.unlock")
        }
        .padding()
        .onAppear {
            guard !didAutoPrompt else {
                return
            }
            didAutoPrompt = true
            Task {
                await appModel.unlock()
            }
        }
    }
}
