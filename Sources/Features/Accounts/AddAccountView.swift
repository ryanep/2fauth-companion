import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit)
    import UIKit
#endif

struct AddAccountView: View {
    private enum Phase {
        case scanner
        case loading
        case confirmation
        case saving
        case error(AddAccountError)
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appModel: AppModel

    @State private var phase: Phase = .scanner
    @State private var preview: AddAccountPreview?
    @State private var serviceName = ""
    @State private var accountName = ""
    @State private var saveError: AddAccountError?
    @State private var isShowingSaveError = false
    @State private var didInjectDebugURI = false
    @State private var didCopyCode = false
    @State private var previewTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("add_account.title")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("add_account.cancel") {
                            cancelPreview()
                            dismiss()
                        }
                        .disabled(isSaving)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if isSaving {
                            ProgressView()
                                .accessibilityLabel("add_account.save.loading")
                                .accessibilityIdentifier("add_account.confirm")
                        } else if isConfirming {
                            Button("add_account.button.save") {
                                saveAccount()
                            }
                            .accessibilityIdentifier("add_account.confirm")
                            .disabled(!canAddAccount)
                        }
                    }
                }
                .interactiveDismissDisabled()
                .onDisappear {
                    cancelPreview()
                }
                .alert("add_account.error.title", isPresented: $isShowingSaveError) {
                    Button("add_account.error.ok", role: .cancel) {}
                } message: {
                    Text(saveError?.localizedDescription ?? String(localized: "add_account.error.invalid_response"))
                }
        }
    }
}

extension AddAccountView {
    @ViewBuilder
    private var content: some View {
        switch phase {
        case .scanner:
            scannerContent
        case .loading:
            ProgressView("add_account.preview.loading")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .confirmation:
            if let preview {
                confirmationView(preview)
            }
        case .saving:
            if let preview {
                confirmationView(preview)
            }
        case .error(let error):
            errorView(error)
        }
    }

    @ViewBuilder
    private var scannerContent: some View {
        #if DEBUG
            if let injectedURI = ProcessInfo.processInfo.environment["UI_TEST_SCANNED_OTP_URI"] {
                ProgressView("add_account.preview.loading")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear {
                        guard !didInjectDebugURI else { return }
                        didInjectDebugURI = true
                        startPreview(injectedURI)
                    }
            } else {
                scanner
            }
        #else
            scanner
        #endif
    }

    private var scanner: some View {
        QRCodeScannerView { uri in
            startPreview(uri)
        }
    }

