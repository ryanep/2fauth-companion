import Combine
import SwiftData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct AccountsView: View {
    @EnvironmentObject private var appModel: AppModel
    @Query(sort: \AccountEntity.account) private var accounts: [AccountEntity]
    @State private var searchText: String = ""

    var body: some View {
        List(filteredAccounts) { account in
            AccountRowView(account: account)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .overlay {
            if filteredAccounts.isEmpty {
                ContentUnavailableView(
                    "No Accounts",
                    systemImage: "shield",
                    description: Text(emptyStateMessage)
                )
            }
        }
        .navigationTitle("Accounts")
        .searchable(text: $searchText, prompt: "Search accounts")
        .refreshable {
            await appModel.syncNow()
        }
        .safeAreaInset(edge: .bottom) {
            if let syncMessage = appModel.syncMessage {
                Text(syncMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        }
        .task {
            await appModel.syncNow()
        }
    }

    private var filteredAccounts: [AccountEntity] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return accounts
        }

        return accounts.filter { account in
            let accountName = account.account.localizedLowercase
            let serviceName = (account.service ?? "").localizedLowercase
            let otpType = account.otpType.localizedLowercase
            let term = query.localizedLowercase
            return accountName.contains(term) || serviceName.contains(term) || otpType.contains(term)
        }
    }

    private var emptyStateMessage: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Sync to fetch your 2FA accounts."
            : "No accounts match your search."
    }
}

private struct AccountRowView: View {
    @EnvironmentObject private var appModel: AppModel
    let account: AccountEntity
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    @State private var otpCode: String = "------"
    @State private var now: Date = .init()
    @State private var didCopyCode = false

    private var otpType: String {
        normalizedOTPType(account.otpType)
    }

    private var isTimeBasedCode: Bool {
        otpType == "totp" || otpType == "steamtotp"
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.service ?? "Unknown Service")
                    .font(.headline)

                Text(account.account)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if isTimeBasedCode {
                    Text(otpCode)
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(didCopyCode ? .green : .primary)
                } else if otpType == "hotp" {
                    HStack(spacing: 8) {
                        Text(otpCode)
                            .font(.title3.monospacedDigit().weight(.semibold))
                            .foregroundStyle(didCopyCode ? .green : .primary)

                        Button("Next") {
                            otpCode = appModel.generateHOTP(for: account) ?? "------"
                            triggerLightHaptic()
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    Text("Unsupported OTP type")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            }

            Spacer(minLength: 8)

            if isTimeBasedCode {
                ZStack {
                    Circle()
                        .stroke(lineWidth: 5)
                        .foregroundStyle(.quaternary)

                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(
                            ringColor,
                            style: StrokeStyle(lineWidth: 5, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.25), value: progress)

                    Text("\(secondsRemaining)s")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 34, height: 34)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.green.opacity(didCopyCode ? 0.5 : 0), lineWidth: 1.5)
                .animation(.easeInOut(duration: 0.2), value: didCopyCode)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            handleCopyCodeTap()
        }
        .onAppear {
            refreshCode()
        }
        .onReceive(timer) { tick in
            now = tick
            refreshCode()
        }
    }

    private var secondsRemaining: Int {
        let configured = account.period ?? 30
        let period = configured > 0 ? configured : 1
        let elapsed = Int(now.timeIntervalSince1970).quotientAndRemainder(dividingBy: period).remainder
        let remaining = period - elapsed
        return remaining > 0 ? remaining : 1
    }

    private var progress: CGFloat {
        let configured = account.period ?? 30
        let period = CGFloat(configured > 0 ? configured : 1)
        return CGFloat(secondsRemaining) / period
    }

    private var ringColor: Color {
        if secondsRemaining <= 5 {
            return .red
        }
        if secondsRemaining <= 10 {
            return .orange
        }
        return .green
    }

    private func refreshCode() {
        switch otpType {
        case "totp":
            otpCode = appModel.generateTOTP(for: account, at: now) ?? "------"
        case "steamtotp":
            otpCode = appModel.generateSteamGuard(for: account, at: now) ?? "-----"
        default:
            otpCode = "------"
        }
    }

    private func normalizedOTPType(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func copyCodeToClipboard() {
        guard !otpCode.contains("-") else {
            return
        }
#if canImport(UIKit)
        UIPasteboard.general.string = otpCode
        triggerCopyHaptic()
#endif
    }

    private func handleCopyCodeTap() {
        guard !otpCode.contains("-") else {
            return
        }

        copyCodeToClipboard()
        withAnimation(.easeOut(duration: 0.2)) {
            didCopyCode = true
        }

        Task {
            try? await Task.sleep(for: .seconds(1.2))
            await MainActor.run {
                withAnimation(.easeIn(duration: 0.2)) {
                    didCopyCode = false
                }
            }
        }
    }

#if canImport(UIKit)
    private func triggerLightHaptic() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
    }

    private func triggerCopyHaptic() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
    }
#else
    private func triggerLightHaptic() {}
    private func triggerCopyHaptic() {}
#endif
}
