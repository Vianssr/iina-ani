import CoreData
import Foundation
import SQLite3
@testable import IINA_ANI

@main
@MainActor
struct BookmarkFavoritesMigrationRegression {
    private struct LegacyRow {
        let url: String
        let remark: String?
        let liveTitle: String
        let order: Double
    }

    private struct MigratedRow: Equatable {
        let url: String
        let remark: String?
        let liveTitle: String
        let order: Double
        let favoriteID: UUID?
        let originalURL: String?
        let canonicalURL: String?
        let sourceID: String?
        let favoriteTitle: String?
        let createdAt: Date?
    }

    private static let rows = [
        LegacyRow(url: "https://www.bilibili.com/video/BV1xx411c7mD?p=1&spm_id_from=legacy",
                  remark: "Pinned note", liveTitle: "Legacy video title", order: 0.125),
        LegacyRow(url: "https://www.bilibili.com/video/BV1xx411c7mD?p=1&spm_id_from=legacy",
                  remark: "", liveTitle: "Duplicate title", order: 1.375),
        LegacyRow(url: "https://www.bilibili.com/video/BV1xx411c7mD?p=2&spm_id_from=legacy",
                  remark: nil, liveTitle: "Part two", order: 2.625),
        LegacyRow(url: "https://live.bilibili.com/1010", remark: "Live room note",
                  liveTitle: "Old live title", order: 3.875),
        LegacyRow(url: "https://www.bilibili.com/bangumi/play/ep282958", remark: "",
                  liveTitle: "Anime episode", order: 5.125),
        LegacyRow(url: "https://b23.tv/legacyShort", remark: nil,
                  liveTitle: "Short link", order: 7.25),
        LegacyRow(url: "not a valid URL", remark: "Broken link note",
                  liveTitle: "Broken link", order: 9.5)
    ]

    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw RegressionFailure("usage: bookmark-favorites-migration-regression <compiled-DataModel.momd>")
        }
        let modelDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        guard let loadedCurrent = NSManagedObjectModel(contentsOf: modelDirectory),
              let currentModel = loadedCurrent.mutableCopy() as? NSManagedObjectModel,
              let bookmark = currentModel.entitiesByName["Bookmark"] else {
            throw RegressionFailure("current DataModel.momd or Bookmark entity is missing")
        }
        bookmark.managedObjectClassName = NSStringFromClass(NSManagedObject.self)

        let oldURLs = try FileManager.default.contentsOfDirectory(at: modelDirectory, includingPropertiesForKeys: nil)
            .filter { ["Bookmark v0.3.mom", "Library v0.4.mom"].contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard oldURLs.count == 2 else { throw RegressionFailure("historical v0.3/v0.4 model fixtures are missing") }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IINA-ANI-BookmarkFavoritesMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for oldURL in oldURLs {
            guard let loadedOld = NSManagedObjectModel(contentsOf: oldURL),
                  let oldModel = loadedOld.mutableCopy() as? NSManagedObjectModel,
                  let oldBookmark = oldModel.entitiesByName["Bookmark"] else {
                throw RegressionFailure("could not load historical model \(oldURL.lastPathComponent)")
            }
            oldBookmark.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
            try require(oldBookmark.attributesByName["order"] != nil && oldBookmark.attributesByName["liveTitle"] != nil,
                        "legacy mixed bookmark fixture requires title and fractional order fields")
            try await exerciseHistoricalStore(oldModel: oldModel, currentModel: currentModel, label: oldURL.lastPathComponent,
                                        root: root)
            print("PASS: \(oldURL.lastPathComponent) backup, migration, idempotent reopen, and restore")
        }

        try await testEmptyStoreVersion(model: currentModel, root: root)
        try await testFailedSaveRollback(model: currentModel, modelDirectory: modelDirectory, root: root)
        try await testFutureVersionProtection(model: currentModel, root: root)
        try testInvalidBackupProtection(root: root)
        print("PASS: failed-save rollback, future-version no-downgrade, invalid-backup preservation")
        try await testWorkClassificationMigration(model: currentModel, root: root)
    }

    private static func testWorkClassificationMigration(model: NSManagedObjectModel, root: URL) async throws {
        let url = root.appendingPathComponent("r3.sqlite")
        let container = try await openContainer(model: model, at: url)
        let metadata = BangumiMetadata(subject: BangumiSubject(id: 42, name: "Metadata", type: 2), episodes: [], fetchedAt: .now)
        let videoMetadata = BangumiMetadata(subject: BangumiSubject(id: 43, name: "Metadata", type: 6), episodes: [], fetchedAt: .now)
        let oldWorks = [Work(bangumiID: 42, title: "Same title", bangumiMetadata: metadata),
                        Work(bangumiID: 43, title: "Same title", bangumiMetadata: videoMetadata),
                        Work(bangumiID: 44, title: "Same title", collectionStatus: .onHold,
                             collectionStatusPending: true, collectionStatusRevision: UUID())]
        let manual = Work(title: "Manual", classification: MediaClassification(kind: .live, provenance: "manual"), classificationIsManual: true)
        let library = WorkLibrary(container: container)
        try library.upsert(manual)
        for work in oldWorks {
            var payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(work)) as! [String: Any]
            payload.removeValue(forKey: "classification")
            payload.removeValue(forKey: "classificationIsManual")
            payload["futureKey"] = "preserved"
            let record = NSEntityDescription.insertNewObject(forEntityName: "WorkRecord", into: container.viewContext)
            record.setValue(work.id, forKey: "id")
            record.setValue(try JSONSerialization.data(withJSONObject: payload), forKey: "payload")
        }
        try container.viewContext.save()
        let episode = Episode(workID: oldWorks[0].id, label: "Episode", sort: 0)
        try library.upsert(episode)
        let favorites = FavoriteLibrary(container: container)
        for work in oldWorks { try favorites.addWork(workID: work.id) }
        let bookmark = try favorites.addLink(url: "https://live.bilibili.com/1010", title: "Live")
        let file = root.appendingPathComponent("completed-media.mkv")
        try Data("owned completed download".utf8).write(to: file)
        try close(container)
        let backup = try requireBackup(WorkClassificationMigration.prepareBackup(storeURL: url), label: "R3")
        let backupBytes = try Data(contentsOf: backup)
        let loaded = try await openContainer(model: model, at: url)
        try WorkClassificationMigration.migrate(container: loaded)
        loaded.viewContext.reset()
        let migrated = WorkLibrary(container: loaded)
        for (work, kind) in zip(oldWorks, [MediaContentKind.anime, .video, .unknown]) {
            let actual = try migrated.fetchWork(id: work.id)!
            try require(actual.id == work.id && actual.classification.kind == kind && actual.title == work.title && actual.bangumiID == work.bangumiID,
                        "R3 migration guessed from ID/title or changed Work identity")
            try require(actual.collectionStatus == work.collectionStatus &&
                        actual.collectionStatusPending == work.collectionStatusPending &&
                        actual.collectionStatusRevision == work.collectionStatusRevision,
                        "Media-kind migration must preserve nil and explicit pending collection categories")
        }
        try require(try migrated.fetchWork(id: manual.id) == manual, "R3 migration overwrote existing manual classification")
        try require(try migrated.episodes(forWorkID: oldWorks[0].id) == [episode] &&
                    FavoriteLibrary(container: loaded).favoriteWorkIDs() == Set(oldWorks.map(\.id)) &&
                    FavoriteLibrary(container: loaded).links().map(\.id) == [bookmark.id], "R3 migration deleted favorites or episode identities")
        let records = try loaded.viewContext.fetch(NSFetchRequest<NSManagedObject>(entityName: "WorkRecord"))
        for record in records where record.value(forKey: "id") as? UUID != manual.id {
            let payload = try JSONSerialization.jsonObject(with: record.value(forKey: "payload") as! Data) as! [String: Any]
            try require(payload["futureKey"] as? String == "preserved", "R3 migration discarded an unrelated payload field")
        }
        try close(loaded)
        try require(try WorkClassificationMigration.prepareBackup(storeURL: url) == nil && Data(contentsOf: backup) == backupBytes,
                    "R3 version/immutable backup did not survive reopen")
        let reopened = try await openContainer(model: model, at: url)
        try WorkClassificationMigration.migrate(container: reopened)
        try require(try WorkLibrary(container: reopened).fetchWork(id: manual.id) == manual &&
                    Data(contentsOf: file) == Data("owned completed download".utf8), "idempotent classification migration changed data or completed media")
        try close(reopened)
        let backupContainer = try await openContainer(model: model, at: backup)
        let original = try backupContainer.viewContext.fetch(NSFetchRequest<NSManagedObject>(entityName: "WorkRecord"))
        let oldRecord = original.first { $0.value(forKey: "id") as? UUID == oldWorks[0].id }!
        let oldPayload = try JSONSerialization.jsonObject(with: oldRecord.value(forKey: "payload") as! Data) as! [String: Any]
        try require(oldPayload["classification"] == nil, "R3 backup was not a pre-migration copy")
        try close(backupContainer)

        let corruptURL = root.appendingPathComponent("r3-corrupt.sqlite")
        let corrupt = try await openContainer(model: model, at: corruptURL)
        let record = NSEntityDescription.insertNewObject(forEntityName: "WorkRecord", into: corrupt.viewContext)
        record.setValue(UUID(), forKey: "id")
        let invalid = Data("{broken payload".utf8)
        record.setValue(invalid, forKey: "payload")
        try corrupt.viewContext.save()
        var rejected = false
        do { try WorkClassificationMigration.migrate(container: corrupt) } catch { rejected = true }
        try require(rejected && (record.value(forKey: "payload") as? Data) == invalid,
                    "failed R3 migration replaced corrupt input")
        let store = corrupt.persistentStoreCoordinator.persistentStores[0]
        try require(corrupt.persistentStoreCoordinator.metadata(for: store)[WorkClassificationMigration.versionMetadataKey] == nil,
                    "failed migration recorded completion")
        try close(corrupt)
        let emptyURL = root.appendingPathComponent("r3-empty.sqlite")
        let empty = try await openContainer(model: model, at: emptyURL)
        try WorkClassificationMigration.migrate(container: empty)
        try close(empty)
        try require(try WorkClassificationMigration.prepareBackup(storeURL: emptyURL) == nil, "empty R3 migration marker was not durable")
        let emptyReopened = try await openContainer(model: model, at: emptyURL)
        try WorkClassificationMigration.migrate(container: emptyReopened)
        let emptyStore = emptyReopened.persistentStoreCoordinator.persistentStores[0]
        var future = emptyReopened.persistentStoreCoordinator.metadata(for: emptyStore)
        future[WorkClassificationMigration.versionMetadataKey] = 99
        emptyReopened.persistentStoreCoordinator.setMetadata(future, for: emptyStore)
        try WorkClassificationMigration.migrate(container: emptyReopened)
        try require(emptyReopened.persistentStoreCoordinator.metadata(for: emptyStore)[WorkClassificationMigration.versionMetadataKey] as? Int == 99,
                    "R3 migration downgraded a future payload version")
        try close(emptyReopened)
        print("PASS: R3 immutable SQLite copy, payload version, metadata-only evidence, legacy unknown, manual/future-field preservation, idempotent reopen, corruption rollback")
    }


    private static func testEmptyStoreVersion(model: NSManagedObjectModel, root: URL) async throws {
        let url = root.appendingPathComponent("empty.sqlite")
        let container = try await openContainer(model: model, at: url)
        try BookmarkFavoritesMigration.migrate(container: container)
        try require(try BookmarkFavoritesMigration.prepareBackup(storeURL: url) == nil, "empty-store completion must be durable without a later favorite write")
        try close(container)
        let reopened = try await openContainer(model: model, at: url)
        try require(try storedVersion(in: reopened.persistentStoreCoordinator) == 1 && snapshot(from: reopened.viewContext).isEmpty,
                    "empty-store restart must preserve version without manufacturing favorites")
        try close(reopened)
    }

    private static func exerciseHistoricalStore(oldModel: NSManagedObjectModel,
                                                currentModel: NSManagedObjectModel,
                                                label: String, root: URL) async throws {
        let storeURL = root.appendingPathComponent("\(label).sqlite")
        let oldCoordinator = try createLegacyStore(model: oldModel, at: storeURL, rows: rows)
        let backupURL = try requireBackup(BookmarkFavoritesMigration.prepareBackup(storeURL: storeURL), label: label)
        let backupBytes = try Data(contentsOf: backupURL)
        try require(try BookmarkFavoritesMigration.prepareBackup(storeURL: storeURL) == backupURL,
                    "backup retry must return the fixed adjacent backup")
        try require(try Data(contentsOf: backupURL) == backupBytes,
                    "retry must never overwrite a verified prior backup")
        try verifyBackupUsesModel(backupURL, model: oldModel, expectedCount: rows.count)
        try oldCoordinator.persistentStores.forEach { try oldCoordinator.remove($0) }

        var container = try await openContainer(model: currentModel, at: storeURL)
        try BookmarkFavoritesMigration.migrate(container: container)
        let afterFirstMigration = try snapshot(from: container.viewContext)
        try assertMigrated(afterFirstMigration, expected: rows)
        let duplicate = try FavoriteLibrary(container: container).addLink(url: "https://www.bilibili.com/video/BV1xx411c7mD?p=1&spm_id_from=new", title: "Must not overwrite")
        try require(duplicate.id == afterFirstMigration[0].favoriteID && duplicate.title == "Pinned note" && duplicate.order == rows[0].order,
                    "new additions deduplicate against migrated identities without deleting old duplicate rows")
        try BookmarkFavoritesMigration.migrate(container: container)
        let afterRepeatedMigration = try snapshot(from: container.viewContext)
        try require(afterRepeatedMigration == afterFirstMigration,
                    "calling migration twice must preserve IDs, titles, dates, URLs, and fractional ordering")
        try require(try storedVersion(in: container.persistentStoreCoordinator) == 1,
                    "migration metadata must be stamped only after successful save")
        try require(try BookmarkFavoritesMigration.prepareBackup(storeURL: storeURL) == nil,
                    "a completed migration must not create a backup on a later startup")

        do {
            try BookmarkFavoritesMigration.restoreBackup(at: backupURL, to: storeURL)
            throw RegressionFailure("restore accepted a still-loaded coordinator")
        } catch is RegressionFailure { throw RegressionFailure("restore accepted a still-loaded coordinator") }
        catch {}
        try require(try snapshot(from: container.viewContext) == afterFirstMigration, "rejected live-store restore preserves all migrated rows")
        try close(container)
        container = try await openContainer(model: currentModel, at: storeURL)
        try BookmarkFavoritesMigration.migrate(container: container)
        let afterReopen = try snapshot(from: container.viewContext)
        try require(afterReopen == afterFirstMigration,
                    "migration retry after reopening must reuse committed identity and timestamps")
        try close(container)
        try leaveCommittedWALProbe(at: storeURL)
        try require(FileManager.default.fileExists(atPath: storeURL.path + "-wal"),
                    "restore fixture must include committed WAL data")
        try BookmarkFavoritesMigration.restoreBackup(at: backupURL, to: storeURL)
        try require(try Data(contentsOf: backupURL) == backupBytes, "restore must keep the backup unchanged")
        try verifyBackupUsesModel(backupURL, model: oldModel, expectedCount: rows.count)
        try verifyOldStore(at: storeURL, model: oldModel, expectedRows: rows)
        try require(try !sqliteTableExists("W5_RESTORE_PROBE", at: storeURL),
                    "restore must remove stale WAL writes instead of replaying them on the restored store")
    }

    private static func createLegacyStore(model: NSManagedObjectModel, at url: URL,
                                          rows: [LegacyRow]) throws -> NSPersistentStoreCoordinator {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let options: [AnyHashable: Any] = [NSSQLitePragmasOption: ["journal_mode": "WAL"]]
        _ = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
                                               at: url, options: options)
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        try context.performAndWait {
            guard let entity = NSEntityDescription.entity(forEntityName: "Bookmark", in: context) else {
                throw RegressionFailure("legacy model has no Bookmark entity")
            }
            for row in rows {
                let bookmark = NSManagedObject(entity: entity, insertInto: context)
                bookmark.setValue(row.url, forKey: "url")
                if entity.attributesByName["remark"] != nil { bookmark.setValue(row.remark, forKey: "remark") }
                if entity.attributesByName["liveTitle"] != nil { bookmark.setValue(row.liveTitle, forKey: "liveTitle") }
                if entity.attributesByName["order"] != nil { bookmark.setValue(row.order, forKey: "order") }
                if entity.attributesByName["liveName"] != nil { bookmark.setValue("Legacy channel", forKey: "liveName") }
                if entity.attributesByName["state"] != nil { bookmark.setValue(Int16(0), forKey: "state") }
            }
            try context.save()
        }
        return coordinator
    }

    private static func verifyBackupUsesModel(_ backupURL: URL, model: NSManagedObjectModel,
                                              expectedCount: Int) throws {
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType,
                                                                                    at: backupURL)
        guard let hashes = metadata[NSStoreModelVersionHashesKey] as? [String: Data],
              let bookmarkHash = hashes["Bookmark"],
              bookmarkHash == model.entitiesByName["Bookmark"]?.versionHash else {
            throw RegressionFailure("backup no longer carries the original historical schema")
        }
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        _ = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
                                               at: backupURL, options: [NSReadOnlyPersistentStoreOption: true])
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let count = try context.performAndWait {
            try context.count(for: NSFetchRequest<NSManagedObject>(entityName: "Bookmark"))
        }
        try require(count == expectedCount, "verified backup must be readable using its pre-migration model")
        try coordinator.persistentStores.forEach { try coordinator.remove($0) }
    }

    private static func snapshot(from context: NSManagedObjectContext) throws -> [MigratedRow] {
        try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Bookmark")
            request.sortDescriptors = [NSSortDescriptor(key: "order", ascending: true)]
            return try context.fetch(request).map { bookmark in
                MigratedRow(url: bookmark.value(forKey: "url") as? String ?? "",
                            remark: bookmark.value(forKey: "remark") as? String,
                            liveTitle: bookmark.value(forKey: "liveTitle") as? String ?? "",
                            order: (bookmark.value(forKey: "order") as? NSNumber)?.doubleValue ?? .nan,
                            favoriteID: bookmark.value(forKey: "favoriteID") as? UUID,
                            originalURL: bookmark.value(forKey: "originalURL") as? String,
                            canonicalURL: bookmark.value(forKey: "canonicalURL") as? String,
                            sourceID: bookmark.value(forKey: "sourceID") as? String,
                            favoriteTitle: bookmark.value(forKey: "favoriteTitle") as? String,
                            createdAt: bookmark.value(forKey: "createdAt") as? Date)
            }
        }
    }

    private static func assertMigrated(_ actual: [MigratedRow], expected: [LegacyRow]) throws {
        try require(actual.count == expected.count, "legacy rows, including canonical duplicates, must never be dropped")
        for (index, pair) in zip(actual, expected).enumerated() {
            let row = pair.0
            let old = pair.1
            let expectedTitle = nonempty(old.remark) ?? nonempty(old.liveTitle) ?? old.url

            try require(row.url == old.url && row.originalURL == old.url && row.remark == old.remark &&
                        row.liveTitle == old.liveTitle && row.order == old.order,
                        "legacy url/title/remark/fractional order must remain unchanged at row \(index)")
            try require(row.favoriteID != nil && row.favoriteTitle == expectedTitle && row.createdAt != nil,
                        "favorite identity, title precedence and stable creation date must be filled at row \(index)")

            if old.url == "not a valid URL" {
                try require(row.canonicalURL == old.url && row.sourceID == "unavailable",
                            "invalid URLs must remain exact offline unknown-source links")
            }
        }
        let ids = actual.compactMap(\.favoriteID)
        try require(Set(ids).count == expected.count, "each legacy row must retain its own favorite UUID")
        try require(actual[0].canonicalURL == actual[1].canonicalURL && actual[0].canonicalURL != actual[2].canonicalURL,
                    "legacy duplicate rows remain separate while part identity is retained")
    }

    private static func verifyOldStore(at url: URL, model: NSManagedObjectModel,
                                       expectedRows: [LegacyRow]) throws {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        _ = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url,
                                               options: [NSReadOnlyPersistentStoreOption: true])
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let actual = try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: "Bookmark")
            request.sortDescriptors = [NSSortDescriptor(key: "order", ascending: true)]
            return try context.fetch(request).map {
                LegacyRow(url: $0.value(forKey: "url") as? String ?? "",
                          remark: $0.value(forKey: "remark") as? String,
                          liveTitle: $0.value(forKey: "liveTitle") as? String ?? "",
                          order: ($0.value(forKey: "order") as? NSNumber)?.doubleValue ?? .nan)
            }
        }
        try require(actual.count == expectedRows.count, "restore must recover every legacy row")
        for (restored, expected) in zip(actual, expectedRows) {
            try require(restored.url == expected.url && restored.remark == expected.remark &&
                        restored.liveTitle == expected.liveTitle && restored.order == expected.order,
                        "restore must recover original legacy values exactly")
        }
        try coordinator.persistentStores.forEach { try coordinator.remove($0) }
    }

    private static func testFailedSaveRollback(model: NSManagedObjectModel, modelDirectory: URL, root: URL) async throws {
        let storeURL = root.appendingPathComponent("failed-save.sqlite")
        let oldModel = try historicalModel(named: "Library v0.4.mom", in: modelDirectory)
        let oldCoordinator = try createLegacyStore(model: oldModel, at: storeURL, rows: Array(rows.prefix(2)))
        try oldCoordinator.persistentStores.forEach { try oldCoordinator.remove($0) }
        var container = try await openContainer(model: model, at: storeURL)
        try close(container)
        try executeSQLite("CREATE TRIGGER W5_FAIL_FAVORITE_MIGRATION BEFORE UPDATE ON ZBOOKMARK BEGIN SELECT RAISE(ABORT, 'forced regression save failure'); END;",
                          at: storeURL)

        container = try await openContainer(model: model, at: storeURL)
        do {
            try BookmarkFavoritesMigration.migrate(container: container)
            throw RegressionFailure("migration unexpectedly succeeded despite the SQLite save trigger")
        } catch is RegressionFailure {
            throw RegressionFailure("migration unexpectedly succeeded despite the SQLite save trigger")
        } catch {
            // The injected store error must propagate and the private-context transaction must roll back.
        }
        let failedRows = try snapshot(from: container.viewContext)
        try require(failedRows.count == 2 && failedRows.allSatisfy { $0.favoriteID == nil && $0.originalURL == nil && $0.createdAt == nil },
                    "failed save must leave every original row without partially committed favorite fields")
        try require(try storedVersion(in: container.persistentStoreCoordinator) == 0,
                    "failed save must not stamp migration metadata")
        try close(container)
        try executeSQLite("DROP TRIGGER W5_FAIL_FAVORITE_MIGRATION", at: storeURL)

        container = try await openContainer(model: model, at: storeURL)
        try BookmarkFavoritesMigration.migrate(container: container)
        let retriedRows = try snapshot(from: container.viewContext)
        try require(retriedRows.count == 2 && retriedRows.allSatisfy { $0.favoriteID != nil && $0.createdAt != nil },
                    "migration must remain safely retryable after a failed save")
        try close(container)
    }

    private static func testFutureVersionProtection(model: NSManagedObjectModel, root: URL) async throws {
        let storeURL = root.appendingPathComponent("future-version.sqlite")
        var container = try await openContainer(model: model, at: storeURL)
        let bookmark = NSManagedObject(entity: model.entitiesByName["Bookmark"]!, insertInto: container.viewContext)
        bookmark.setValue("https://future.example/link", forKey: "url")
        bookmark.setValue(10.25, forKey: "order")
        try container.viewContext.save()
        guard let store = container.persistentStoreCoordinator.persistentStores.first else {
            throw RegressionFailure("future-version fixture did not attach its store")
        }
        var metadata = container.persistentStoreCoordinator.metadata(for: store)
        metadata[BookmarkFavoritesMigration.versionMetadataKey] = 9

        try close(container)
        try NSPersistentStoreCoordinator.setMetadata(metadata, forPersistentStoreOfType: NSSQLiteStoreType,
                                                    at: storeURL, options: nil)

        try require(try BookmarkFavoritesMigration.prepareBackup(storeURL: storeURL) == nil,
                    "a future migration version must not cause a backup or downgrade")
        container = try await openContainer(model: model, at: storeURL)
        try BookmarkFavoritesMigration.migrate(container: container)
        let row = try snapshot(from: container.viewContext).first
        try require(row?.favoriteID == nil && row?.originalURL == nil &&
                    (try storedVersion(in: container.persistentStoreCoordinator)) == 9,
                    "a future version must be left unchanged by migration")
        try close(container)
    }

    private static func testInvalidBackupProtection(root: URL) throws {
        let absentStoreURL = root.appendingPathComponent("not-created.sqlite")
        try require(try BookmarkFavoritesMigration.prepareBackup(storeURL: absentStoreURL) == nil,
                    "a store with no file must not create a backup")
        let storeURL = root.appendingPathComponent("invalid-source.sqlite")
        let originalBytes = Data("not a Core Data SQLite store".utf8)
        try originalBytes.write(to: storeURL)
        do {
            _ = try BookmarkFavoritesMigration.prepareBackup(storeURL: storeURL)
            throw RegressionFailure("backup preparation accepted a non-SQLite store")
        } catch is RegressionFailure {
            throw RegressionFailure("backup preparation accepted a non-SQLite store")
        } catch {
            // An unreadable source must abort startup before altering it.
        }
        try require(try Data(contentsOf: storeURL) == originalBytes &&
                    !FileManager.default.fileExists(atPath: storeURL.path + ".w5-backup"),
                    "backup failure must leave the source untouched and must not install a partial backup")
        let targetURL = root.appendingPathComponent("invalid-restore-target.sqlite")
        let targetBytes = Data("leave this target untouched".utf8)
        try targetBytes.write(to: targetURL)
        do {
            try BookmarkFavoritesMigration.restoreBackup(at: storeURL, to: targetURL)
            throw RegressionFailure("restore accepted an invalid backup")
        } catch is RegressionFailure {
            throw RegressionFailure("restore accepted an invalid backup")
        } catch {
            // Backup validation must fail before opening or replacing the target.
        }
        try require(try Data(contentsOf: targetURL) == targetBytes,
                    "invalid backup validation must leave the restore target byte-for-byte unchanged")
    }

    private static func historicalModel(named name: String, in modelDirectory: URL) throws -> NSManagedObjectModel {
        guard let modelURL = try FileManager.default.contentsOfDirectory(at: modelDirectory, includingPropertiesForKeys: nil).first(where: { $0.lastPathComponent == name }),
              let loaded = NSManagedObjectModel(contentsOf: modelURL),
              let model = loaded.mutableCopy() as? NSManagedObjectModel,
              let bookmark = model.entitiesByName["Bookmark"] else {
            throw RegressionFailure("historical model \(name) is unavailable")
        }
        bookmark.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        return model
    }

    private static func requireBackup(_ url: URL?, label: String) throws -> URL {
        guard let url else { throw RegressionFailure("missing pre-migration backup for \(label)") }
        return url
    }

    private static func openContainer(model: NSManagedObjectModel, at url: URL) async throws -> NSPersistentContainer {
        let container = NSPersistentContainer(name: "DataModel", managedObjectModel: model)
        let description = NSPersistentStoreDescription(url: url)
        description.type = NSSQLiteStoreType
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        container.persistentStoreDescriptions = [description]
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            container.loadPersistentStores { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        return container
    }

    private static func close(_ container: NSPersistentContainer) throws {
        container.viewContext.reset()
        for store in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(store)
        }
    }

    private static func storedVersion(in coordinator: NSPersistentStoreCoordinator) throws -> Int {
        guard let store = coordinator.persistentStores.first else { return 0 }
        let value = coordinator.metadata(for: store)[BookmarkFavoritesMigration.versionMetadataKey]
        if let number = value as? NSNumber { return number.intValue }
        if let integer = value as? Int { return integer }
        return 0
    }

    private static func leaveCommittedWALProbe(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else { throw RegressionFailure("could not open restore target to stage WAL writes") }
        defer { sqlite3_close(database) }
        try executeSQLite("PRAGMA journal_mode=WAL", database: database)
        try executeSQLite("CREATE TABLE W5_RESTORE_PROBE (value TEXT)", database: database)
        try executeSQLite("INSERT INTO W5_RESTORE_PROBE VALUES ('must not replay')", database: database)
        var persistentWAL: Int32 = 1
        guard sqlite3_file_control(database, "main", SQLITE_FCNTL_PERSIST_WAL, &persistentWAL) == SQLITE_OK else {
            throw RegressionFailure("SQLite could not preserve the committed WAL fixture")
        }
    }

    private static func executeSQLite(_ sql: String, at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else { throw RegressionFailure("could not open SQLite regression fixture") }
        defer { sqlite3_close(database) }
        try executeSQLite(sql, database: database)
    }

    private static func executeSQLite(_ sql: String, database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw RegressionFailure("SQLite fixture statement failed: \(message)")
        }
        sqlite3_free(errorMessage)
    }

    private static func sqliteTableExists(_ name: String, at url: URL) throws -> Bool {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else { throw RegressionFailure("could not inspect restored SQLite store") }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database,
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1", -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw RegressionFailure("could not query restored SQLite store") }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = name.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw RegressionFailure(message) }
    }

    private struct RegressionFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
