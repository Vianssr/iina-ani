import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Rebuildable public artwork, isolated from the authoritative library and catalog cache.
/// Stores downsampled JPEGs: at most 64 MiB / 256 files on disk and 12 MiB / 64 in memory.
actor MobileCoverCache {
    static let shared = MobileCoverCache()
    private let diskLimit = 64 * 1_024 * 1_024
    private let memoryLimit = 12 * 1_024 * 1_024
    private let maximumDownload = 8 * 1_024 * 1_024
    private let directory: URL?
    private let session: URLSession
    private var prepared = false
    private var memory: [String: Entry] = [:]
    private var memoryBytes = 0
    private var clock: UInt64 = 0

    private struct Entry {
        let data: Data
        var accessed: UInt64
    }

    init() {
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "ANI", isDirectory: true)
            .appendingPathComponent("MobileCovers", isDirectory: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration)
    }

    func data(for input: URL) async -> Data? {
        guard !Task.isCancelled,
              var components = URLComponents(url: input, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host?.isEmpty == false,
              components.user == nil, components.password == nil else { return nil }
        // Match the desktop cache policy: artwork is public, not an account or signed-URL store.
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { return nil }
        let key = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        clock &+= 1
        if var entry = memory[key] {
            entry.accessed = clock
            memory[key] = entry
            return entry.data
        }
        if !prepared {
            prepared = true
            if let directory { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
            _ = trimDisk()
        }
        let file = directory?.appendingPathComponent(key + ".jpg")
        if let file,
           let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > 0, size <= maximumDownload,
           let data = try? Data(contentsOf: file),
           CGImageSourceCreateWithData(data as CFData, nil) != nil {
            try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: file.path)
            remember(data, key: key)
            return data
        }
        if let file { try? FileManager.default.removeItem(at: file) }
        do {
            // Download to a temporary file, so oversized responses aren't allocated as image data.
            let (temporary, response) = try await session.download(from: url)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                  let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0, size <= maximumDownload else { return nil }
            let original = try Data(contentsOf: temporary)
            guard let data = thumbnail(original), !Task.isCancelled else { return nil }
            remember(data, key: key)
            if let file, trimDisk(reserving: data.count) { try? data.write(to: file, options: .atomic) }
            return data
        } catch {
            return nil
        }
    }

    private func thumbnail(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 720
              ] as CFDictionary) else { return nil }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination), result.length <= maximumDownload else { return nil }
        return result as Data
    }

    private func remember(_ data: Data, key: String) {
        memoryBytes -= memory.removeValue(forKey: key)?.data.count ?? 0
        clock &+= 1
        memory[key] = Entry(data: data, accessed: clock)
        memoryBytes += data.count
        while memoryBytes > memoryLimit || memory.count > 64 {
            guard let oldest = memory.min(by: { $0.value.accessed < $1.value.accessed })?.key,
                  let removed = memory.removeValue(forKey: oldest) else { break }
            memoryBytes -= removed.data.count
        }
    }

    /// Evict oldest files before admitting a write; a failed eviction never grows the disk cache.
    private func trimDisk(reserving bytes: Int = 0) -> Bool {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]) else { return false }
        var entries: [(url: URL, size: Int, date: Date)] = []
        for file in files where file.pathExtension == "jpg" {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true, let size = values.fileSize else { return false }
            entries.append((file, size, values.contentModificationDate ?? .distantPast))
        }
        var total = entries.reduce(0) { $0 + $1.size }
        var count = entries.count
        let incoming = bytes > 0 ? 1 : 0
        for entry in entries.sorted(by: { $0.date < $1.date }) {
            if total + bytes <= diskLimit && count + incoming <= 256 { break }
            do { try FileManager.default.removeItem(at: entry.url) }
            catch { return false }
            total -= entry.size
            count -= 1
        }
        return total + bytes <= diskLimit && count + incoming <= 256
    }
}
