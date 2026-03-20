import SwiftUI

struct PrivacyShieldView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        shieldBackgroundColor
            .ignoresSafeArea()
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: "lock.fill")
                        .font(.title2)
                    Text("privacy_shield.title")
                        .font(.headline)
                }
                .foregroundStyle(shieldForegroundColor)
            }
    }

    private var shieldBackgroundColor: Color {
        colorScheme == .dark ? .black : .white
    }

    private var shieldForegroundColor: Color {
        colorScheme == .dark ? .white : .black
    }
}

#Preview("Light") {
    PrivacyShieldView()
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    PrivacyShieldView()
        .preferredColorScheme(.dark)
}
