import Foundation
import SDWebImage

struct CacheFootprint: Sendable, Equatable {
    let coversAndEmoticons: Int64
    let metadata: Int64
    let downloadTemporaryFiles: Int64
    let completedDownloads: Int64

    var rebuildableBytes: Int64 { coversAndEmoticons + metadata }
    var totalBytes: Int64 { rebuildableBytes + downloadTemporaryFiles + completedDownloads }
}

final class ImageCacheService: @unchecked Sendable {
    static let shared: ImageCacheService = {
        let cacheBase = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        let storage = try? AppStoragePaths.production()
        let appID = Bundle.main.bundleIdentifier ?? "IINA-ANI"
        let appCache = cacheBase.appendingPathComponent(appID, isDirectory: true)
        return ImageCacheService(
            coverAndEmoticonRoot: appCache.appendingPathComponent("SDWebImage", isDirectory: true).appendingPathComponent("default", isDirectory: true),
            metadataRoot: appCache.appendingPathComponent("MetadataCache", isDirectory: true),
            downloadTemporaryDirectory: storage?.downloadTemporaryDirectory,
            completedDownloadsDirectory: storage?.completedDownloadsDirectory
        )
    }()

    let coverAndEmoticonRoot: URL
    let metadataRoot: URL
    let downloadTemporaryDirectory: URL?
    let completedDownloadsDirectory: URL?
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let limitKey = "rebuildableCacheUpperLimitBytes"

    init(coverAndEmoticonRoot: URL, metadataRoot: URL, downloadTemporaryDirectory: URL?, completedDownloadsDirectory: URL?, defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.coverAndEmoticonRoot = coverAndEmoticonRoot.standardizedFileURL
        self.metadataRoot = metadataRoot.standardizedFileURL
        self.downloadTemporaryDirectory = downloadTemporaryDirectory?.standardizedFileURL
        self.completedDownloadsDirectory = completedDownloadsDirectory?.standardizedFileURL
        self.defaults = defaults
        self.fileManager = fileManager
    }
    /// Persist only public artwork URLs, never query credentials or account context.
    static func publicCoverURL(_ value: String?) -> String? {
        guard let value, var parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil else { return nil }
        parts.query = nil
        parts.fragment = nil
        return parts.string
    }

    /// Download admission owns this work; closing a view must not cancel the cache fill.
    @MainActor static func cacheDownloadCover(_ value: String?) async {
        guard !Task.isCancelled, let value = publicCoverURL(value), let url = URL(string: value) else { return }
        let request = DownloadCoverCacheRequest()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                request.start(url, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor in request.cancel() }
        }
    }

    var maximumRebuildableBytes: Int64 {
        get {
            let stored = defaults.object(forKey: limitKey) as? Int64 ?? (512 * 1_024 * 1_024)
            return max(0, stored)
        }
        set { defaults.set(max(0, newValue), forKey: limitKey) }
    }

    func footprint() -> CacheFootprint {
        CacheFootprint(
            coversAndEmoticons: size(of: coverAndEmoticonRoot),
            metadata: size(of: metadataRoot),
            downloadTemporaryFiles: downloadTemporaryDirectory.map { size(of: $0) } ?? 0,
            completedDownloads: completedDownloadsDirectory.map { size(of: $0) } ?? 0
        )
    }

    func clearRebuildableCache() throws {
        try validateCleanupRoots()
        try clearContents(of: coverAndEmoticonRoot)
        try clearContents(of: metadataRoot)
    }

    @discardableResult
    func evictRebuildableCacheToLimit() throws -> CacheFootprint {
        try validateCleanupRoots()
        let limit = maximumRebuildableBytes
        var files = filesInRebuildableRoots()
        var total = files.reduce(Int64(0)) { $0 + $1.bytes }
        guard total > limit else { return footprint() }
        files.sort { $0.modified < $1.modified }
        for file in files where total > limit {
            try fileManager.removeItem(at: file.url)
            total -= file.bytes
        }
        return footprint()
    }

    /// Refuse ambiguous ownership before removing any files, including through path aliases.
    private func validateCleanupRoots() throws {
        let protected = [downloadTemporaryDirectory, completedDownloadsDirectory].compactMap {
            $0?.resolvingSymlinksInPath().pathComponents
        }
        for root in [coverAndEmoticonRoot, metadataRoot] {
            let components = root.resolvingSymlinksInPath().pathComponents
            for path in protected where components.starts(with: path) || path.starts(with: components) {
                throw CocoaError(.fileWriteNoPermission)
            }
        }
    }

    private struct FileEntry {
        let url: URL
        let bytes: Int64
        let modified: Date
    }

    private func filesInRebuildableRoots() -> [FileEntry] {
        [coverAndEmoticonRoot, metadataRoot].flatMap { root in
            guard isRealDirectory(root),
                  let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsPackageDescendants]) else { return [FileEntry]() }
            var result: [FileEntry] = []
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
                      values.isSymbolicLink != true,
                      values.isRegularFile == true else { continue }
                result.append(FileEntry(url: url, bytes: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast))
            }
            return result
        }
    }

    private func size(of root: URL) -> Int64 {
        guard isRealDirectory(root),
              let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsPackageDescendants]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private func clearContents(of root: URL) throws {
        guard isRealDirectory(root) else { return }
        for child in try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) {
            // Removing a symlink removes the link, never its target.
            try fileManager.removeItem(at: child)
        }
    }

    private func isRealDirectory(_ url: URL) -> Bool {
        guard (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == nil else { return false }
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

@MainActor
private final class DownloadCoverCacheRequest {
    private var operation: SDWebImageCombinedOperation?
    private var continuation: CheckedContinuation<Void, Never>?

    func start(_ url: URL, continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
        guard !Task.isCancelled else { finish(); return }
        operation = SDWebImageManager.shared.loadImage(with: url, options: [.waitStoreCache], progress: nil) { [weak self] _, _, _, _, finished, _ in
            MainActor.assumeIsolated {
                if finished { self?.finish() }
            }
        }
    }

    func cancel() {
        operation?.cancel()
        finish()
    }

    private func finish() {
        operation = nil
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}
