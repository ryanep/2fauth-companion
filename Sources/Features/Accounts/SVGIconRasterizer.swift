import Foundation

#if canImport(UIKit) && canImport(WebKit)
    import UIKit
    import WebKit

    @MainActor
    final class SVGIconRasterizer: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private var continuation: CheckedContinuation<Data?, Never>?
        private var webView: WKWebView?
        private var containerView: UIView?
        private var timeoutTask: Task<Void, Never>?
        private var didResume = false

        func rasterize(_ data: Data) async -> Data? {
            guard !Task.isCancelled else {
                return nil
            }
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                    didResume = false
                    let configuration = WKWebViewConfiguration()
                    configuration.websiteDataStore = .nonPersistent()
                    configuration.userContentController.add(self, name: "iconReady")
                    let webView = WKWebView(
                        frame: CGRect(origin: .zero, size: CGSize(width: 128, height: 128)),
                        configuration: configuration
                    )
                    webView.isOpaque = false
                    webView.backgroundColor = .clear
                    webView.scrollView.backgroundColor = .clear
                    webView.scrollView.isScrollEnabled = false
                    webView.scrollView.contentInsetAdjustmentBehavior = .never
                    webView.navigationDelegate = self
                    self.webView = webView
                    guard attachToActiveWindow(webView) else {
                        resume(returning: nil)
                        return
                    }

                    let encodedSVG = data.base64EncodedString()
                    let html = """
                        <!doctype html>
                        <html>
                        <head>
                            <meta name="viewport" content="width=device-width, initial-scale=1.0">
                            <meta
                                http-equiv="Content-Security-Policy"
                                content="default-src 'none'; img-src data:; script-src 'unsafe-inline'; style-src 'unsafe-inline'"
                            >
                            <style>
                                html, body {
                                    margin: 0;
                                    padding: 0;
                                    width: 128px;
                                    height: 128px;
                                    overflow: hidden;
                                    background: transparent;
                                }
                                body {
                                    display: flex;
                                    align-items: center;
                                    justify-content: center;
                                }
                                img {
                                    max-width: 128px;
                                    max-height: 128px;
                                    object-fit: contain;
                                }
                            </style>
                        </head>
                        <body>
                            <img id="icon" src="data:image/svg+xml;base64,\(encodedSVG)">
                            <script>
                                const post = (message) => window.webkit.messageHandlers.iconReady.postMessage(message);
                                const finish = () => requestAnimationFrame(() => {
                                    const canvas = document.createElement('canvas');
                                    canvas.width = 128;
                                    canvas.height = 128;
                                    const context = canvas.getContext('2d');
                                    const scale = Math.min(128 / image.naturalWidth, 128 / image.naturalHeight);
                                    const width = image.naturalWidth * scale;
                                    const height = image.naturalHeight * scale;
                                    context.clearRect(0, 0, 128, 128);
                                    context.drawImage(image, (128 - width) / 2, (128 - height) / 2, width, height);
                                    post(canvas.toDataURL('image/png'));
                                });
                                const fail = () => post('failed');
                                const image = document.getElementById('icon');
                                const decodeAndFinish = () => {
                                    if (image.decode) {
                                        image.decode().then(finish).catch(finish);
                                    } else {
                                        finish();
                                    }
                                };
                                if (image.complete) {
                                    if (image.naturalWidth > 0 && image.naturalHeight > 0) {
                                        decodeAndFinish();
                                    } else {
                                        fail();
                                    }
                                } else {
                                    image.onload = decodeAndFinish;
                                    image.onerror = fail;
                                }
                            </script>
                        </body>
                        </html>
                        """
                    webView.loadHTMLString(html, baseURL: nil)

                    timeoutTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(5))
                        self?.resume(returning: nil)
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.resume(returning: nil)
                }
            }
        }

        nonisolated func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            Task { @MainActor in
                guard message.name == "iconReady", !self.didResume else {
                    return
                }

                guard let value = message.body as? String,
                    value.hasPrefix("data:image/png;base64,"),
                    let data = Data(base64Encoded: String(value.dropFirst("data:image/png;base64,".count)))
                else {
                    self.resume(returning: nil)
                    return
                }
                self.resume(returning: data)
            }
        }

        nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            Task { @MainActor in
                self.resume(returning: nil)
            }
        }

        nonisolated func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error
        ) {
            Task { @MainActor in
                self.resume(returning: nil)
            }
        }

        nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            Task { @MainActor in
                self.resume(returning: nil)
            }
        }

        private func resume(returning data: Data?) {
            guard !didResume else {
                return
            }
            didResume = true
            timeoutTask?.cancel()
            timeoutTask = nil
            continuation?.resume(returning: data)
            continuation = nil
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: "iconReady")
            containerView?.removeFromSuperview()
            containerView = nil
            webView = nil
        }

        private func attachToActiveWindow(_ webView: WKWebView) -> Bool {
            guard
                let window = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .filter({ $0.activationState == .foregroundActive })
                    .flatMap(\.windows)
                    .first(where: \.isKeyWindow)
            else {
                return false
            }

            let containerView = UIView(
                frame: CGRect(
                    x: max(0, (window.bounds.width - 128) / 2),
                    y: max(0, (window.bounds.height - 128) / 2),
                    width: 128,
                    height: 128
                )
            )
            containerView.alpha = 0.01
            containerView.isUserInteractionEnabled = false
            containerView.backgroundColor = .clear
            webView.frame = containerView.bounds
            containerView.addSubview(webView)
            window.addSubview(containerView)
            self.containerView = containerView
            return true
        }
    }
#endif
