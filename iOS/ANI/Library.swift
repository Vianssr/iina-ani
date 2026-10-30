import Foundation
import Observation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct CachedCatalogDetail: Codable {
    let anime: Anime
    let fetchedAt: Date
}

struct CachedCatalogEpisodes: Codable {
    let episodes: [CatalogEpisode]
    let fetchedAt: Date
}

@MainActor @Observable
final class MobileLibrary {
    private(set) var favorites: [Anime] = []
    var storageError = false
    private(set) var isReadable = false
    private(set) var cacheError = false
    /// Set only by the validated account session. Never persisted as a credential.
    var activeCollectionAccountID: Int?
    private let legacyFile: URL
    private let file: URL
    private let cacheDirectory: URL
    private var document = LibraryDocument()
    private var authorityBytes: Data?

    /// `file` remains the legacy location; only the separate versioned file is authoritative after migration.
    init(file: URL = URL.applicationSupportDirectory.appendingPathComponent("ANI/favorites.json"),
         libraryFile: URL? = nil, cacheDirectory: URL? = nil) {
        legacyFile = file
        self.file = libraryFile ?? file.deletingLastPathComponent().appendingPathComponent("library.json")
        self.cacheDirectory = cacheDirectory ?? file.deletingLastPathComponent().appendingPathComponent("CatalogCache", isDirectory: true)
        retryLoad()
    }

    func retryLoad() {
        do {
            let loaded: LibraryDocument
            if let bytes = try Self.readIfPresent(file) {
                authorityBytes = bytes
                // Never fall back to legacy data when the authority exists but is unreadable or newer.
                loaded = try Self.decodeDocument(bytes)
                let version = try JSONDecoder().decode(Version.self, from: bytes).version
                if version < 3 {
                    try preserve(bytes, at: file.appendingPathExtension("v\(version).backup"))
                    try activate(loaded)
                }
            } else if let bytes = try Self.readIfPresent(legacyFile) {
                authorityBytes = nil
                try preserveLegacy(bytes)
                let legacy = try JSONDecoder().decode([Anime].self, from: bytes)
                var migrated = LibraryDocument()
                migrated.favorites = legacy
                var seen = Set<Int>()
                migrated.works = legacy.compactMap { anime in
                    guard seen.insert(anime.id).inserted else { return nil }
                    return StoredWork(subjectID: anime.id, createdAt: nil, status: nil)
                }
                try Self.validate(migrated)
                try activate(migrated)
                loaded = migrated
            } else {
                authorityBytes = nil
                loaded = LibraryDocument()
            }
            document = loaded
            favorites = loaded.favorites
            isReadable = true
            storageError = false
        } catch {
            // Retain the last readable presentation, but block all authoritative writes until retry succeeds.
            isReadable = false
            storageError = true
        }
    }

    func contains(_ anime: Anime) -> Bool { favorites.contains { $0.id == anime.id } }

    func status(for subjectID: Int) -> BangumiCollectionStatus? {
        document.works.first { $0.subjectID == subjectID }?.status
    }

    func toggle(_ anime: Anime) {
        guard isReadable else { storageError = true; return }
        var updated = document
        updated.favorites.removeAll { $0.id == anime.id }
        if let index = updated.works.firstIndex(where: { $0.subjectID == anime.id }) {
            updated.works[index].favoriteRevision = UUID()
        }
        if !contains(anime) { updated.favorites.insert(anime, at: 0) }
        if !updated.works.contains(where: { $0.subjectID == anime.id }) {
            updated.works.append(StoredWork(subjectID: anime.id, createdAt: .now, status: nil))
        }
        commit(updated)
    }

    func setStatus(_ status: BangumiCollectionStatus?, for anime: Anime) {
        guard isReadable else { storageError = true; return }
        var updated = document
        let revision = UUID()
        if let index = updated.works.firstIndex(where: { $0.subjectID == anime.id }) {
            updated.works[index].status = status
            updated.works[index].classificationRevision = revision
            updated.works[index].localClassificationEdit = true
        } else {
            updated.works.append(StoredWork(subjectID: anime.id, createdAt: .now, status: status,
                                          classificationRevision: revision, localClassificationEdit: true))
        }
        // Clearing a category is strictly local, not a remote deletion.
        updated.pendingCollections.removeAll {
            $0.subjectID == anime.id && ($0.accountID == activeCollectionAccountID || $0.accountID == nil)
        }
        if let status {
            updated.pendingCollections.append(MobileCollectionOperation(subjectID: anime.id, status: status,
                revision: revision, accountID: activeCollectionAccountID))
        }
        commit(updated)
    }


