import Foundation

/// Durable paths retain the existing on-disk layout. Failure never falls back to a cache or temp root.
struct AppStoragePaths: Sendable {
    let applicationSupport: URL

    init(applicationSupport: URL) {
        self.applicationSupport = applicationSupport.standardizedFileURL
    }

    static func production(fileManager: FileManager = .default) throws -> AppStoragePaths {
        let base = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                       appropriateFor: nil, create: true)
        return AppStoragePaths(applicationSupport: base.appendingPathComponent(
            Bundle.main.bundleIdentifier ?? "IINA-ANI", isDirectory: true))
    }

    /// Keep the legacy library location until an explicit, verified data migration is provided.
    static func libraryStoreURL(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                       appropriateFor: nil, create: true)
        return base.appendingPathComponent("IINA+", isDirectory: true).appendingPathComponent("DataModel.sqlite")
    }

    var downloadTemporaryDirectory: URL { applicationSupport.appendingPathComponent("Downloads/Temporary", isDirectory: true) }
    var completedDownloadsDirectory: URL { applicationSupport.appendingPathComponent("Downloads/Completed", isDirectory: true) }
    var downloadTaskStore: URL { applicationSupport.appendingPathComponent("Downloads/tasks-v1.json") }
}
