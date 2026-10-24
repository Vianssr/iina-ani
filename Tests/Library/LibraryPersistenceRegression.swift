import CoreData
import Foundation
@testable import IINA_ANI

@main
@MainActor
struct LibraryPersistenceRegression {
    static func main() throws {
        let modelURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let appURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let model = try unwrap(NSManagedObjectModel(contentsOf: modelURL))
        let bundle = try unwrap(Bundle(url: appURL))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("new/library.sqlite")
        let work = Work(bangumiID: 42, title: "Persistence regression")
        var savedWork: Work?
        do {
            let owner = try LibraryPersistence(storeURL: url, model: model)
            try owner.works.upsert(work)
            try owner.favorites.addWork(workID: work.id)
            savedWork = try owner.works.fetchWork(id: work.id)
            try require(try owner.favorites.works().map(\.id) == [work.id], "repositories do not share the library")
            let context = try unwrap(owner.favorites.changeNotificationSource as? NSManagedObjectContext)
            let record = try unwrap(try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "WorkFavoriteRecord")).first)
            record.setValue(17.0, forKey: "order")
            try owner.saveIfNeeded()
            try require(!context.hasChanges, "termination save did not flush pending changes")
        }
        do {
            let owner = try LibraryPersistence(storeURL: url, model: model)
            try require(try owner.works.fetchWork(id: work.id) == savedWork, "work did not survive reopen")
            try require(try owner.favorites.favoriteWorkIDs() == [work.id], "favorites duplicated or lost on reopen")
            let context = try unwrap(owner.favorites.changeNotificationSource as? NSManagedObjectContext)
            let record = try unwrap(try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "WorkFavoriteRecord")).first)
            try require((record.value(forKey: "order") as? Double) == 17, "pending save did not persist")
        }
        // Use a real historical model and SQLite file to exercise the production opening pipeline.
        for legacyName in ["Bookmark.mom", "Bookmark v0.3.mom"] {
            let legacyModel = try unwrap(NSManagedObjectModel(contentsOf: modelURL.appendingPathComponent(legacyName)))
            let legacyURL = root.appendingPathComponent(legacyName + ".sqlite")
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: legacyModel)
            let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: legacyURL)
            let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
            let entity = try unwrap(legacyModel.entitiesByName["Bookmark"])
            let bookmark = NSManagedObject(entity: entity, insertInto: context)
            bookmark.setValue("https://www.bilibili.com/video/BV1xx411c7mD", forKey: "url")
            if entity.attributesByName["liveTitle"] != nil { bookmark.setValue("Retained title", forKey: "liveTitle") }
            bookmark.setValue("Retained note", forKey: "remark")
            if entity.attributesByName["liveName"] != nil { bookmark.setValue("", forKey: "liveName") }
            if entity.attributesByName["state"] != nil { bookmark.setValue(Int16(0), forKey: "state") }
            if entity.attributesByName["order"] != nil { bookmark.setValue(0.5, forKey: "order") }
            try context.save()
            context.reset()
            try coordinator.remove(store)
            var migratedID: UUID?
            do {
                let owner = try LibraryPersistence(storeURL: legacyURL, model: model, modelBundles: [bundle])
                let links = try owner.favorites.links()
                try require(links.count == 1, "legacy bookmark lost")
                migratedID = links.first?.id
                try require(links.first?.order == (legacyName == "Bookmark.mom" ? 0 : 0.5), "legacy bookmark order changed")
                try require(FileManager.default.fileExists(atPath: legacyURL.path + ".w5-backup/backup.sqlite"), "pre-migration backup missing")
            }
            do {
                let owner = try LibraryPersistence(storeURL: legacyURL, model: model, modelBundles: [bundle])
                try require(try owner.favorites.links().map(\.id) == [try unwrap(migratedID)], "migration changed identity on reopen")
            }
        }
        let corrupt = root.appendingPathComponent("corrupt.sqlite")
        let bytes = Data("not a database".utf8)
        try bytes.write(to: corrupt)
        do {
            _ = try LibraryPersistence(storeURL: corrupt, model: model)
            throw Failure(message: "corrupt store silently replaced")
        } catch is Failure { throw Failure(message: "corrupt store silently replaced") }
          catch { try require(try Data(contentsOf: corrupt) == bytes, "failed open modified original bytes") }
        let parent = root.appendingPathComponent("not-a-directory")
        try bytes.write(to: parent)
        do {
            _ = try LibraryPersistence(storeURL: parent.appendingPathComponent("library.sqlite"), model: model)
            throw Failure(message: "invalid storage path silently accepted")
        } catch is Failure { throw Failure(message: "invalid storage path silently accepted") }
          catch { try require(try Data(contentsOf: parent) == bytes, "invalid path replaced existing file") }
        print("PASS: shared repositories, pending save, reopen, legacy pipeline/backup/identity, corrupt store and invalid path preservation")
    }

    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(message: message) }
    }
    static func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw Failure(message: "missing fixture") }
        return value
    }
    struct Failure: Error { let message: String }
}
