import CoreData
import Foundation

@main
@MainActor
struct WorkLibraryRegression {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw RegressionError("usage: work-library-regression <compiled-DataModel.momd>")
        }
        let modelDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        guard let loadedCurrentModel = NSManagedObjectModel(contentsOf: modelDirectory),
              let currentModel = loadedCurrentModel.mutableCopy() as? NSManagedObjectModel,
              let currentBookmark = currentModel.entitiesByName["Bookmark"] else {
            throw RegressionError("current model is missing or has no Bookmark entity")
        }
        currentBookmark.managedObjectClassName = NSStringFromClass(NSManagedObject.self)

        let oldModels = try FileManager.default.contentsOfDirectory(at: modelDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "mom" && $0.lastPathComponent != "Library v0.5.mom" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !oldModels.isEmpty else { throw RegressionError("no historical .mom versions found") }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IINA-ANI-WorkLibrarySmoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for oldModelURL in oldModels {
            guard let loadedOldModel = NSManagedObjectModel(contentsOf: oldModelURL),
                  let oldModel = loadedOldModel.mutableCopy() as? NSManagedObjectModel,
                  let bookmarkEntity = oldModel.entitiesByName["Bookmark"] else {
                throw RegressionError("invalid old model: \(oldModelURL.lastPathComponent)")
            }
            bookmarkEntity.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
            let hasOrder = bookmarkEntity.attributesByName["order"] != nil
            let storeURL = root.appendingPathComponent(oldModelURL.deletingPathExtension().lastPathComponent + ".sqlite")
            let expectedURLs = ["https://smoke.invalid/\(oldModelURL.lastPathComponent)/a",
                                "https://smoke.invalid/\(oldModelURL.lastPathComponent)/b"]
            try createLegacyBookmarkStore(model: oldModel, at: storeURL, urls: expectedURLs,
                                          orders: hasOrder ? [17.375, 82.625] : [])

            let migrated = try await openContainer(at: storeURL, model: currentModel)
            try BookmarkOrderMigration.initializeOrderIfMissing(in: migrated.viewContext, sourceModel: oldModel)
            let request = NSFetchRequest<NSManagedObject>(entityName: "Bookmark")
            request.sortDescriptors = [NSSortDescriptor(key: "url", ascending: true)]
            let bookmarks = try migrated.viewContext.fetch(request)
            try require(bookmarks.count == 2, "bookmark count changed migrating \(oldModelURL.lastPathComponent)")
            let actualURLs = bookmarks.compactMap { $0.value(forKey: "url") as? String }
            try require(actualURLs == expectedURLs, "bookmark identity changed migrating \(oldModelURL.lastPathComponent)")
            let actualOrders = bookmarks.compactMap { $0.value(forKey: "order") as? Double }
            let expectedOrders = hasOrder ? [17.375, 82.625] : [0.0, 1.0]
            try require(actualOrders == expectedOrders,
                        "bookmark ordering changed migrating \(oldModelURL.lastPathComponent): \(actualOrders)")
            try migrated.persistentStoreCoordinator.remove(migrated.persistentStoreCoordinator.persistentStores[0])
            print("PASS: migrated \(oldModelURL.lastPathComponent)")
        }

        try await testWorkIdentityReopen(model: currentModel, root: root)
        print("PASS: Work/Episode/WorkSourceLink identity, confirmed mapping, reparent rejection, and reopen")
        try await testClassification(model: currentModel, root: root)
        try await testCollectionStatus(model: currentModel, root: root)
    }

    private static func testCollectionStatus(model: NSManagedObjectModel, root: URL) async throws {
        let url = root.appendingPathComponent("collection-status.sqlite")
        let container = try await openContainer(at: url, model: model)
        let library = WorkLibrary(container: container)
        let work = Work(bangumiID: 42, title: "Local collection", classification: MediaClassification(kind: .anime, provenance: "fixture"))
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(work)) as! [String: Any]
        for key in ["collectionStatus", "collectionStatusPending", "collectionStatusRevision"] { legacy.removeValue(forKey: key) }
        let restored = try JSONDecoder().decode(Work.self, from: JSONSerialization.data(withJSONObject: legacy))
        try require(restored.collectionStatus == nil && !restored.collectionStatusPending && restored.collectionStatusRevision == nil,
                    "pre-category Work payload must retain unclassified state without fabricated pending edits")
        try library.upsert(restored)
        let pending = try library.setCollectionStatus(workID: work.id, status: .onHold)
        try require(pending.collectionStatus == .onHold && pending.collectionStatusPending, "local category must be immediately saved pending")
        try container.persistentStoreCoordinator.remove(container.persistentStoreCoordinator.persistentStores[0])
        let reopened = try await openContainer(at: url, model: model)
        let reopenedLibrary = WorkLibrary(container: reopened)
        let saved = try reopenedLibrary.fetchWork(id: work.id)!
        try require(saved == pending, "category, revision and pending command must survive SQLite reopen")
        let ignored = try reopenedLibrary.applyCollectionStatus(.wish, workID: work.id, subjectID: 42,
            associationRevision: saved.bangumiAssociationRevision, collectionRevision: saved.collectionStatusRevision,
            acknowledgingLocalEdit: false)
        try require(ignored == saved, "remote read must not replace a durable pending local command")
        let newer = try reopenedLibrary.setCollectionStatus(workID: work.id, status: .dropped)
        do {
            _ = try reopenedLibrary.applyCollectionStatus(.onHold, workID: work.id, subjectID: 42,
                associationRevision: saved.bangumiAssociationRevision, collectionRevision: saved.collectionStatusRevision,
                acknowledgingLocalEdit: true)
            throw RegressionError("stale write acknowledgement replaced newer local category")
        } catch WorkLibrary.LibraryError.collectionStatusChanged { }
        let acknowledged = try reopenedLibrary.applyCollectionStatus(.dropped, workID: work.id, subjectID: 42,
            associationRevision: newer.bangumiAssociationRevision, collectionRevision: newer.collectionStatusRevision,
            acknowledgingLocalEdit: true)
        try require(!acknowledged.collectionStatusPending && acknowledged.collectionStatus == .dropped &&
                    acknowledged.title == work.title, "acknowledgement must update only collection fields")
        _ = try reopenedLibrary.setBangumiAssociation(workID: work.id, subjectID: 43)
        let relinked = try reopenedLibrary.setBangumiAssociation(workID: work.id, subjectID: 42)
        try require(relinked.collectionStatus == .dropped && relinked.collectionStatusPending,
                    "relink preserves local category but requires explicit new-subject sync")
        do {
            _ = try reopenedLibrary.applyCollectionStatus(.wish, workID: work.id, subjectID: 42,
                associationRevision: acknowledged.bangumiAssociationRevision, collectionRevision: acknowledged.collectionStatusRevision,
                acknowledgingLocalEdit: false)
            throw RegressionError("association changed away and back accepted stale collection read")
        } catch WorkLibrary.LibraryError.bangumiAssociationChanged { }
        try reopened.persistentStoreCoordinator.remove(reopened.persistentStoreCoordinator.persistentStores[0])
        print("PASS: collection legacy decoding, durable pending status, stale acknowledgement and association protection")
    }

    private static func testWorkIdentityReopen(model: NSManagedObjectModel, root: URL) async throws {
        let storeURL = root.appendingPathComponent("work-library.sqlite")
        let work = Work(id: UUID(), bangumiID: 42, title: "Same title", aliases: ["Alias"],
                        coverURL: "https://smoke.invalid/cover", year: 2026, summary: "Identity", updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                        classification: MediaClassification(kind: .anime, provenance: "fixture"))
        let sameTitleWork = Work(id: UUID(), title: work.title, classification: work.classification)
        let mainEpisode = Episode(id: UUID(), workID: work.id, externalID: "main-1", kind: .main, label: "Episode 1", sort: 1)
        let specialEpisode = Episode(id: UUID(), workID: work.id, externalID: "sp-1", kind: .special, label: "Special", sort: 0.5)
        let episodeZero = Episode(id: UUID(), workID: work.id, externalID: "ep-0", kind: .main, label: "Episode 0", sort: 0)
        let otherEpisode = Episode(workID: sameTitleWork.id, label: "Unrelated work episode", sort: 1)
        let sourceWork = SourceItemRef(sourceID: "smoke", pageURL: "https://smoke.invalid/work", kind: .work)
        let selection = PlayableSelection(
            item: sourceWork,
            episode: SourceItemRef(sourceID: "smoke", pageURL: "https://smoke.invalid/episode/0", kind: .episode),
            lineID: "line", qualityID: "quality", accountID: UUID(), classification: work.classification
        )
        let link = WorkSourceLink(
            id: UUID(), workID: work.id, sourceWork: sourceWork,
            episodeMappings: [EpisodeSourceMapping(episodeID: episodeZero.id, selection: selection)]
        )

        try await withContainer(at: storeURL, model: model) { library in
            try library.upsert(work)
            try library.upsert(sameTitleWork)
            try library.upsert(mainEpisode)
            try library.upsert(specialEpisode)
            try library.upsert(episodeZero)
            try library.upsert(otherEpisode)
            try library.upsert(link)
        }

        let reopened = try await openContainer(at: storeURL, model: model)
        let library = WorkLibrary(container: reopened)
        try require(try library.fetchWork(id: work.id) == work, "work identity changed after reopen")
        try require(try library.fetchWork(id: sameTitleWork.id) == sameTitleWork && work.id != sameTitleWork.id,
                    "same-title works were incorrectly merged")
        try require(try library.episodes(forWorkID: work.id) == [episodeZero, specialEpisode, mainEpisode],
                    "episode kind/identity/order changed after reopen")
        try require(try library.sourceLinks(forWorkID: work.id) == [link], "confirmed source mapping changed after reopen")

        let duplicateTitle = Work(id: work.id, bangumiID: work.bangumiID, title: "Edited metadata",
                                  aliases: work.aliases, coverURL: work.coverURL, year: work.year,
                                  summary: work.summary, updatedAt: Date(), classification: work.classification)
        try library.upsert(duplicateTitle)
        try require(try library.sourceLinks(forWorkID: work.id) == [link], "metadata update removed confirmed source mapping")

        let reparented = Episode(id: episodeZero.id, workID: sameTitleWork.id, externalID: episodeZero.externalID,
                                 kind: episodeZero.kind, label: episodeZero.label, sort: episodeZero.sort)
        do {
            try library.upsert(reparented)
            throw RegressionError("episode identity was reparented across works")
        } catch WorkLibrary.LibraryError.episodeBelongsToDifferentWork {
            // Expected: the original confirmed mapping remains owned by its work.
        }
        let crossWorkLink = WorkSourceLink(
            workID: work.id, sourceWork: sourceWork,
            episodeMappings: [EpisodeSourceMapping(episodeID: otherEpisode.id, selection: selection)]
        )
        do {
            try library.upsert(crossWorkLink)
            throw RegressionError("cross-work episode mapping was accepted")
        } catch WorkLibrary.LibraryError.episodeBelongsToDifferentWork {
            // Expected: explicit source mapping cannot cross Work identity.
        }
        try require(try library.sourceLinks(forWorkID: work.id) == [link], "rejected cross-work change invalidated confirmed mapping")
        let external = try JSONDecoder().decode(BangumiSubject.self, from: Data(#"{"id":42,"type":2,"name":"External title","name_cn":"外部名稱","summary":"External description","date":"2026-10-01","images":{"large":"https://smoke.invalid/external-cover"},"infobox":[],"eps":12,"total_episodes":13}"#.utf8))
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_100)
        let snapshot = BangumiMetadata(subject: external, episodes: [], fetchedAt: fetchedAt)
        let beforeRefresh = try library.fetchWork(id: work.id)!
        let refreshed = try library.applyBangumiMetadata(snapshot, toWorkID: work.id, expectedAssociationRevision: nil)
        try require(refreshed.title == beforeRefresh.title && refreshed.aliases == beforeRefresh.aliases &&
                    refreshed.coverURL == beforeRefresh.coverURL && refreshed.year == beforeRefresh.year &&
                    refreshed.summary == beforeRefresh.summary, "external refresh overwrote local fields")
        try require(refreshed.bangumiMetadata?.subject.title == "外部名稱" && refreshed.bangumiMetadata?.fetchedAt == fetchedAt,
                    "external metadata/provenance not saved")
        try require(try library.sourceLinks(forWorkID: work.id) == [link] &&
                    library.episodes(forWorkID: work.id) == [episodeZero, specialEpisode, mainEpisode],
                    "external refresh altered local episodes or confirmed source mappings")
        try require(try library.setBangumiAssociation(workID: work.id, subjectID: 42).bangumiMetadata == snapshot,
                    "reselecting the current association discarded metadata")
        try library.setBangumiAssociation(workID: work.id, subjectID: 43)
        let relinked = try library.setBangumiAssociation(workID: work.id, subjectID: 42)
        try require(relinked.id == work.id && relinked.bangumiMetadata == nil, "relink rebuilt identity or retained wrong metadata")
        do {
            try library.applyBangumiMetadata(snapshot, toWorkID: work.id, expectedAssociationRevision: nil)
            throw RegressionError("in-flight refresh survived an A-to-B-to-A association change")
        } catch WorkLibrary.LibraryError.bangumiAssociationChanged { }
        let reapplied = try library.applyBangumiMetadata(snapshot, toWorkID: work.id,
                                                        expectedAssociationRevision: relinked.bangumiAssociationRevision)
        let unlinked = try library.setBangumiAssociation(workID: work.id, subjectID: nil)
        try require(unlinked.id == work.id && unlinked.title == reapplied.title && unlinked.bangumiMetadata == nil,
                    "unlink removed local work data")
        try require(try library.sourceLinks(forWorkID: work.id) == [link], "unlink removed source mappings")
        let independentlyCreated = try library.createLocalWork(title: unlinked.title)
        try require(independentlyCreated.id != unlinked.id && independentlyCreated.bangumiID == nil,
                    "same-name local works were auto-associated or merged")
        let linkedAgain = try library.setBangumiAssociation(workID: work.id, subjectID: 42)
        let finalWork = try library.applyBangumiMetadata(snapshot, toWorkID: work.id,
                                                         expectedAssociationRevision: linkedAgain.bangumiAssociationRevision)
        try reopened.persistentStoreCoordinator.remove(reopened.persistentStoreCoordinator.persistentStores[0])
        let metadataReopened = try await openContainer(at: storeURL, model: model)
        let metadataLibrary = WorkLibrary(container: metadataReopened)
        try require(try metadataLibrary.fetchWork(id: work.id) == finalWork, "metadata did not survive Core Data reopen")
        try require(try metadataLibrary.sourceLinks(forWorkID: work.id) == [link], "reopen lost source association")
        try require(try metadataLibrary.worksAssociated(withBangumiID: 42).map(\.id) == [work.id],
                    "Bangumi lookup guessed by title or lost persisted association")
        do {
            try metadataLibrary.removeSourceLink(id: link.id, workID: sameTitleWork.id)
            throw RegressionError("source removal accepted another work identity")
        } catch WorkLibrary.LibraryError.invalidSourceWork { }
        try require(try metadataLibrary.sourceLinks(forWorkID: work.id) == [link], "rejected source removal changed association")
        try metadataLibrary.removeSourceLink(id: link.id, workID: work.id)
        try metadataLibrary.removeSourceLink(id: link.id, workID: work.id)
        try require(try metadataLibrary.sourceLinks(forWorkID: work.id).isEmpty, "source association was not removed")
        try require(try metadataLibrary.fetchWork(id: work.id) == finalWork, "source removal changed work metadata")
        try require(try metadataLibrary.episodes(forWorkID: work.id) == [episodeZero, specialEpisode, mainEpisode],
                    "source removal deleted episode identities")
        try metadataReopened.persistentStoreCoordinator.remove(metadataReopened.persistentStoreCoordinator.persistentStores[0])
        print("PASS: Bangumi metadata persisted; local overrides/mappings preserved; unlink/relink and stale refresh protected")
    }

    private static func testClassification(model: NSManagedObjectModel, root: URL) async throws {
        let url = root.appendingPathComponent("classification.sqlite")
        let container = try await openContainer(at: url, model: model)
        let library = WorkLibrary(container: container)
        let work = Work(bangumiID: 100, title: "Animation-looking title")
        try library.upsert(work)
        let episode = Episode(workID: work.id, label: "Episode", sort: 1)
        try library.upsert(episode)
        let ref = SourceItemRef(sourceID: "fixture", pageURL: "https://fixture.invalid/video", kind: .video)
        let link = WorkSourceLink(workID: work.id, sourceWork: ref)
        try library.upsert(link)
        try require(try library.worksLinked(to: ref).map(\.id) == [work.id], "exact source lookup lost Work identity")
        for kind in [MediaContentKind.unknown, .video, .live] {
            let corrected = try library.setClassification(workID: work.id, kind: kind)
            try require(corrected.id == work.id && corrected.classificationIsManual, "correction rebuilt identity")
            do {
                try library.setBangumiAssociation(workID: work.id, subjectID: 101)
                throw RegressionError("non-anime Bangumi association accepted")
            } catch WorkLibrary.LibraryError.animeRequired { }
            let mapped = WorkSourceLink(workID: work.id, sourceWork: ref,
                episodeMappings: [EpisodeSourceMapping(episodeID: episode.id,
                    selection: PlayableSelection(item: ref, classification: corrected.classification))])
            do {
                try library.upsert(mapped)
                throw RegressionError("non-anime episode mapping accepted")
            } catch WorkLibrary.LibraryError.animeRequired { }
        }
        let metadata = BangumiMetadata(subject: BangumiSubject(id: 100, name: "Remote", type: 2), episodes: [], fetchedAt: .now)
        let refreshed = try library.applyBangumiMetadata(metadata, toWorkID: work.id, expectedAssociationRevision: nil)
        try require(refreshed.classification.kind == .live && refreshed.classification.provenance == "manual", "metadata overwrote manual correction")
        try require(try library.episodes(forWorkID: work.id) == [episode] && library.sourceLinks(forWorkID: work.id) == [link], "correction removed episode/source identity")
        let legacyData = try JSONEncoder().encode(work)
        var legacy = try JSONSerialization.jsonObject(with: legacyData) as! [String: Any]
        legacy.removeValue(forKey: "classification")
        legacy.removeValue(forKey: "classificationIsManual")
        let old = try JSONDecoder().decode(Work.self, from: JSONSerialization.data(withJSONObject: legacy))
        try require(old.classification == .unknown && !old.classificationIsManual, "legacy ID/title fabricated classification")
        for (type, kind) in [(2, MediaContentKind.anime), (6, .video), (1, .unknown), (3, .unknown), (4, .unknown)] {
            let subject = BangumiSubject(id: 100, name: work.title, type: type)
            try require(subject.classification.kind == kind && subject.classification.provenance == "bangumi.subject.type=\(type)",
                        "subject evidence used ID/title instead of declared API type")
        }
        let selection = PlayableSelection(item: ref)
        var saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(selection)) as! [String: Any]
        saved.removeValue(forKey: "classification")
        let oldSelection = try JSONDecoder().decode(PlayableSelection.self, from: JSONSerialization.data(withJSONObject: saved))
        try require(oldSelection.item == ref && oldSelection.classification == .unknown, "old selection changed source hash identity")
        try container.persistentStoreCoordinator.remove(container.persistentStoreCoordinator.persistentStores[0])
        let reopened = try await openContainer(at: url, model: model)
        try require(try WorkLibrary(container: reopened).fetchWork(id: work.id) == refreshed, "manual classification did not persist")
        try reopened.persistentStoreCoordinator.remove(reopened.persistentStoreCoordinator.persistentStores[0])
        print("PASS: R3 classification persistence, legacy unknown, exact source identity, anime-only commands, manual metadata protection")
    }


    private static func createLegacyBookmarkStore(model: NSManagedObjectModel, at url: URL,
                                                  urls: [String], orders: [Double]) throws {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
                                                       at: url, options: nil)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        for (index, bookmarkURL) in urls.enumerated() {
            let bookmark = NSEntityDescription.insertNewObject(forEntityName: "Bookmark", into: context)
            if bookmark.entity.attributesByName["url"] != nil { bookmark.setValue(bookmarkURL, forKey: "url") }
            if bookmark.entity.attributesByName["order"] != nil { bookmark.setValue(orders[index], forKey: "order") }
            if bookmark.entity.attributesByName["remark"] != nil { bookmark.setValue("isolated smoke", forKey: "remark") }
        }
        try context.save()
        try coordinator.remove(store)
    }

    private static func withContainer(at url: URL, model: NSManagedObjectModel,
                                      operation: (WorkLibrary) throws -> Void) async throws {
        let container = try await openContainer(at: url, model: model)
        try operation(WorkLibrary(container: container))
        try container.persistentStoreCoordinator.remove(container.persistentStoreCoordinator.persistentStores[0])
    }

    private static func openContainer(at url: URL, model: NSManagedObjectModel) async throws -> NSPersistentContainer {
        let container = NSPersistentContainer(name: "DataModel", managedObjectModel: model)
        let description = NSPersistentStoreDescription(url: url)
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

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw RegressionError(message) }
    }

    private struct RegressionError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
