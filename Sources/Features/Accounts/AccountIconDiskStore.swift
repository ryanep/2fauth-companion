import Foundation

struct AccountIconCachedFile: Sendable {
    let data: Data
    let modificationDate: Date?
    let hasValidRasterMetadata: Bool
}

struct AccountIconDiskStore {
    private struct DiskFile {
        let url: URL
        let byteCount: Int?
        let modificationDate: Date
        let isAllowed: Bool
    }

    let fileManager: FileManager
    let cacheDirectory: URL
    let policy: AccountIconCachePolicy

    static func defaultCacheDirectory(fileManager: FileManager) -> URL {
        let baseDirectory =
            (try? fileManager.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? fileManager.temporaryDirectory
        return baseDirectory.appendingPathComponent("AccountIcons", isDirectory: true)
    }

    static func removePersistentData(fileManager: FileManager, cacheDirectory: URL) throws {
        guard fileManager.fileExists(atPath: cacheDirectory.path) else {
            return
        }
        try fileManager.removeItem(at: cacheDirectory)
    }

    func cacheURL(for url: URL) -> URL {
        AccountIconURLResolver.cacheURL(for: url, in: cacheDirectory)
    }

    static func readCachedFile(
        at url: URL,
        policy: AccountIconCachePolicy,
        rasterProcessor: AccountIconRasterProcessor
    ) async -> AccountIconCachedFile? {
        let maximumSourceBytes = policy.maximumSourceBytes
        let task = Task.detached(priority: .userInitiated) { () -> AccountIconCachedFile? in
            guard !Task.isCancelled,
                let data = try? Data(contentsOf: url, options: [.mappedIfSafe])
            else {
                return nil
            }
            guard !Task.isCancelled else {
                return nil
            }
            guard !data.isEmpty, data.count <= maximumSourceBytes else {
                return nil
            }
            let modificationDate = try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
            return AccountIconCachedFile(
                data: data,
                modificationDate: modificationDate,
                hasValidRasterMetadata: rasterProcessor.hasValidRasterMetadata(data)
            )
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func write(_ data: Data, to url: URL) {
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
    }

    func replaceNormalizedFile(_ data: Data, at url: URL, modificationDate: Date) {
        try? data.write(to: url, options: [.atomic])
        try? fileManager.setAttributes(
            [.modificationDate: modificationDate],
            ofItemAtPath: url.path
        )
    }

    func removeFile(at url: URL) {
        try? fileManager.removeItem(at: url)
    }

    func removePersistentData() {
        try? Self.removePersistentData(fileManager: fileManager, cacheDirectory: cacheDirectory)
    }

    func hasCachedData(for url: URL) -> Bool {
        fileManager.fileExists(atPath: cacheURL(for: url).path)
    }

    func prune(keeping urls: Set<URL>) {
        guard
            let files = try? fileManager.contentsOfDirectory(
                at: cacheDirectory,
                includingPropertiesForKeys: nil
            )
        else {
            return
        }

        let keptFilenames = Set(urls.map(AccountIconURLResolver.cacheFilename(for:)))
        for file in files where !keptFilenames.contains(file.lastPathComponent) {
            try? fileManager.removeItem(at: file)
        }
    }

    func trim(allowedURLs: Set<URL>?) {
        guard
            let files = try? fileManager.contentsOfDirectory(
                at: cacheDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                options: []
            )
        else {
            return
        }
        let allowedFilenames = allowedURLs.map { Set($0.map(AccountIconURLResolver.cacheFilename(for:))) }
        var diskFiles = files.map { url -> DiskFile in
            let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
            )
            return DiskFile(
                url: url,
                byteCount: values?.isRegularFile == true ? values?.fileSize : nil,
                modificationDate: values?.contentModificationDate ?? .distantPast,
                isAllowed: allowedFilenames?.contains(url.lastPathComponent) ?? true
            )
        }
        var fileCount = diskFiles.count
        var unknownSizeCount = diskFiles.count(where: { $0.byteCount == nil })
        var totalBytes = diskFiles.reduce(0) { $0 + ($1.byteCount ?? 0) }
        guard
            unknownSizeCount > 0
                || fileCount > policy.maximumDiskFileCount
                || totalBytes > policy.maximumDiskBytes
        else {
            return
        }
        diskFiles.sort {
            if $0.isAllowed != $1.isAllowed {
                return !$0.isAllowed
            }
            return $0.modificationDate < $1.modificationDate
        }
        for file in diskFiles
        where unknownSizeCount > 0
            || fileCount > policy.maximumDiskFileCount
            || totalBytes > policy.maximumDiskBytes
        {
            do {
                try fileManager.removeItem(at: file.url)
                fileCount -= 1
                if let byteCount = file.byteCount {
                    totalBytes -= byteCount
                } else {
                    unknownSizeCount -= 1
                }
            } catch {
                continue
            }
        }
    }
}
