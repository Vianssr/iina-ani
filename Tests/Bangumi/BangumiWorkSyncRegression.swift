import CoreData
import Foundation
@testable import IINA_ANI

@main
@MainActor
struct BangumiWorkSyncRegression {
    static func main() async throws {
        let modelURL = URL(fileURLWithPath: CommandLine.arguments[1])
        guard let model = NSManagedObjectModel(contentsOf: modelURL) else { throw Failure("Missing model") }
        let container = NSPersistentContainer(name: "DataModel", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            container.loadPersistentStores { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        let library = WorkLibrary(container: container)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bangumi-sync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ImageCacheService(coverAndEmoticonRoot: root.appendingPathComponent("covers"),
                                      metadataRoot: root.appendingPathComponent("metadata"),
                                      downloadTemporaryDirectory: root.appendingPathComponent("temporary"),
                                      completedDownloadsDirectory: root.appendingPathComponent("completed"))
        let anime = MediaClassification(kind: .anime, provenance: "fixture")
        let local = try library.createLocalWork(title: "My local name", classification: anime)
        let transport = TransportState()
        let service = BangumiService(cache: cache, transport: { request in try await transport.send(request) })
        let sync = BangumiWorkSync(library: library, service: service)
        let initiallyUnlinked = try await sync.refresh(workID: local.id)
        try require(initiallyUnlinked.state == .unlinked && initiallyUnlinked.origin == nil && initiallyUnlinked.work.bangumiMetadata == nil,
                    "unlinked work must remain local, not return fabricated metadata")
        let linked = try await sync.associate(workID: local.id, subjectID: 42)
        try require(linked.state == .available && linked.work.title == local.title && linked.work.bangumiMetadata?.subject.title == "Remote 42",
                    "first association must save external metadata separately from the local name")
        let obtainedAt = linked.work.bangumiMetadata!.fetchedAt
        try cache.clearRebuildableCache()
        await transport.goOffline()
        let offline = try await sync.refresh(workID: local.id, forceRefresh: true)
        try require(offline.origin == .staleCache && offline.failure != nil && offline.work.bangumiMetadata?.fetchedAt == obtainedAt,
                    "clearing replaceable cache must not remove saved library metadata or its obtained time")

        let failing = try library.createLocalWork(title: "Not downloaded yet", classification: anime)
        try library.setBangumiAssociation(workID: failing.id, subjectID: 43)
        let unlinked = try library.createLocalWork(title: "No association")
        let absent = UUID()
        let reports = try await sync.refreshFavorites(workIDs: [failing.id, local.id, unlinked.id, absent, local.id], forceRefresh: true)
        try require(reports.map(\.workID) == [failing.id, local.id, unlinked.id, absent], "scheduled refresh must deduplicate by local identity")
        try require(reports[0].read == nil && reports[0].failure != nil && reports[1].read?.origin == .staleCache &&
                    reports[2].read?.state == .unlinked && reports[3].failure != nil,
                    "one refresh failure must not prevent cached or unlinked favorites from being read")

        let raceService = BangumiService(cache: cache, transport: { request in
            if request.url!.path.contains("/subjects/") {
                try await MainActor.run {
                    try library.setBangumiAssociation(workID: local.id, subjectID: 43)
                    try library.setBangumiAssociation(workID: local.id, subjectID: 42)
                    var edited = try library.fetchWork(id: local.id)!
                    edited.title = "Edited during fetch"
                    try library.upsert(edited)
                }
            }
            return try TransportState.response(request)
        })
        do {
            _ = try await BangumiWorkSync(library: library, service: raceService).refresh(workID: local.id, forceRefresh: true)
            throw Failure("refresh committed after association changed away and back")
        } catch WorkLibrary.LibraryError.bangumiAssociationChanged { }
        let afterRace = try library.fetchWork(id: local.id)!
        try require(afterRace.title == "Edited during fetch" && afterRace.bangumiMetadata == nil,
                    "stale response must preserve local edits and the current association state")
        _ = try library.setClassification(workID: local.id, kind: .video)
        let onlineService = BangumiService(cache: cache, transport: { request in try TransportState.response(request) })
        let corrected = try await BangumiWorkSync(library: library, service: onlineService).refresh(workID: local.id, forceRefresh: true)
        try require(corrected.work.id == local.id && corrected.work.classification.kind == .video && corrected.work.classificationIsManual,
                    "Bangumi sync overwrote a persisted manual content correction")
        do {
            _ = try await sync.associate(workID: local.id, subjectID: 44)
            throw Failure("non-anime association was accepted")
        } catch WorkLibrary.LibraryError.animeRequired { }
        try await episodeNumberBackfill(library: library, container: container, cache: cache)
        try await collectionStatusSync(library: library, cache: cache)
        try await onlineCollections(library: library, container: container, cache: cache)
        print("PASS: unlinked state, saved-metadata offline fallback after cache clear, scheduled partial failure, association race, episode-number backfill")
    }

    private static func onlineCollections(library: WorkLibrary, container: NSPersistentContainer, cache: ImageCacheService) async throws {
        let suite = "bangumi-online-sync-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        let account = SiteAccount(id: UUID(), sourceID: "bangumi", displayName: "Import account", enabled: true, status: .valid)
        defaults.set(try JSONEncoder().encode([account]), forKey: "site-account-metadata-v1")
        preferences.setDefaultAccountID(account.id, for: "bangumi")
        let accounts = SiteAccounts(preferences: preferences, keychainService: suite)
        let remote = OnlineCollectionTransport()
        let service = BangumiService(cache: cache, accounts: accounts, transport: { try await remote.send($0) })
        let sync = BangumiWorkSync(library: library, service: service)
        let favorites = FavoriteLibrary(container: container)
        let anime = MediaClassification(kind: .anime, provenance: "fixture")
        let pending = Work(bangumiID: 7002, title: "Keep my title", aliases: ["My alias"],
            classification: anime, collectionStatus: .doing, collectionStatusPending: true, collectionStatusRevision: UUID())
        let edited = Work(bangumiID: 7003, title: "Concurrent edit", classification: anime, collectionStatus: .wish)
        let removed = Work(bangumiID: 7004, title: "Removed during import", classification: anime)
        let absent = Work(title: "Never delete local-only work", classification: anime, collectionStatus: .onHold)
        for work in [pending, edited, removed, absent] {
            try library.upsert(work)
            try favorites.addWork(workID: work.id)
        }
        let source = WorkSourceLink(workID: pending.id,
            sourceWork: SourceItemRef(sourceID: "fixture", pageURL: "https://fixture.invalid/kept", kind: .work))
        try library.upsert(source)
        let initialWorkCount = try library.allWorks().count
        await remote.configure(baseID: 7000, blockSecond: true)
        let importing = Task { try await sync.loadOnlineCollections(favorites: favorites) }
        await remote.waitUntilSuspended()
        let stagedCount = try library.allWorks().count
        try require(stagedCount == initialWorkCount, "first successful page must not mutate local records before the last page")
        let localEdit = try library.setCollectionStatus(workID: edited.id, status: .dropped)
        let acknowledged = try library.applyCollectionStatus(.dropped, workID: edited.id, subjectID: 7003,
            associationRevision: localEdit.bangumiAssociationRevision, collectionRevision: localEdit.collectionStatusRevision,
            acknowledgingLocalEdit: true)
        try favorites.removeWork(workID: removed.id)
        await remote.release()
        let count = try await importing.value
        let pendingAfter = try library.fetchWork(id: pending.id)!
        let editedAfter = try library.fetchWork(id: edited.id)!
        let removedAfter = try library.fetchWork(id: removed.id)!
        let sourceAfter = try library.sourceLinks(forWorkID: pending.id)
        let favoriteIDs = try favorites.favoriteWorkIDs()
        let absentAfter = try library.fetchWork(id: absent.id)!
        let newWork = try library.worksAssociated(withBangumiID: 7001).first!
        try require(count == 5 && pendingAfter == pending && editedAfter == acknowledged,
                    "overlapping pages deduplicate and preserve both pending and newer acknowledged local edits")
        try require(sourceAfter == [source] && favoriteIDs.contains(pending.id) && !favoriteIDs.contains(removed.id) &&
                    favoriteIDs.contains(absent.id) && absentAfter == absent,
                    "import must preserve local links and absent favorites without undoing an in-flight removal")
        try require(removedAfter.collectionStatus == .onHold && !removedAfter.collectionStatusPending,
                    "remote state must replace an implicit local wish default without manufacturing a pending write")
        try require(newWork.title == "作品 7001" && newWork.coverURL == "https://example.invalid/7001.jpg" &&
                    newWork.year == 2021 && newWork.bangumiID == 7001 && newWork.bangumiMetadata == nil &&
                    !newWork.collectionStatusPending, "new remote favorites use slim data without inventing episode metadata or pending writes")
        let beforeRepeat = try library.allWorks().count
        await remote.configure(baseID: 7000)
        let repeated = try await sync.loadOnlineCollections(favorites: favorites)
        let afterRepeat = try library.allWorks().count
        let readded = try favorites.favoriteWorkIDs()
        let pendingRepeat = try library.fetchWork(id: pending.id)!
        try require(repeated == 5 && beforeRepeat == afterRepeat && readded.contains(removed.id) && pendingRepeat == pending,
                    "repeating an explicit import adds no duplicate works and may intentionally restore a previously removed favorite")

        // Every failure happens after a successful page containing entirely new remote subjects.
        for mode in ["http", "cancel", "account", "task-cancel"] {
            let before = try Dictionary(uniqueKeysWithValues: library.allWorks().map { ($0.id, $0) })
            let favoritesBefore = try favorites.favoriteWorkIDs()
            await remote.configure(baseID: 8000, blockSecond: mode == "account" || mode == "task-cancel",
                                   failSecond: mode == "http", cancelSecond: mode == "cancel")
            let task = Task { try await sync.loadOnlineCollections(favorites: favorites) }
            if mode == "account" || mode == "task-cancel" {
                await remote.waitUntilSuspended()
                if mode == "account" { try await accounts.setDefault(accountID: nil, sourceID: "bangumi") }
                else { task.cancel() }
                await remote.release()
            }
            do {
                _ = try await task.value
                throw Failure("failed or cancelled import committed local data")
            } catch BangumiError.httpStatus(503) {
                try require(mode == "http", "unexpected HTTP failure")
            } catch BangumiError.account {
                try require(mode == "account", "unexpected account failure")
            } catch is CancellationError {
                try require(mode == "cancel" || mode == "task-cancel", "unexpected cancellation")
            }
            let after = try Dictionary(uniqueKeysWithValues: library.allWorks().map { ($0.id, $0) })
            let favoritesAfter = try favorites.favoriteWorkIDs()
            try require(before == after && favoritesBefore == favoritesAfter,
                        "account change, page failure and cancellation must leave every local record untouched")
            try await accounts.setDefault(accountID: account.id, sourceID: "bangumi")
        }
        await remote.configure(baseID: 9000)
        _ = try await sync.loadOnlineCollections(favorites: favorites)
        let imported = try library.allWorks().filter { (9001...9005).contains($0.bangumiID ?? 0) }
        try require(imported.count == 5 && Set(imported.compactMap(\.collectionStatus)) == Set(BangumiCollectionStatus.allCases) &&
                    imported.allSatisfy { !$0.collectionStatusPending },
                    "all five remote categories must persist as distinct classified local favorites")
    }

    private actor OnlineCollectionTransport {
        private var baseID = 7000
        private var blockSecond = false
        private var failSecond = false
        private var cancelSecond = false
        private var blocked: CheckedContinuation<Void, Never>?
        private var waiter: CheckedContinuation<Void, Never>?

        func configure(baseID: Int, blockSecond: Bool = false, failSecond: Bool = false, cancelSecond: Bool = false) {
            self.baseID = baseID
            self.blockSecond = blockSecond
            self.failSecond = failSecond
            self.cancelSecond = cancelSecond
        }
        func waitUntilSuspended() async {
            if blocked != nil { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func release() { blocked?.resume(); blocked = nil }
        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            guard request.httpMethod == "GET" else { throw Failure("online import must be strictly read-only") }
            let data: Data
            var code = 200
            if request.url!.path == "/v0/me" {
                data = Data(#"{"id":7}"#.utf8)
            } else {
                guard request.url!.path == "/v0/users/7/collections" else {
                    throw Failure("import fetched another user or per-subject metadata")
                }
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                guard query.first(where: { $0.name == "subject_type" })?.value == "2",
                      !query.contains(where: { $0.name == "type" }),
                      let raw = query.first(where: { $0.name == "offset" })?.value, let offset = Int(raw) else {
                    throw Failure("incorrect anime collection query")
                }
                if offset == 2 {
                    if blockSecond {
                        blockSecond = false
                        await withCheckedContinuation { continuation in
                            blocked = continuation
                            waiter?.resume(); waiter = nil
                        }
                    }
                    if cancelSecond { throw CancellationError() }
                    if failSecond { code = 503 }
                }
                let ids: [Int]
                switch offset {
                case 0: ids = [1, 2]
                case 2: ids = [2, 3]
                case 4: ids = [4, 5]
                default: throw Failure("unexpected import pagination offset")
                }
                let records: [[String: Any]] = ids.map { index in
                    let id = baseID + index
                    return ["subject_id": id, "subject_type": 2, "type": index, "private": true,
                            "subject": ["id": id, "type": 2, "name": "Remote \(id)", "name_cn": "作品 \(id)",
                                        "date": "2021-04-01", "images": ["large": "https://example.invalid/\(id).jpg"]]]
                }
                data = try JSONSerialization.data(withJSONObject: ["data": records, "total": 6, "limit": 2, "offset": offset])
            }
            return (data, HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
        }
    }

    private static func collectionStatusSync(library: WorkLibrary, cache: ImageCacheService) async throws {
        let suite = "bangumi-collection-sync-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        let account = SiteAccount(id: UUID(), sourceID: "bangumi", displayName: "Fixture", enabled: true, status: .valid)
        defaults.set(try JSONEncoder().encode([account]), forKey: "site-account-metadata-v1")
        preferences.setDefaultAccountID(account.id, for: "bangumi")
        let accounts = SiteAccounts(preferences: preferences, keychainService: suite)
        let remote = CollectionTransport()
        let service = BangumiService(cache: cache, accounts: accounts, transport: { try await remote.send($0) })
        let sync = BangumiWorkSync(library: library, service: service)
        let work = Work(bangumiID: 42, title: "Local title", classification: MediaClassification(kind: .anime, provenance: "fixture"))
        try library.upsert(work)
        let read = try await sync.refreshCollectionStatus(workID: work.id)
        try require(read.work.collectionStatus == .wish && !read.collectionStatusPending && read.work.title == work.title,
                    "explicit remote read merges only collection state")
        let saved = try await sync.setCollectionStatus(workID: work.id, status: .doing)
        try require(saved.origin == .network && saved.work.collectionStatus == .doing && !saved.collectionStatusPending,
                    "successful collection write must acknowledge pending local status")
        let acknowledged = try library.fetchWork(id: work.id)!
        try require(acknowledged.collectionStatus == .doing && !acknowledged.collectionStatusPending,
                    "HTTP 202 acknowledgement must persist the category and clear pending state")
        await remote.configure(failure: 503)
        do {
            _ = try await sync.setCollectionStatus(workID: work.id, status: .onHold)
            throw Failure("failed collection write reported success")
        } catch BangumiError.httpStatus(503) { }
        let pending = try library.fetchWork(id: work.id)!
        try require(pending.collectionStatus == .onHold && pending.collectionStatusPending,
                    "HTTP failure must leave the user's latest category durably pending")
        let count = await remote.requestCount
        let reopenedSync = BangumiWorkSync(library: library, service: service)
        let skipped = try await reopenedSync.refreshCollectionStatus(workID: work.id)
        let afterSkip = await remote.requestCount
        try require(skipped.work == pending && skipped.collectionStatusPending && count == afterSkip,
                    "a new sync owner must preserve pending state and avoid a conflicting remote read")
        await remote.configure(failure: nil)
        await remote.setOffline(true)
        do {
            _ = try await reopenedSync.setCollectionStatus(workID: work.id, status: .onHold)
            throw Failure("offline collection write reported success")
        } catch BangumiError.network { }
        let offlineSaved = try library.fetchWork(id: work.id)!
        try require(offlineSaved.collectionStatus == .onHold && offlineSaved.collectionStatusPending,
                    "offline failure must preserve local status for explicit retry")
        await remote.setOffline(false)
        let retried = try await reopenedSync.setCollectionStatus(workID: work.id, status: .onHold)
        try require(!retried.collectionStatusPending && retried.work.collectionStatus == .onHold,
                    "explicit same-status retry must synchronize and clear pending")

        await remote.suspendNextRequest()
        let reading = Task { try await sync.refreshCollectionStatus(workID: work.id) }
        await remote.waitUntilSuspended()
        let localEdit = try library.setCollectionStatus(workID: work.id, status: .dropped)
        await remote.release()
        let staleRead = try await reading.value
        try require(staleRead.work == localEdit && staleRead.collectionStatusPending,
                    "in-flight remote read must not overwrite a later local edit")

        await remote.suspendNextRequest()
        let writing = Task { try await sync.setCollectionStatus(workID: work.id, status: .wish) }
        await remote.waitUntilSuspended()
        let newer = try library.setCollectionStatus(workID: work.id, status: .collected)
        await remote.release()
        do { _ = try await writing.value; throw Failure("stale acknowledgement reported current edit synced") }
        catch WorkLibrary.LibraryError.collectionStatusChanged { }
        let afterWriteRace = try library.fetchWork(id: work.id)!
        try require(afterWriteRace == newer, "stale write must leave newer local status pending")
        _ = try await sync.setCollectionStatus(workID: work.id, status: .collected)

        await remote.suspendNextRequest()
        let olderWrite = Task { try await sync.setCollectionStatus(workID: work.id, status: .wish) }
        await remote.waitUntilSuspended()
        let releaseOlder = Task { @MainActor in
            // The direct second command below saves locally before its first suspension.
            let current = try library.fetchWork(id: work.id)!
            try require(current.collectionStatus == .collected && current.collectionStatusPending,
                        "second command must save before waiting for an older remote write")
            await remote.release()
        }
        let latestWrite = try await reopenedSync.setCollectionStatus(workID: work.id, status: .collected)
        try await releaseOlder.value
        do { _ = try await olderWrite.value; throw Failure("superseded overlapping write was acknowledged") }
        catch WorkLibrary.LibraryError.collectionStatusChanged { }
        let latestRemote = try await sync.refreshCollectionStatus(workID: work.id)
        try require(latestWrite.work.collectionStatus == .collected && !latestWrite.collectionStatusPending &&
                    latestRemote.work.collectionStatus == .collected,
                    "writes across sync owners must serialize so an older slow response cannot land last remotely")

        await remote.suspendNextRequest()
        let associationRead = Task { try await sync.refreshCollectionStatus(workID: work.id) }
        await remote.waitUntilSuspended()
        _ = try library.setBangumiAssociation(workID: work.id, subjectID: 43)
        _ = try library.setBangumiAssociation(workID: work.id, subjectID: 42)
        await remote.release()
        do { _ = try await associationRead.value; throw Failure("stale association collection read committed") }
        catch WorkLibrary.LibraryError.bangumiAssociationChanged { }

        let unlinked = try library.createLocalWork(title: "Unlinked")
        do {
            _ = try await sync.setCollectionStatus(workID: unlinked.id, status: .wish)
            throw Failure("unlinked write must report local-only failure")
        } catch BangumiError.account { }
        let localOnly = try library.fetchWork(id: unlinked.id)!
        try require(localOnly.collectionStatus == .wish && localOnly.collectionStatusPending, "unlinked local category was lost")
        try await accounts.setDefault(accountID: nil, sourceID: "bangumi")
        do {
            _ = try await sync.setCollectionStatus(workID: work.id, status: .doing)
            throw Failure("signed-out collection sync reported success")
        } catch BangumiError.account { }
        let signedOut = try library.fetchWork(id: work.id)!
        try require(signedOut.collectionStatus == .doing && signedOut.collectionStatusPending,
                    "signed-out failure must preserve local category")
    }

    private actor CollectionTransport {
        var requestCount = 0
        private var status: BangumiCollectionStatus = .wish
        private var failure: Int?
        private var offline = false
        private var suspendNext = false
        private var blocked: CheckedContinuation<Void, Never>?
        private var waiter: CheckedContinuation<Void, Never>?

        func configure(failure: Int?) { self.failure = failure }
        func setOffline(_ offline: Bool) { self.offline = offline }
        func suspendNextRequest() { suspendNext = true }
        func waitUntilSuspended() async {
            if blocked != nil { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func release() { blocked?.resume(); blocked = nil }
        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            requestCount += 1
            if offline { throw URLError(.notConnectedToInternet) }
            let path = request.url!.path
            if path == "/v0/me" {
                return response(request, json: #"{"id":7}"#, code: 200)
            }
            guard path == "/v0/users/7/collections/42" || path == "/v0/users/-/collections/42" else {
                throw Failure("unexpected endpoint in collection sync")
            }
            if suspendNext {
                suspendNext = false
                await withCheckedContinuation { continuation in
                    blocked = continuation
                    waiter?.resume()
                    waiter = nil
                }
            }
            if let failure { return response(request, json: "", code: failure) }
            if request.httpMethod == "POST" {
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Int]
                guard body.count == 1, let raw = body["type"], let newStatus = BangumiCollectionStatus(rawValue: raw) else {
                    throw Failure("collection write must only change type")
                }
                status = newStatus
                return response(request, json: "", code: 202)
            }
            return response(request, json: "{\"subject_id\":42,\"type\":\(status.rawValue)}", code: 200)
        }
        private func response(_ request: URLRequest, json: String, code: Int) -> (Data, URLResponse) {
            (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
        }
    }

    private static func episodeNumberBackfill(library: WorkLibrary, container: NSPersistentContainer, cache: ImageCacheService) async throws {
        let anime = MediaClassification(kind: .anime, provenance: "fixture")
        let local = try library.createLocalWork(title: "Local season name", classification: anime)
        let associated = try library.setBangumiAssociation(workID: local.id, subjectID: 42)
        let legacyMetadata = BangumiMetadata(subject: BangumiSubject(id: 42, name: "Saved remote name", type: 2),
            episodes: [BangumiEpisode(id: 900, type: 0, sort: 25, name: "First")],
            fetchedAt: Date().addingTimeInterval(-60))
        var legacyWork = associated
        legacyWork.bangumiMetadata = legacyMetadata
        legacyWork.aliases = ["Local alias"]
        legacyWork.summary = "Local synopsis"
        // Exercise the pre-ep library payload through Codable, then through Core Data.
        let restored = try JSONDecoder().decode(Work.self, from: JSONEncoder().encode(legacyWork))
        try library.upsert(restored)
        let episode = Episode(workID: local.id, externalID: "900", label: "Local episode label", sort: 25)
        try library.upsert(episode)
        let ref = SourceItemRef(sourceID: "fixture", pageURL: "https://fixture.invalid/season", kind: .work)
        let link = WorkSourceLink(workID: local.id, sourceWork: ref,
            episodeMappings: [EpisodeSourceMapping(episodeID: episode.id, selection: PlayableSelection(item: ref, classification: anime))])
        try library.upsert(link)
        let favorites = FavoriteLibrary(container: container)
        try favorites.addWork(workID: local.id)
        try cache.clearRebuildableCache()
        let transport = TransportState()
        let service = BangumiService(cache: cache, transport: { try await transport.send($0) })
        let sync = BangumiWorkSync(library: library, service: service)
        let backfilled = try await sync.refresh(workID: local.id)
        try require(backfilled.origin == .network && backfilled.failure == nil && backfilled.work.bangumiMetadata?.needsEpisodeNumberRefresh == false,
                    "fresh saved pre-ep library metadata must fetch official episode numbers without forceRefresh")
        try require(backfilled.work.bangumiMetadata?.episodes.first?.sort == 25 && backfilled.work.bangumiMetadata?.episodes.first?.ep == 1,
                    "backfill preserves the official global sort while adding the official within-subject ep")
        try require(backfilled.work.id == restored.id && backfilled.work.bangumiID == restored.bangumiID &&
                    backfilled.work.bangumiAssociationRevision == restored.bangumiAssociationRevision && backfilled.work.title == restored.title &&
                    backfilled.work.aliases == restored.aliases && backfilled.work.summary == restored.summary,
                    "number backfill must preserve Work UUID, association revision, and local overrides")
        let backfilledEpisodes = try library.episodes(forWorkID: local.id)
        let backfilledLinks = try library.sourceLinks(forWorkID: local.id)
        let backfilledFavorites = try favorites.favoriteWorkIDs()
        try require(backfilledEpisodes == [episode] && backfilledLinks == [link] && backfilledFavorites.contains(local.id),
                    "number backfill must preserve episode UUIDs, source mappings, and favorites")
        let saved = try library.fetchWork(id: local.id)!
        try require(saved.bangumiMetadata?.episodes.first?.ep == 1 && saved.bangumiMetadata?.needsEpisodeNumberRefresh == false,
                    "persisted official ep must survive library payload decoding for subsequent refresh consumers")
        try cache.clearRebuildableCache()
        await transport.goOffline()
        let completeFresh = try await sync.refresh(workID: local.id)
        try require(completeFresh.origin == .cache && completeFresh.failure == nil && completeFresh.work == saved,
                    "complete fresh saved metadata skips network even after rebuildable cache eviction")
        try library.upsert(restored)
        let offline = try await sync.refresh(workID: local.id)
        try require(offline.origin == .staleCache && offline.failure != nil && offline.work == restored &&
                    offline.work.bangumiMetadata?.episodes.first?.ep == nil && offline.work.bangumiMetadata?.needsEpisodeNumberRefresh == true,
                    "fresh legacy library payload attempts backfill offline but retains its original unknown ep and obtained time")
        let offlineEpisodes = try library.episodes(forWorkID: local.id)
        let offlineLinks = try library.sourceLinks(forWorkID: local.id)
        let offlineFavorites = try FavoriteLibrary(container: container).favoriteWorkIDs()
        try require(offlineEpisodes == [episode] && offlineLinks == [link] && offlineFavorites.contains(local.id),
                    "offline numbering refresh must not remove episode/source identities or persistent favorites")
    }

    private actor TransportState {
        var offline = false
        func goOffline() { offline = true }
        func send(_ request: URLRequest) throws -> (Data, URLResponse) {
            if offline { throw URLError(.notConnectedToInternet) }
            return try Self.response(request)
        }
        nonisolated static func response(_ request: URLRequest) throws -> (Data, URLResponse) {
            let object: [String: Any]
            if request.url!.path.contains("/subjects/") {
                let id = Int(request.url!.lastPathComponent)!
                object = ["id": id, "name": "Remote \(id)", "name_cn": "", "type": 2, "date": "2026-10-01"]
            } else {
                let episodes: [[String: Any]] = [["id": 900, "type": 0, "sort": 25, "ep": 1, "name": "First"]]
                object = ["data": episodes, "total": episodes.count, "limit": 100, "offset": 0]
            }
            return (try JSONSerialization.data(withJSONObject: object),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message) }
    }
    private struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
}
