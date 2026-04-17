import SwiftUI

struct WatchAccountsView: View {
    @EnvironmentObject private var accountStore: WatchAccountStore
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var now: Date = .init()

    var body: some View {
        NavigationStack {
            List(accountStore.accounts) { account in
                WatchAccountRowView(account: account, now: now)
                    .listRowInsets(.init(top: 6, leading: 2, bottom: 6, trailing: 2))
                    .listRowBackground(Color.clear)
            }
            .navigationTitle("Accounts")
            .overlay {
                if accountStore.accounts.isEmpty {
                    ContentUnavailableView(
                        "No Codes",
                        systemImage: "shield",
                        description: Text("Open 2FAuth on iPhone to sync your accounts.")
                    )
                    .accessibilityIdentifier("watch.empty")
                }
            }
            .onReceive(timer) { tick in
                now = tick
            }
        }
        .accessibilityIdentifier("watch.accounts.screen")
    }
}

private struct WatchAccountRowView: View {
    @EnvironmentObject private var accountStore: WatchAccountStore
    let account: WatchAccountModel
    let now: Date

    private var serviceAccessibilityKey: String {
        let value = (account.service ?? "Unknown Service").lowercased()
        let parts = value.split { !$0.isLetter && !$0.isNumber }
        let joined = parts.map(String.init).joined(separator: "-")
        return joined.isEmpty ? "unknown-service" : joined
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(account.service ?? "Unknown Service")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 6)

                if accountStore.supportsLiveCountdown(account.otpType) {
                    Text("\(accountStore.secondsRemaining(for: account, now: now))s")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("watch.countdown.\(serviceAccessibilityKey)")
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.thinMaterial, in: Capsule())
                }
            }

            Text(accountStore.code(for: account, at: now))
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .accessibilityIdentifier("watch.code.\(serviceAccessibilityKey)")

            Text(account.account)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("watch.row.\(serviceAccessibilityKey)")
    }
}
