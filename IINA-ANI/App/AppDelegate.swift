//
//  AppDelegate.swift
//  iina+
//
//  Created by xjbeta on 2018/7/5.
//  Copyright © 2018 xjbeta. All rights reserved.
//

import Cocoa
import SDWebImage
import HuyaKit

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }
    @MainActor lazy var services = AppServices(workLibrary: { [weak self] in self?.workLibrary })
    @MainActor lazy var workspaceApplication = WorkspaceApplicationController(delegate: self)
    @MainActor private lazy var mainMenu = MainMenu(delegate: self)

    @MainActor func makeDataManager() -> DataManager {
        DataManager(context: persistentContainer.viewContext, favorites: favoriteLibrary, decoder: services.decoder)
    }
    override init() {
        let cacheBase = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "IINA-ANI"
        let cacheDirectory = cacheBase.appendingPathComponent(bundleID, isDirectory: true).appendingPathComponent("SDWebImage", isDirectory: true)
        SDImageCache.defaultDiskCacheDirectory = cacheDirectory.path
        super.init()
    }

    
    
    @MainActor private lazy var discoveryResult = Result {
        try DiscoveryService.production(works: workLibrary, favorites: favoriteLibrary,
                                        decoder: services.decoder)
    }
    @MainActor private var discoveryTask: Task<Void, Never>?
    @MainActor private var discoveryRefreshPending = false
    @MainActor private var isTerminating = false

    @MainActor func discovery() throws -> DiscoveryService {
        let service = try discoveryResult.get()
        service.setRefreshPolicy(services.preferences.discoveryRefreshPolicy)
        return service
    }
    private var dayChangeObserver: NSObjectProtocol?
	
    
    
    lazy var logUrl: URL? = {
        do {
            var logPath = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            logPath.appendPathComponent(Bundle.main.bundleIdentifier!)
            var isDir = ObjCBool(false)
            if !FileManager.default.fileExists(atPath: logPath.path, isDirectory: &isDir) {
                try FileManager.default.createDirectory(at: logPath, withIntermediateDirectories: true, attributes: nil)
            }
            guard let appName = Bundle.main.infoDictionary?["CFBundleExecutable"] as? String else {
                return nil
            }
            logPath.appendPathComponent("\(appName).log")
            return logPath
        } catch let error {
            Log(error)
            return nil
        }
    }()
	
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        
        
        deleteUselessFiles()
        Log("App did finish launch")
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        Log("App Version \(version) (Build \(build))")
        Log("macOS " + ProcessInfo().operatingSystemVersionString)

        persistentContainer.persistentStoreDescriptions.forEach {
            Log("CoreData Path: \($0.url?.path ?? "none")")
        }
        
        initImageCache()
        mainMenu.install()
        workspaceApplication.showWorkspace()
        Task {
            do { await (try services.downloads()).restoreAccountLeases() }
            catch { Log("Download task store unavailable; check Application Support permissions and space.") }
        }
        refreshDiscovery()
        dayChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main) { _ in
                Task { @MainActor in (NSApp.delegate as? AppDelegate)?.refreshDiscovery() }
            }
        
        // HuyaKit logs: error-only by default; set HuyaLogger.level = .debug when tracing
        HuyaLogger.handler = { message, _ in
            Log("[HuyaKit] \(message)")
        }
        
        Task {
            do { _ = try await services.httpServer.start() }
            catch { Log("Local playback service unavailable; check the configured port.") }
        }
		

    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        switch url.pathExtension.lowercased() {
        case "iinaskin": workspaceApplication.openSkinPackage(at: url)
        case "torrent": workspaceApplication.openLink(url.absoluteString)
        default: return false
        }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshDiscovery()
    }

    @MainActor private func refreshDiscovery() {
        guard !isTerminating else { return }
        guard discoveryTask == nil else { discoveryRefreshPending = true; return }
        discoveryTask = Task { @MainActor in
            defer {
                discoveryTask = nil
                if discoveryRefreshPending { discoveryRefreshPending = false; refreshDiscovery() }
            }
            do { _ = try await discovery().refresh() }
            catch is CancellationError { }
            catch { Log("Discovery state unavailable; check Application Support permissions and space.") }
        }
    }


    
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        workspaceApplication.showWorkspace()
        return false
    }
    
	
    func initImageCache() {
        let cache = SDImageCache.shared
        cache.config.maxDiskAge = 60 * 60 * 24 * 14
        cache.config.maxDiskSize = UInt(clamping: max(Int64(1), ImageCacheService.shared.maximumRebuildableBytes))
        Log("Image Cache Path: \(cache.diskCachePath)")
        cache.deleteOldFiles(completionBlock: nil)
        do {
            try ImageCacheService.shared.evictRebuildableCacheToLimit()
        } catch {
            Log("Could not enforce rebuildable cache limit: \(error)")
        }
    }
    
    func deleteUselessFiles() {
        if let url = logUrl {
            try? FileManager.default.removeItem(at: url)
        }
        
        UserDefaults.standard.removeObject(forKey: "enableLogging")
        UserDefaults.standard.removeObject(forKey: "logLevel")
        // delete log files for old api.
        let libraryPath = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
        let logsUrl = libraryPath.first!.appendingPathComponent("Logs", isDirectory: true)
        let bundleID = Bundle.main.bundleIdentifier!
        let logDirURL = logsUrl.appendingPathComponent(bundleID, isDirectory: true)
        try? FileManager.default.removeItem(at: logDirURL)
    }
    
    // MARK: - Core Data stack
    
    @MainActor lazy var persistentContainer: NSPersistentContainer = {
        let container = NSPersistentContainer(name: "DataModel")
        // Product branding must not redirect existing libraries to an empty store.
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let storeURL = support.appendingPathComponent("IINA+", isDirectory: true)
            .appendingPathComponent("DataModel.sqlite")
        container.persistentStoreDescriptions = [NSPersistentStoreDescription(url: storeURL)]
        let sourceModel = sourceModelForStore(container: container)
        let shouldInitializeBookmarkOrder = sourceModel.map(BookmarkOrderMigration.sourceModelLacksOrder) ?? false
        do {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            for description in container.persistentStoreDescriptions {
                if let url = description.url, description.type == NSSQLiteStoreType {
                    _ = try BookmarkFavoritesMigration.prepareBackup(storeURL: url)
                    _ = try WorkClassificationMigration.prepareBackup(storeURL: url)
                }
            }
        } catch {
            NSApp.presentError(error)
            fatalError("Library backup failed; the original store has not been opened for migration.")
        }
        container.persistentStoreDescriptions.forEach { description in
            description.shouldAddStoreAsynchronously = false
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
        }

        container.loadPersistentStores { _, error in
            if let error = error {
                fatalError("Unresolved error \(error)")
            }
            container.viewContext.automaticallyMergesChangesFromParent = true
            container.viewContext.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
            if shouldInitializeBookmarkOrder, let sourceModel {
                // Synchronous startup runs on the main actor, as does viewContext.
                do {
                    try BookmarkOrderMigration.initializeOrderIfMissing(in: container.viewContext, sourceModel: sourceModel)
                } catch {
                    NSApp.presentError(error)
                    fatalError("Bookmark ordering migration failed; restore the pre-W5 backup before retrying.")
                }
            }
            do {
                try BookmarkFavoritesMigration.migrate(container: container)
            } catch {
                NSApp.presentError(error)
                fatalError("Favorites migration failed; the pre-W5 backup is retained.")
            }
            do {
                try WorkClassificationMigration.migrate(container: container)
            } catch {
                NSApp.presentError(error)
                fatalError("Work classification migration failed; the pre-R3 backup is retained.")
            }
        }
        return container
    }()

    @MainActor lazy var workLibrary = WorkLibrary(container: persistentContainer)
    @MainActor lazy var favoriteLibrary = FavoriteLibrary(container: persistentContainer)
    
    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let context = persistentContainer.viewContext
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                if sender.presentError(error as NSError) { return .terminateCancel }
                let alert = NSAlert()
                alert.messageText = NSLocalizedString("Could not save changes while quitting. Quit anyway?", comment: "Quit without saves error question message")
                alert.informativeText = NSLocalizedString("Quitting now will lose any changes you have made since the last successful save", comment: "Quit without saves error question info")
                alert.addButton(withTitle: NSLocalizedString("Quit anyway", comment: "Quit anyway button title"))
                alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button title"))
                if alert.runModal() == .alertSecondButtonReturn { return .terminateCancel }
            }
        }
        Task { @MainActor in
            isTerminating = true
            if let discoveryTask { discoveryTask.cancel(); await discoveryTask.value }
            if let dayChangeObserver { NotificationCenter.default.removeObserver(dayChangeObserver) }
            await services.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    
    
    private func sourceModelForStore(container: NSPersistentContainer) -> NSManagedObjectModel? {
        guard let storeURL = container.persistentStoreDescriptions.first?.url,
              FileManager.default.fileExists(atPath: storeURL.path),
              let metadata = try? NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: storeURL) else {
            return nil
        }
        return NSManagedObjectModel.mergedModel(from: [Bundle.main], forStoreMetadata: metadata)
    }
}