    func hasPendingCollectionChange(for subjectID: Int) -> Bool {
        document.pendingCollections.contains { $0.subjectID == subjectID }
    }

    func pendingCollections(for accountID: Int) -> [MobileCollectionOperation] {
        document.pendingCollections.filter { $0.accountID == accountID }
    }

    var unassignedCollectionCount: Int { document.pendingCollections.filter { $0.accountID == nil }.count }

    /// Explicit consent is required before anonymous edits become an account's commands.
    func assignUnassignedCollections(to accountID: Int) throws {
        guard accountID > 0, activeCollectionAccountID == accountID else { throw StorageFailure.invalidData }
        try mutateDocument { value in
            let unassigned = value.pendingCollections.filter { $0.accountID == nil }
            value.pendingCollections.removeAll { $0.accountID == nil }
            for operation in unassigned {
                // The current anonymous command supersedes an older command for this account.
                value.pendingCollections.removeAll { $0.accountID == accountID && $0.subjectID == operation.subjectID }
                value.pendingCollections.append(MobileCollectionOperation(subjectID: operation.subjectID,
                    status: operation.status, revision: operation.revision, accountID: accountID))
            }
        }
    }

    func acknowledgeCollection(_ operation: MobileCollectionOperation) throws {
        guard activeCollectionAccountID == operation.accountID else { throw StorageFailure.invalidData }
        try mutateDocument { value in
            guard value.pendingCollections.contains(operation) else { return }
            value.pendingCollections.removeAll { $0 == operation }
            if let index = value.works.firstIndex(where: { $0.subjectID == operation.subjectID }),
               value.works[index].classificationRevision == operation.revision {
                value.works[index].localClassificationEdit = false
                value.works[index].classificationRevision = UUID()
            }
        }
    }

    struct CollectionImportSnapshot {
        fileprivate let revisions: [Int: UUID]
        fileprivate let favoriteRevisions: [Int: UUID]
    }

    func collectionImportSnapshot() -> CollectionImportSnapshot {
        CollectionImportSnapshot(revisions: Dictionary(uniqueKeysWithValues:
            document.works.map { ($0.subjectID, $0.classificationRevision) }),
            favoriteRevisions: Dictionary(uniqueKeysWithValues: document.works.map { ($0.subjectID, $0.favoriteRevision) }))
    }

    /// One atomic merge after every page succeeds; remote absence never removes local data.
    func importCollections(_ records: [MobileRemoteCollection], snapshot: CollectionImportSnapshot,
                           accountID: Int) throws {
        guard activeCollectionAccountID == accountID else { throw StorageFailure.invalidData }
        try mutateDocument { value in
            var seen = Set<Int>()
            for record in records where seen.insert(record.anime.id).inserted {
                guard record.anime.id > 0 else { throw StorageFailure.invalidData }
                if let index = value.works.firstIndex(where: { $0.subjectID == record.anime.id }) {
                    if snapshot.revisions[record.anime.id] == value.works[index].classificationRevision,
                       !value.works[index].localClassificationEdit,
                       !value.pendingCollections.contains(where: { $0.subjectID == record.anime.id }) {
                        value.works[index].status = record.status
                        value.works[index].classificationRevision = UUID()
                    }
                    // A favorite removed (or added then removed) during the request stays removed.
                    if snapshot.favoriteRevisions[record.anime.id] != value.works[index].favoriteRevision { continue }
                } else {
                    value.works.append(StoredWork(subjectID: record.anime.id, createdAt: .now, status: record.status))
                }
                if !value.favorites.contains(where: { $0.id == record.anime.id }) {
                    value.favorites.append(record.anime)
                }
            }
        }
    }

