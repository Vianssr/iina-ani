import CoreData
import Foundation

struct LinkFavorite: Hashable, Sendable {
    let id: UUID
    let originalURL: String
    let canonicalURL: String?
    let sourceID: String?
    let title: String
    let order: Double
    let createdAt: Date
}

enum FavoriteSort: Sendable {
    case manual
    case title
    case createdNewest
}

@MainActor
final class FavoriteLibrary {
    enum FavoriteError: Error, Equatable {

        case duplicateCanonicalLink(UUID)
        case linkNotFound(UUID)
        case favoriteWorkNotFound(UUID)
        case invalidBookmarkModel
    }

    private let context: NSManagedObjectContext
    private let normalizer: (String) throws -> SourceItemRef
    private let works: WorkLibrary

    /// Scope UI change observation to this library rather than every Core Data stack.
    var changeNotificationSource: AnyObject { context }

    init(context: NSManagedObjectContext, works: WorkLibrary,
         normalizer: @escaping (String) throws -> SourceItemRef = SourceRegistry.shared.favoriteItem(for:)) {
        self.context = context
        self.normalizer = normalizer
        self.works = works
    }

    convenience init(container: NSPersistentContainer,
                     normalizer: @escaping (String) throws -> SourceItemRef = SourceRegistry.shared.favoriteItem(for:)) {
        self.init(context: container.viewContext, works: WorkLibrary(context: container.viewContext), normalizer: normalizer)
    }

    @discardableResult
    func addLink(url: String, title: String? = nil) throws -> LinkFavorite {
        let item = try normalizer(url)
        try Self.requireSelectedTorrent(item)
        if let existing = try matchingLink(item) { return try snapshot(existing) }

        let order = try nextOrder(entity: "Bookmark")
        let now = Date()
        let record = try newRecord(entity: "Bookmark")
        let id = UUID()
        record.setValue(id, forKey: "favoriteID")
        record.setValue(item.sourceID == "torrent" ? item.pageURL : url, forKey: "originalURL")
        record.setValue(item.pageURL, forKey: "canonicalURL")
        record.setValue(item.sourceID, forKey: "sourceID")
        record.setValue(item.pageURL, forKey: "url")
        record.setValue(title, forKey: "favoriteTitle")
        // The existing AppKit row binds these non-optional cache fields before refresh.
        record.setValue(title ?? (item.sourceID == "torrent" ? item.pageURL : url), forKey: "liveTitle")
        record.setValue("", forKey: "liveName")
        record.setValue(Int16(0), forKey: "state")
        record.setValue(order, forKey: "order")
        record.setValue(now, forKey: "createdAt")
        do { try context.save() } catch { context.rollback(); throw error }
        return try snapshot(record)
    }

    /// Store the exact selected file, never a magnet containing tracker credentials.
    @discardableResult
    func addTorrent(selection: TorrentSelection, title: String? = nil) throws -> LinkFavorite {
        guard selection.isValid else { throw DownloadFailure.invalidSelection }
        return try addLink(url: selection.identityURL.absoluteString, title: title)
    }

    func torrentSelection(id: UUID) throws -> TorrentSelection {
        guard let record = try linkRecord(id: id),
              record.value(forKey: "sourceID") as? String == "torrent",
              let raw = record.value(forKey: "canonicalURL") as? String,
              let url = URL(string: raw), let selection = TorrentSelection(identityURL: url) else {
            throw DownloadFailure.invalidSelection
        }
        return selection
    }

    // AppKit also consumes these descriptors; UUID values do not support KVC comparison.
    static let manualLinkSortDescriptors = [NSSortDescriptor(key: "order", ascending: true)]

