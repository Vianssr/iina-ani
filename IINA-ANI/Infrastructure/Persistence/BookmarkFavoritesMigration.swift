@preconcurrency import CoreData
import Darwin
import Foundation
import SQLite3

/// Converts legacy Bookmark rows in place while retaining the original rows as link favorites.
enum BookmarkFavoritesMigration {
    static let versionMetadataKey = "IINA.BookmarkFavoritesMigration.version"

    private static let currentVersion = 1
    private static let backupDirectorySuffix = ".w5-backup"
    private static let backupFilename = "backup.sqlite"

    private enum MigrationError: Error, LocalizedError {
        case noSQLiteStore
        case missingAttribute(String)
        case invalidVersionMetadata
        case sqlite(String)
        case invalidBackup(URL)
        case backupAlreadyExists(URL)
        case restoreRequiresClosedStore(URL)
        case cannotReplace(URL, Int32)

        var errorDescription: String? {
            switch self {
            case .noSQLiteStore:
                return String(localized: "Bookmark favorites migration requires a loaded SQLite persistent store.")
            case .missingAttribute(let name):
                return String(localized: "The loaded Bookmark entity is missing the \(name) migration attribute.")
            case .invalidVersionMetadata:
                return String(localized: "Bookmark favorites migration version metadata is invalid.")
            case .sqlite(let message):
                return String(localized: "SQLite backup/restore failed: \(message)")
            case .invalidBackup(let url):
                return String(localized: "The Bookmark migration backup is not a valid Core Data SQLite store: \(url.path)")
            case .backupAlreadyExists(let url):
                return String(localized: "An existing Bookmark migration backup is incomplete or invalid and was left untouched: \(url.path)")
            case .restoreRequiresClosedStore(let url):
                return String(localized: "Close the application and every coordinator using \(url.path) before restoring its backup.")
            case .cannotReplace(let url, let code):
                return String(localized: "Could not atomically restore the Core Data store at \(url.path) (errno \(code)).")
            }
        }
    }

    /// Makes a consistent, adjacent SQLite backup before Core Data is allowed to migrate the store.
    /// A completed backup is never replaced on a retry.
    static func prepareBackup(storeURL: URL) throws -> URL? {
        try prepareBackup(storeURL: storeURL, versionMetadataKey: versionMetadataKey,
                          currentVersion: currentVersion, backupDirectorySuffix: backupDirectorySuffix)
    }