    private func mutateDocument(_ mutation: (inout LibraryDocument) throws -> Void) throws {
        do {
            guard isReadable else { throw StorageFailure.unreadable }
            var updated = document
            try mutation(&updated)
            try Self.validate(updated)
            try activate(updated)
            document = updated
            favorites = updated.favorites
            storageError = false
        } catch {
            storageError = true
            throw error
        }
    }
    func mapping(for work: PlaybackWorkIdentity, episode: PlaybackEpisodeIdentity) -> ConfirmedSourceMapping? {
        storedMapping(for: work, episode: episode).flatMap { $0.matches(work: work, episode: episode) ? $0 : nil }
    }

    /// Same stable episode ID with changed raw metadata is stale, not an absent mapping.
    func storedMapping(for work: PlaybackWorkIdentity, episode: PlaybackEpisodeIdentity) -> ConfirmedSourceMapping? {
        document.mappings.first { $0.mapping.context.work == work && $0.mapping.context.episode.localID == episode.localID }?.mapping
    }

    func mappingFailure(for work: PlaybackWorkIdentity, episode: PlaybackEpisodeIdentity) -> PlaybackFailure? {
        document.mappings.first { $0.mapping.context.work == work && $0.mapping.context.episode.localID == episode.localID }?.failure
    }

    func saveMapping(_ mapping: ConfirmedSourceMapping) throws {
        try mutateMappings { updated in
            try mapping.validateForPersistence()
            updated.mappings.removeAll {
                $0.mapping.context.work == mapping.context.work &&
                    $0.mapping.context.episode.localID == mapping.context.episode.localID
            }
            updated.mappings.append(StoredMapping(mapping: mapping, failure: nil))
        }
    }

    func removeMapping(for work: PlaybackWorkIdentity, episode: PlaybackEpisodeIdentity) throws {
        try mutateMappings { updated in
            updated.mappings.removeAll { $0.mapping.context.work == work && $0.mapping.context.episode.localID == episode.localID }
        }
    }

    func invalidateMapping(for work: PlaybackWorkIdentity, episode: PlaybackEpisodeIdentity, failure: PlaybackFailure) throws {
        try mutateMappings { updated in
            guard [.missingEpisode, .configurationChanged].contains(failure),
                  let index = updated.mappings.firstIndex(where: {
                      $0.mapping.context.work == work && $0.mapping.context.episode.localID == episode.localID
                  }) else { throw StorageFailure.invalidData }
            updated.mappings[index].failure = failure
        }
    }

    private func mutateMappings(_ mutation: (inout LibraryDocument) throws -> Void) throws {
        do {
            guard isReadable else { throw StorageFailure.unreadable }
            var updated = document
            try mutation(&updated)
            try Self.validate(updated)
            try activate(updated)
            document = updated
            storageError = false
        } catch {
            storageError = true
            throw error
        }
    }

    private func commit(_ updated: LibraryDocument) {
        do {
            try Self.validate(updated)
            try activate(updated)
            document = updated
            favorites = updated.favorites
            storageError = false
        } catch { storageError = true }
    }

    private func preserveLegacy(_ bytes: Data) throws {
        try preserve(bytes, at: legacyFile.appendingPathExtension("backup"))
    }

    private func preserve(_ bytes: Data, at backup: URL) throws {
        if let existing = try Self.readIfPresent(backup) {
            if existing == bytes { return }
            // A user-repaired legacy file must not destroy an earlier backup.
            let additional = backup.appendingPathExtension(UUID().uuidString)
            try bytes.write(to: additional, options: .withoutOverwriting)
            guard try Data(contentsOf: additional) == bytes else { throw StorageFailure.invalidData }
        } else {
            try bytes.write(to: backup, options: .withoutOverwriting)
            guard try Data(contentsOf: backup) == bytes else { throw StorageFailure.invalidData }
        }
    }