    func linkObjects() throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Bookmark")
        request.sortDescriptors = Self.manualLinkSortDescriptors
        return try context.fetch(request)
    }

    private func linkRecord(id: UUID) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Bookmark")
        request.predicate = NSPredicate(format: "favoriteID == %@", id as CVarArg)
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    private func matchingLink(_ item: SourceItemRef, excluding id: UUID? = nil) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: "Bookmark")
        let identity = NSPredicate(format: "sourceID == %@ AND canonicalURL == %@", item.sourceID, item.pageURL)
        if let id {
            request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [identity,
                NSPredicate(format: "favoriteID != %@", id as CVarArg)])
        } else { request.predicate = identity }
        request.sortDescriptors = Self.manualLinkSortDescriptors
        request.fetchLimit = 1
        return try context.fetch(request).first
    }
    func links(query: String = "", sort: FavoriteSort = .manual) throws -> [LinkFavorite] {
        var result = try linkObjects().map(snapshot)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty {
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(needle) ||
                $0.originalURL.localizedCaseInsensitiveContains(needle) ||
                ($0.canonicalURL?.localizedCaseInsensitiveContains(needle) ?? false) ||
                ($0.sourceID?.localizedCaseInsensitiveContains(needle) ?? false)
            }
        }
        switch sort {
        case .manual:
            break
        case .title:
            result.sort {
                let comparison = $0.title.localizedStandardCompare($1.title)
                return comparison == .orderedSame ? $0.id.uuidString < $1.id.uuidString : comparison == .orderedAscending
            }
        case .createdNewest:
            result.sort { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt }
        }
        return result
    }

    func deleteLink(id: UUID) throws {
        guard let record = try linkRecord(id: id) else { throw FavoriteError.linkNotFound(id) }
        context.delete(record)
        do { try context.save() } catch { context.rollback(); throw error }
    }

    func moveLink(id: UUID, toIndex: Int) throws {
        var records = try linkObjects()
        guard let old = records.firstIndex(where: { $0.value(forKey: "favoriteID") as? UUID == id }) else { throw FavoriteError.linkNotFound(id) }
        let record = records.remove(at: old)
        records.insert(record, at: min(max(0, toIndex), records.count))
        for (index, row) in records.enumerated() { row.setValue(Double(index), forKey: "order") }
        do { try context.save() } catch { context.rollback(); throw error }
    }

    @discardableResult
    func updateLink(id: UUID, url: String, title: String) throws -> LinkFavorite {
        guard let record = try linkRecord(id: id) else { throw FavoriteError.linkNotFound(id) }
        // Keep unavailable stored links editable when only their title changes.
        if url == (record.value(forKey: "originalURL") as? String) {
            record.setValue(title, forKey: "favoriteTitle")
            do { try context.save() } catch { context.rollback(); throw error }
            return try snapshot(record)
        }
        let normalized = try normalizer(url)
        try Self.requireSelectedTorrent(normalized)
        if let collision = try matchingLink(normalized, excluding: id) {
            guard let collisionID = collision.value(forKey: "favoriteID") as? UUID else { throw FavoriteError.invalidBookmarkModel }
            throw FavoriteError.duplicateCanonicalLink(collisionID)
        }
        record.setValue(normalized.sourceID == "torrent" ? normalized.pageURL : url, forKey: "originalURL")
        record.setValue(normalized.pageURL, forKey: "url")
        record.setValue(title, forKey: "favoriteTitle")
        record.setValue(normalized.pageURL, forKey: "canonicalURL")
        record.setValue(normalized.sourceID, forKey: "sourceID")
        do { try context.save() } catch { context.rollback(); throw error }
        return try snapshot(record)
    }

    func sources(workID: UUID) throws -> [WorkSourceLink] {
        try works.sourceLinks(forWorkID: workID)
    }

    func updateWork(workID: UUID, title: String, aliases: [String]) throws {
        guard var work = try works.fetchWork(id: workID) else {
            throw FavoriteError.favoriteWorkNotFound(workID)
        }
        work.title = title
        work.aliases = aliases
        work.updatedAt = .now
        do { try works.upsert(work) } catch { context.rollback(); throw error }
    }

    func addWork(workID: UUID) throws {
        guard try works.fetchWork(id: workID) != nil else { throw FavoriteError.favoriteWorkNotFound(workID) }
        if try favoriteWorkIDs().contains(workID) { return }
        let order = try nextOrder(entity: "WorkFavoriteRecord")
        let record = try newRecord(entity: "WorkFavoriteRecord")
        record.setValue(workID, forKey: "id")
        record.setValue(order, forKey: "order")
        record.setValue(Date(), forKey: "createdAt")
        do { try context.save() } catch { context.rollback(); throw error }
    }

    func removeWork(workID: UUID) throws {
        let request = NSFetchRequest<NSManagedObject>(entityName: "WorkFavoriteRecord")
        request.predicate = NSPredicate(format: "id == %@", workID as CVarArg)
        for row in try context.fetch(request) { context.delete(row) }
        do { try context.save() } catch { context.rollback(); throw error }
    }

    func works(query: String = "", sort: FavoriteSort = .manual) throws -> [Work] {
        var orderByID: [UUID: Double] = [:]
        var createdAtByID: [UUID: Date] = [:]
        for row in try workFavoriteRecords() {
            guard let id = row.value(forKey: "id") as? UUID, orderByID[id] == nil else { continue }
            orderByID[id] = row.value(forKey: "order") as? Double ?? 0
            createdAtByID[id] = row.value(forKey: "createdAt") as? Date ?? .distantPast
        }
        var favorites = try orderByID.keys.compactMap { try works.fetchWork(id: $0) }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty {
            favorites = favorites.filter { $0.title.localizedCaseInsensitiveContains(needle) ||
                $0.aliases.contains(where: { $0.localizedCaseInsensitiveContains(needle) }) }
        }
        switch sort {
        case .manual:
            favorites.sort { orderByID[$0.id] == orderByID[$1.id] ? $0.id.uuidString < $1.id.uuidString : (orderByID[$0.id] ?? 0) < (orderByID[$1.id] ?? 0) }
        case .title:
            favorites.sort {
                let comparison = $0.title.localizedStandardCompare($1.title)
                return comparison == .orderedSame ? $0.id.uuidString < $1.id.uuidString : comparison == .orderedAscending
            }
        case .createdNewest:
            favorites.sort { createdAtByID[$0.id] == createdAtByID[$1.id] ? $0.id.uuidString < $1.id.uuidString : (createdAtByID[$0.id] ?? .distantPast) > (createdAtByID[$1.id] ?? .distantPast) }
        }
        return favorites
    }

    func moveWork(workID: UUID, toIndex: Int) throws {
        var rows = try workFavoriteRecords().sorted {
            let a = $0.value(forKey: "order") as? Double ?? 0, b = $1.value(forKey: "order") as? Double ?? 0
            let ai = $0.value(forKey: "id") as? UUID, bi = $1.value(forKey: "id") as? UUID
            return a == b ? (ai?.uuidString ?? "") < (bi?.uuidString ?? "") : a < b
        }
        guard let old = rows.firstIndex(where: { $0.value(forKey: "id") as? UUID == workID }) else { throw FavoriteError.favoriteWorkNotFound(workID) }
        let row = rows.remove(at: old)
        rows.insert(row, at: min(max(0, toIndex), rows.count))
        for (index, favorite) in rows.enumerated() { favorite.setValue(Double(index), forKey: "order") }
        do { try context.save() } catch { context.rollback(); throw error }
    }

    func favoriteWorkIDs() throws -> Set<UUID> {
        Set(try workFavoriteRecords().compactMap { $0.value(forKey: "id") as? UUID })
    }

    @discardableResult
    func addSource(workID: UUID, source: SourceItemRef) throws -> WorkSourceLink {
        try Self.requireSelectedTorrent(source)
        guard try works.fetchWork(id: workID) != nil else { throw WorkLibrary.LibraryError.workNotFound(workID) }
        if let existing = try works.sourceLinks(forWorkID: workID).first(where: {
            $0.sourceWork.sourceID == source.sourceID && $0.sourceWork.pageURL == source.pageURL
        }) { return existing }
        let link = WorkSourceLink(workID: workID, sourceWork: source)
        do { try works.upsert(link) }
        catch { context.rollback(); throw error }
        return link
    }


    private static func requireSelectedTorrent(_ item: SourceItemRef) throws {
        guard item.sourceID == "torrent" else { return }
        guard let url = URL(string: item.pageURL), TorrentSelection(identityURL: url) != nil else {
            throw DownloadFailure.invalidSelection
        }
    }

    private func snapshot(_ record: NSManagedObject) throws -> LinkFavorite {
        guard let original = record.value(forKey: "originalURL") as? String ?? record.value(forKey: "url") as? String else { throw FavoriteError.invalidBookmarkModel }
        guard let id = record.value(forKey: "favoriteID") as? UUID else { throw FavoriteError.invalidBookmarkModel }
        let url = record.value(forKey: "canonicalURL") as? String
        let favoriteTitle = record.value(forKey: "favoriteTitle") as? String
        let liveTitle = record.value(forKey: "liveTitle") as? String
        let title = favoriteTitle.flatMap { $0.isEmpty ? nil : $0 }
            ?? liveTitle.flatMap { $0.isEmpty ? nil : $0 } ?? original
        return LinkFavorite(id: id, originalURL: original, canonicalURL: url,
            sourceID: record.value(forKey: "sourceID") as? String, title: title,
            order: record.value(forKey: "order") as? Double ?? 0,
            createdAt: record.value(forKey: "createdAt") as? Date ?? .distantPast)
    }

    private func nextOrder(entity: String) throws -> Double {
        let request = NSFetchRequest<NSManagedObject>(entityName: entity)
        request.sortDescriptors = [NSSortDescriptor(key: "order", ascending: false)]
        request.fetchLimit = 1
        return (try context.fetch(request).first?.value(forKey: "order") as? Double).map { $0 + 1 } ?? 0
    }

    private func newRecord(entity: String) throws -> NSManagedObject {
        guard let description = NSEntityDescription.entity(forEntityName: entity, in: context) else { throw FavoriteError.invalidBookmarkModel }
        return NSManagedObject(entity: description, insertInto: context)
    }

    private func workFavoriteRecords() throws -> [NSManagedObject] {
        try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "WorkFavoriteRecord"))
    }
}
