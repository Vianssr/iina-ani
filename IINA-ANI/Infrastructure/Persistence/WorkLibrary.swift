import CoreData
import Foundation

struct Work: Codable, Hashable, Sendable {
    let id: UUID
    var bangumiID: Int?
    var title: String
    var aliases: [String]
    var coverURL: String?
    var year: Int?
    var summary: String?
    var updatedAt: Date
    /// External fields are separate from the local name, cover and description.
    var bangumiMetadata: BangumiMetadata?
    var bangumiAssociationRevision: UUID?
    var classification: MediaClassification
    var classificationIsManual: Bool
    var collectionStatus: BangumiCollectionStatus?
    /// A durable local edit must not be replaced by a remote read, including local nil (no remote delete).
    var collectionStatusPending: Bool
    var collectionStatusRevision: UUID?
    /// The profile that owns this durable command; never retarget a failed retry after sign-out.
    var collectionStatusAccountID: UUID?

    init(id: UUID = UUID(), bangumiID: Int? = nil, title: String, aliases: [String] = [],
         coverURL: String? = nil, year: Int? = nil, summary: String? = nil, updatedAt: Date = .now,
         bangumiMetadata: BangumiMetadata? = nil, bangumiAssociationRevision: UUID? = nil,
         classification: MediaClassification = .unknown, classificationIsManual: Bool = false,
         collectionStatus: BangumiCollectionStatus? = nil, collectionStatusPending: Bool = false,
         collectionStatusRevision: UUID? = nil, collectionStatusAccountID: UUID? = nil) {
        self.id = id
        self.bangumiID = bangumiID
        self.title = title
        self.aliases = aliases
        self.coverURL = coverURL
        self.year = year
        self.summary = summary
        self.updatedAt = updatedAt
        self.bangumiMetadata = bangumiMetadata
        self.bangumiAssociationRevision = bangumiAssociationRevision
        self.classification = classification
        self.classificationIsManual = classificationIsManual
        self.collectionStatus = collectionStatus
        self.collectionStatusPending = collectionStatusPending
        self.collectionStatusRevision = collectionStatusRevision
        self.collectionStatusAccountID = collectionStatusAccountID
    }

    private enum CodingKeys: String, CodingKey {
        case id, bangumiID, title, aliases, coverURL, year, summary, updatedAt
        case bangumiMetadata, bangumiAssociationRevision, classification, classificationIsManual
        case collectionStatus, collectionStatusPending, collectionStatusRevision
        case collectionStatusAccountID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        bangumiID = try c.decodeIfPresent(Int.self, forKey: .bangumiID)
        title = try c.decode(String.self, forKey: .title)
        aliases = try c.decode([String].self, forKey: .aliases)
        coverURL = try c.decodeIfPresent(String.self, forKey: .coverURL)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        bangumiMetadata = try c.decodeIfPresent(BangumiMetadata.self, forKey: .bangumiMetadata)
        bangumiAssociationRevision = try c.decodeIfPresent(UUID.self, forKey: .bangumiAssociationRevision)
        classification = try c.decodeIfPresent(MediaClassification.self, forKey: .classification) ?? .unknown
        classificationIsManual = try c.decodeIfPresent(Bool.self, forKey: .classificationIsManual) ?? false
        collectionStatus = try c.decodeIfPresent(BangumiCollectionStatus.self, forKey: .collectionStatus)
        collectionStatusPending = try c.decodeIfPresent(Bool.self, forKey: .collectionStatusPending) ?? false
        collectionStatusRevision = try c.decodeIfPresent(UUID.self, forKey: .collectionStatusRevision)
        collectionStatusAccountID = try c.decodeIfPresent(UUID.self, forKey: .collectionStatusAccountID)
    }
}

struct Episode: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case main, special, opening, ending, other

        var displayTitle: String {
            switch self {
            case .main: return String(localized: "Main Episode")
            case .special: return String(localized: "Special")
            case .opening: return String(localized: "Opening")
            case .ending: return String(localized: "Ending")
            case .other: return String(localized: "Other")
            }
        }
    }

    let id: UUID
    let workID: UUID
    var externalID: String?
    var kind: Kind
    var label: String
    var sort: Double

    init(id: UUID = UUID(), workID: UUID, externalID: String? = nil,
         kind: Kind = .main, label: String, sort: Double) {
        self.id = id
        self.workID = workID
        self.externalID = externalID
        self.kind = kind
        self.label = label
        self.sort = sort
    }
}