    fileprivate static func prepareBackup(storeURL: URL, versionMetadataKey: String,
                                          currentVersion: Int, backupDirectorySuffix: String) throws -> URL? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: storeURL.path) else { return nil }

        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType,
                                                                                    at: storeURL)
        if try migrationVersion(in: metadata, key: versionMetadataKey) >= currentVersion { return nil }

        let backupDirectory = storeURL.deletingLastPathComponent()
            .appendingPathComponent(storeURL.lastPathComponent + backupDirectorySuffix, isDirectory: true)
        let backupURL = backupDirectory.appendingPathComponent(backupFilename, isDirectory: false)
        if fileManager.fileExists(atPath: backupDirectory.path) {
            guard fileManager.fileExists(atPath: backupURL.path), isValidStore(at: backupURL) else {
                throw MigrationError.backupAlreadyExists(backupDirectory)
            }
            return backupURL
        }

        let stagingDirectory = storeURL.deletingLastPathComponent()
            .appendingPathComponent(".\(storeURL.lastPathComponent)\(backupDirectorySuffix)-\(UUID().uuidString).tmp",
                                   isDirectory: true)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: stagingDirectory) }

        let stagedBackupURL = stagingDirectory.appendingPathComponent(backupFilename, isDirectory: false)
        try copySQLiteStore(from: storeURL, to: stagedBackupURL)
        guard isValidStore(at: stagedBackupURL) else { throw MigrationError.invalidBackup(stagedBackupURL) }

        do {
            try fileManager.moveItem(at: stagingDirectory, to: backupDirectory)
            return backupURL
        } catch {
            // A concurrent startup may have installed the same fixed backup first. Reuse it only
            // after validation; never replace a pre-existing backup, even when it is invalid.
            if fileManager.fileExists(atPath: backupURL.path), isValidStore(at: backupURL) {
                return backupURL
            }
            throw error
        }
    }

    /// Fills favorite identity columns in one private-context transaction on the loaded coordinator.
    /// Legacy rows are never merged or deleted, including duplicate canonical URLs.
    static func migrate(container: NSPersistentContainer,
                        normalizer: @Sendable (String) throws -> SourceItemRef = { try SourceRegistry.shared.favoriteItem(for: $0) }) throws {
        let coordinator = container.persistentStoreCoordinator
        guard let store = coordinator.persistentStores.first(where: { $0.type == NSSQLiteStoreType }) else {
            throw MigrationError.noSQLiteStore
        }
        let metadata = coordinator.metadata(for: store)
        guard try migrationVersion(in: metadata) < currentVersion else { return }

        guard let entity = coordinator.managedObjectModel.entitiesByName["Bookmark"] else {
            throw MigrationError.missingAttribute("Bookmark")
        }
        for attribute in ["favoriteID", "originalURL", "canonicalURL", "sourceID", "favoriteTitle", "createdAt"] {
            guard entity.attributesByName[attribute] != nil else { throw MigrationError.missingAttribute(attribute) }
        }

        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        try context.performAndWait {
            do {
                let request = NSFetchRequest<NSManagedObject>(entityName: "Bookmark")
                let importedAt = Date()
                for bookmark in try context.fetch(request) {
                    let url = bookmark.value(forKey: "url") as? String ?? ""
                    if bookmark.value(forKey: "favoriteID") == nil { bookmark.setValue(UUID(), forKey: "favoriteID") }
                    if bookmark.value(forKey: "originalURL") == nil { bookmark.setValue(url, forKey: "originalURL") }
                    if bookmark.value(forKey: "favoriteTitle") == nil {
                        let remark = bookmark.value(forKey: "remark") as? String
                        let title = bookmark.value(forKey: "liveTitle") as? String
                        bookmark.setValue(nonempty(remark) ?? nonempty(title) ?? url, forKey: "favoriteTitle")
                    }
                    if bookmark.value(forKey: "createdAt") == nil { bookmark.setValue(importedAt, forKey: "createdAt") }
                    if bookmark.value(forKey: "canonicalURL") == nil || bookmark.value(forKey: "sourceID") == nil {
                        let item = try normalizer(url)
                        if bookmark.value(forKey: "canonicalURL") == nil { bookmark.setValue(item.pageURL, forKey: "canonicalURL") }
                        if bookmark.value(forKey: "sourceID") == nil { bookmark.setValue(item.sourceID, forKey: "sourceID") }
                    }
                }
                try context.save()
            } catch {
                context.rollback()
                throw error
            }
        }

        var updatedMetadata = metadata
        updatedMetadata[versionMetadataKey] = currentVersion
        coordinator.setMetadata(updatedMetadata, for: store)
        let storeIdentifier = store.identifier
        do {
            // setMetadata only stages values for the next store save. An explicit empty
            // save request persists the completion marker even when there are no bookmarks.
            try context.performAndWait {
                let request = NSSaveChangesRequest(inserted: nil, updated: nil, deleted: nil, locked: nil)
                guard let target = coordinator.persistentStores.first(where: { $0.identifier == storeIdentifier }) else {
                    throw MigrationError.noSQLiteStore
                }
                request.affectedStores = [target]
                _ = try coordinator.execute(request, with: context)
            }
        } catch {
            coordinator.setMetadata(metadata, for: store)
            throw error
        }
    }

    /// Restores an immutable backup atomically. Call only after closing the application and all
    /// persistent-store coordinators; an exclusive SQLite lock is also required where available.
    static func restoreBackup(at backupURL: URL, to storeURL: URL) throws {
        guard backupURL.standardizedFileURL != storeURL.standardizedFileURL else {
            throw MigrationError.invalidBackup(backupURL)
        }
        guard isValidStore(at: backupURL) else { throw MigrationError.invalidBackup(backupURL) }

        let fileManager = FileManager.default
        let parent = storeURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let stageURL = parent.appendingPathComponent(".\(storeURL.lastPathComponent).restore-\(UUID().uuidString).sqlite")
        defer { try? fileManager.removeItem(at: stageURL) }

        try copySQLiteStore(from: backupURL, to: stageURL)
        guard isValidStore(at: stageURL) else { throw MigrationError.invalidBackup(stageURL) }

        if fileManager.fileExists(atPath: storeURL.path) {
            try requireExclusiveClosedStore(at: storeURL)
        }

        // WAL data was checkpointed while acquiring the exclusive lock. Removing its now-obsolete
        // sidecars before the atomic replacement prevents them from being replayed against backup.sqlite.
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = URL(fileURLWithPath: storeURL.path + suffix)
            if fileManager.fileExists(atPath: sidecar.path) { try fileManager.removeItem(at: sidecar) }
        }

        let result = stageURL.path.withCString { source in
            storeURL.path.withCString { destination in Darwin.rename(source, destination) }
        }
        guard result == 0 else { throw MigrationError.cannotReplace(storeURL, errno) }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    fileprivate static func migrationVersion(in metadata: [String: Any], key: String = versionMetadataKey) throws -> Int {
        guard let stored = metadata[key] else { return 0 }
        if let number = stored as? NSNumber { return number.intValue }
        if let version = stored as? Int { return version }
        throw MigrationError.invalidVersionMetadata
    }

    private static func isValidStore(at url: URL) -> Bool {
        do {
            try validateSQLite(at: url)
            _ = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: url)
            return true
        } catch {
            return false
        }
    }

    private static func validateSQLite(at url: URL) throws {
        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard openResult == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 returned \(openResult)"
            if let database { sqlite3_close(database) }
            throw MigrationError.sqlite(message)
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, "PRAGMA quick_check", -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            throw MigrationError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        var sawOK = false
        while true {
            let stepResult = sqlite3_step(statement)
            if stepResult == SQLITE_DONE { break }
            guard stepResult == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
                throw MigrationError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
            guard String(cString: text) == "ok", !sawOK else {
                throw MigrationError.sqlite("PRAGMA quick_check did not return a single ok row")
            }
            sawOK = true
        }
        guard sawOK else { throw MigrationError.sqlite("PRAGMA quick_check returned no result") }

        var metadataStatement: OpaquePointer?
        let metadataResult = sqlite3_prepare_v2(database,
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'Z_METADATA' LIMIT 1", -1,
            &metadataStatement, nil)
        guard metadataResult == SQLITE_OK, let metadataStatement else {
            throw MigrationError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(metadataStatement) }
        guard sqlite3_step(metadataStatement) == SQLITE_ROW else {
            throw MigrationError.sqlite("Core Data Z_METADATA table is missing")
        }
    }

    private static func copySQLiteStore(from sourceURL: URL, to destinationURL: URL) throws {
        var source: OpaquePointer?
        let sourceResult = sqlite3_open_v2(sourceURL.path, &source, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard sourceResult == SQLITE_OK, let source else {
            let message = source.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 returned \(sourceResult)"
            if let source { sqlite3_close(source) }
            throw MigrationError.sqlite(message)
        }
        defer { sqlite3_close(source) }

        var destination: OpaquePointer?
        let destinationResult = sqlite3_open_v2(destinationURL.path, &destination,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard destinationResult == SQLITE_OK, let destination else {
            let message = destination.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 returned \(destinationResult)"
            if let destination { sqlite3_close(destination) }
            throw MigrationError.sqlite(message)
        }
        defer { sqlite3_close(destination) }

        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw MigrationError.sqlite(String(cString: sqlite3_errmsg(destination)))
        }
        let stepResult = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
            throw MigrationError.sqlite(String(cString: sqlite3_errmsg(destination)))
        }
        // A WAL source copies WAL header flags too. The immutable backup must be readable
        // as a single file, without creating missing WAL/SHM sidecars on a read-only open.
        guard sqlite3_exec(destination, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else {
            throw MigrationError.sqlite(String(cString: sqlite3_errmsg(destination)))
        }
    }

    private static func requireExclusiveClosedStore(at url: URL) throws {
        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard openResult == SQLITE_OK, let database else {

            if let database { sqlite3_close(database) }
            throw MigrationError.restoreRequiresClosedStore(url)
        }
        defer { sqlite3_close(database) }

        guard sqlite3_exec(database, "PRAGMA locking_mode=EXCLUSIVE", nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(database, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            throw MigrationError.restoreRequiresClosedStore(url)
        }

        let journalMode = try sqliteTextValue(database, query: "PRAGMA journal_mode")
        if journalMode.lowercased() == "wal" {
            var logFrames: Int32 = 0
            var checkpointedFrames: Int32 = 0
            let checkpointResult = sqlite3_wal_checkpoint_v2(database, "main", SQLITE_CHECKPOINT_TRUNCATE,
                                                            &logFrames, &checkpointedFrames)
            guard checkpointResult == SQLITE_OK else { throw MigrationError.restoreRequiresClosedStore(url) }
        }
    }

    private static func sqliteTextValue(_ database: OpaquePointer, query: String) throws -> String {
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(database, query, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            throw MigrationError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else {
            throw MigrationError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        return String(cString: value)
    }
}

/// R3 evolves the versioned JSON payload, not source identity or the Core Data entity schema.
enum WorkClassificationMigration {
    static let versionMetadataKey = "IINA.WorkClassificationMigration.version"
    private static let currentVersion = 1

    static func prepareBackup(storeURL: URL) throws -> URL? {
        try BookmarkFavoritesMigration.prepareBackup(storeURL: storeURL, versionMetadataKey: versionMetadataKey,
                                                     currentVersion: currentVersion, backupDirectorySuffix: ".r3-backup")
    }

    static func migrate(container: NSPersistentContainer) throws {
        let coordinator = container.persistentStoreCoordinator
        guard let store = coordinator.persistentStores.first(where: { $0.type == NSSQLiteStoreType }),
              let storeURL = store.url else { throw WorkLibrary.LibraryError.corruptStoredPayload }
        let metadata = coordinator.metadata(for: store)
        guard try BookmarkFavoritesMigration.migrationVersion(in: metadata, key: versionMetadataKey) < currentVersion else { return }
        // Direct callers receive the same immutable safety copy as application startup.
        _ = try prepareBackup(storeURL: storeURL)
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        try context.performAndWait {
            do {
                let request = NSFetchRequest<NSManagedObject>(entityName: "WorkRecord")
                for record in try context.fetch(request) {
                    guard let data = record.value(forKey: "payload") as? Data,
                          var payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        throw WorkLibrary.LibraryError.corruptStoredPayload
                    }
                    // Decode before committing any migration; malformed old data is never replaced.
                    let work = try JSONDecoder().decode(Work.self, from: data)
                    if payload["classification"] == nil {
                        let classification = work.bangumiMetadata?.subject.classification ?? .unknown
                        payload["classification"] = ["kind": classification.kind.rawValue,
                                                     "provenance": classification.provenance]
                    }
                    if payload["classificationIsManual"] == nil { payload["classificationIsManual"] = false }
                    // Preserve every old key, including data owned by later payload versions.
                    record.setValue(try JSONSerialization.data(withJSONObject: payload), forKey: "payload")
                }
                var updatedMetadata = metadata
                updatedMetadata[versionMetadataKey] = currentVersion
                coordinator.setMetadata(updatedMetadata, for: store)
                let save = NSSaveChangesRequest(inserted: context.insertedObjects, updated: context.updatedObjects,
                                                deleted: nil, locked: nil)
                save.affectedStores = [store]
                _ = try coordinator.execute(save, with: context)
                context.reset()
            } catch {
                context.rollback()
                coordinator.setMetadata(metadata, for: store)
                throw error
            }
        }
    }
}