    private func activate(_ updated: LibraryDocument) throws {
        guard try Self.readIfPresent(file) == authorityBytes else {
            isReadable = false
            throw StorageFailure.unreadable
        }
        let manager = FileManager.default
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = file.appendingPathExtension("staged")
        let bytes = try JSONEncoder().encode(updated)
        try bytes.write(to: staged, options: .atomic)
        let stagedBytes = try Data(contentsOf: staged)
        guard stagedBytes == bytes else { throw StorageFailure.invalidData }
        _ = try Self.decodeDocument(stagedBytes)
        // Same-directory rename atomically activates exactly the bytes that were verified above.
        guard rename(staged.path, file.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        authorityBytes = bytes
    }

    private static func readIfPresent(_ url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) {
                return nil
            }
            throw error
        }
    }

    private static func decodeDocument(_ bytes: Data) throws -> LibraryDocument {
        let decoder = JSONDecoder()
        let version = try decoder.decode(Version.self, from: bytes).version
        let value: LibraryDocument
        switch version {
        case 1, 2:
            let original = try decoder.decode(LegacyLibraryDocument.self, from: bytes)
            guard (version == 1 || original.mappings != nil),
                  original.works.allSatisfy({ $0.id == "bangumi:\($0.subjectID)" }) else {
                throw StorageFailure.invalidData
            }
            var migrated = LibraryDocument()
            migrated.favorites = original.favorites
            migrated.works = original.works.map {
                StoredWork(subjectID: $0.subjectID, createdAt: $0.createdAt, status: $0.status,
                           localClassificationEdit: true)
            }
            migrated.mappings = original.mappings ?? []
            // Pre-account classifications stay local until the user explicitly assigns them.
            migrated.pendingCollections = migrated.works.compactMap { work in
                work.status.map { MobileCollectionOperation(subjectID: work.subjectID, status: $0,
                    revision: work.classificationRevision, accountID: nil) }
            }
            value = migrated
        case 3:
            value = try decoder.decode(LibraryDocument.self, from: bytes)
        default:
            throw StorageFailure.unsupportedVersion
        }
        try validate(value)
        return value
    }

    private static func validate(_ value: LibraryDocument) throws {
        guard value.version == 3 else { throw StorageFailure.unsupportedVersion }
        var subjects = Set<Int>()
        for work in value.works {
            guard work.subjectID > 0, work.id == "bangumi:\(work.subjectID)",
                  subjects.insert(work.subjectID).inserted,
                  work.createdAt.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true else {
                throw StorageFailure.invalidData
            }
        }
        guard value.favorites.allSatisfy({ $0.id > 0 && subjects.contains($0.id) }) else { throw StorageFailure.invalidData }
        var mappingKeys = Set<MappingKey>()
        for entry in value.mappings {
            try entry.mapping.validateForPersistence()
            let context = entry.mapping.context
            guard mappingKeys.insert(MappingKey(work: context.work, episodeID: context.episode.localID)).inserted,
                  entry.failure.map({ [.missingEpisode, .configurationChanged].contains($0) }) ?? true else {
                throw StorageFailure.invalidData
            }
        }
        var operationKeys = Set<String>()
        for operation in value.pendingCollections {
            guard subjects.contains(operation.subjectID),
                  operation.accountID.map({ $0 > 0 }) ?? true,
                  operationKeys.insert("\(operation.accountID.map(String.init) ?? "unassigned"):\(operation.subjectID)").inserted else {
                throw StorageFailure.invalidData
            }
        }
    }

    private struct Version: Decodable { let version: Int }
    private struct LibraryDocument: Codable {
        var version = 3
        // Keep snapshots in their original order, including any legacy duplicates and exact cached text.
        var favorites: [Anime] = []
        var works: [StoredWork] = []
        var mappings: [StoredMapping] = []
        var pendingCollections: [MobileCollectionOperation] = []
    }
    private struct LegacyLibraryDocument: Decodable {
        let version: Int
        let favorites: [Anime]
        let works: [LegacyStoredWork]
        let mappings: [StoredMapping]?
    }
    private struct LegacyStoredWork: Decodable {
        let id: String
        let subjectID: Int
        let createdAt: Date?
        let status: BangumiCollectionStatus?
    }
    private struct StoredMapping: Codable {
        let mapping: ConfirmedSourceMapping
        var failure: PlaybackFailure?
    }
    private struct MappingKey: Hashable {
        let work: PlaybackWorkIdentity
        let episodeID: String
    }
    private struct StoredWork: Codable {
        let id: String
        let subjectID: Int
        let createdAt: Date?
        var status: BangumiCollectionStatus?
        var classificationRevision: UUID
        var localClassificationEdit: Bool
        var favoriteRevision: UUID

        init(subjectID: Int, createdAt: Date?, status: BangumiCollectionStatus?,
             classificationRevision: UUID = UUID(), localClassificationEdit: Bool = false) {
            id = "bangumi:\(subjectID)"
            self.subjectID = subjectID
            self.createdAt = createdAt
            self.status = status
            self.classificationRevision = classificationRevision
            self.localClassificationEdit = localClassificationEdit
            favoriteRevision = UUID()
        }
    }

    private enum StorageFailure: Error { case unsupportedVersion, invalidData, unreadable }

    private struct CacheEntry<Value: Codable>: Codable {
        let version: Int
        let subjectID: Int
        let value: Value
    }

    func cachedDetail(for subjectID: Int) -> CachedCatalogDetail? {
        guard let entry: CachedCatalogDetail = readCache("detail", for: subjectID) else { return nil }
        guard entry.anime.id == subjectID, entry.fetchedAt.timeIntervalSinceReferenceDate.isFinite else {
            cacheError = true
            return nil
        }
        return entry
    }

    func cachedEpisodes(for subjectID: Int) -> CachedCatalogEpisodes? {
        guard let entry: CachedCatalogEpisodes = readCache("episodes", for: subjectID) else { return nil }
        guard Self.validEpisodes(entry.episodes), entry.fetchedAt.timeIntervalSinceReferenceDate.isFinite else {
            cacheError = true
            return nil
        }
        return entry
    }

    func cacheDetail(_ anime: Anime, fetchedAt: Date = .now) {
        guard anime.id > 0, fetchedAt.timeIntervalSinceReferenceDate.isFinite else { cacheError = true; return }
        writeCache(CachedCatalogDetail(anime: anime, fetchedAt: fetchedAt), kind: "detail", for: anime.id)
    }

    func cacheEpisodes(_ episodes: [CatalogEpisode], for subjectID: Int, fetchedAt: Date = .now) {
        guard subjectID > 0, Self.validEpisodes(episodes), fetchedAt.timeIntervalSinceReferenceDate.isFinite else {
            cacheError = true
            return
        }
        writeCache(CachedCatalogEpisodes(episodes: episodes, fetchedAt: fetchedAt), kind: "episodes", for: subjectID)
    }

    private static func validEpisodes(_ episodes: [CatalogEpisode]) -> Bool {
        var seen = Set<Int>()
        return episodes.allSatisfy {
            $0.id > 0 && $0.type >= 0 && $0.sort.isFinite && $0.sort >= 0 &&
            ($0.ep.map { $0.isFinite && $0 >= 0 } ?? true) && seen.insert($0.id).inserted
        }
    }

    private func cacheFile(_ kind: String, for subjectID: Int) -> URL {
        cacheDirectory.appendingPathComponent("\(subjectID).\(kind).json")
    }

    private func readCache<Value: Codable>(_ kind: String, for subjectID: Int) -> Value? {
        guard subjectID > 0 else { cacheError = true; return nil }
        do {
            guard let bytes = try Self.readIfPresent(cacheFile(kind, for: subjectID)) else { return nil }
            let entry = try JSONDecoder().decode(CacheEntry<Value>.self, from: bytes)
            guard entry.version == 1, entry.subjectID == subjectID else { throw StorageFailure.invalidData }
            return entry.value
        } catch { cacheError = true; return nil }
    }

    private func writeCache<Value: Codable>(_ value: Value, kind: String, for subjectID: Int) {
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            let bytes = try JSONEncoder().encode(CacheEntry(version: 1, subjectID: subjectID, value: value))
            try bytes.write(to: cacheFile(kind, for: subjectID), options: .atomic)
            cacheError = false
        } catch { cacheError = true }
    }
}

/// Presentation order never rewrites the saved insertion order.
enum FavoriteSort: Hashable { case recent, title, rating }

extension MobileLibrary {
    func matching(_ query: String, sort: FavoriteSort, filter: CollectionStatusFilter = .all) -> [Anime] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = favorites.filter {
            filter.matches(status(for: $0.id)) &&
            (keyword.isEmpty || $0.title.localizedStandardContains(keyword) || $0.name.localizedStandardContains(keyword))
        }
        switch sort {
        case .recent: return matches
        case .title:
            return matches.sorted {
                let order = $0.title.localizedStandardCompare($1.title)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
        case .rating:
            return matches.sorted {
                let lhs = $0.rating?.score ?? -1
                let rhs = $1.rating?.score ?? -1
                return lhs == rhs ? $0.id < $1.id : lhs > rhs
            }
        }
    }
}
