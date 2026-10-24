import CoreData
import Foundation

/// Owns the library stack and its repositories. Opening either succeeds completely,
/// including backups and migrations, or throws without exposing a partial library.
@MainActor
final class LibraryPersistence {
    enum OpenError: Error {
        case missingModel
        case unknownSourceModel
        case storeNotLoaded
    }

    private let container: NSPersistentContainer
    let works: WorkLibrary
    let favorites: FavoriteLibrary
    let storeURL: URL

    static func production(fileManager: FileManager = .default) throws -> LibraryPersistence {
        guard let url = Bundle.main.url(forResource: "DataModel", withExtension: "momd"),
              let model = NSManagedObjectModel(contentsOf: url) else { throw OpenError.missingModel }
        return try LibraryPersistence(storeURL: AppStoragePaths.libraryStoreURL(fileManager: fileManager),
                                      model: model)
    }

    init(storeURL: URL, model: NSManagedObjectModel, modelBundles: [Bundle] = [.main]) throws {
        self.storeURL = storeURL
        let container = NSPersistentContainer(name: "DataModel", managedObjectModel: model)
        let description = NSPersistentStoreDescription(url: storeURL)
        description.shouldAddStoreAsynchronously = false
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        container.persistentStoreDescriptions = [description]

        let sourceModel: NSManagedObjectModel?
        if FileManager.default.fileExists(atPath: storeURL.path) {
            let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
                ofType: NSSQLiteStoreType, at: storeURL)
            if model.isConfiguration(withName: nil, compatibleWithStoreMetadata: metadata) {
                sourceModel = model
            } else {
                guard let source = NSManagedObjectModel.mergedModel(from: modelBundles, forStoreMetadata: metadata)
                else { throw OpenError.unknownSourceModel }
                sourceModel = source
            }
        } else { sourceModel = nil }

        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        _ = try BookmarkFavoritesMigration.prepareBackup(storeURL: storeURL)
        _ = try WorkClassificationMigration.prepareBackup(storeURL: storeURL)

        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        guard !container.persistentStoreCoordinator.persistentStores.isEmpty else { throw OpenError.storeNotLoaded }
        let context = container.viewContext
        context.automaticallyMergesChangesFromParent = true
        context.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        do {
            if let sourceModel {
                try BookmarkOrderMigration.initializeOrderIfMissing(in: context, sourceModel: sourceModel)
            }
            try BookmarkFavoritesMigration.migrate(container: container)
            try WorkClassificationMigration.migrate(container: container)
            // Ordering can register legacy bookmarks in viewContext before the private-context
            // migrations fill their identities. Clear those snapshots before exposing repositories;
            // automatic merging alone is deferred until the main queue can process notifications.
            context.reset()
        } catch {
            // Release the failed stack; never fall back to an empty or temporary store.
            for store in container.persistentStoreCoordinator.persistentStores {
                try? container.persistentStoreCoordinator.remove(store)
            }
            throw error
        }
        self.container = container
        works = WorkLibrary(context: context)
        favorites = FavoriteLibrary(context: context, works: works)
    }

    var viewContext: NSManagedObjectContext { container.viewContext }

    func saveIfNeeded() throws {
        let context = container.viewContext
        if context.hasChanges { try context.save() }
    }
}
