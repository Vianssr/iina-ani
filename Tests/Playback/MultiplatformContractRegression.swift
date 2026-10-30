import Foundation

/// Compiled from these same shared sources for macOS and the iOS simulator.
@main
struct MultiplatformContractRegression {
    struct Failure: Error { let message: String }

    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(message: message) }
    }

    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
        try identities()
        try bangumiAndContext()
        try collectionStatuses()
        let fixtures = [
            "IINA-ANI/Sources/fqdm.json",
            "Examples/MobileSources/internet-archive.json"
        ]
        for path in fixtures {
            let data = try Data(contentsOf: root.appendingPathComponent(path))
            try configuration(data)
            try configuredIdentities(data)
        }
        for path in fixtures {
            try confirmedMappings(Data(contentsOf: root.appendingPathComponent(path)))
        }
        print("PASS: shared identities, raw Bangumi metadata, exact confirmed mappings, safe configured identities, revisions, platform capabilities, errors and collection statuses")
    }

    static func collectionStatuses() throws {
        let statuses = BangumiCollectionStatus.displayOrder
        try require(statuses == [.wish, .doing, .collected, .onHold, .dropped] &&
                    statuses.map(\.rawValue) == [1, 3, 2, 4, 5] &&
                    Set(statuses) == Set(BangumiCollectionStatus.allCases),
                    "Shared status names, display order and persisted Bangumi raw values must stay compatible")
        let values: [BangumiCollectionStatus?] = [nil] + statuses.map { Optional($0) }
        let encoded = try JSONEncoder().encode(values)
        let decoded = try JSONDecoder().decode([BangumiCollectionStatus?].self, from: encoded)
        try require(String(decoding: encoded, as: UTF8.self) == "[null,1,3,2,4,5]" &&
                    decoded == values,
                    "Every status and unclassified nil must round-trip as the existing integer wire contract")
        try require(values.allSatisfy { CollectionStatusFilter.all.matches($0) },
                    "All classifications must include unclassified works")
        try require(values.filter { CollectionStatusFilter.unclassified.matches($0) } == [nil],
                    "Unclassified must match only nil, never a guessed wish status")
        for status in statuses {
            try require(values.filter { CollectionStatusFilter.status(status).matches($0) } == [status],
                        "A status filter must match exactly its category and exclude unclassified works")
        }
        let filters = Set<CollectionStatusFilter>([.all, .unclassified] + statuses.map { .status($0) })
        try require(filters.count == 7, "All, unclassified and five status filters must have distinct identities")
        do {
            _ = try JSONDecoder().decode(BangumiCollectionStatus.self, from: Data("6".utf8))
            throw Failure(message: "Unknown status must not silently become a valid category")
        } catch is DecodingError { }
    }

    static func identities() throws {
        struct Fixture {
            let source: String
            let work: String
            let episode: String
        }
        let fixtures = [
            Fixture(source: "a:b", work: "c", episode: "d"),
            Fixture(source: "a", work: "b:c", episode: "d"),
            Fixture(source: "a", work: "b", episode: "c:d"),
            Fixture(source: "a", work: "b", episode: "c|d"),
            Fixture(source: "a|b", work: "c", episode: "d"),
            Fixture(source: "a", work: "season-one", episode: "1"),
            Fixture(source: "a", work: "season-two", episode: "1"),
            Fixture(source: "b", work: "season-one", episode: "1"),
            Fixture(source: "a", work: "season-one", episode: "2"),
            Fixture(source: "源", work: "季度:一", episode: "特別篇|1.5")
        ]
        let episodes = fixtures.map {
            PlaybackEpisodeIdentity.source(sourceID: $0.source, workID: $0.work, episodeID: $0.episode)
        }
        try require(Set(episodes.map(\.localID)).count == fixtures.count,
                    "Source/work/season/episode or delimiter identities collided")
        try require(PlaybackWorkIdentity.source(sourceID: "a:b", workID: "c") !=
                    PlaybackWorkIdentity.source(sourceID: "a", workID: "b:c"), "Work framing collision")
        try require(PlaybackWorkIdentity.source(sourceID: "源", workID: "一").localID ==
                    "source-work:v1:3:源3:一", "Identity framing must use UTF-8 byte counts on both platforms")
        try require(episodes.allSatisfy { $0.bangumiID == nil && $0.type == nil && $0.sort == nil },
                    "Unassociated source episodes must not invent Bangumi metadata")
        let work = SourceItemRef(sourceID: "source", pageURL: "https://fixture.invalid/season/one", kind: .work)
        let episode = SourceItemRef(sourceID: "source", pageURL: "https://fixture.invalid/episode/1", kind: .episode)
        let otherSeason = SourceItemRef(sourceID: "source", pageURL: "https://fixture.invalid/season/two", kind: .work)
        let foreign = SourceItemRef(sourceID: "foreign", pageURL: episode.pageURL, kind: .episode)
        try require(PlaybackEpisodeIdentity.source(work: work, episode: episode) !=
                    PlaybackEpisodeIdentity.source(work: otherSeason, episode: episode), "Native page IDs need season scope")
        try require(PlaybackEpisodeIdentity.source(work: work, episode: episode) !=
                    PlaybackEpisodeIdentity.source(work: work, episode: foreign), "Native page IDs need both source scopes")
    }

    static func bangumiAndContext() throws {
        let work = PlaybackWorkIdentity.bangumi(42)
        let normal = PlaybackEpisodeIdentity.bangumi(101, type: 0, sort: 1.25)
        let special = PlaybackEpisodeIdentity.bangumi(102, type: 1, sort: 1.25)
        try require(work.localID == "bangumi-work:v1:2:42" && work.bangumiID == 42,
                    "Bangumi work IDs must be deterministic")
        try require(normal.localID == "bangumi-episode:v1:3:101" && normal.bangumiID == 101 &&
                    normal.type == 0 && normal.sort == 1.25, "Bangumi episode metadata was rounded or lost")
        try require(normal.localID != special.localID && special.type == 1,
                    "SP and normal episodes with identical displayed sort must not collide")
        try require(PlaybackEpisodeIdentity.bangumi(101, type: nil, sort: nil).localID == normal.localID,
                    "Missing or refreshed presentation metadata cannot change a Bangumi episode ID")
        let selection = PlayableSelection(
            item: SourceItemRef(sourceID: "fixture", pageURL: "https://fixture.invalid/work/42", kind: .work),
            episode: SourceItemRef(sourceID: "fixture", pageURL: "https://fixture.invalid/work/42/episode/101", kind: .episode),
            lineID: "line:2", qualityID: "HD", classification: MediaClassification(kind: .anime, provenance: "fixture"))
        let context = PlaybackContext(work: work, episode: normal, selection: selection, configurationRevision: "fixture-revision")
        let encoded = try JSONEncoder().encode(context)
        try require(try JSONDecoder().decode(PlaybackContext.self, from: encoded) == context,
                    "Playback context must retain all exact source, line, quality, revision and requested IDs")
        let json = String(decoding: encoded, as: UTF8.self)
        try require(!json.contains("mediaURL") && !json.contains("streamURL") && !json.contains("title"),
                    "Durable context must not contain presentation titles or resolved media input")
    }

    static func configuration(_ data: Data) throws {
        let original = try SourceConfiguration.load(data: data)
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        func load(_ root: [String: Any], options: JSONSerialization.WritingOptions = []) throws -> SourceConfiguration {
            try SourceConfiguration.load(data: JSONSerialization.data(withJSONObject: root, options: options))
        }
        try require(try load(root, options: [.sortedKeys, .prettyPrinted]).configurationRevision == original.configurationRevision,
                    "JSON object key order or whitespace changed the configuration revision")
        var reordered = root
        reordered["capabilities"] = (root["capabilities"] as! [String]).reversed().map { $0 }
        try require(try load(reordered).configurationRevision == original.configurationRevision,
                    "Declared capability set order changed the revision")
        var defaults = root
        defaults.removeValue(forKey: "credentialHosts")
        if original.mediaHosts.isEmpty { defaults.removeValue(forKey: "mediaHosts") }
        try require(try load(defaults).configurationRevision == original.configurationRevision,
                    "Omitted optional default content changed the revision")

        func changed(_ root: [String: Any], _ label: String) throws {
            try require(try load(root).configurationRevision != original.configurationRevision,
                        "Configuration revision omitted " + label)
        }
        var hosts = root
        hosts["hosts"] = original.hosts + ["additional.invalid"]
        try changed(hosts, "hosts")
        for (field, value) in [
            ("pattern", original.route.pattern + "$"),
            ("detailTemplate", original.route.detailTemplate + "?edition=2"),
            ("queryIdentityParameter", "different_identity")
        ] {
            var changedRoot = root
            var route = root["route"] as! [String: Any]
            route[field] = value
            changedRoot["route"] = route
            try changed(changedRoot, "route." + field)
        }
        var catalogRoot = root
        var catalog = root["catalog"] as! [String: Any]
        catalog[original.catalog.format == "html" ? "titleSelector" : "jsonTitlePath"] = "changed-title-rule"
        catalogRoot["catalog"] = catalog
        try changed(catalogRoot, "catalog rules")
        var playerRoot = root
        var player = root["player"] as! [String: Any]
        player["allowedExtensions"] = original.player.allowedExtensions + ["mkv"]
        playerRoot["player"] = player
        try changed(playerRoot, "player rules")
        var searchRoot = root
        var search = root["search"] as! [String: Any]
        search["rowsPerPage"] = original.search!.rowsPerPage + 1
        searchRoot["search"] = search
        try changed(searchRoot, "search rules")

        let mobile = original.effectiveCapabilities(on: .iOS)
        let desktop = original.effectiveCapabilities(on: .macOS)
        let forbidden: Set<SourceCapability> = [.iina, .jsPlayer, .danmaku, .download, .browse, .quality]
        try require(mobile.isDisjoint(with: forbidden), "Declarations enabled an unimplemented mobile backend")
        try require(mobile.isSubset(of: original.capabilities) && desktop.isSubset(of: original.capabilities),
                    "Effective capabilities must never exceed declarations")
        try require(mobile.contains(.mpv) && desktop.contains(.iina) && desktop.contains(.download),
                    "Intersection removed supported fixture backend capabilities")
        var noMPV = root
        noMPV["capabilities"] = (root["capabilities"] as! [String]).filter { $0 != "mpv" }
        try require(try !load(noMPV).effectiveCapabilities(on: .iOS).contains(.mpv), "Backend support invented a declaration")
        if original.capabilities.contains(.lines) {
            var qualityRoot = root
            qualityRoot["capabilities"] = (root["capabilities"] as! [String]) + ["quality"]
            let quality = try load(qualityRoot)
            try require(!quality.effectiveCapabilities(on: .macOS).contains(.quality) &&
                        !quality.effectiveCapabilities(on: .iOS).contains(.quality), "Line streams invented independent quality selection")
        }
        var invalid = root
        invalid["configurationRevision"] = "not-a-v1-field"
        do {
            _ = try load(invalid)
            throw Failure(message: "Revision leaked into the strict version-1 schema")
        } catch SourceConfiguration.ConfigurationError.invalidConfiguration {}
        for capability in ["browse", "jsPlayer", "danmaku"] {
            var unsupported = root
            unsupported["capabilities"] = (root["capabilities"] as! [String]) + [capability]
            do {
                _ = try load(unsupported)
                throw Failure(message: "Existing unsupported configuration validation was relaxed")
            } catch is SourceConfiguration.ConfigurationError {}
        }
    }

    static func configuredIdentities(_ data: Data) throws {
        let config = try SourceConfiguration.load(data: data)
        let urls: [String]
        if config.id == "fqdm" {
            urls = [
                "https://www.fqdm.cc/index.php/vod/play/id/42/sid/1/nid/1.html",
                "https://www.fqdm.cc/index.php/vod/play/id/42/sid/2/nid/1.html",
                "https://www.fqdm.cc/index.php/vod/play/id/43/sid/1/nid/1.html",
                "https://www.fqdm.cc/index.php/vod/play/id/42/sid/1/nid/2.html"
            ]
        } else {
            urls = [
                "https://archive.org/details/season-one?file=episode%3A1.mp4",
                "https://archive.org/details/season-one?file=episode%3A1.mp4",
                "https://archive.org/details/season-two?file=episode%3A1.mp4",
                "https://archive.org/details/season-one?file=episode%3A2.mp4"
            ]
        }
        let identities = try urls.map { url -> PlaybackEpisodeIdentity in
            let parts = try config.parts(url)
            guard let episode = parts.episodeIdentity else { throw Failure(message: "Missing fixture source episode identity") }
            return .source(sourceID: config.id, workID: parts.id, episodeID: episode)
        }
        try require(identities[0] == identities[1], "Delivery lines must not invent a different domain episode")
        try require(identities[0] != identities[2] && identities[0] != identities[3],
                    "Configured identity collided across seasons or episodes")
    }

    static func confirmedMappings(_ data: Data) throws {
        let config = try SourceConfiguration.load(data: data)
        let isFile = config.route.queryIdentityParameter != nil
        let workURL = isFile ? "https://archive.org/details/season-one" :
            "https://www.fqdm.cc/index.php/vod/detail/id/42.html"
        let episodeURL = isFile ? workURL + "?file=episode%201.mp4" :
            "https://www.fqdm.cc/index.php/vod/play/id/42/sid/2/nid/1.html"
        let work = try config.item(workURL)
        let episode = try config.item(episodeURL)
        let selection = PlayableSelection(item: work, episode: episode, lineID: "2", qualityID: "HD",
            accountID: UUID(), classification: MediaClassification(kind: .unknown, provenance: "untrusted"))
        let canonical = try config.mappingSelection(selection)
        try require(canonical.accountID == nil && canonical.torrent == nil &&
                    canonical.item == work && canonical.episode == episode &&
                    canonical.lineID == "2" && canonical.qualityID == "HD" &&
                    canonical.classification == config.classification,
                    "Canonicalization must retain source/work/episode/line/quality, strip account and use configured classification")
        var decorated = selection
        decorated.item = SourceItemRef(sourceID: config.id, pageURL: workURL + "?utm_source=fixture&token=fixture-only#tracking", kind: .work)
        decorated.episode = SourceItemRef(sourceID: config.id,
            pageURL: episodeURL + (isFile ? "&" : "?") + "utm_campaign=fixture&access_token=fixture-only#tracking", kind: .episode)
        try require(try config.mappingSelection(decorated) == canonical,
                    "Tracking, credential query values and fragments must never enter a mapping")
        let domainWork = PlaybackWorkIdentity.bangumi(42)
        let domainEpisode = PlaybackEpisodeIdentity.bangumi(901, type: 0, sort: 1.25)
        let mapping = ConfirmedSourceMapping(context: PlaybackContext(work: domainWork, episode: domainEpisode,
            selection: canonical, configurationRevision: config.configurationRevision),
            sourceTitle: "Same title", confirmedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try mapping.validateForPersistence()
        let bytes = try JSONEncoder().encode(mapping)
        try require(try JSONDecoder().decode(ConfirmedSourceMapping.self, from: bytes) == mapping,
                    "Confirmed mapping must roundtrip independently of transient mutable selection input")
        var confirmedAnime = canonical
        confirmedAnime.classification = MediaClassification(kind: .anime, provenance: "bangumi.subject.type=2")
        func classifiedMapping(_ selection: PlayableSelection) -> ConfirmedSourceMapping {
            ConfirmedSourceMapping(context: PlaybackContext(work: domainWork, episode: domainEpisode,
                selection: selection, configurationRevision: config.configurationRevision), sourceTitle: "Anime")
        }
        let classified = classifiedMapping(confirmedAnime)
        try classified.validateForPersistence()
        let restored = try JSONDecoder().decode(ConfirmedSourceMapping.self, from: JSONEncoder().encode(classified))
        try require(restored.context.selection.classification == confirmedAnime.classification,
                    "Durable confirmed mappings must preserve real Bangumi classification evidence")
        for unsafe in ["", "https://fixture.invalid/?token=private", "type=2&token=private",
                       "type=2\nprivate", String(repeating: "x", count: 257)] {
            var invalid = confirmedAnime
            invalid.classification.provenance = unsafe
            do {
                try classifiedMapping(invalid).validateForPersistence()
                throw Failure(message: "Unsafe classification evidence entered durable mapping")
            } catch PlaybackFailure.unsupportedResponse {}
        }
        var unsafeQuality = confirmedAnime
        unsafeQuality.qualityID = "token=private"
        do {
            try classifiedMapping(unsafeQuality).validateForPersistence()
            throw Failure(message: "Classification evidence rules weakened source quality label validation")
        } catch PlaybackFailure.unsupportedResponse {}
        try require(mapping.matches(work: domainWork, episode: domainEpisode), "Exact mapping failed to match")
        for other in [
            PlaybackEpisodeIdentity.bangumi(902, type: 0, sort: 1.25),
            .bangumi(901, type: 1, sort: 1.25),
            .bangumi(901, type: 0, sort: 1.5),
            .bangumi(901, type: nil, sort: nil)
        ] {
            try require(!mapping.matches(work: domainWork, episode: other),
                        "Visible sort, reused ID, SP or missing raw metadata silently reused a confirmed mapping")
        }
        try require(!mapping.matches(work: .bangumi(43), episode: domainEpisode),
                    "Same-title seasons must not share a confirmed mapping")
        let storedText = String(decoding: bytes, as: UTF8.self)
        try require(!storedText.contains("accountID") && !storedText.contains("token") &&
                    !storedText.contains("utm_") && !storedText.contains("mediaURL"),
                    "Persisted mapping contains transient/credential input")
        if isFile {
            try require(canonical.episode?.pageURL == episodeURL, "Configured file identity was stripped")
            var filePunctuation = selection
            filePunctuation.episode = SourceItemRef(sourceID: config.id,
                pageURL: workURL + "?file=episode%3A1.mp4&utm_source=fixture", kind: .episode)
            let durableFile = try config.mappingSelection(filePunctuation)
            try require(try config.parts(durableFile.episode!.pageURL).episodeIdentity == "episode:1.mp4",
                        "Canonicalization changed the configured raw file identity")
        }

        func reject(_ candidate: PlayableSelection, _ label: String) throws {
            do {
                _ = try config.mappingSelection(candidate)
                throw Failure(message: "Unsafe mapping accepted: " + label)
            } catch is PlaybackFailure {}
        }
        var foreignSource = selection
        foreignSource.episode = SourceItemRef(sourceID: "other", pageURL: episodeURL, kind: .episode)
        try reject(foreignSource, "foreign source")
        var otherSeason = selection
        otherSeason.episode = SourceItemRef(sourceID: config.id,
            pageURL: episodeURL.replacingOccurrences(of: isFile ? "season-one" : "/id/42/",
                with: isFile ? "season-two" : "/id/43/"), kind: .episode)
        try reject(otherSeason, "other season")
        var missingEpisode = selection
        missingEpisode.episode = nil
        try reject(missingEpisode, "missing episode")
        var wrongKind = selection
        wrongKind.episode = SourceItemRef(sourceID: config.id, pageURL: episodeURL, kind: .video)
        try reject(wrongKind, "non-episode")
        var media = selection
        media.episode = SourceItemRef(sourceID: config.id, pageURL: "https://\(config.hosts[0])/media.mp4", kind: .episode)
        try reject(media, "resolved media URL")
        var userInfo = selection
        userInfo.episode = SourceItemRef(sourceID: config.id,
            pageURL: episodeURL.replacingOccurrences(of: "https://", with: "https://fixture-user:fixture-password@"), kind: .episode)
        try reject(userInfo, "userinfo")
        if !isFile {
            for line in [nil, "0", "1"] as [String?] {
                var desktopLine = selection
                desktopLine.lineID = line
                let durable = try config.mappingSelection(desktopLine)
                try require(durable.lineID == line && durable.episode == episode,
                            "Adapter-owned stream index must not be confused with route line identity")
            }
        } else {
            for suffix in ["&file=episode%201.mp4", "&file=another.mp4", "&file=", "&file"] {
                var duplicate = selection
                duplicate.episode = SourceItemRef(sourceID: config.id, pageURL: episodeURL + suffix, kind: .episode)
                try reject(duplicate, "duplicate file identity")
            }
            for query in ["file=", "file", "file=https%3A%2F%2Fcdn.invalid%2Fstream.mp4"] {
                var invalidFile = selection
                invalidFile.episode = SourceItemRef(sourceID: config.id, pageURL: workURL + "?" + query, kind: .episode)
                try reject(invalidFile, "invalid file identity")
            }
        }
        var torrent = selection
        torrent.torrent = TorrentSelection(infoHashes: ["v1:" + String(repeating: "a", count: 40)],
            fileIndex: 0, path: "episode.mp4", size: 100)
        try reject(torrent, "torrent selection")
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for parameter in ["token", "access_token", "Cookie", "auth", "api-key", "session_id", "signature", "utm_source"] {
            var unsafeRoot = root
            var route = root["route"] as! [String: Any]
            route["queryIdentityParameter"] = parameter
            unsafeRoot["route"] = route
            let unsafeConfig = try SourceConfiguration.load(data: JSONSerialization.data(withJSONObject: unsafeRoot))
            do {
                _ = try unsafeConfig.mappingSelection(selection)
                throw Failure(message: "Sensitive configured identity parameter was accepted")
            } catch PlaybackFailure.unsupportedResponse {}
        }
    }

}
