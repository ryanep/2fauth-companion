import AVFoundation
import SwiftUI
import UIKit
import VisionKit

struct QRCodeScannerView: View {
    private enum ScannerState: Equatable {
        case checking
        case ready
        case unsupported
        case unavailable
        case denied
    }

    let onScan: (String) -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var scannerState: ScannerState = .checking
    @State private var hasCompleted = false

    var body: some View {
        Group {
            switch scannerState {
            case .checking:
                ProgressView("add_account.scanner.preparing")
            case .ready:
                DataScannerView(onScan: complete) {
                    scannerState = .unavailable
                }
                .ignoresSafeArea()
                .overlay(alignment: .bottom) {
                    Text("add_account.scanner.instruction")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                        .allowsHitTesting(false)
                }
            case .unsupported:
                scannerMessage(
                    title: String(localized: "add_account.scanner.unsupported.title"),
                    message: String(localized: "add_account.scanner.unsupported.message"),
                    systemImage: "camera.fill"
                )
            case .unavailable:
                scannerMessage(
                    title: String(localized: "add_account.scanner.unavailable.title"),
                    message: String(localized: "add_account.scanner.unavailable.message"),
                    systemImage: "camera.fill"
                )
            case .denied:
                VStack(spacing: 16) {
                    scannerMessage(
                        title: String(localized: "add_account.scanner.denied.title"),
                        message: String(localized: "add_account.scanner.denied.message"),
                        systemImage: "camera.fill"
                    )
                    Button("add_account.scanner.settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .task {
            await prepareScanner()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, scannerState != .checking else { return }
            Task {
                await prepareScanner()
            }
        }
    }

    private func scannerMessage(
        title: String,
        message: String,
        systemImage: String
    ) -> some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
    }

    @MainActor
    private func prepareScanner() async {
        guard DataScannerViewController.isSupported else {
            scannerState = .unsupported
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            scannerState = DataScannerViewController.isAvailable ? .ready : .unavailable
        case .notDetermined:
            let isAuthorized = await AVCaptureDevice.requestAccess(for: .video)
            if isAuthorized {
                scannerState = DataScannerViewController.isAvailable ? .ready : .unavailable
            } else {
                scannerState = .denied
            }
        case .denied, .restricted:
            scannerState = .denied
        @unknown default:
            scannerState = .denied
        }
    }

    private func complete(_ uri: String) {
        guard !hasCompleted else { return }
        hasCompleted = true
        onScan(uri)
    }
}

private struct DataScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onUnavailable: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, onUnavailable: onUnavailable)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: true,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        do {
            try controller.startScanning()
        } catch {
            Task { @MainActor in
                onUnavailable()
            }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        uiViewController.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onScan: (String) -> Void
        private let onUnavailable: () -> Void
        private var hasScanned = false

        init(onScan: @escaping (String) -> Void, onUnavailable: @escaping () -> Void) {
            self.onScan = onScan
            self.onUnavailable = onUnavailable
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !hasScanned else { return }
            for item in addedItems {
                guard case .barcode(let barcode) = item, let value = barcode.payloadStringValue else {
                    continue
                }
                hasScanned = true
                dataScanner.stopScanning()
                onScan(value)
                return
            }
        }

        func dataScannerDidBecomeUnavailable(_ dataScanner: DataScannerViewController) {
            guard !hasScanned else { return }
            dataScanner.stopScanning()
            onUnavailable()
        }
    }
}
