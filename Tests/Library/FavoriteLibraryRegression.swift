import CoreData
import Foundation
@testable import IINA_ANI

@main
@MainActor
struct FavoriteLibraryRegression {
    static func main() async throws {
        let modelURL = URL(fileURLWithPath: CommandLine.arguments[1])
        guard let loaded = NSManagedObjectModel(contentsOf: modelURL),
              let model = loaded.mutableCopy() as? NSManagedObjectModel else { throw Failure("Missing model") }
        model.entitiesByName["Bookmark"]?.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("w5-favorites-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("library.sqlite")
        let container = try await open(model, store)
        let library = FavoriteLibrary(container: container)
        let works = WorkLibrary(container: container)
        let one = Work(bangumiID: 42, title: "Shared title", aliases: ["First alias"])
        let two = Work(bangumiID: 42, title: "Shared title")
        try works.upsert(one)
        try works.upsert(two)
        let episode = Episode(workID: one.id, label: "Episode 1", sort: 1)
        try works.upsert(episode)
        try library.addWork(workID: one.id)
        try library.addWork(workID: one.id)
        try library.addWork(workID: two.id)
        try require(try library.favoriteWorkIDs() == [one.id, two.id], "Work ID, not title/Bangumi ID, owns favorite identity")
        try library.moveWork(workID: two.id, toIndex: 0)
        try require(try library.works().map(\.id) == [two.id, one.id], "work manual ordering")
        try require(try library.works(query: "alias").map(\.id) == [one.id], "work alias query")
        let sourceA = SourceItemRef(sourceID: "fqdm", pageURL: "https://www.fqdm.cc/bangumi/7", kind: .work)
        let sourceB = SourceItemRef(sourceID: "internet-archive", pageURL: "https://archive.org/details/feature", kind: .work)
        let linked = try library.addSource(workID: one.id, source: sourceA)
        let reused = try library.addSource(workID: one.id, source: sourceA)
        let other = try library.addSource(workID: one.id, source: sourceB)
        try require(linked.id == reused.id && Set(try works.sourceLinks(forWorkID: one.id).map(\.id)) == [linked.id, other.id], "multiple sources attach to one stable Work")
        let videoRef = SourceItemRef(sourceID: "bilibili", pageURL: "https://www.bilibili.com/video/BV1xx411c7mD", kind: .video)
        let videoLink = try library.addSource(workID: one.id, source: videoRef)
        try require(videoLink.sourceWork == videoRef, "generic video link must not be coerced to an anime work")
        let corrected = try works.setClassification(workID: one.id, kind: .video)
        try require(corrected.id == one.id && library.favoriteWorkIDs() == [one.id, two.id] &&
                    works.episodes(forWorkID: one.id) == [episode], "classification correction deleted favorites or episodes")
        try library.updateWork(workID: one.id, title: "Renamed locally", aliases: ["Edited alias"])
        let editedWork = try works.fetchWork(id: one.id)!
        try require(editedWork.title == "Renamed locally", "local work title is editable")
        try require(try library.works(query: "Edited alias").map(\.id) == [one.id] &&
                    library.works().map(\.id) == [two.id, one.id] && works.fetchWork(id: one.id)?.bangumiID == 42 &&
                    works.episodes(forWorkID: one.id) == [episode], "editing title and aliases preserves identity, order, Bangumi association and episodes")

        let raw = "https://www.bilibili.com/video/BV1xx411c7mD?p=1&spm_id_from=w5#original"
        let first = try library.addLink(url: raw, title: "Zulu")
        let second = try library.addLink(url: "https://www.bilibili.com/video/BV1xx411c7mD?p=2", title: "Alpha")
        try library.moveLink(id: second.id, toIndex: 0)
        let movedOrder = try library.links().first(where: { $0.id == first.id })!.order
        let duplicate = try library.addLink(url: "https://www.bilibili.com/video/BV1xx411c7mD?p=1&spm_id_from=duplicate", title: "Must not overwrite")
        try require(duplicate.id == first.id && duplicate.originalURL == raw && duplicate.title == "Zulu" && duplicate.order == movedOrder, "tracking dedup preserves original URL, title and moved order")
        try require(first.canonicalURL == "https://www.bilibili.com/video/BV1xx411c7mD" && second.canonicalURL == "https://www.bilibili.com/video/BV1xx411c7mD?p=2", "Bili part identities stay distinct")
        let genericURL = "https://unavailable.w5.invalid/watch?episode=4&key=identity"
        let generic = try library.addLink(url: genericURL, title: "Gamma")
        let broken = try library.addLink(url: "broken old URL", title: "Old title")
        let renamedBroken = try library.updateLink(id: broken.id, url: broken.originalURL, title: "Edited unavailable link")
        try require(renamedBroken.id == broken.id && renamedBroken.originalURL == "broken old URL" &&
                    renamedBroken.title == "Edited unavailable link" && renamedBroken.order == broken.order,
                    "unavailable stored URL supports title-only edits without rewriting its identity")
        let repaired = try library.updateLink(id: broken.id, url: "https://unavailable.w5.invalid/repaired?episode=0", title: "Beta")
        try require(repaired.id == broken.id && repaired.canonicalURL?.contains("episode=0") == true, "broken link can be repaired without replacing identity")
        do {
            _ = try library.updateLink(id: second.id, url: raw, title: "Collision")
            throw Failure("canonical collision was accepted")
        } catch FavoriteLibrary.FavoriteError.duplicateCanonicalLink(let id) { try require(id == first.id, "collision identifies existing favorite") }
        try require(try library.links().first(where: { $0.id == second.id })?.title == "Alpha", "rejected edit preserves previous title")
        try require(try library.links(query: "episode=4").map(\.id) == [generic.id], "link query includes preserved unavailable URL")
        try require(try library.links(sort: .title).map(\.title) == ["Alpha", "Beta", "Gamma", "Zulu"], "independent link title sorting")
        for (index, record) in try library.linkObjects().enumerated() {
            record.setValue(Date(timeIntervalSince1970: Double(index + 1)), forKey: "createdAt")
        }
        try container.viewContext.save()
        try require(try library.links(sort: .createdNewest).first?.id == repaired.id, "newest sorting uses saved creation time")
        try require(try library.works().map(\.id) == [two.id, one.id], "link sorting cannot change work order")

        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/Sources")
        let registry = SourceRegistry(builtinDirectory: sources, userDirectory: root.appendingPathComponent("sources"))
        let archiveURL = "https://archive.org/details/feature?file=feature.mp4&download=1"
        let archive = try FavoriteLibrary(container: container, normalizer: registry.favoriteItem(for:)).addLink(url: archiveURL, title: "Archive")
        try require(archive.sourceID == "internet-archive" && archive.canonicalURL == archiveURL, "configured source retains file identity query")
        let corrupt = NSEntityDescription.insertNewObject(forEntityName: "Bookmark", into: container.viewContext)
        corrupt.setValue("no identity", forKey: "url")
        try container.viewContext.save()
        do {
            _ = try library.links()
            throw Failure("missing persistent favorite UUID was silently replaced")
        } catch FavoriteLibrary.FavoriteError.invalidBookmarkModel {}
        container.viewContext.delete(corrupt)
        try container.viewContext.save()
        let savedLinks = try library.links()
        try close(container)
        let reopened = try await open(model, store)
        let reloaded = FavoriteLibrary(container: reopened)
        try require(try reloaded.links() == savedLinks, "all link identities, titles, originals and order survive reopen")
        try require(try reloaded.works().map(\.id) == [two.id, one.id], "work favorite order survives reopen")
        try reloaded.deleteLink(id: first.id)
        try reloaded.removeWork(workID: one.id)
        let retained = WorkLibrary(container: reopened)
        try require(try retained.fetchWork(id: one.id) == editedWork && retained.episodes(forWorkID: one.id) == [episode] &&
                    Set(retained.sourceLinks(forWorkID: one.id).map(\.id)) == [linked.id, other.id, videoLink.id] && reloaded.favoriteWorkIDs() == [two.id],
                    "unfavorite deletes membership only, preserving Work/Episode/SourceLinks")
        try require(try reloaded.links().allSatisfy { $0.id != first.id } && reloaded.links().contains { $0.id == second.id }, "link deletion is independent")
        try close(reopened)
        try await torrentIdentityPersistence(model, root.appendingPathComponent("torrent.sqlite"))
        try await independentCollectionStatus(model, root.appendingPathComponent("collection-status.sqlite"))
        print("PASS: work-ID dedup, two confirmed sources, real Bili/configured identities, broken-link repair, collision atomicity, independent query/sort, deletion isolation, corrupt-ID rejection and reopen; exact torrent favorites/episode mappings")
    }

    private static func independentCollectionStatus(_ model: NSManagedObjectModel, _ store: URL) async throws {
        let container = try await open(model, store)
        let works = WorkLibrary(container: container)
        let favorites = FavoriteLibrary(container: container)
        let fresh = Work(bangumiID: 42, title: "New favorite")
        let legacy = Work(bangumiID: 43, title: "Legacy favorite")
        let unrelated = Work(title: "Not a favorite")
        let remote = Work(bangumiID: 44, title: "Remote category", collectionStatus: .collected)
        let pending = Work(bangumiID: 45, title: "Pending category", collectionStatus: .dropped,
                           collectionStatusPending: true, collectionStatusRevision: UUID())
        for work in [fresh, legacy, unrelated, remote, pending] { try works.upsert(work) }
        try favorites.addWork(workID: fresh.id)
        try favorites.addWork(workID: remote.id)
        try favorites.addWork(workID: pending.id)
        let record = NSEntityDescription.insertNewObject(forEntityName: "WorkFavoriteRecord", into: container.viewContext)
        record.setValue(legacy.id, forKey: "id")
        record.setValue(3.0, forKey: "order")
        record.setValue(Date(), forKey: "createdAt")
        try container.viewContext.save()
        try require(try works.fetchWork(id: fresh.id) == fresh,
                    "adding a favorite preserves unclassified nil without a pending command or revision")
        try close(container)

        let reopened = try await open(model, store)
        let reloaded = FavoriteLibrary(container: reopened)
        let retained = WorkLibrary(container: reopened)
        let firstRead = try reloaded.works()
        try require(try firstRead.first(where: { $0.id == legacy.id }) == legacy &&
                    retained.fetchWork(id: legacy.id) == legacy,
                    "reading a legacy nil favorite must not infer a category or write a classification")
        try require(try retained.fetchWork(id: unrelated.id) == unrelated &&
                    retained.fetchWork(id: remote.id) == remote && retained.fetchWork(id: pending.id) == pending,
                    "favorite reads preserve nonfavorites, explicit remote categories and pending edits")
        try reloaded.addWork(workID: fresh.id)
        try require(try reloaded.works() == firstRead && reloaded.favoriteWorkIDs().count == 4,
                    "repeated reads and adds preserve favorite identities and ordering")
        let imported = try retained.applyCollectionStatus(.doing, workID: legacy.id, subjectID: 43,
            associationRevision: legacy.bangumiAssociationRevision, collectionRevision: legacy.collectionStatusRevision,
            acknowledgingLocalEdit: false)
        try require(imported.collectionStatus == .doing && !imported.collectionStatusPending &&
                    (try reloaded.works()).first(where: { $0.id == legacy.id }) == imported,
                    "incoming remote category can classify a legacy nil work and survives subsequent reads")
        try close(reopened)
        let final = try await open(model, store)
        let finalWorks = WorkLibrary(container: final)
        try require(try finalWorks.fetchWork(id: fresh.id) == fresh &&
                    finalWorks.fetchWork(id: legacy.id) == imported,
                    "unclassified nil and explicit imported category survive another reopen")
        let finalFavorites = FavoriteLibrary(container: final)
        try finalFavorites.removeWork(workID: pending.id)
        try require(try finalWorks.fetchWork(id: pending.id) == pending &&
                    !finalFavorites.favoriteWorkIDs().contains(pending.id),
                    "removing membership preserves the explicit category, pending flag and revision")
        let classifiedNonfavorite = try finalWorks.setCollectionStatus(workID: unrelated.id, status: .onHold)
        try require(classifiedNonfavorite.collectionStatus == .onHold &&
                    !(try finalFavorites.favoriteWorkIDs()).contains(unrelated.id),
                    "classifying a nonfavorite must not add favorite membership")
        try close(final)
        print("PASS: unclassified legacy/new favorites, independent membership/status, pending preservation and remote replacement")
    }

    private static func torrentIdentityPersistence(_ model: NSManagedObjectModel, _ store: URL) async throws {
        let hashes: Set<String> = ["v1:" + String(repeating: "a", count: 40), "v2:" + String(repeating: "b", count: 64)]
        let selected = TorrentSelection(infoHashes: hashes, fileIndex: 3, path: "Series/02 第二集.mkv", size: 900_123)!
        let another = TorrentSelection(infoHashes: hashes, fileIndex: 1, path: "Series/01.mkv", size: 100)!
        let container = try await open(model, store)
        let favorites = FavoriteLibrary(container: container)
        let magnet = "magnet:?xt=urn:btih:" + String(repeating: "a", count: 40) + "&tr=https%3A%2F%2Ftracker.invalid%2Ftest-passkey"
        for input in [magnet, "file:///tmp/unselected.torrent"] {
            var rejected = false
            do { _ = try favorites.addLink(url: input) } catch { rejected = true }
            try require(rejected, "unselected torrent import was persisted as a favorite")
        }
        let saved = try favorites.addTorrent(selection: selected, title: "Episode 2")
        var rejectedEdit = false
        do { _ = try favorites.updateLink(id: saved.id, url: magnet, title: "Unselected") } catch { rejectedEdit = true }
        try require(rejectedEdit && (try favorites.torrentSelection(id: saved.id)) == selected,
                    "editing a favorite to a raw magnet lost its exact file identity")
        let duplicate = try favorites.addTorrent(selection: selected, title: "No overwrite")
        let first = try favorites.addTorrent(selection: another)
        try require(saved.id == duplicate.id && saved.id != first.id, "torrent dedup uses exact selected file, not only swarm")
        let item = try SourceRegistry.shared.item(for: selected.identityURL.absoluteString)
        let anime = MediaClassification(kind: .anime, provenance: "manual")
        let choice = PlayableSelection(item: item, torrent: selected, classification: anime)
        let work = Work(title: "Torrent work", classification: anime, classificationIsManual: true)
        let episode = Episode(workID: work.id, label: "2", sort: 2)
        let works = WorkLibrary(container: container)
        try works.upsert(work)
        try works.upsert(episode)
        let link = WorkSourceLink(workID: work.id,
            sourceWork: SourceItemRef(sourceID: "torrent", pageURL: selected.identityURL.absoluteString, kind: .work),
            episodeMappings: [.init(episodeID: episode.id, selection: choice)])
        try works.upsert(link)
        try close(container)
        let reopened = try await open(model, store)
        let restored = FavoriteLibrary(container: reopened)
        try require(try restored.torrentSelection(id: saved.id) == selected, "favorite reopen must preserve nonfirst file, both hashes, path and size")
        try require(try WorkLibrary(container: reopened).sourceLinks(forWorkID: work.id) == [link], "episode mapping reopens exact torrent identity")
        try restored.deleteLink(id: first.id)
        try require(try restored.torrentSelection(id: saved.id) == selected, "deleting another torrent file favorite preserves selection")
        try close(reopened)
    }

    private static func open(_ model: NSManagedObjectModel, _ url: URL) async throws -> NSPersistentContainer {
        let container = NSPersistentContainer(name: "DataModel", managedObjectModel: model)
        container.persistentStoreDescriptions = [NSPersistentStoreDescription(url: url)]
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            container.loadPersistentStores { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        return container
    }
    private static func close(_ container: NSPersistentContainer) throws {
        container.viewContext.reset()
        for store in container.persistentStoreCoordinator.persistentStores { try container.persistentStoreCoordinator.remove(store) }
    }
    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(message) }
    }
    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