    private func confirmationView(_ preview: AddAccountPreview) -> some View {
        Form {
            Section("add_account.section.current_code") {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    currentCodeRow(preview: preview, at: context.date)
                }
            }

            Section("add_account.confirmation.title") {
                LabeledContent("add_account.field.service") {
                    TextField("", text: $serviceName)
                        .textContentType(.organizationName)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("add_account.service")
                }
                LabeledContent("add_account.field.account") {
                    TextField("", text: $accountName)
                        .textContentType(.username)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("add_account.account")
                }
            }

            Section("add_account.section.otp_settings") {
                LabeledContent("add_account.field.otp_type", value: preview.otpType.uppercased())
                LabeledContent("add_account.field.digits", value: String(preview.digits))
                LabeledContent(
                    "add_account.field.period",
                    value: String.localizedStringWithFormat(
                        String(localized: "add_account.period.seconds"),
                        preview.period
                    )
                )
            }
        }
        .disabled(isSaving)
    }

    @ViewBuilder
    private func currentCodeRow(preview: AddAccountPreview, at date: Date) -> some View {
        if let code = appModel.generateCode(for: preview, at: date) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(code)
                        .font(.title.monospaced().weight(.semibold))
                        .foregroundStyle(didCopyCode ? .green : .primary)
                        .contentTransition(.numericText())
                    copyStatus
                }

                Spacer(minLength: 8)

                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 5)
                    Circle()
                        .trim(from: 0, to: codeProgress(preview: preview, at: date))
                        .stroke(
                            codeRingColor(preview: preview, at: date),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    Text(
                        String.localizedStringWithFormat(
                            String(localized: "accounts.seconds_remaining"),
                            codeSecondsRemaining(preview: preview, at: date)
                        )
                    )
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                }
                .frame(width: 42, height: 42)
                .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                copyCode(code)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("add_account.current_code")
            .accessibilityValue(didCopyCode ? "copied" : "ready")
            .accessibilityAddTraits(.isButton)
        } else {
            Label("add_account.code.unavailable", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("add_account.current_code.unavailable")
        }
    }

    @ViewBuilder
    private var copyStatus: some View {
        if didCopyCode {
            Text("add_account.code.copied")
        } else {
            Text("add_account.code.tap_to_copy")
        }
    }

    private func errorView(_ error: AddAccountError) -> some View {
        ContentUnavailableView {
            Label("add_account.error.title", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error.localizedDescription)
        } actions: {
            if error == .createdButNotCached || error == .creationOutcomeUnknown {
                Button("add_account.button.done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("add_account.button.scan_again") {
                    resetScanner()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    @MainActor
    private func previewScannedURI(_ uri: String) async {
        guard case .scanner = phase else { return }
        phase = .loading
        do {
            let result = try await appModel.previewAccount(uri: uri)
            try Task.checkCancellation()
            preview = result
            serviceName = result.service ?? ""
            accountName = result.account
            phase = .confirmation
        } catch is CancellationError {
            return
        } catch let error as AddAccountError {
            phase = .error(error)
        } catch {
            phase = .error(.invalidResponse)
        }
    }

    private func saveAccount() {
        guard case .confirmation = phase, let preview else { return }
        phase = .saving
        Task {
            do {
                try await appModel.addAccount(
                    preview: preview,
                    service: serviceName,
                    account: accountName
                )
                dismiss()
            } catch let error as AddAccountError {
                if error == .createdButNotCached || error == .creationOutcomeUnknown {
                    phase = .error(error)
                } else {
                    phase = .confirmation
                    saveError = error
                    isShowingSaveError = true
                }
            } catch {
                phase = .confirmation
                saveError = .invalidResponse
                isShowingSaveError = true
            }
        }
    }

    private func resetScanner() {
        cancelPreview()
        preview = nil
        serviceName = ""
        accountName = ""
        didCopyCode = false
        saveError = nil
        didInjectDebugURI = false
        phase = .scanner
    }

    private func cancelPreview() {
        previewTask?.cancel()
        previewTask = nil
    }

    private func startPreview(_ uri: String) {
        previewTask?.cancel()
        previewTask = Task {
            await previewScannedURI(uri)
            previewTask = nil
        }
    }

    private var isSaving: Bool {
        if case .saving = phase { return true }
        return false
    }

    private var isConfirming: Bool {
        if case .confirmation = phase { return true }
        return false
    }

    private var canAddAccount: Bool {
        guard let preview else { return false }
        return !accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && appModel.generateCode(for: preview) != nil
    }

    private func codeSecondsRemaining(preview: AddAccountPreview, at date: Date) -> Int {
        let period = max(preview.period, 1)
        let elapsed = Int(date.timeIntervalSince1970).quotientAndRemainder(dividingBy: period).remainder
        return max(period - elapsed, 1)
    }

    private func codeProgress(preview: AddAccountPreview, at date: Date) -> CGFloat {
        CGFloat(codeSecondsRemaining(preview: preview, at: date)) / CGFloat(max(preview.period, 1))
    }

    private func codeRingColor(preview: AddAccountPreview, at date: Date) -> Color {
        let remaining = codeSecondsRemaining(preview: preview, at: date)
        if remaining <= 5 { return .red }
        if remaining <= 10 { return .orange }
        return .green
    }

    private func copyCode(_ code: String) {
        #if canImport(UIKit)
            UIPasteboard.general.setItems(
                [[UTType.plainText.identifier: code]],
                options: [
                    .localOnly: true,
                    .expirationDate: Date().addingTimeInterval(60)
                ]
            )
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
        didCopyCode = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            await MainActor.run {
                didCopyCode = false
            }
        }
    }
}