struct EpisodeSourceMapping: Codable, Hashable, Sendable {
    var episodeID: UUID
    var selection: PlayableSelection
    /// Missing on legacy records; configured sources require explicit reconfirmation.
    var confirmation: ConfirmedSourceMapping?
    var catalogGroup: [String]?

    init(episodeID: UUID, selection: PlayableSelection, confirmation: ConfirmedSourceMapping? = nil,
         catalogGroup: [String]? = nil) {
        self.episodeID = episodeID
        self.selection = selection
        self.confirmation = confirmation
        self.catalogGroup = catalogGroup
    }
}

struct WorkSourceLink: Codable, Hashable, Sendable {
    let id: UUID
    let workID: UUID
    let sourceWork: SourceItemRef
    var episodeMappings: [EpisodeSourceMapping]

    init(id: UUID = UUID(), workID: UUID, sourceWork: SourceItemRef,
         episodeMappings: [EpisodeSourceMapping] = []) {
        self.id = id
        self.workID = workID
        self.sourceWork = sourceWork
        self.episodeMappings = episodeMappings
    }
}

@MainActor
final class WorkLibrary {
    enum LibraryError: Error, Equatable {
        case workNotFound(UUID)
        case episodeNotFound(UUID)
        case episodeBelongsToDifferentWork(episodeID: UUID, expectedWorkID: UUID)
        case duplicateEpisodeMapping(UUID)
        case invalidSourceWork
        case selectionBelongsToDifferentSource(UUID)
        case corruptStoredPayload
        case invalidBangumiID
        case bangumiAssociationChanged(UUID)
        case animeRequired
        case collectionStatusChanged(UUID)
    }

    private let context: NSManagedObjectContext
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    convenience init(container: NSPersistentContainer) {
        self.init(context: container.viewContext)
    }

    func upsert(_ work: Work) throws {
        let record = try record(entity: "WorkRecord", id: work.id)
        record.setValue(work.id, forKey: "id")
        record.setValue(try encoder.encode(work), forKey: "payload")
        try context.saveIfChanged()
    }

    func fetchWork(id: UUID) throws -> Work? {
        guard let record = try recordIfPresent(entity: "WorkRecord", id: id) else { return nil }
        return try decode(Work.self, from: record)
    }

