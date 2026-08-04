import CryptoKit
import Foundation
import ImageIO

#if canImport(UIKit)
    import UIKit
#endif

#if canImport(WebKit)
    import WebKit
#endif

actor AccountIconCache {
    private struct InFlightImageLoad {
        let id: UUID
        let task: Task<Data?, Never>
        var waiterIDs: Set<UUID>
        var isUnownedRefresh: Bool
    }

    private struct CachedFile: Sendable {
        let data: Data
        let modificationDate: Date?
        let hasValidRasterMetadata: Bool
    }

    private struct MemoryImageData {
        let data: Data
        let modificationDate: Date
    }

    static let shared = AccountIconCache()

    private static let maximumDownloadBytes = 2 * 1_024 * 1_024
    private static let maximumRasterDimension = 2_048
    private static let maximumRasterPixels = 4_194_304
    private static let cachedRasterDimension = 128
    private static let maximumCacheAge: TimeInterval = 7 * 24 * 60 * 60
    private static let maximumConcurrentRasterizations = 4
    private static let cacheVersion = "2"

    typealias SVGRasterizer = @Sendable (Data) async -> Data?

    private let session: URLSession
    private let fileManager: FileManager
    private let cacheDirectory: URL
    private let rasterizeSVG: SVGRasterizer
    private var inFlightImageLoads: [URL: InFlightImageLoad] = [:]
    private var memoryImageData: [URL: MemoryImageData] = [:]
    private var cacheEpoch = 0
    private var sessionRevision = 0
    private var allowedURLs: Set<URL>?
    private var urlRevisions: [URL: Int] = [:]
    private var activeRasterizationCount = 0
    private var rasterizationWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        session: URLSession? = nil,
        fileManager: FileManager = .default,
        cacheDirectory: URL? = nil,
        rasterizeSVG: @escaping SVGRasterizer = AccountIconCache.defaultRasterizeSVG
    ) {
        self.session = session ?? Self.makeSession()
        self.fileManager = fileManager
        self.rasterizeSVG = rasterizeSVG
        let baseDirectory = (try? fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        self.cacheDirectory = cacheDirectory ?? baseDirectory.appendingPathComponent("AccountIcons", isDirectory: true)
    }

    static func iconURL(baseURL: URL, iconFilename: String?) -> URL? {
        let value = iconFilename?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty,
            var baseComponents = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
            let scheme = baseComponents.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            baseComponents.host != nil
        else {
            return nil
        }

        baseComponents.user = nil
        baseComponents.password = nil
        baseComponents.query = nil
        baseComponents.fragment = nil
        guard let sanitizedBaseURL = baseComponents.url else {
            return nil
        }

        let iconRoot = sanitizedBaseURL
            .appendingPathComponent("storage", isDirectory: true)
            .appendingPathComponent("icons", isDirectory: true)

        if let absoluteURL = URL(string: value), absoluteURL.scheme != nil {
            guard sameOrigin(absoluteURL, sanitizedBaseURL),
                absoluteURL.user == nil,
                absoluteURL.password == nil,
                absoluteURL.query == nil,
                absoluteURL.fragment == nil,
                !hasUnsafeEncodedPathSegment(absoluteURL),
                isDirectChild(absoluteURL, of: iconRoot)
            else {
                return nil
            }
            return absoluteURL
        }

        let pathComponents = value
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        let filename: String
        if pathComponents.count == 3,
            pathComponents[0] == "storage",
            pathComponents[1] == "icons"
        {
            filename = pathComponents[2]
        } else if pathComponents.count == 1 {
            filename = pathComponents[0]
        } else {
            return nil
        }

        guard isSafeFilename(filename) else {
            return nil
        }
        return iconRoot.appendingPathComponent(filename, isDirectory: false)
    }

    func imageData(for url: URL, allowRemoteLoad: Bool = true) async -> Data? {
        if let entry = memoryImageData[url] {
            if allowRemoteLoad,
                !isFresh(modificationDate: entry.modificationDate),
                inFlightImageLoads[url] == nil
            {
                refreshInBackground(url: url, cachedURL: cacheURL(for: url))
            }
            return entry.data
        }

        let cachedURL = cacheURL(for: url)
        let epoch = cacheEpoch
        let revision = urlRevisions[url, default: 0]
        let cachedFile = await Self.readCachedFile(at: cachedURL)
        guard !Task.isCancelled, epoch == cacheEpoch, isAllowed(url)
        else {
            return nil
        }
        guard revision == urlRevisions[url, default: 0] else {
            return memoryImageData[url]?.data
        }

        if let cachedFile,
            !cachedFile.data.isEmpty,
            cachedFile.data.count <= Self.maximumDownloadBytes
        {
            let data = cachedFile.data
            if isSVGData(data, from: url) {
                guard allowRemoteLoad else {
                    return nil
                }
                return await coalescedImageData(for: url, cachedURL: cachedURL, cachedData: data)
            }
            if isRasterImageData(data), cachedFile.hasValidRasterMetadata {
                let modificationDate = cachedFile.modificationDate ?? .distantPast
                memoryImageData[url] = MemoryImageData(data: data, modificationDate: modificationDate)
                if allowRemoteLoad, !isFresh(modificationDate: modificationDate) {
                    refreshInBackground(url: url, cachedURL: cachedURL)
                }
                return data
            }
            try? fileManager.removeItem(at: cachedURL)
        }

        guard allowRemoteLoad else {
            return nil
        }
        return await coalescedImageData(for: url, cachedURL: cachedURL, cachedData: nil)
    }

    private func coalescedImageData(for url: URL, cachedURL: URL, cachedData: Data?) async -> Data? {
        let (loadID, task) = startImageLoad(
            url: url,
            cachedURL: cachedURL,
            cachedData: cachedData,
            isUnownedRefresh: false
        )
        let waiterID = UUID()
        inFlightImageLoads[url]?.waiterIDs.insert(waiterID)
        let data = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task {
                await self.cancelWaiter(waiterID, for: url, loadID: loadID)
            }
        }
        removeWaiter(waiterID, for: url, loadID: loadID)
        return Task.isCancelled ? nil : data
    }

    private func startImageLoad(
        url: URL,
        cachedURL: URL,
        cachedData: Data?,
        isUnownedRefresh: Bool
    ) -> (id: UUID, task: Task<Data?, Never>) {
        if var load = inFlightImageLoads[url] {
            if !isUnownedRefresh {
                load.isUnownedRefresh = false
                inFlightImageLoads[url] = load
            }
            return (load.id, load.task)
        }

        let id = UUID()
        let epoch = cacheEpoch
        let revision = urlRevisions[url, default: 0]
        let task = Task<Data?, Never> { [weak self] in
            guard let self else {
                return nil
            }
            let data = await self.loadAndCacheImageData(
                for: url,
                cachedURL: cachedURL,
                cachedData: cachedData,
                epoch: epoch,
                revision: revision
            )
            await self.completeImageLoad(for: url, id: id)
            return data
        }
        inFlightImageLoads[url] = InFlightImageLoad(
            id: id,
            task: task,
            waiterIDs: [],
            isUnownedRefresh: isUnownedRefresh
        )
        return (id, task)
    }

    private func completeImageLoad(for url: URL, id: UUID) {
        if inFlightImageLoads[url]?.id == id {
            inFlightImageLoads[url] = nil
        }
    }

    private func refreshInBackground(url: URL, cachedURL: URL) {
        _ = startImageLoad(url: url, cachedURL: cachedURL, cachedData: nil, isUnownedRefresh: true)
    }

    private func cancelWaiter(_ waiterID: UUID, for url: URL, loadID: UUID) {
        removeWaiter(waiterID, for: url, loadID: loadID, cancelIfUnowned: true)
    }

    private func removeWaiter(
        _ waiterID: UUID,
        for url: URL,
        loadID: UUID,
        cancelIfUnowned: Bool = false
    ) {
        guard var load = inFlightImageLoads[url], load.id == loadID else {
            return
        }
        load.waiterIDs.remove(waiterID)
        if cancelIfUnowned, load.waiterIDs.isEmpty, !load.isUnownedRefresh {
            load.task.cancel()
            inFlightImageLoads[url] = nil
        } else {
            inFlightImageLoads[url] = load
        }
    }

    private func loadAndCacheImageData(
        for url: URL,
        cachedURL: URL,
        cachedData: Data?,
        epoch: Int,
        revision: Int
    ) async -> Data? {
        guard isCurrent(url: url, epoch: epoch, revision: revision) else {
            return nil
        }
        if let cachedData {
            return await rasterizeAndCacheSVG(
                cachedData,
                cachedURL: cachedURL,
                sourceURL: url,
                epoch: epoch,
                revision: revision
            )
        }

        guard let data = try? await downloadImageData(from: url), !data.isEmpty else {
            return nil
        }

        guard isCurrent(url: url, epoch: epoch, revision: revision) else {
            return nil
        }

        if isSVGData(data, from: url) {
            return await rasterizeAndCacheSVG(
                data,
                cachedURL: cachedURL,
                sourceURL: url,
                epoch: epoch,
                revision: revision
            )
        }

        guard isRasterImageData(data),
            let cacheData = normalizedRasterData(data),
            hasVisibleRasterContent(cacheData)
        else {
            ErrorReporter.report("account.icon_invalid_image")
            return nil
        }
        guard isCurrent(url: url, epoch: epoch, revision: revision) else {
            return nil
        }
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? cacheData.write(to: cachedURL, options: [.atomic])
        urlRevisions[url] = revision + 1
        memoryImageData[url] = MemoryImageData(data: cacheData, modificationDate: Date())
        return cacheData
    }

    func clear(sessionRevision: Int) {
        guard sessionRevision == self.sessionRevision else {
            return
        }
        clearCache()
    }

    func advanceSession(to revision: Int) {
        guard revision > sessionRevision else {
            return
        }
        sessionRevision = revision
        for load in inFlightImageLoads.values {
            load.task.cancel()
        }
        inFlightImageLoads.removeAll()
        cacheEpoch += 1
        allowedURLs = nil
    }

    private func clearCache() {
        for load in inFlightImageLoads.values {
            load.task.cancel()
        }
        inFlightImageLoads.removeAll()
        memoryImageData.removeAll()
        cacheEpoch += 1
        allowedURLs = nil
        urlRevisions.removeAll()
        guard fileManager.fileExists(atPath: cacheDirectory.path) else {
            return
        }
        try? fileManager.removeItem(at: cacheDirectory)
    }

    func cancelUnownedRefreshes() {
        let urls = inFlightImageLoads.compactMap { url, load in
            load.isUnownedRefresh ? url : nil
        }
        for url in urls {
            inFlightImageLoads.removeValue(forKey: url)?.task.cancel()
        }
    }

    func prune(keeping urls: Set<URL>, sessionRevision: Int) {
        guard sessionRevision == self.sessionRevision else {
            return
        }
        pruneCache(keeping: urls)
    }

    private func pruneCache(keeping urls: Set<URL>) {
        for (url, load) in inFlightImageLoads where !urls.contains(url) {
            load.task.cancel()
        }
        allowedURLs = urls
        memoryImageData = memoryImageData.filter { urls.contains($0.key) }
        urlRevisions = urlRevisions.filter { urls.contains($0.key) }

        guard let files = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        let keptFilenames = Set(urls.map(cacheFilename(for:)))
        for file in files where !keptFilenames.contains(file.lastPathComponent) {
            try? fileManager.removeItem(at: file)
        }
    }

    func cache(data: Data, for url: URL) {
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: cacheURL(for: url), options: [.atomic])
        urlRevisions[url, default: 0] += 1
    }

    func hasCachedData(for url: URL) -> Bool {
        fileManager.fileExists(atPath: cacheURL(for: url).path)
    }

    private func downloadImageData(from url: URL) async throws -> Data? {
        let (bytes, response) = try await session.bytes(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
            httpResponse.statusCode == 200,
            httpResponse.expectedContentLength <= Int64(Self.maximumDownloadBytes),
            let responseURL = httpResponse.url,
            Self.sameOrigin(responseURL, url),
            responseURL.standardized.path == url.standardized.path
        else {
            return nil
        }

        var data = Data()
        if httpResponse.expectedContentLength > 0 {
            data.reserveCapacity(Int(httpResponse.expectedContentLength))
        }
        for try await byte in bytes {
            guard data.count < Self.maximumDownloadBytes else {
                throw URLError(.dataLengthExceedsMaximum)
            }
            data.append(byte)
        }
        return data
    }

    private func isSVGData(_ data: Data, from url: URL) -> Bool {
        if isRasterImageData(data) {
            return false
        }

        if url.pathExtension.localizedLowercase == "svg" {
            return true
        }

        let prefix = String(decoding: data.prefix(256), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return prefix.hasPrefix("<svg") || prefix.hasPrefix("<?xml") && prefix.contains("<svg")
    }

    private func isRasterImageData(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47])
            || data.starts(with: [0xFF, 0xD8, 0xFF])
            || data.starts(with: [0x47, 0x49, 0x46, 0x38])
            || data.starts(with: [0x52, 0x49, 0x46, 0x46]) && data.dropFirst(8).starts(with: [0x57, 0x45, 0x42, 0x50])
    }

    private func rasterizeAndCacheSVG(
        _ data: Data,
        cachedURL: URL,
        sourceURL: URL,
        epoch: Int,
        revision: Int
    ) async -> Data? {
        await acquireRasterizationSlot()
        defer { releaseRasterizationSlot() }

        guard isCurrent(url: sourceURL, epoch: epoch, revision: revision) else {
            return nil
        }

        guard let rasterizedData = await rasterizeSVG(data), !rasterizedData.isEmpty,
            isRasterImageData(rasterizedData),
            hasVisibleRasterContent(rasterizedData)
        else {
            ErrorReporter.report("account.icon_svg_rasterize_failed")
            return nil
        }

        guard isCurrent(url: sourceURL, epoch: epoch, revision: revision) else {
            return nil
        }
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? rasterizedData.write(to: cachedURL, options: [.atomic])
        urlRevisions[sourceURL] = revision + 1
        memoryImageData[sourceURL] = MemoryImageData(data: rasterizedData, modificationDate: Date())
        return rasterizedData
    }

    private func isCurrent(url: URL, epoch: Int, revision: Int) -> Bool {
        !Task.isCancelled
            && epoch == cacheEpoch
            && revision == urlRevisions[url, default: 0]
            && isAllowed(url)
    }

    private func isAllowed(_ url: URL) -> Bool {
        allowedURLs?.contains(url) ?? true
    }

    private func acquireRasterizationSlot() async {
        guard activeRasterizationCount >= Self.maximumConcurrentRasterizations else {
            activeRasterizationCount += 1
            return
        }
        await withCheckedContinuation { continuation in
            rasterizationWaiters.append(continuation)
        }
    }

    private func releaseRasterizationSlot() {
        guard !rasterizationWaiters.isEmpty else {
            activeRasterizationCount -= 1
            return
        }
        rasterizationWaiters.removeFirst().resume()
    }

    private func hasVisibleRasterContent(_ data: Data) -> Bool {
        #if canImport(UIKit)
            guard let image = UIImage(data: data), let cgImage = image.cgImage else {
                return false
            }

            let width = cgImage.width
            let height = cgImage.height
            guard width > 0,
                height > 0,
                width <= Self.maximumRasterDimension,
                height <= Self.maximumRasterDimension,
                width <= Self.maximumRasterPixels / height
            else {
                return false
            }

            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            guard let context = CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                return false
            }

            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

            for index in stride(from: 0, to: pixels.count, by: 4) {
                if pixels[index + 3] > 0 {
                    return true
                }
            }
            return false
        #else
            return true
        #endif
    }

    private func normalizedRasterData(_ data: Data) -> Data? {
        #if canImport(UIKit)
            guard let image = UIImage(data: data), let cgImage = image.cgImage else {
                return nil
            }
            let width = cgImage.width
            let height = cgImage.height
            guard width > 0,
                height > 0,
                width <= Self.maximumRasterDimension,
                height <= Self.maximumRasterDimension,
                width <= Self.maximumRasterPixels / height
            else {
                return nil
            }
            guard width > Self.cachedRasterDimension || height > Self.cachedRasterDimension else {
                return data
            }

            let target = CGFloat(Self.cachedRasterDimension)
            let scale = min(target / CGFloat(width), target / CGFloat(height))
            let drawSize = CGSize(width: CGFloat(width) * scale, height: CGFloat(height) * scale)
            let drawOrigin = CGPoint(x: (target - drawSize.width) / 2, y: (target - drawSize.height) / 2)
            let format = UIGraphicsImageRendererFormat()
            format.opaque = false
            format.scale = 1
            return UIGraphicsImageRenderer(
                size: CGSize(width: target, height: target),
                format: format
            ).pngData { _ in
                image.draw(in: CGRect(origin: drawOrigin, size: drawSize))
            }
        #else
            return data
        #endif
    }

    private func cacheURL(for url: URL) -> URL {
        cacheDirectory.appendingPathComponent(cacheFilename(for: url), isDirectory: false)
    }

    private nonisolated static func readCachedFile(at url: URL) async -> CachedFile? {
        let task = Task.detached(priority: .userInitiated) { () -> CachedFile? in
            guard !Task.isCancelled,
                let data = try? Data(contentsOf: url, options: [.mappedIfSafe])
            else {
                return nil
            }
            guard !Task.isCancelled else {
                return nil
            }
            guard !data.isEmpty, data.count <= Self.maximumDownloadBytes else {
                return nil
            }
            let modificationDate = try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
            let isRaster = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
                || data.starts(with: [0xFF, 0xD8, 0xFF])
                || data.starts(with: [0x47, 0x49, 0x46, 0x38])
                || data.starts(with: [0x52, 0x49, 0x46, 0x46])
                    && data.dropFirst(8).starts(with: [0x57, 0x45, 0x42, 0x50])
            let source = isRaster ? CGImageSourceCreateWithData(data as CFData, nil) : nil
            let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) }
            let values = properties as? [CFString: Any]
            let width = (values?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let height = (values?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            let hasValidRasterMetadata = source.map {
                CGImageSourceGetStatusAtIndex($0, 0) == .statusComplete
            } == true
                && width > 0
                && height > 0
                && width <= Self.maximumRasterDimension
                && height <= Self.maximumRasterDimension
                && width <= Self.maximumRasterPixels / height
            return CachedFile(
                data: data,
                modificationDate: modificationDate,
                hasValidRasterMetadata: hasValidRasterMetadata
            )
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func isFresh(modificationDate: Date) -> Bool {
        return Date().timeIntervalSince(modificationDate) <= Self.maximumCacheAge
    }

    private func cacheFilename(for url: URL) -> String {
        SHA256.hash(data: Data("\(Self.cacheVersion)|\(url.absoluteString)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func isSafeFilename(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
    }

    private static func isDirectChild(_ url: URL, of directory: URL) -> Bool {
        let parentPath = directory.standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let candidatePath = url.standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard candidatePath.hasPrefix(parentPath + "/") else {
            return false
        }
        return !candidatePath.dropFirst(parentPath.count + 1).contains("/")
    }

    private static func hasUnsafeEncodedPathSegment(_ url: URL) -> Bool {
        guard let percentEncodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath else {
            return true
        }
        return percentEncodedPath.split(separator: "/").contains { segment in
            guard let decoded = String(segment).removingPercentEncoding else {
                return true
            }
            return decoded == "." || decoded == ".." || decoded.contains("\\")
        }
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port {
            return port
        }
        switch url.scheme?.lowercased() {
        case "http":
            return 80
        case "https":
            return 443
        default:
            return nil
        }
    }

    private static func makeSession() -> URLSession {
        URLSession(
            configuration: .ephemeral,
            delegate: AccountIconURLSessionDelegate(),
            delegateQueue: nil
        )
    }

    static func defaultRasterizeSVG(_ data: Data) async -> Data? {
        #if canImport(UIKit) && canImport(WebKit)
            return await SVGIconRasterizer().rasterize(data)
        #else
            return nil
        #endif
    }
}

private final class AccountIconURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

#if canImport(UIKit) && canImport(WebKit)
    @MainActor
    private final class SVGIconRasterizer: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
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

        nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
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
            guard let window = UIApplication.shared.connectedScenes
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
