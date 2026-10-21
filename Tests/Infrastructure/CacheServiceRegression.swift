import Foundation
@testable import IINA_ANI

@main
enum CacheServiceRegression {
    static func main() throws {
        try require(ImageCacheService.publicCoverURL("https://images.example/cover.jpg?token=private#fragment") == "https://images.example/cover.jpg", "download artwork metadata must not persist query credentials")
        for address in ["https://user:password@images.example/cover.jpg", "file:///tmp/cover.jpg", "data:image/png;base64,AAAA", "https:///cover.jpg", ""] {
            try require(ImageCacheService.publicCoverURL(address) == nil, "non-public artwork must not be cached: \(address)")
        }
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("iina-cache-regression-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let covers = root.appendingPathComponent("covers", isDirectory: true)
        let metadata = root.appendingPathComponent("metadata", isDirectory: true)
        let temporary = root.appendingPathComponent("temporary", isDirectory: true)
        let completed = root.appendingPathComponent("completed", isDirectory: true)
        for directory in [covers, metadata, temporary, completed] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let outside = root.appendingPathComponent("outside.bin")
        try Data(repeating: 7, count: 11).write(to: outside)
        try Data(repeating: 1, count: 5).write(to: covers.appendingPathComponent("old-cover"))
        try Data(repeating: 2, count: 7).write(to: metadata.appendingPathComponent("record"))
        try Data(repeating: 3, count: 13).write(to: temporary.appendingPathComponent("active-part"))
        try Data(repeating: 4, count: 17).write(to: completed.appendingPathComponent("finished-video"))
        try fileManager.createSymbolicLink(at: covers.appendingPathComponent("external-link"), withDestinationURL: outside)

        let suite = "iina-cache-regression.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw RegressionError.assertion("isolated defaults unavailable") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = ImageCacheService(
            coverAndEmoticonRoot: covers,
            metadataRoot: metadata,
            downloadTemporaryDirectory: temporary,
            completedDownloadsDirectory: completed,
            defaults: defaults
        )
        let before = service.footprint()
        try require(before.coversAndEmoticons == 5, "cover tree size must exclude symlink targets")
        try require(before.metadata == 7 && before.downloadTemporaryFiles == 13 && before.completedDownloads == 17, "cache categories must be measured separately")

        service.maximumRebuildableBytes = 7
        let reopened = ImageCacheService(
            coverAndEmoticonRoot: covers,
            metadataRoot: metadata,
            downloadTemporaryDirectory: temporary,
            completedDownloadsDirectory: completed,
            defaults: UserDefaults(suiteName: suite)!
        )
        try require(reopened.maximumRebuildableBytes == 7, "cache upper limit must persist across service instances")
        _ = try reopened.evictRebuildableCacheToLimit()
        let afterEviction = reopened.footprint()
        try require(afterEviction.rebuildableBytes <= 7, "eviction must enforce the rebuildable cache limit")
        try require(afterEviction.downloadTemporaryFiles == 13 && afterEviction.completedDownloads == 17, "eviction must not touch download files")
        let afterEvictionOutside = try Data(contentsOf: outside)
        try require(afterEvictionOutside.count == 11, "eviction must not follow a cache symlink")

        try Data(repeating: 5, count: 3).write(to: covers.appendingPathComponent("new-cover"))
        try reopened.clearRebuildableCache()
        let afterClear = reopened.footprint()
        try require(afterClear.rebuildableBytes == 0, "clear must empty both owned rebuildable roots")
        try require(afterClear.downloadTemporaryFiles == 13 && afterClear.completedDownloads == 17, "clear must preserve active and completed downloads")
        let afterClearOutside = try Data(contentsOf: outside)
        try require(afterClearOutside.count == 11, "clear must unlink symlinks without deleting their targets")
        let protected = root.appendingPathComponent("protected", isDirectory: true)
        try fileManager.createDirectory(at: protected, withIntermediateDirectories: true)
        let protectedFile = protected.appendingPathComponent("keep")
        try Data(repeating: 6, count: 9).write(to: protectedFile)
        let redirectedRoot = root.appendingPathComponent("redirected-cache", isDirectory: true)
        try fileManager.createSymbolicLink(at: redirectedRoot, withDestinationURL: protected)
        let redirectedService = ImageCacheService(
            coverAndEmoticonRoot: redirectedRoot,
            metadataRoot: root.appendingPathComponent("missing-metadata", isDirectory: true),
            downloadTemporaryDirectory: temporary,
            completedDownloadsDirectory: completed,
            defaults: defaults
        )
        try redirectedService.clearRebuildableCache()
        try require(fileManager.fileExists(atPath: protectedFile.path), "clear must reject symlinked owned roots")
        let nestedDownloads = metadata.appendingPathComponent("downloads", isDirectory: true)
        try fileManager.createDirectory(at: nestedDownloads, withIntermediateDirectories: true)
        let nestedFile = nestedDownloads.appendingPathComponent("finished-video")
        let payload = Data(repeating: 8, count: 19)
        try payload.write(to: nestedFile)
        let retainedCover = covers.appendingPathComponent("keep-on-refusal")
        try payload.write(to: retainedCover)
        let overlapping = ImageCacheService(
            coverAndEmoticonRoot: covers, metadataRoot: metadata,
            downloadTemporaryDirectory: temporary, completedDownloadsDirectory: nestedDownloads,
            defaults: defaults
        )
        overlapping.maximumRebuildableBytes = 0
        do {
            _ = try overlapping.evictRebuildableCacheToLimit()
            throw RegressionError.assertion("eviction must refuse cache/download root overlap")
        } catch CocoaError.fileWriteNoPermission {}
        do {
            try overlapping.clearRebuildableCache()
            throw RegressionError.assertion("clear must refuse cache/download root overlap")
        } catch CocoaError.fileWriteNoPermission {}
        let preserved = try Data(contentsOf: nestedFile)
        try require(preserved == payload, "refused cleanup must preserve nested download bytes")
        let retained = try Data(contentsOf: retainedCover)
        try require(retained == payload, "ownership validation must precede mutation of either cache root")
        print("Cache service filesystem regressions passed")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw RegressionError.assertion(message) }
    }

    private enum RegressionError: Error {
        case assertion(String)
    }
}
