import Foundation

struct AccountIconCachePolicy: Sendable {
    let maximumSourceBytes: Int
    let maximumSourceDimension: Int
    let maximumSourcePixels: Int
    let normalizedDimension: Int
    let maximumMemoryBytes: Int
    let maximumDiskBytes: Int
    let maximumDiskFileCount: Int
    let maximumConcurrentDownloads: Int
    let maximumConcurrentRasterizations: Int

    static let production = AccountIconCachePolicy(
        maximumSourceBytes: 2 * 1_024 * 1_024,
        maximumSourceDimension: 2_048,
        maximumSourcePixels: 4_194_304,
        normalizedDimension: 128,
        maximumMemoryBytes: 16 * 1_024 * 1_024,
        maximumDiskBytes: 32 * 1_024 * 1_024,
        maximumDiskFileCount: 256,
        maximumConcurrentDownloads: 4,
        maximumConcurrentRasterizations: 4
    )
}

struct AccountIconCacheResourceAdmissionState: Sendable {
    let activeDownloads: Int
    let queuedDownloads: Int
    let activeRasterizations: Int
    let queuedRasterizations: Int
}

final class AccountIconUpdateDelivery {
    let continuation: AsyncStream<Data>.Continuation
    private let allowsRemoteUpdates: Bool
    private var latestData: Data?
    private var pendingData: Data?
    private var didPublishInitial = false

    private init(
        continuation: AsyncStream<Data>.Continuation,
        allowsRemoteUpdates: Bool
    ) {
        self.continuation = continuation
        self.allowsRemoteUpdates = allowsRemoteUpdates
    }

    static func make(allowsRemoteUpdates: Bool) -> (AsyncStream<Data>, AccountIconUpdateDelivery) {
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(2))
        return (
            stream,
            AccountIconUpdateDelivery(
                continuation: continuation,
                allowsRemoteUpdates: allowsRemoteUpdates
            )
        )
    }

    func publishInitial(_ data: Data?) {
        didPublishInitial = true
        if let data {
            latestData = data
            continuation.yield(data)
        }
        if let pendingData, pendingData != latestData {
            latestData = pendingData
            continuation.yield(pendingData)
        }
        pendingData = nil
    }

    func publishReplacement(_ data: Data) {
        guard allowsRemoteUpdates else {
            return
        }
        if didPublishInitial {
            guard latestData != data else {
                return
            }
            latestData = data
            continuation.yield(data)
        } else if pendingData != data {
            pendingData = data
        }
    }

    func finish() {
        continuation.finish()
    }
}

