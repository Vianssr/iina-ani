import Foundation

@main
struct MobileRegression {
    @MainActor static func main() throws {
        let anime = try decodeAnime(#"{"id":42,"name":"Original","name_cn":"作品","images":{"common":"https://example.com/cover.jpg"},"summary":"Cached text\n原文","date":"2025-01-02","rating":{"score":8.2}}"#)
        let sparse = try decodeAnime(#"{"id":43,"name":"Original"}"#)
        let legacy = try decodeAnime(#"{"id":1,"name":"Legacy","images":{"large":"http://lain.bgm.tv/pic/cover.jpg"}}"#)
        precondition(legacy.cover?.scheme == "https")
        precondition(anime.title == "作品" && anime.cover?.host == "example.com")
        precondition(sparse.title == "Original" && sparse.cover == nil)
        precondition(tryDecodeRoundTrip(anime) == anime)
        precondition(MediaAddress.parse("  https://example.com/stream.m3u8?signature=test \n") != nil)
        for invalid in ["", "relative.mp4", "file:///tmp/a.mp4", "javascript:alert(1)", "http://example.com/a", "https://user:secret@example.com/a", "https://"] {
            precondition(MediaAddress.parse(invalid) == nil, "Invalid address accepted")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try migration(root.appendingPathComponent("migration"), anime, sparse)
        try migrationRetry(root.appendingPathComponent("migration-retry"), anime, sparse)
        try corruptAndFutureAuthority(root.appendingPathComponent("authority"), anime, sparse)
        try transactionsAndClassification(root.appendingPathComponent("transactions"), anime, sparse)
        try independentCache(root.appendingPathComponent("cache"), anime, sparse)
        try versionOneUpgrade(root.appendingPathComponent("v1-upgrade"), anime, sparse)
        try durableMappings(root.appendingPathComponent("mappings"), anime, sparse)
        print("PASS: catalog, versioned migration/retry/upgrade, transactional favorites/classification/mappings, unreadable-data protection, independent dated detail/episode cache")
    }

    @MainActor static func migration(_ directory: URL, _ anime: Anime, _ sparse: Anime) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = directory.appendingPathComponent("favorites.json")
        // Legacy duplicates and their distinct snapshots must not be silently deduplicated or rewritten.
        let older = try decodeAnime(#"{"id":42,"name":"Older cached text","summary":"Preserve exactly"}"#)
        let values = [sparse, anime, older]
        let bytes = try JSONEncoder().encode(values)
        try bytes.write(to: legacy)
        let library = MobileLibrary(file: legacy)
        precondition(library.isReadable && !library.storageError)
        precondition(library.favorites == values)
        precondition(library.favorites.count == values.count)
        precondition(library.status(for: anime.id) == nil && library.status(for: sparse.id) == nil)
        precondition(tryRead(legacy) == bytes)
        precondition(tryRead(legacy.appendingPathExtension("backup")) == bytes)
        let authority = directory.appendingPathComponent("library.json")
        let object = try jsonObject(authority)
        precondition(object["version"] as? Int == 3)
        let works = object["works"] as! [[String: Any]]
        precondition(works.count == 2)
        for work in works {
            precondition(work["createdAt"] == nil || work["createdAt"] is NSNull)
            precondition(work["status"] == nil || work["status"] is NSNull)
            precondition(work["id"] as? String == "bangumi:\(work["subjectID"] as! Int)")
        }
        let restarted = MobileLibrary(file: legacy)
        precondition(restarted.favorites == values)
        // Once activated, the legacy file is neither a fallback nor a second write target.
        let changedLegacy = Data("now corrupt legacy".utf8)
        try changedLegacy.write(to: legacy)
        restarted.setStatus(.doing, for: anime)
        precondition(restarted.favorites == values)
        precondition(MobileLibrary(file: legacy).status(for: anime.id) == .doing)
        precondition(tryRead(legacy) == changedLegacy)
        precondition(tryRead(legacy.appendingPathExtension("backup")) == bytes)
        let updatedWorks = try jsonObject(authority)["works"] as! [[String: Any]]
        precondition(updatedWorks.map { $0["id"] as! String } == works.map { $0["id"] as! String })
    }

    @MainActor static func migrationRetry(_ directory: URL, _ anime: Anime, _ sparse: Anime) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = directory.appendingPathComponent("favorites.json")
        let authority = directory.appendingPathComponent("library.json")
        let stage = authority.appendingPathExtension("staged")
        let bytes = try JSONEncoder().encode([sparse, anime])
        try bytes.write(to: legacy)
        // A deterministic staging failure occurs after legacy backup, before activation/publication.
        try manager.createDirectory(at: stage, withIntermediateDirectories: false)
        let library = MobileLibrary(file: legacy)
        precondition(library.storageError && !library.isReadable && library.favorites.isEmpty)
        precondition(!manager.fileExists(atPath: authority.path))
        precondition(tryRead(legacy) == bytes && tryRead(legacy.appendingPathExtension("backup")) == bytes)
        library.toggle(anime)
        library.setStatus(.collected, for: anime)
        precondition(library.favorites.isEmpty && library.status(for: anime.id) == nil)
        try manager.removeItem(at: stage)
        // An interrupted staged payload is not itself authoritative; retry replaces and verifies it.
        try Data("partial staged payload".utf8).write(to: stage)
        library.retryLoad()
        precondition(library.isReadable && !library.storageError)
        precondition(library.favorites == [sparse, anime])
        library.retryLoad()
        precondition(library.favorites == [sparse, anime])
        precondition(MobileLibrary(file: legacy).favorites == [sparse, anime])
        precondition(tryRead(legacy) == bytes && tryRead(legacy.appendingPathExtension("backup")) == bytes)

        let brokenDirectory = directory.appendingPathComponent("broken-legacy")
        try manager.createDirectory(at: brokenDirectory, withIntermediateDirectories: false)
        let brokenLegacy = brokenDirectory.appendingPathComponent("favorites.json")
        let broken = Data("broken original".utf8)
        try broken.write(to: brokenLegacy)
        let blocked = MobileLibrary(file: brokenLegacy)
        precondition(!blocked.isReadable && blocked.storageError)
        precondition(tryRead(brokenLegacy) == broken && tryRead(brokenLegacy.appendingPathExtension("backup")) == broken)
        // Repairing the original allows an explicit retry without destroying the earlier backup.
        try bytes.write(to: brokenLegacy)
        blocked.retryLoad()
        precondition(blocked.isReadable && blocked.favorites == [sparse, anime])
        precondition(tryRead(brokenLegacy.appendingPathExtension("backup")) == broken)
    }

    @MainActor static func corruptAndFutureAuthority(_ directory: URL, _ anime: Anime, _ sparse: Anime) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = directory.appendingPathComponent("favorites.json")
        try JSONEncoder().encode([sparse]).write(to: legacy)
        let authority = directory.appendingPathComponent("library.json")
        let good = MobileLibrary(file: legacy)
        good.setStatus(.onHold, for: sparse)
        let saved = try Data(contentsOf: authority)
        var invalidID = try jsonObject(authority)
        var works = invalidID["works"] as! [[String: Any]]
        works[0]["id"] = "bangumi:999"
        invalidID["works"] = works
        var unknownStatus = try jsonObject(authority)
        works = unknownStatus["works"] as! [[String: Any]]
        works[0]["status"] = 999
        unknownStatus["works"] = works
        let invalidPayloads = [
            Data("corrupt data".utf8),
            Data(#"{"version":999,"favorites":[],"works":[]}"#.utf8),
            try JSONSerialization.data(withJSONObject: invalidID),
            try JSONSerialization.data(withJSONObject: unknownStatus)
        ]
        for broken in invalidPayloads {
            try broken.write(to: authority)
            let unreadable = MobileLibrary(file: legacy)
            precondition(unreadable.storageError && !unreadable.isReadable && unreadable.favorites.isEmpty)
            unreadable.toggle(anime)
            unreadable.setStatus(.collected, for: anime)
            precondition(unreadable.status(for: anime.id) == nil && unreadable.favorites.isEmpty)
            unreadable.retryLoad()
            precondition(!unreadable.isReadable && tryRead(authority) == broken)
            // An existing readable instance keeps its presentation on failed retry, but cannot write it back.
            good.retryLoad()
            precondition(!good.isReadable && good.favorites == [sparse] && good.status(for: sparse.id) == .onHold)
            good.toggle(sparse)
            good.setStatus(.wish, for: sparse)
            precondition(tryRead(authority) == broken && good.status(for: sparse.id) == .onHold)
            try saved.write(to: authority)
            unreadable.retryLoad()
            precondition(unreadable.isReadable && !unreadable.storageError)
            precondition(unreadable.favorites == [sparse] && unreadable.status(for: sparse.id) == .onHold)
            good.retryLoad()
        }
    }

    @MainActor static func transactionsAndClassification(_ directory: URL, _ anime: Anime, _ sparse: Anime) throws {
        let manager = FileManager.default
        let legacy = directory.appendingPathComponent("favorites.json")
        let authority = directory.appendingPathComponent("library.json")
        let library = MobileLibrary(file: legacy)
        library.toggle(anime)
        library.toggle(sparse)
        precondition(library.favorites == [sparse, anime])
        library.setStatus(.doing, for: anime)
        library.setStatus(.wish, for: sparse)
        precondition(library.matching("  original  ", sort: .recent).map(\.id) == [43, 42])
        precondition(library.matching("作品", sort: .recent).map(\.id) == [42])
        precondition(library.matching("missing", sort: .recent).isEmpty)
        precondition(library.matching(" ", sort: .rating).map(\.id) == [42, 43])
        precondition(library.matching("", sort: .title).map(\.id) == [43, 42])
        precondition(library.matching("original", sort: .recent, filter: .status(.doing)) == [anime])
        precondition(library.matching("", sort: .recent, filter: .unclassified).isEmpty)
        precondition(library.favorites == [sparse, anime])
        let originalBytes = try Data(contentsOf: authority)
        let stage = authority.appendingPathExtension("staged")
        try manager.createDirectory(at: stage, withIntermediateDirectories: false)
        library.toggle(anime)
        precondition(library.storageError && library.favorites == [sparse, anime])
        library.setStatus(.dropped, for: anime)
        precondition(library.storageError && library.status(for: anime.id) == .doing)
        precondition(tryRead(authority) == originalBytes)
        let restored = MobileLibrary(file: legacy)
        precondition(restored.favorites == [sparse, anime] && restored.status(for: anime.id) == .doing)
        try manager.removeItem(at: stage)
        library.toggle(anime)
        precondition(!library.storageError && !library.contains(anime) && library.status(for: anime.id) == .doing)
        let removed = MobileLibrary(file: legacy)
        precondition(removed.favorites == [sparse] && removed.status(for: anime.id) == .doing)
        removed.setStatus(.collected, for: anime)
        precondition(!removed.contains(anime) && removed.status(for: anime.id) == .collected)
        removed.toggle(anime)
        precondition(removed.favorites == [anime, sparse] && removed.status(for: anime.id) == .collected)
        removed.setStatus(nil, for: anime)
        precondition(removed.contains(anime) && removed.status(for: anime.id) == nil)
        precondition(removed.matching("", sort: .recent, filter: .unclassified) == [anime])
        for status in BangumiCollectionStatus.displayOrder {
            removed.setStatus(status, for: anime)
            precondition(MobileLibrary(file: legacy).status(for: anime.id) == status)
        }
        removed.setStatus(nil, for: anime)
        let finalLibrary = MobileLibrary(file: legacy)
        precondition(finalLibrary.favorites == [anime, sparse] && finalLibrary.status(for: anime.id) == nil)
        let subjectIDs = (try jsonObject(authority)["works"] as! [[String: Any]]).map { $0["id"] as! String }
        precondition(Set(subjectIDs) == Set(["bangumi:42", "bangumi:43"]))
        precondition(!manager.fileExists(atPath: legacy.path), "Fresh libraries must not dual-write legacy storage")
        let neverFavorited = try decodeAnime(#"{"id":99,"name":"Classification only"}"#)
        finalLibrary.setStatus(.onHold, for: neverFavorited)
        precondition(finalLibrary.favorites == [anime, sparse] && !finalLibrary.contains(neverFavorited))
        let classifiedOnly = MobileLibrary(file: legacy)
        precondition(classifiedOnly.status(for: 99) == .onHold && !classifiedOnly.contains(neverFavorited))
        classifiedOnly.setStatus(nil, for: neverFavorited)
        precondition(MobileLibrary(file: legacy).status(for: 99) == nil)
    }

    @MainActor static func independentCache(_ directory: URL, _ anime: Anime, _ sparse: Anime) throws {
        let legacy = directory.appendingPathComponent("favorites.json")
        let authority = directory.appendingPathComponent("library.json")
        let cache = directory.appendingPathComponent("CatalogCache")
        let detailFile = cache.appendingPathComponent("42.detail.json")
        let episodeFile = cache.appendingPathComponent("42.episodes.json")
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let secondDate = Date(timeIntervalSince1970: 1_700_000_100)
        // Duplicate visible numbers across distinct IDs/types, plus fractional sort, must survive exactly.
        let episodes = [
            CatalogEpisode(id: 9003, type: 1, sort: 1, ep: 1, name: "SP", name_cn: "特別篇", airdate: nil),
            CatalogEpisode(id: 9001, type: 0, sort: 1, ep: nil, name: "Main", name_cn: nil, airdate: "2020-01-01"),
            CatalogEpisode(id: 9002, type: 0, sort: 1.5, ep: 1, name: "Fraction", name_cn: "", airdate: "2099-01-01"),
            CatalogEpisode(id: 9004, type: 2, sort: 1, ep: 1, name: "OP", name_cn: nil, airdate: nil)
        ]
        let library = MobileLibrary(file: legacy)
        library.toggle(anime)
        library.setStatus(.doing, for: anime)
        let authorityBytes = try Data(contentsOf: authority)
        library.cacheDetail(anime, fetchedAt: firstDate)
        library.cacheEpisodes(episodes, for: anime.id, fetchedAt: secondDate)
        let restored = MobileLibrary(file: legacy)
        precondition(restored.cachedDetail(for: anime.id)?.anime == anime)
        precondition(restored.cachedDetail(for: anime.id)?.fetchedAt == firstDate)
        precondition(restored.cachedEpisodes(for: anime.id)?.episodes == episodes)
        precondition(restored.cachedEpisodes(for: anime.id)?.fetchedAt == secondDate)
        precondition(restored.cachedDetail(for: sparse.id) == nil && restored.cachedEpisodes(for: sparse.id) == nil)
        let detailBytes = try Data(contentsOf: detailFile)
        let episodeBytes = try Data(contentsOf: episodeFile)
        restored.cacheEpisodes([episodes[0], episodes[0]], for: anime.id, fetchedAt: firstDate)
        precondition(restored.cacheError && tryRead(episodeFile) == episodeBytes)
        restored.cacheDetail(anime, fetchedAt: Date(timeIntervalSinceReferenceDate: .infinity))
        precondition(restored.cacheError && tryRead(detailFile) == detailBytes)
        let broken = Data("broken disposable cache".utf8)
        try broken.write(to: detailFile)
        let damaged = MobileLibrary(file: legacy)
        precondition(damaged.cachedDetail(for: anime.id) == nil && damaged.cacheError)
        precondition(damaged.cachedEpisodes(for: anime.id)?.episodes == episodes)
        precondition(damaged.favorites == [anime] && damaged.status(for: anime.id) == .doing)
        precondition(!damaged.storageError && damaged.isReadable && tryRead(detailFile) == broken)
        damaged.cacheDetail(anime, fetchedAt: secondDate)
        precondition(damaged.cachedDetail(for: anime.id)?.fetchedAt == secondDate)
        precondition(tryRead(authority) == authorityBytes)
        // Subject envelopes and embedded details are independently checked; rejected bytes stay untouched.
        var wrongSubject = try jsonObject(detailFile)
        wrongSubject["subjectID"] = sparse.id
        let wrongSubjectBytes = try JSONSerialization.data(withJSONObject: wrongSubject)
        try wrongSubjectBytes.write(to: detailFile)
        precondition(damaged.cachedDetail(for: anime.id) == nil && tryRead(detailFile) == wrongSubjectBytes)
        var wrongDetail = try JSONSerialization.jsonObject(with: detailBytes) as! [String: Any]
        var value = wrongDetail["value"] as! [String: Any]
        var embedded = value["anime"] as! [String: Any]
        embedded["id"] = sparse.id
        value["anime"] = embedded
        wrongDetail["value"] = value
        let wrongDetailBytes = try JSONSerialization.data(withJSONObject: wrongDetail)
        try wrongDetailBytes.write(to: detailFile)
        precondition(damaged.cachedDetail(for: anime.id) == nil && tryRead(detailFile) == wrongDetailBytes)
        try broken.write(to: episodeFile)
        let independentlyDamaged = MobileLibrary(file: legacy)
        precondition(independentlyDamaged.cachedEpisodes(for: anime.id) == nil)
        independentlyDamaged.cacheDetail(anime, fetchedAt: firstDate)
        precondition(independentlyDamaged.cachedDetail(for: anime.id)?.anime == anime)
        precondition(independentlyDamaged.favorites == [anime] && independentlyDamaged.status(for: anime.id) == .doing)
        independentlyDamaged.cacheEpisodes(episodes, for: anime.id, fetchedAt: secondDate)
        precondition(MobileLibrary(file: legacy).cachedEpisodes(for: anime.id)?.episodes == episodes)
        precondition(tryRead(authority) == authorityBytes)
        var invalidEpisodes = try jsonObject(episodeFile)
        var episodeValue = invalidEpisodes["value"] as! [String: Any]
        var episodeValues = episodeValue["episodes"] as! [[String: Any]]
        episodeValues[0]["sort"] = -1
        episodeValue["episodes"] = episodeValues
        invalidEpisodes["value"] = episodeValue
        let invalidEpisodeBytes = try JSONSerialization.data(withJSONObject: invalidEpisodes)
        try invalidEpisodeBytes.write(to: episodeFile)
        precondition(independentlyDamaged.cachedEpisodes(for: anime.id) == nil)
        precondition(tryRead(episodeFile) == invalidEpisodeBytes)
        var futureEpisodes = try JSONSerialization.jsonObject(with: episodeBytes) as! [String: Any]
        futureEpisodes["version"] = 999
        let futureEpisodeBytes = try JSONSerialization.data(withJSONObject: futureEpisodes)
        try futureEpisodeBytes.write(to: episodeFile)
        precondition(independentlyDamaged.cachedEpisodes(for: anime.id) == nil)
        precondition(tryRead(episodeFile) == futureEpisodeBytes)
        independentlyDamaged.cacheEpisodes(episodes, for: anime.id, fetchedAt: secondDate)
        // Cache writes still work with a corrupt authority and cannot repair/overwrite that authority.
        try broken.write(to: authority)
        let unreadable = MobileLibrary(file: legacy)
        unreadable.cacheDetail(sparse, fetchedAt: firstDate)
        precondition(unreadable.cachedDetail(for: sparse.id)?.anime == sparse)
        precondition(!unreadable.isReadable && unreadable.storageError && tryRead(authority) == broken)
        // Conversely, cache write failure cannot roll back or block a library transaction.
        try authorityBytes.write(to: authority)
        let blockedCache = directory.appendingPathComponent("blocked-cache")
        try Data("not a directory".utf8).write(to: blockedCache)
        let cacheWriteFailure = MobileLibrary(file: legacy, cacheDirectory: blockedCache)
        cacheWriteFailure.cacheEpisodes(episodes, for: anime.id, fetchedAt: firstDate)
        precondition(cacheWriteFailure.cacheError && !cacheWriteFailure.storageError)
        cacheWriteFailure.setStatus(.onHold, for: anime)
        precondition(!cacheWriteFailure.storageError && MobileLibrary(file: legacy).status(for: anime.id) == .onHold)
        precondition(tryRead(blockedCache) == Data("not a directory".utf8))
    }

    @MainActor static func versionOneUpgrade(_ directory: URL, _ anime: Anime, _ sparse: Anime) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = directory.appendingPathComponent("favorites.json")
        let authority = directory.appendingPathComponent("library.json")
        let stage = authority.appendingPathExtension("staged")
        let favorites = try JSONSerialization.jsonObject(with: JSONEncoder().encode([sparse, anime, sparse]))
        let works: [[String: Any]] = [
            ["id": "bangumi:43", "subjectID": 43],
            ["id": "bangumi:42", "subjectID": 42, "createdAt": 12345.0, "status": 3]
        ]
        let original = try JSONSerialization.data(withJSONObject: ["version": 1, "favorites": favorites, "works": works])
        try original.write(to: authority)
        try Data("legacy is no longer authority".utf8).write(to: legacy)
        try manager.createDirectory(at: stage, withIntermediateDirectories: false)
        let failed = MobileLibrary(file: legacy)
        precondition(!failed.isReadable && failed.storageError && failed.favorites.isEmpty)
        precondition(tryRead(authority) == original)
        let backup = authority.appendingPathExtension("v1.backup")
        precondition(tryRead(backup) == original)
        failed.toggle(anime)
        precondition(tryRead(authority) == original)
        try manager.removeItem(at: stage)
        failed.retryLoad()
        precondition(failed.isReadable && !failed.storageError && failed.favorites == [sparse, anime, sparse])
        precondition(failed.status(for: 42) == .doing && failed.status(for: 43) == nil)
        let upgraded = try jsonObject(authority)
        precondition(upgraded["version"] as? Int == 3 && (upgraded["mappings"] as! [Any]).isEmpty)
        precondition((upgraded["favorites"] as! NSArray).isEqual(favorites))
        let upgradedWorks = upgraded["works"] as! [[String: Any]]
        for (index, originalWork) in works.enumerated() {
            for (key, value) in originalWork {
                precondition((upgradedWorks[index][key] as! NSObject) == (value as! NSObject))
            }
        }
        precondition(failed.unassignedCollectionCount == 1)
        precondition(tryRead(backup) == original)
        let restarted = MobileLibrary(file: legacy)
        precondition(restarted.favorites == failed.favorites && restarted.status(for: 42) == .doing)
        let firstMapping = mappingFixture()
        try restarted.saveMapping(firstMapping)
        precondition(restarted.mapping(for: firstMapping.context.work, episode: firstMapping.context.episode) == firstMapping)
        precondition(tryRead(backup) == original)
    }

    static func mappingFixture(workID: Int = 42, episodeID: Int = 901, type: Int = 0,
                               sort: Double = 1.25, season: String = "season-one", line: String = "1") -> ConfirmedSourceMapping {
        let selection = PlayableSelection(
            item: SourceItemRef(sourceID: "fixture", pageURL: "https://fixture.invalid/details/\(season)", kind: .work),
            episode: SourceItemRef(sourceID: "fixture", pageURL: "https://fixture.invalid/details/\(season)?file=episode.mp4", kind: .episode),
            lineID: line, qualityID: "HD", classification: .unknown)
        return ConfirmedSourceMapping(context: PlaybackContext(
            work: .bangumi(workID), episode: .bangumi(episodeID, type: type, sort: sort),
            selection: selection, configurationRevision: "sha256:" + String(repeating: "a", count: 64)),
            sourceTitle: "Same title", confirmedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @MainActor static func durableMappings(_ directory: URL, _ anime: Anime, _ sparse: Anime) throws {
        let manager = FileManager.default
        let legacy = directory.appendingPathComponent("favorites.json")
        let authority = directory.appendingPathComponent("library.json")
        let stage = authority.appendingPathExtension("staged")
        let mapping = mappingFixture()
        let work = mapping.context.work
        let episode = mapping.context.episode
        let library = MobileLibrary(file: legacy)
        library.toggle(anime)
        library.setStatus(.doing, for: anime)
        try library.saveMapping(mapping)
        let sameTitleOtherSeason = mappingFixture(workID: 43, episodeID: 901, season: "season-two")
        let special = mappingFixture(episodeID: 902, type: 1, sort: 1.25)
        try library.saveMapping(sameTitleOtherSeason)
        try library.saveMapping(special)
        precondition(library.mapping(for: work, episode: episode) == mapping)
        precondition(library.mapping(for: sameTitleOtherSeason.context.work, episode: episode) == sameTitleOtherSeason)
        precondition(library.mapping(for: work, episode: special.context.episode) == special)
        let changedMetadata = PlaybackEpisodeIdentity.bangumi(901, type: 1, sort: 1.5)
        precondition(library.mapping(for: work, episode: changedMetadata) == nil)
        precondition(library.storedMapping(for: work, episode: changedMetadata) == mapping)
        precondition(library.storedMapping(for: work, episode: .bangumi(903, type: 0, sort: 1.25)) == nil)
        library.toggle(anime)
        library.cacheDetail(anime)
        library.cacheEpisodes([], for: anime.id)
        try manager.removeItem(at: directory.appendingPathComponent("CatalogCache"))
        let restarted = MobileLibrary(file: legacy)
        precondition(!restarted.contains(anime) && restarted.status(for: anime.id) == .doing)
        precondition(restarted.mapping(for: work, episode: episode) == mapping)
        precondition(restarted.cachedDetail(for: anime.id) == nil)

        let originalBytes = try Data(contentsOf: authority)
        let replacement = mappingFixture(line: "2")
        try manager.createDirectory(at: stage, withIntermediateDirectories: false)
        expectFailure { try restarted.saveMapping(replacement) }
        precondition(restarted.storageError && restarted.mapping(for: work, episode: episode) == mapping)
        expectFailure { try restarted.removeMapping(for: work, episode: episode) }
        expectFailure { try restarted.invalidateMapping(for: work, episode: episode, failure: .missingEpisode) }
        precondition(restarted.mappingFailure(for: work, episode: episode) == nil)
        precondition(restarted.mapping(for: work, episode: episode) == mapping && tryRead(authority) == originalBytes)
        precondition(MobileLibrary(file: legacy).mapping(for: work, episode: episode) == mapping)
        try manager.removeItem(at: stage)
        try restarted.invalidateMapping(for: work, episode: episode, failure: .missingEpisode)
        let invalidated = MobileLibrary(file: legacy)
        precondition(invalidated.mappingFailure(for: work, episode: changedMetadata) == .missingEpisode)
        precondition(invalidated.mapping(for: work, episode: episode) == mapping)
        try invalidated.saveMapping(replacement)
        precondition(invalidated.mappingFailure(for: work, episode: episode) == nil)
        precondition(invalidated.mapping(for: work, episode: episode) == replacement)
        try invalidated.invalidateMapping(for: work, episode: episode, failure: .configurationChanged)
        let changedConfiguration = MobileLibrary(file: legacy)
        precondition(changedConfiguration.mappingFailure(for: work, episode: episode) == .configurationChanged)
        precondition(changedConfiguration.mapping(for: work, episode: episode) == replacement)
        try changedConfiguration.saveMapping(replacement)
        precondition(changedConfiguration.mappingFailure(for: work, episode: episode) == nil)
        let preferred = MobileLibrary(file: legacy)
        precondition(preferred.mapping(for: work, episode: episode) == replacement)
        precondition(preferred.mapping(for: work, episode: special.context.episode) == special)

        let saved = try Data(contentsOf: authority)
        let base = try jsonObject(authority)
        var missingMappings = base
        missingMappings.removeValue(forKey: "mappings")
        var future = base
        future["version"] = 999
        var duplicate = base
        var entries = base["mappings"] as! [[String: Any]]
        entries.append(entries[0])
        duplicate["mappings"] = entries
        for broken in [Data("broken mapping authority".utf8),
                       try JSONSerialization.data(withJSONObject: missingMappings),
                       try JSONSerialization.data(withJSONObject: future),
                       try JSONSerialization.data(withJSONObject: duplicate)] {
            try broken.write(to: authority)
            try JSONEncoder().encode([sparse]).write(to: legacy)
            let blocked = MobileLibrary(file: legacy)
            precondition(!blocked.isReadable && blocked.storageError && blocked.favorites.isEmpty)
            expectFailure { try blocked.saveMapping(mapping) }
            expectFailure { try blocked.removeMapping(for: work, episode: episode) }
            precondition(tryRead(authority) == broken)
            preferred.retryLoad()
            precondition(!preferred.isReadable && preferred.mapping(for: work, episode: episode) == replacement)
            expectFailure { try preferred.saveMapping(mapping) }
            precondition(tryRead(authority) == broken)
            try saved.write(to: authority)
            preferred.retryLoad()
            precondition(preferred.isReadable && preferred.mapping(for: work, episode: episode) == replacement)
        }

        for invalid in [
            mutatedMapping(mapping) { $0.accountID = UUID() },
            mutatedMapping(mapping) { $0.episode = SourceItemRef(sourceID: "fixture", pageURL: "https://fixture.invalid/details/season-one?token=not-a-real-token", kind: .episode) },
            mutatedMapping(mapping) { $0.episode = SourceItemRef(sourceID: "fixture", pageURL: "https://fixture.invalid/video.mp4", kind: .episode) },
            mutatedMapping(mapping) { $0.episode = SourceItemRef(sourceID: "fixture", pageURL: "https://fixture.invalid/details/season-one?file=episode.mp4&utm_source=fixture", kind: .episode) },
            mutatedMapping(mapping) { $0.episode = SourceItemRef(sourceID: "foreign", pageURL: "https://fixture.invalid/details/season-one?file=episode.mp4", kind: .episode) }
        ] {
            expectFailure { try preferred.saveMapping(invalid) }
            precondition(preferred.mapping(for: work, episode: episode) == replacement && tryRead(authority) == saved)
            var corrupt = base
            var corruptEntries = base["mappings"] as! [[String: Any]]
            corruptEntries[0]["mapping"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(invalid))
            corrupt["mappings"] = corruptEntries
            let unsafeBytes = try JSONSerialization.data(withJSONObject: corrupt)
            try unsafeBytes.write(to: authority)
            let rejected = MobileLibrary(file: legacy)
            precondition(!rejected.isReadable && rejected.storageError)
            expectFailure { try rejected.saveMapping(mapping) }
            precondition(tryRead(authority) == unsafeBytes)
            try saved.write(to: authority)
        }
        try preferred.removeMapping(for: work, episode: episode)
        let removed = MobileLibrary(file: legacy)
        precondition(removed.mapping(for: work, episode: episode) == nil)
        precondition(removed.mapping(for: work, episode: special.context.episode) == special)
        precondition(removed.mapping(for: sameTitleOtherSeason.context.work, episode: episode) == sameTitleOtherSeason)
        let encoded = String(decoding: saved, as: UTF8.self)
        precondition(!encoded.contains("accountID") && !encoded.contains("mediaURL") && !encoded.contains("streamURL"))
    }

    static func mutatedMapping(_ mapping: ConfirmedSourceMapping,
                               mutation: (inout PlayableSelection) -> Void) -> ConfirmedSourceMapping {
        var selection = mapping.context.selection
        mutation(&selection)
        return ConfirmedSourceMapping(context: PlaybackContext(work: mapping.context.work, episode: mapping.context.episode,
            selection: selection, configurationRevision: mapping.context.configurationRevision),
            sourceTitle: mapping.sourceTitle, confirmedAt: mapping.confirmedAt)
    }

    static func expectFailure(_ operation: () throws -> Void) {
        do {
            try operation()
            preconditionFailure("Unsafe or failed transaction unexpectedly succeeded")
        } catch {}
    }

    static func decodeAnime(_ json: String) throws -> Anime {
        try JSONDecoder().decode(Anime.self, from: Data(json.utf8))
    }

    static func tryRead(_ file: URL) -> Data? { try? Data(contentsOf: file) }

    static func jsonObject(_ file: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
    }

    static func tryDecodeRoundTrip(_ anime: Anime) -> Anime? {
        guard let encoded = try? JSONEncoder().encode(anime) else { return nil }
        return try? JSONDecoder().decode(Anime.self, from: encoded)
    }
}