    func allWorks() throws -> [Work] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "WorkRecord")
        return try context.fetch(request).map { try decode(Work.self, from: $0) }
    }

    func worksAssociated(withBangumiID subjectID: Int) throws -> [Work] {
        try allWorks().filter { $0.bangumiID == subjectID }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// Removing an association never deletes the work, episodes, favorites or downloads.
    func removeSourceLink(id: UUID, workID: UUID) throws {
        guard let record = try recordIfPresent(entity: "WorkSourceLinkRecord", id: id) else { return }
        let link = try decode(WorkSourceLink.self, from: record)
        guard link.workID == workID else { throw LibraryError.invalidSourceWork }
        context.delete(record)
        do { try context.saveIfChanged() } catch { context.rollback(); throw error }
    }

    /// No title matching: each explicitly created local work has its own identity.
    @discardableResult
    func createLocalWork(title: String, classification: MediaClassification = .unknown) throws -> Work {
        let work = Work(title: title, classification: classification)
        try upsert(work)
        return work
    }

    /// Changes evidence in place without deleting associations, episodes, favorites or downloads.
    @discardableResult
    func setClassification(workID: UUID, kind: MediaContentKind) throws -> Work {
        guard var work = try fetchWork(id: workID) else { throw LibraryError.workNotFound(workID) }
        work.classification = MediaClassification(kind: kind, provenance: "manual")
        work.classificationIsManual = true
        work.updatedAt = .now
        try upsert(work)
        return work
    }

    func worksLinked(to item: SourceItemRef) throws -> [Work] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "WorkSourceLinkRecord")
        let ids = Set(try context.fetch(request).map { try decode(WorkSourceLink.self, from: $0) }
            .filter { link in
                (link.sourceWork.sourceID == item.sourceID && link.sourceWork.pageURL == item.pageURL) || link.episodeMappings.contains {
                    let ref = $0.selection.episode ?? $0.selection.item
                    return ref.sourceID == item.sourceID && ref.pageURL == item.pageURL
                }
            }.map(\.workID))
        return try ids.compactMap { try fetchWork(id: $0) }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    @discardableResult
    func setBangumiAssociation(workID: UUID, subjectID: Int?) throws -> Work {
        if let subjectID, subjectID <= 0 { throw LibraryError.invalidBangumiID }
        guard var work = try fetchWork(id: workID) else { throw LibraryError.workNotFound(workID) }
        if subjectID != nil, work.classification.kind != .anime { throw LibraryError.animeRequired }
        guard work.bangumiID != subjectID else { return work }
        work.bangumiID = subjectID
        work.bangumiMetadata = nil
        work.bangumiAssociationRevision = UUID()
        work.collectionStatusRevision = UUID()
        work.collectionStatusPending = work.collectionStatus != nil
        work.updatedAt = .now
        try upsert(work)
        return work
    }

    @discardableResult
    func setCollectionStatus(workID: UUID, status: BangumiCollectionStatus?, accountID: UUID? = nil) throws -> Work {
        guard var work = try fetchWork(id: workID) else { throw LibraryError.workNotFound(workID) }
        work.collectionStatus = status
        work.collectionStatusPending = true
        work.collectionStatusRevision = UUID()
        work.collectionStatusAccountID = accountID
        work.updatedAt = .now
        do { try upsert(work) } catch { context.rollback(); throw error }
        return work
    }

    @discardableResult
    func bindCollectionStatusAccount(workID: UUID, revision: UUID?, accountID: UUID) throws -> Work {
        guard var work = try fetchWork(id: workID) else { throw LibraryError.workNotFound(workID) }
        guard work.collectionStatusPending, work.collectionStatusRevision == revision,
              work.collectionStatusAccountID == nil || work.collectionStatusAccountID == accountID else {
            throw LibraryError.collectionStatusChanged(workID)
        }
        work.collectionStatusAccountID = accountID
        do { try upsert(work) } catch { context.rollback(); throw error }
        return work
    }

    /// Merge only collection fields into the latest work, never a pre-request snapshot.
    @discardableResult
    func applyCollectionStatus(_ status: BangumiCollectionStatus?, workID: UUID, subjectID: Int,
                               associationRevision: UUID?, collectionRevision: UUID?,
                               acknowledgingLocalEdit: Bool) throws -> Work {
        guard var work = try fetchWork(id: workID) else { throw LibraryError.workNotFound(workID) }
        guard work.bangumiID == subjectID, work.bangumiAssociationRevision == associationRevision else {
            throw LibraryError.bangumiAssociationChanged(workID)
        }
        guard work.collectionStatusRevision == collectionRevision else {
            if !acknowledgingLocalEdit { return work }
            throw LibraryError.collectionStatusChanged(workID)
        }
        guard acknowledgingLocalEdit || !work.collectionStatusPending else { return work }
        work.collectionStatus = status
        work.collectionStatusPending = false
        work.collectionStatusAccountID = nil
        work.collectionStatusRevision = UUID()
        work.updatedAt = .now
        try upsert(work)
        return work
    }

    /// Re-read after network I/O: a refresh must not overwrite edits or a new association.
    @discardableResult
    func applyBangumiMetadata(_ metadata: BangumiMetadata, toWorkID workID: UUID,
                              expectedAssociationRevision: UUID?) throws -> Work {
        guard var work = try fetchWork(id: workID) else { throw LibraryError.workNotFound(workID) }
        guard work.bangumiID == metadata.subject.id,
              work.bangumiAssociationRevision == expectedAssociationRevision else {
            throw LibraryError.bangumiAssociationChanged(workID)
        }
        if let existing = work.bangumiMetadata, existing.fetchedAt > metadata.fetchedAt { return work }
        work.bangumiMetadata = metadata
        if !work.classificationIsManual { work.classification = metadata.subject.classification }
        work.updatedAt = .now
        try upsert(work)
        return work
    }

    func upsert(_ episode: Episode) throws {
        guard try fetchWork(id: episode.workID) != nil else { throw LibraryError.workNotFound(episode.workID) }
        if let existing = try fetchEpisode(id: episode.id), existing.workID != episode.workID {
            throw LibraryError.episodeBelongsToDifferentWork(episodeID: episode.id, expectedWorkID: existing.workID)
        }
        let record = try record(entity: "EpisodeRecord", id: episode.id)
        record.setValue(episode.id, forKey: "id")
        record.setValue(episode.workID, forKey: "workID")
        record.setValue(try encoder.encode(episode), forKey: "payload")
        try context.saveIfChanged()
    }

    func episodes(forWorkID workID: UUID) throws -> [Episode] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "EpisodeRecord")
        request.predicate = NSPredicate(format: "workID == %@", workID as CVarArg)
        return try context.fetch(request).map { try decode(Episode.self, from: $0) }
            .sorted { $0.sort == $1.sort ? $0.id.uuidString < $1.id.uuidString : $0.sort < $1.sort }
    }

    /// Commit one preferred source for this exact domain episode after successful resolution.
    /// Keep source links and every other episode mapping, including unconfirmed legacy records.
    func setPreferredMapping(_ mapping: EpisodeSourceMapping, forWorkID workID: UUID,
                             sourceWork: SourceItemRef) throws {
        let links = try sourceLinks(forWorkID: workID)
        let targetID = links.first(where: { $0.sourceWork == sourceWork })?.id ?? UUID()
        var updates: [WorkSourceLink] = []
        for var link in links where link.id == targetID || link.episodeMappings.contains(where: { $0.episodeID == mapping.episodeID }) {
            link.episodeMappings.removeAll { $0.episodeID == mapping.episodeID }
            if link.id == targetID { link.episodeMappings.append(mapping) }
            updates.append(link)
        }
        if !links.contains(where: { $0.id == targetID }) {
            updates.append(WorkSourceLink(id: targetID, workID: workID, sourceWork: sourceWork, episodeMappings: [mapping]))
        }
        do {
            for link in updates { try stage(link) }
            try context.saveIfChanged()
        } catch {
            context.rollback()
            throw error
        }
    }

    func upsert(_ link: WorkSourceLink) throws {
        try stage(link)
        try context.saveIfChanged()
    }

    private func stage(_ link: WorkSourceLink) throws {
        guard let work = try fetchWork(id: link.workID) else { throw LibraryError.workNotFound(link.workID) }
        if !link.episodeMappings.isEmpty, work.classification.kind != .anime { throw LibraryError.animeRequired }
        var mappedEpisodes = Set<UUID>()
        for mapping in link.episodeMappings {
            guard mapping.selection.classification.kind == .anime else { throw LibraryError.animeRequired }
            guard mappedEpisodes.insert(mapping.episodeID).inserted else {
                throw LibraryError.duplicateEpisodeMapping(mapping.episodeID)
            }
            guard let episode = try fetchEpisode(id: mapping.episodeID) else {
                throw LibraryError.episodeNotFound(mapping.episodeID)
            }
            guard episode.workID == link.workID else {
                throw LibraryError.episodeBelongsToDifferentWork(episodeID: mapping.episodeID, expectedWorkID: link.workID)
            }
            guard mapping.selection.item.sourceID == link.sourceWork.sourceID,
                  mapping.selection.episode?.sourceID == nil || mapping.selection.episode?.sourceID == link.sourceWork.sourceID else {
                throw LibraryError.selectionBelongsToDifferentSource(mapping.episodeID)
            }
        }

        let record = try record(entity: "WorkSourceLinkRecord", id: link.id)
        record.setValue(link.id, forKey: "id")
        record.setValue(link.workID, forKey: "workID")
        record.setValue(try encoder.encode(link), forKey: "payload")
    }

    func sourceLinks(forWorkID workID: UUID) throws -> [WorkSourceLink] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "WorkSourceLinkRecord")
        request.predicate = NSPredicate(format: "workID == %@", workID as CVarArg)
        return try context.fetch(request).map { try decode(WorkSourceLink.self, from: $0) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// A catalog's last row is not evidence of a completed season. Unknown evidence retains history.
    /// Online fallback is deliberately limited to one exact source-work association and a full,
    /// unique sibling group matching the declared main-episode count; filenames/titles never map episodes.
    func completedSeasonItems(for selection: PlayableSelection, candidates: [SourceItemRef],
                              downloads: [DownloadRecord], now: Date) throws -> [SourceItemRef]? {
        let current = selection.episode ?? selection.item
        guard !candidates.isEmpty, candidates.last == current,
              Set(candidates).count == candidates.count else { return nil }
        if current.kind == .local {
            guard let record = uniqueCompletedDownload(for: current, downloads: downloads),
                  let work = try downloadWork(record),
                  let season = completedMainEpisodes(for: work, now: now),
                  let final = season.last else { return nil }
            let links = try sourceLinks(forWorkID: work.id)
            let episodes = try episodes(forWorkID: work.id)
            guard remoteEpisodeID(for: record, links: links, episodes: episodes) == final.id else { return nil }
            let mainIDs = Set(season.map(\.id))
            var result: [SourceItemRef] = []
            for candidate in candidates {
                guard let download = uniqueCompletedDownload(for: candidate, downloads: downloads),
                      let owner = try downloadWork(download), owner.id == work.id,
                      let episodeID = remoteEpisodeID(for: download, links: links, episodes: episodes),
                      mainIDs.contains(episodeID) else { continue }
                result.append(candidate)
            }
            return result.contains(current) ? result : nil
        }

        guard selection.item.sourceID == current.sourceID,
              candidates.allSatisfy({ $0.sourceID == current.sourceID && $0.kind != .local }),
              let work = try uniqueLinkedWork(for: selection.item),
              let season = completedMainEpisodes(for: work, now: now),
              candidates.count == season.count else { return nil }
        let linkedCurrent = try worksLinked(to: current)
        guard linkedCurrent.allSatisfy({ $0.id == work.id }) else { return nil }
        let links = try sourceLinks(forWorkID: work.id).filter { sameSource($0.sourceWork, selection.item) }
        guard !links.isEmpty else { return nil }
        let episodes = try episodes(forWorkID: work.id)
        // A confirmed mapping takes precedence over count/order evidence, including a contradiction.
        for (index, candidate) in candidates.enumerated() {
            let mappings = links.flatMap(\.episodeMappings).filter {
                sameSource($0.selection.episode ?? $0.selection.item, candidate)
            }
            guard mappings.allSatisfy({ mapping in
                episodes.first(where: { $0.id == mapping.episodeID && $0.kind == .main })?.externalID
                    == "bangumi:\(season[index].id)"
            }) else { return nil }
            let owners = try worksLinked(to: candidate)
            guard owners.allSatisfy({ $0.id == work.id }) else { return nil }
        }
        return candidates
    }

    private func completedMainEpisodes(for work: Work, now: Date) -> [BangumiEpisode]? {
        guard work.classification.kind == .anime, let subjectID = work.bangumiID, subjectID > 0,
              let metadata = work.bangumiMetadata, metadata.subject.id == subjectID,
              metadata.subject.type == 2, let total = metadata.subject.totalEpisodes, total > 0 else { return nil }
        let main = metadata.episodes.filter { $0.type == 0 }
        guard main.count == total, Set(main.map(\.id)).count == total,
              main.allSatisfy({ $0.id > 0 && $0.sort.isFinite }) else { return nil }
        let usesRelativeNumbers = main.allSatisfy { $0.ep != nil }
        guard usesRelativeNumbers || main.allSatisfy({ $0.ep == nil }) else { return nil }
        let ordered = main.sorted { ($0.ep ?? $0.sort) < ($1.ep ?? $1.sort) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        let today = formatter.string(from: now)
        var previousSort: Double?
        for (index, episode) in ordered.enumerated() {
            guard (episode.ep ?? episode.sort) == Double(index + 1),
                  previousSort.map({ episode.sort > $0 }) ?? true,
                  Self.hasKnownEpisodeTitle(episode.title),
                  let airdate = episode.airdate, airdate.count == 10,
                  let date = formatter.date(from: airdate), formatter.string(from: date) == airdate,
                  airdate < today else { return nil }
            previousSort = episode.sort
        }
        return ordered
    }

    private static func hasKnownEpisodeTitle(_ value: String) -> Bool {
        let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch title {
        case "", "未知", "標題未知", "标题未知": return false
        default: return title.caseInsensitiveCompare("unknown") != .orderedSame
        }
    }

    private func sameSource(_ lhs: SourceItemRef, _ rhs: SourceItemRef) -> Bool {
        lhs.sourceID == rhs.sourceID && lhs.pageURL == rhs.pageURL
    }

    private func uniqueLinkedWork(for item: SourceItemRef) throws -> Work? {
        let works = try worksLinked(to: item)
        return works.count == 1 ? works.first : nil
    }

    private func uniqueCompletedDownload(for item: SourceItemRef, downloads: [DownloadRecord]) -> DownloadRecord? {
        guard item.kind == .local, let file = URL(string: item.pageURL), file.isFileURL else { return nil }
        let matches = downloads.filter {
            $0.state == .completed && $0.completedFile?.standardizedFileURL == file.standardizedFileURL
        }
        return matches.count == 1 ? matches.first : nil
    }

    private func downloadWork(_ record: DownloadRecord) throws -> Work? {
        let sourceWorks = try worksLinked(to: record.selection.item)
        let episodeWorks = try worksLinked(to: record.selection.episode ?? record.selection.item)
        let work: Work?
        if let id = record.workID {
            work = try fetchWork(id: id)
        } else if let id = record.bangumiID {
            let matches = try worksAssociated(withBangumiID: id)
            work = matches.count == 1 ? matches.first : nil
        } else {
            let matches = Dictionary((sourceWorks + episodeWorks).map { ($0.id, $0) },
                                     uniquingKeysWith: { first, _ in first })
            work = matches.count == 1 ? matches.values.first : nil
        }
        guard let work, record.bangumiID == nil || record.bangumiID == work.bangumiID,
              (sourceWorks + episodeWorks).allSatisfy({ $0.id == work.id }) else { return nil }
        return work
    }

    private func remoteEpisodeID(for record: DownloadRecord, links: [WorkSourceLink],
                                 episodes: [Episode]) -> Int? {
        var ids = Set<Int>()
        if let key = record.episodeKey {
            let external = episodes.first(where: { $0.id.uuidString == key })?.externalID ?? key
            guard let id = bangumiEpisodeID(external) else { return nil }
            ids.insert(id)
        }
        let current = record.selection.episode ?? record.selection.item
        for mapping in links.flatMap(\.episodeMappings) where sameSource(mapping.selection.episode ?? mapping.selection.item, current) {
            guard let episode = episodes.first(where: { $0.id == mapping.episodeID && $0.kind == .main }),
                  let external = episode.externalID, let id = bangumiEpisodeID(external) else { return nil }
            ids.insert(id)
        }
        return ids.count == 1 ? ids.first : nil
    }

    private func bangumiEpisodeID(_ key: String) -> Int? {
        guard key.hasPrefix("bangumi:"), let id = Int(key.dropFirst("bangumi:".count)), id > 0 else { return nil }
        return id
    }

    private func fetchEpisode(id: UUID) throws -> Episode? {
        guard let record = try recordIfPresent(entity: "EpisodeRecord", id: id) else { return nil }
        return try decode(Episode.self, from: record)
    }

    private func record(entity: String, id: UUID) throws -> NSManagedObject {
        if let existing = try recordIfPresent(entity: entity, id: id) { return existing }
        guard let description = NSEntityDescription.entity(forEntityName: entity, in: context) else {
            throw LibraryError.corruptStoredPayload
        }
        return NSManagedObject(entity: description, insertInto: context)
    }

    private func recordIfPresent(entity: String, id: UUID) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: entity)
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return try context.fetch(request).first
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from record: NSManagedObject) throws -> Value {
        guard let data = record.value(forKey: "payload") as? Data else { throw LibraryError.corruptStoredPayload }
        do { return try decoder.decode(type, from: data) }
        catch { throw LibraryError.corruptStoredPayload }
    }
}

enum BookmarkOrderMigration {
    static func sourceModelLacksOrder(_ model: NSManagedObjectModel) -> Bool {
        model.entitiesByName["Bookmark"]?.attributesByName["order"] == nil
    }

    static func initializeOrderIfMissing(in context: NSManagedObjectContext, sourceModel: NSManagedObjectModel) throws {
        guard sourceModelLacksOrder(sourceModel) else { return }
        let request = NSFetchRequest<NSManagedObject>(entityName: "Bookmark")
        request.sortDescriptors = [NSSortDescriptor(key: "url", ascending: true)]
        for (index, bookmark) in try context.fetch(request).enumerated() {
            bookmark.setValue(Double(index), forKey: "order")
        }
        if context.hasChanges { try context.save() }
    }
}

private extension NSManagedObjectContext {
    func saveIfChanged() throws {
        if hasChanges { try save() }
    }
}