actor AccountIconCache {
    private struct InFlightImageLoad {
        let id: UUID
        let task: Task<Data?, Never>
        var waiterIDs: Set<UUID>
        var isUnownedRefresh: Bool
    }

    private struct MemoryImageData {
        let data: Data
        let modificationDate: Date
        var accessOrder: UInt64
    }

    private struct ImageUpdateObserver {
        let delivery: AccountIconUpdateDelivery
        var initialLoadTask: Task<Void, Never>?
    }

    private struct SlotWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private enum SlotKind: Sendable {
        case download
        case rasterization
    }

    static let shared = AccountIconCache()

    private static let maximumCacheAge: TimeInterval = 7 * 24 * 60 * 60
    typealias SVGRasterizer = @Sendable (Data) async -> Data?

    private let downloader: AccountIconDownloader
    private let diskStore: AccountIconDiskStore
    private let rasterProcessor: AccountIconRasterProcessor
    private let rasterizeSVG: SVGRasterizer
    private let policy: AccountIconCachePolicy
    private var inFlightImageLoads: [URL: InFlightImageLoad] = [:]
    private var imageUpdateObservers: [URL: [UUID: ImageUpdateObserver]] = [:]
    private var memoryImageData: [URL: MemoryImageData] = [:]
    private var memoryByteCount = 0
    private var memoryAccessOrder: UInt64 = 0
    private var cacheEpoch = 0
    private var sessionRevision = 0
    private var allowedURLs: Set<URL>?
    private var urlRevisions: [URL: Int] = [:]
    private var activeDownloadCount = 0
    private var downloadWaiters: [SlotWaiter] = []
    private var activeRasterizationCount = 0
    private var rasterizationWaiters: [SlotWaiter] = []

    init(
        session: URLSession? = nil,
        fileManager: FileManager = .default,
        cacheDirectory: URL? = nil,
        rasterizeSVG: @escaping SVGRasterizer = AccountIconCache.defaultRasterizeSVG,
        policy: AccountIconCachePolicy = .production
    ) {
        self.rasterizeSVG = rasterizeSVG
        self.policy = policy
        let cacheDirectory = cacheDirectory ?? Self.defaultCacheDirectory(fileManager: fileManager)
        self.downloader = AccountIconDownloader(
            session: session,
            maximumSourceBytes: policy.maximumSourceBytes
        )
        self.diskStore = AccountIconDiskStore(
            fileManager: fileManager,
            cacheDirectory: cacheDirectory,
            policy: policy
        )
        self.rasterProcessor = AccountIconRasterProcessor(policy: policy)
    }

    static func defaultCacheDirectory(fileManager: FileManager) -> URL {
        AccountIconDiskStore.defaultCacheDirectory(fileManager: fileManager)
    }

    static func removePersistentData(fileManager: FileManager, cacheDirectory: URL) throws {
        try AccountIconDiskStore.removePersistentData(
            fileManager: fileManager,
            cacheDirectory: cacheDirectory
        )
    }

    static func iconURL(baseURL: URL, iconFilename: String?) -> URL? {
        AccountIconURLResolver.iconURL(baseURL: baseURL, iconFilename: iconFilename)
    }

    func imageData(for url: URL, allowRemoteLoad: Bool = true) async -> Data? {
        if let entry = memoryEntry(for: url) {
            if allowRemoteLoad,
                !isFresh(modificationDate: entry.modificationDate),
                inFlightImageLoads[url] == nil
            {
                refreshInBackground(url: url, cachedURL: diskStore.cacheURL(for: url))
            }
            return entry.data
        }

        let cachedURL = diskStore.cacheURL(for: url)
        let epoch = cacheEpoch
        let revision = urlRevisions[url, default: 0]
        let cachedFile = await AccountIconDiskStore.readCachedFile(
            at: cachedURL,
            policy: policy,
            rasterProcessor: rasterProcessor
        )
        guard !Task.isCancelled, epoch == cacheEpoch, isAllowed(url)
        else {
            return nil
        }
        guard revision == urlRevisions[url, default: 0] else {
            return memoryEntry(for: url)?.data
        }

        if let cachedFile,
            !cachedFile.data.isEmpty,
            cachedFile.data.count <= policy.maximumSourceBytes
        {
            let data = cachedFile.data
            if rasterProcessor.isSVGData(data, from: url) {
                guard allowRemoteLoad else {
                    return nil
                }
                return await coalescedImageData(for: url, cachedURL: cachedURL, cachedData: data)
            }
            if rasterProcessor.isRasterImageData(data), cachedFile.hasValidRasterMetadata,
                let normalizedData = rasterProcessor.normalizedRasterData(data),
                rasterProcessor.hasVisibleRasterContent(normalizedData)
            {
                let modificationDate = cachedFile.modificationDate ?? .distantPast
                if normalizedData != data {
                    diskStore.replaceNormalizedFile(normalizedData, at: cachedURL, modificationDate: modificationDate)
                    diskStore.trim(allowedURLs: allowedURLs)
                }
                storeInMemory(normalizedData, for: url, modificationDate: modificationDate)
                if allowRemoteLoad, !isFresh(modificationDate: modificationDate) {
                    refreshInBackground(url: url, cachedURL: cachedURL)
                }
                return normalizedData
            }
            diskStore.removeFile(at: cachedURL)
        }

        guard allowRemoteLoad else {
            return nil
        }
        return await coalescedImageData(for: url, cachedURL: cachedURL, cachedData: nil)
    }

    func imageUpdates(for url: URL, allowRemoteLoad: Bool = true) -> AsyncStream<Data> {
        let observerID = UUID()
        let (stream, delivery) = AccountIconUpdateDelivery.make(allowsRemoteUpdates: allowRemoteLoad)
        delivery.continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeImageUpdateObserver(observerID, for: url)
            }
        }
        imageUpdateObservers[url, default: [:]][observerID] = ImageUpdateObserver(
            delivery: delivery
        )
        let continuation = delivery.continuation
        let initialLoadTask = Task { [weak self] in
            guard let self else {
                continuation.finish()
                return
            }
            let data = await self.imageData(for: url, allowRemoteLoad: allowRemoteLoad)
            await self.publishInitialImageData(data, to: observerID, for: url)
        }
        imageUpdateObservers[url]?[observerID]?.initialLoadTask = initialLoadTask
        return stream
    }

    private func publishInitialImageData(_ data: Data?, to observerID: UUID, for url: URL) {
        guard var observer = imageUpdateObservers[url]?[observerID] else {
            return
        }
        observer.initialLoadTask = nil
        observer.delivery.publishInitial(data)
        imageUpdateObservers[url]?[observerID] = observer
    }

    private func publishReplacementImageData(_ data: Data, for url: URL) {
        guard let observers = imageUpdateObservers[url] else {
            return
        }
        for observer in observers.values {
            observer.delivery.publishReplacement(data)
        }
    }

    private func removeImageUpdateObserver(_ observerID: UUID, for url: URL) {
        guard let observer = imageUpdateObservers[url]?.removeValue(forKey: observerID) else {
            return
        }
        observer.initialLoadTask?.cancel()
        if imageUpdateObservers[url]?.isEmpty == true {
            imageUpdateObservers[url] = nil
        }
    }

    private func finishImageUpdateObservers(for urls: Set<URL>? = nil) {
        let finishedURLs = urls ?? Set(imageUpdateObservers.keys)
        for url in finishedURLs {
            guard let observers = imageUpdateObservers.removeValue(forKey: url) else {
                continue
            }
            for observer in observers.values {
                observer.initialLoadTask?.cancel()
                observer.delivery.finish()
            }
        }
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

        if rasterProcessor.isSVGData(data, from: url) {
            return await rasterizeAndCacheSVG(
                data,
                cachedURL: cachedURL,
                sourceURL: url,
                epoch: epoch,
                revision: revision
            )
        }

        guard rasterProcessor.isRasterImageData(data),
            let cacheData = rasterProcessor.normalizedRasterData(data),
            rasterProcessor.hasVisibleRasterContent(cacheData)
        else {
            ErrorReporter.report("account.icon_invalid_image")
            return nil
        }
        guard isCurrent(url: url, epoch: epoch, revision: revision) else {
            return nil
        }
        diskStore.write(cacheData, to: cachedURL)
        diskStore.trim(allowedURLs: allowedURLs)
        urlRevisions[url] = revision + 1
        storeInMemory(cacheData, for: url, modificationDate: Date())
        publishReplacementImageData(cacheData, for: url)
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
        finishImageUpdateObservers()
        cacheEpoch += 1
        allowedURLs = nil
    }

    private func clearCache() {
        for load in inFlightImageLoads.values {
            load.task.cancel()
        }
        inFlightImageLoads.removeAll()
        finishImageUpdateObservers()
        memoryImageData.removeAll()
        memoryByteCount = 0
        cacheEpoch += 1
        allowedURLs = nil
        urlRevisions.removeAll()
        diskStore.removePersistentData()
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
        finishImageUpdateObservers(for: Set(imageUpdateObservers.keys).subtracting(urls))
        for (url, load) in inFlightImageLoads where !urls.contains(url) {
            load.task.cancel()
        }
        allowedURLs = urls
        memoryImageData = memoryImageData.filter { urls.contains($0.key) }
        memoryByteCount = memoryImageData.values.reduce(0) { $0 + $1.data.count }
        urlRevisions = urlRevisions.filter { urls.contains($0.key) }

        diskStore.prune(keeping: urls)
    }

    func cache(data: Data, for url: URL) {
        diskStore.write(data, to: diskStore.cacheURL(for: url))
        urlRevisions[url, default: 0] += 1
        publishReplacementImageData(data, for: url)
    }

    func hasCachedData(for url: URL) -> Bool {
        diskStore.hasCachedData(for: url)
    }

    func resourceAdmissionState() -> AccountIconCacheResourceAdmissionState {
        AccountIconCacheResourceAdmissionState(
            activeDownloads: activeDownloadCount,
            queuedDownloads: downloadWaiters.count,
            activeRasterizations: activeRasterizationCount,
            queuedRasterizations: rasterizationWaiters.count
        )
    }

    private func downloadImageData(from url: URL) async throws -> Data? {
        guard await acquireSlot(.download) else {
            throw CancellationError()
        }
        defer { releaseSlot(.download) }
        guard !Task.isCancelled else {
            throw CancellationError()
        }
        return try await downloader.downloadImageData(from: url)
    }

    private func rasterizeAndCacheSVG(
        _ data: Data,
        cachedURL: URL,
        sourceURL: URL,
        epoch: Int,
        revision: Int
    ) async -> Data? {
        guard await acquireSlot(.rasterization) else {
            return nil
        }
        defer { releaseSlot(.rasterization) }

        guard isCurrent(url: sourceURL, epoch: epoch, revision: revision) else {
            return nil
        }

        guard let rasterizedData = await rasterizeSVG(data), !rasterizedData.isEmpty,
            rasterProcessor.isRasterImageData(rasterizedData),
            let normalizedData = rasterProcessor.normalizedRasterData(rasterizedData),
            rasterProcessor.hasVisibleRasterContent(normalizedData)
        else {
            ErrorReporter.report("account.icon_svg_rasterize_failed")
            return nil
        }

        guard isCurrent(url: sourceURL, epoch: epoch, revision: revision) else {
            return nil
        }
        diskStore.write(normalizedData, to: cachedURL)
        diskStore.trim(allowedURLs: allowedURLs)
        urlRevisions[sourceURL] = revision + 1
        storeInMemory(normalizedData, for: sourceURL, modificationDate: Date())
        publishReplacementImageData(normalizedData, for: sourceURL)
        return normalizedData
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

    private func acquireSlot(_ kind: SlotKind) async -> Bool {
        guard !Task.isCancelled else {
            return false
        }
        let waiterID = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                if activeSlotCount(for: kind) < maximumSlotCount(for: kind) {
                    incrementActiveSlotCount(for: kind)
                    continuation.resume(returning: true)
                } else {
                    appendSlotWaiter(SlotWaiter(id: waiterID, continuation: continuation), for: kind)
                }
            }
        } onCancel: {
            Task {
                await self.cancelSlotWaiter(waiterID, for: kind)
            }
        }
        guard acquired, !Task.isCancelled else {
            if acquired {
                releaseSlot(kind)
            }
            return false
        }
        return true
    }

    private func cancelSlotWaiter(_ id: UUID, for kind: SlotKind) {
        guard let index = slotWaiters(for: kind).firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = removeSlotWaiter(at: index, for: kind)
        waiter.continuation.resume(returning: false)
    }

    private func releaseSlot(_ kind: SlotKind) {
        if let waiter = popFirstSlotWaiter(for: kind) {
            waiter.continuation.resume(returning: true)
        } else {
            decrementActiveSlotCount(for: kind)
        }
    }

    private func activeSlotCount(for kind: SlotKind) -> Int {
        switch kind {
        case .download: activeDownloadCount
        case .rasterization: activeRasterizationCount
        }
    }

    private func maximumSlotCount(for kind: SlotKind) -> Int {
        switch kind {
        case .download: policy.maximumConcurrentDownloads
        case .rasterization: policy.maximumConcurrentRasterizations
        }
    }

    private func incrementActiveSlotCount(for kind: SlotKind) {
        switch kind {
        case .download: activeDownloadCount += 1
        case .rasterization: activeRasterizationCount += 1
        }
    }

    private func decrementActiveSlotCount(for kind: SlotKind) {
        switch kind {
        case .download: activeDownloadCount -= 1
        case .rasterization: activeRasterizationCount -= 1
        }
    }

    private func slotWaiters(for kind: SlotKind) -> [SlotWaiter] {
        switch kind {
        case .download: downloadWaiters
        case .rasterization: rasterizationWaiters
        }
    }

    private func appendSlotWaiter(_ waiter: SlotWaiter, for kind: SlotKind) {
        switch kind {
        case .download: downloadWaiters.append(waiter)
        case .rasterization: rasterizationWaiters.append(waiter)
        }
    }

    private func removeSlotWaiter(at index: Int, for kind: SlotKind) -> SlotWaiter {
        switch kind {
        case .download: downloadWaiters.remove(at: index)
        case .rasterization: rasterizationWaiters.remove(at: index)
        }
    }

    private func popFirstSlotWaiter(for kind: SlotKind) -> SlotWaiter? {
        guard !slotWaiters(for: kind).isEmpty else {
            return nil
        }
        return removeSlotWaiter(at: 0, for: kind)
    }

    private func memoryEntry(for url: URL) -> MemoryImageData? {
        guard var entry = memoryImageData[url] else {
            return nil
        }
        memoryAccessOrder &+= 1
        entry.accessOrder = memoryAccessOrder
        memoryImageData[url] = entry
        return entry
    }

    private func storeInMemory(_ data: Data, for url: URL, modificationDate: Date) {
        if let existing = memoryImageData.removeValue(forKey: url) {
            memoryByteCount -= existing.data.count
        }
        memoryAccessOrder &+= 1
        memoryImageData[url] = MemoryImageData(
            data: data,
            modificationDate: modificationDate,
            accessOrder: memoryAccessOrder
        )
        memoryByteCount += data.count

        while memoryByteCount > policy.maximumMemoryBytes,
            let leastRecentlyUsed = memoryImageData.min(by: { $0.value.accessOrder < $1.value.accessOrder })
        {
            memoryImageData.removeValue(forKey: leastRecentlyUsed.key)
            memoryByteCount -= leastRecentlyUsed.value.data.count
        }
    }

    private func isFresh(modificationDate: Date) -> Bool {
        return Date().timeIntervalSince(modificationDate) <= Self.maximumCacheAge
    }

    static func defaultRasterizeSVG(_ data: Data) async -> Data? {
        #if canImport(UIKit) && canImport(WebKit)
            return await SVGIconRasterizer().rasterize(data)
        #else
            return nil
        #endif
    }
}
